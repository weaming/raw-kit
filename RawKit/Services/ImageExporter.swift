import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

class ImageExporter {
    private static let defaultHDRExportHeadroom = 16.0
    private static let ultraHDRToolCandidates: [String?] = [
        Bundle.main.url(forResource: "ultrahdr_app", withExtension: nil)?.path,
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ultrahdr_app").path,
        "/opt/homebrew/bin/ultrahdr_app",
        "/usr/local/bin/ultrahdr_app",
    ]
    private static let avifFFmpegToolCandidates: [String?] = [
        Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path,
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffmpeg").path,
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]

    private static var exportContext: CIContext {
        CIContextManager.shared.getRenderContext()
    }

    static func export(
        imageInfo: ImageInfo,
        adjustments: ImageAdjustments,
        config: ExportConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.1)

        // 加载原始图片
        guard let originalImage = await ImageProcessor.loadCIImage(from: imageInfo.url) else {
            throw ExportError.failedToLoadImage
        }

        progress(0.3)

        // 应用调整
        let adjustedImage = ImageProcessor.applyAdjustments(
            to: originalImage,
            adjustments: adjustments
        )

        progress(0.5)

        // 调整尺寸
        let resizedImage: CIImage = if let maxDim = config.maxDimension {
            resizeImage(adjustedImage, maxDimension: maxDim)
        } else {
            adjustedImage
        }

        progress(0.7)

        // 确定输出路径
        let outputURL = determineOutputURL(for: imageInfo, config: config)
        try ensureOutputDirectoryExists(for: outputURL)

        // 导出
        try exportImage(
            resizedImage,
            to: outputURL,
            format: config.format,
            outputPreset: config.outputPreset,
            quality: config.quality,
            ultraHDRGainMapCompression: config.ultraHDRGainMapCompression,
            targetHDRHeadroom: resolveTargetHDRHeadroom(
                imageInfo: imageInfo,
                adjustments: adjustments,
                outputPreset: config.outputPreset
            )
        )

        progress(1.0)

        return outputURL
    }

    private static func ensureOutputDirectoryExists(for outputURL: URL) throws {
        let outputDirectory = outputURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ExportError.failedToCreateOutputDirectory(outputDirectory.path, error.localizedDescription)
        }
    }

    private static func resizeImage(_ image: CIImage, maxDimension: Int) -> CIImage {
        let extent = image.extent
        let width = extent.width
        let height = extent.height

        let maxDim = max(width, height)
        if maxDim <= CGFloat(maxDimension) {
            return image
        }

        let scale = CGFloat(maxDimension) / maxDim
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        return image.transformed(by: transform)
    }

    private static func determineOutputURL(for imageInfo: ImageInfo, config: ExportConfig) -> URL {
        let baseDirectory: URL = if let outputDir = config.outputDirectory {
            outputDir
        } else {
            imageInfo.url.deletingLastPathComponent()
        }

        let baseName = imageInfo.url.deletingPathExtension().lastPathComponent

        // 构建文件名：前缀 + 原始名 + 后缀 + 扩展名
        var fileName = ""
        if !config.prefix.isEmpty {
            fileName += config.prefix
        }
        fileName += baseName
        if !config.suffix.isEmpty {
            fileName += config.suffix
        }
        fileName += ".\(config.format.fileExtension)"

        let outputURL = baseDirectory.appendingPathComponent(fileName)

        return outputURL
    }

    private static func exportImage(
        _ image: CIImage,
        to url: URL,
        format: ExportFormat,
        outputPreset: ExportOutputPreset,
        quality: Double,
        ultraHDRGainMapCompression: UltraHDRGainMapCompression,
        targetHDRHeadroom: Float?
    ) throws {
        let context = exportContext
        let exportReadyImage = try prepareImageForExport(image)
        let cgColorSpace = getColorSpace(for: outputPreset)

        switch format {
        case .tiff:
            try exportTIFF(exportReadyImage, to: url, colorSpace: cgColorSpace, context: context)
        case .jpg:
            try exportJPEG(
                exportReadyImage,
                to: url,
                colorSpace: cgColorSpace,
                quality: quality,
                context: context
            )
        case .heif:
            try exportHEIF(
                exportReadyImage,
                to: url,
                colorSpace: cgColorSpace,
                quality: quality,
                targetHeadroom: targetHDRHeadroom,
                context: context
            )
        case .avif:
            try exportAVIF(
                exportReadyImage,
                to: url,
                colorSpace: cgColorSpace,
                outputPreset: outputPreset,
                quality: quality,
                targetHeadroom: targetHDRHeadroom,
                context: context
            )
        case .jpegGainMap:
            try exportJPEGGainMap(
                exportReadyImage,
                to: url,
                targetHeadroom: targetHDRHeadroom,
                quality: quality,
                context: context
            )
        case .ultraHDRJPEG:
            try exportUltraHDRJPEG(
                exportReadyImage,
                to: url,
                targetHeadroom: targetHDRHeadroom,
                quality: quality,
                compression: ultraHDRGainMapCompression,
                context: context
            )
        case .dng:
            try exportDNG(exportReadyImage, to: url, colorSpace: cgColorSpace, context: context)
        }
    }

    private static func prepareImageForExport(_ image: CIImage) throws -> CIImage {
        let extent = image.extent
        guard extent.isInfinite == false,
              extent.isEmpty == false,
              extent.origin.x.isFinite,
              extent.origin.y.isFinite,
              extent.width.isFinite,
              extent.height.isFinite else {
            throw ExportError.invalidImageExtent
        }

        let width = max(1, Int(extent.width.rounded()))
        let height = max(1, Int(extent.height.rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let translatedImage = image.clampedToExtent().transformed(
            by: CGAffineTransform(
                translationX: -extent.origin.x,
                y: -extent.origin.y
            )
        )

        let scaleX = CGFloat(width) / extent.width
        let scaleY = CGFloat(height) / extent.height
        return translatedImage
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: bounds)
    }

    private static func getColorSpace(for outputPreset: ExportOutputPreset) -> CGColorSpace {
        switch outputPreset {
        case .sdrSRGB:
            CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3SDR:
            CGColorSpace(name: CGColorSpace.displayP3)!
        case .displayP3HLGHDR:
            CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        case .rec2020HLGHDR:
            CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        case .rec2020PQHDR:
            CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        }
    }

    private static func exportTIFF(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        context: CIContext
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.failedToCreateDestination
        }

        // 使用 16-bit half float 格式以保留更多动态范围
        guard let cgImage = context.createCGImage(
            image,
            from: image.extent,
            format: .RGBAh,
            colorSpace: colorSpace
        )
        else {
            throw ExportError.failedToRenderImage
        }

        let properties: [String: Any] = [
            kCGImagePropertyTIFFCompression as String: 5,
            kCGImagePropertyHasAlpha as String: false,
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw ExportError.failedToFinalizeExport
        }
    }

    private static func exportJPEG(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        quality: Double,
        context: CIContext
    ) throws {
        let flattenedImage = makeOpaqueImageForJPEG(image)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.failedToCreateDestination
        }

        guard let cgImage = context.createCGImage(
            flattenedImage,
            from: flattenedImage.extent,
            format: .RGBX8,
            colorSpace: colorSpace
        ) else {
            throw ExportError.failedToRenderImage
        }

        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw ExportError.failedToFinalizeExport
        }
    }

    private static func makeOpaqueImageForJPEG(_ image: CIImage) -> CIImage {
        let bounds = image.extent
        let whiteBackground = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: bounds)

        return image
            .composited(over: whiteBackground)
            .cropped(to: bounds)
    }

    private static func exportHEIF(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        quality: Double,
        targetHeadroom: Float?,
        context: CIContext
    ) throws {
        let outputImage = normalizedHDRImage(image, targetHeadroom: targetHeadroom)

        try context.writeHEIF10Representation(
            of: outputImage,
            to: url,
            colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality,
            ]
        )
    }

    private static func exportAVIF(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        outputPreset: ExportOutputPreset,
        quality: Double,
        targetHeadroom: Float?,
        context: CIContext
    ) throws {
        if outputPreset.isHDR {
            try exportHDRAVIFWithFFmpeg(
                image,
                to: url,
                colorSpace: colorSpace,
                outputPreset: outputPreset,
                quality: quality,
                targetHeadroom: targetHeadroom,
                context: context
            )
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.avif" as CFString,
            1,
            nil
        ) else {
            throw ExportError.failedToCreateDestination
        }

        let outputImage = normalizedHDRImage(
            makeOpaqueImageForJPEG(image),
            targetHeadroom: targetHeadroom
        )

        guard let cgImage = context.createCGImage(
            outputImage,
            from: outputImage.extent,
            format: .rgbXh,
            colorSpace: colorSpace
        ) else {
            throw ExportError.failedToRenderImage
        }

        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
            kCGImagePropertyHasAlpha as String: false,
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw ExportError.failedToFinalizeExport
        }
    }

    private static func exportHDRAVIFWithFFmpeg(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        outputPreset: ExportOutputPreset,
        quality: Double,
        targetHeadroom: Float?,
        context: CIContext
    ) throws {
        guard let ffmpegURL = findAVIFFFMpegTool() else {
            throw ExportError.missingAVIFEncoderTool
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKit-AVIF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let outputImage = normalizedHDRImage(
            makeOpaqueImageForJPEG(image),
            targetHeadroom: targetHeadroom
        )
        let imageExtent = outputImage.extent
        guard imageExtent.isInfinite == false, !imageExtent.isEmpty else {
            throw ExportError.invalidImageExtent
        }

        let width = Int(imageExtent.width.rounded())
        let height = Int(imageExtent.height.rounded())
        guard width > 0, height > 0 else {
            throw ExportError.invalidImageExtent
        }

        let intermediateURL = tempDirectory.appendingPathComponent("hdr-rgba16.raw")
        let renderBounds = CGRect(x: 0, y: 0, width: width, height: height)

        try writeHDRAVIFIntermediateRaw(
            outputImage,
            to: intermediateURL,
            extent: renderBounds,
            width: width,
            height: height,
            colorSpace: colorSpace,
            context: context
        )

        let colorTransfer = avifColorTransferArgument(for: outputPreset)
        let crfValue = String(avifCRFValue(for: quality))

        try runAVIFFFMpegTool(
            ffmpegURL,
            arguments: [
                "-y",
                "-hide_banner",
                "-f", "rawvideo",
                "-pixel_format", "rgba64le",
                "-video_size", "\(width)x\(height)",
                "-framerate", "1",
                "-color_primaries", "bt2020",
                "-color_trc", colorTransfer,
                "-colorspace", "bt2020nc",
                "-color_range", "pc",
                "-i", intermediateURL.path,
                "-frames:v", "1",
                "-an",
                "-c:v", "libaom-av1",
                "-still-picture", "1",
                "-pix_fmt", "yuv420p10le",
                "-color_primaries", "bt2020",
                "-color_trc", colorTransfer,
                "-colorspace", "bt2020nc",
                "-color_range", "pc",
                "-crf", crfValue,
                "-b:v", "0",
                "-cpu-used", "2",
                "-row-mt", "1",
                url.path,
            ]
        )
    }

    private static func writeHDRAVIFIntermediateRaw(
        _ image: CIImage,
        to url: URL,
        extent: CGRect,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        context: CIContext
    ) throws {
        let normalizedImage = image
            .transformed(
                by: CGAffineTransform(
                    translationX: -image.extent.origin.x,
                    y: -image.extent.origin.y
                )
            )
            .cropped(to: extent)

        try renderRawImage(
            normalizedImage,
            to: url,
            extent: extent,
            width: width,
            height: height,
            bytesPerPixel: 8,
            format: .RGBA16,
            colorSpace: colorSpace,
            context: context
        )
    }

    private static func avifColorTransferArgument(for outputPreset: ExportOutputPreset) -> String {
        switch outputPreset.normalized {
        case .rec2020PQHDR:
            "smpte2084"
        case .rec2020HLGHDR, .displayP3HLGHDR:
            "arib-std-b67"
        case .sdrSRGB, .displayP3SDR:
            "iec61966-2-1"
        }
    }

    private static func avifCRFValue(for quality: Double) -> Int {
        let clampedQuality = quality.clamped(to: 0.5 ... 1.0)
        let crfValue = (1.0 - clampedQuality) * 120.0

        return Int(crfValue.rounded()).clamped(to: 0 ... 35)
    }

    private static func exportJPEGGainMap(
        _ image: CIImage,
        to url: URL,
        targetHeadroom: Float?,
        quality: Double,
        context: CIContext
    ) throws {
        let sdrColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let hdrImage = normalizedHDRImage(
            makeOpaqueImageForJPEG(image),
            targetHeadroom: targetHeadroom
        )
        let sdrImage = makeOpaqueImageForJPEG(makeSDRBaseImage(from: hdrImage))

        try context.writeJPEGRepresentation(
            of: sdrImage,
            to: url,
            colorSpace: sdrColorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality,
                .hdrImage: hdrImage,
                .hdrGainMapAsRGB: true,
            ]
        )
    }

    private static func exportUltraHDRJPEG(
        _ image: CIImage,
        to url: URL,
        targetHeadroom: Float?,
        quality: Double,
        compression: UltraHDRGainMapCompression,
        context: CIContext
    ) throws {
        guard let toolURL = findUltraHDRTool() else {
            throw ExportError.missingUltraHDRTool
        }

        let imageExtent = image.extent
        guard imageExtent.isInfinite == false, !imageExtent.isEmpty else {
            throw ExportError.invalidImageExtent
        }

        let width = Int(imageExtent.width.rounded())
        let height = Int(imageExtent.height.rounded())
        guard width > 0, height > 0 else {
            throw ExportError.invalidImageExtent
        }

        let renderBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let normalizedImage = image
            .transformed(
                by: CGAffineTransform(
                    translationX: -imageExtent.origin.x,
                    y: -imageExtent.origin.y
                )
            )
            .cropped(to: renderBounds)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKit-UltraHDR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let hdrRawURL = tempDirectory.appendingPathComponent("hdr-rgba16f.raw")
        let sdrRawURL = tempDirectory.appendingPathComponent("sdr-rgba8.raw")
        let opaqueImage = makeOpaqueImageForJPEG(normalizedImage)
        let hdrImage = normalizedHDRImage(opaqueImage, targetHeadroom: targetHeadroom)
        let sdrImage = makeOpaqueImageForJPEG(makeSDRBaseImage(from: hdrImage))

        try renderHDRRawImage(
            hdrImage,
            to: hdrRawURL,
            extent: renderBounds,
            width: width,
            height: height,
            context: context
        )
        try renderSDRRawImage(
            sdrImage,
            to: sdrRawURL,
            extent: renderBounds,
            width: width,
            height: height,
            context: context
        )

        let baseQuality = Int((quality * 100).rounded()).clamped(to: 1 ... 100)
        let gainMapQuality = Int((Double(baseQuality) * compression.gainMapQualityMultiplier).rounded())
            .clamped(to: 1 ... baseQuality)
        let qualityValue = String(baseQuality)
        let gainMapQualityValue = String(gainMapQuality)
        let maxContentBoost = String(format: "%.4f", Double(targetHeadroom ?? Float(defaultHDRExportHeadroom)))
        let targetPeakNits = String(Int(min(max(Double(targetHeadroom ?? Float(defaultHDRExportHeadroom)) * 100.0, 203.0), 10_000.0).rounded()))
        let gainMapScaleFactor = String(compression.gainMapScaleFactor)
        let usesMultiChannelGainMap = compression.usesMultiChannelGainMap ? "1" : "0"

        try runUltraHDRTool(
            toolURL,
            arguments: [
                "-m", "0",
                "-p", hdrRawURL.path,
                "-y", sdrRawURL.path,
                "-w", "\(width)",
                "-h", "\(height)",
                "-a", "4",
                "-b", "3",
                "-C", "2",
                "-c", "0",
                "-t", "0",
                "-R", "1",
                "-q", qualityValue,
                "-Q", gainMapQualityValue,
                "-s", gainMapScaleFactor,
                "-M", usesMultiChannelGainMap,
                "-D", "1",
                "-k", "1.0",
                "-K", maxContentBoost,
                "-L", targetPeakNits,
                "-z", url.path,
            ]
        )
    }

    private static func findUltraHDRTool() -> URL? {
        for optionalPath in ultraHDRToolCandidates {
            guard let path = optionalPath else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }

            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private static func findAVIFFFMpegTool() -> URL? {
        for optionalPath in avifFFmpegToolCandidates {
            guard let path = optionalPath else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }

            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private static func renderHDRRawImage(
        _ image: CIImage,
        to url: URL,
        extent: CGRect,
        width: Int,
        height: Int,
        context: CIContext
    ) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ??
            CGColorSpace(name: CGColorSpace.linearITUR_2020) else {
            throw ExportError.failedToRenderImage
        }

        try renderRawImage(
            image,
            to: url,
            extent: extent,
            width: width,
            height: height,
            bytesPerPixel: 8,
            format: .RGBAh,
            colorSpace: colorSpace,
            context: context
        )
    }

    private static func renderSDRRawImage(
        _ image: CIImage,
        to url: URL,
        extent: CGRect,
        width: Int,
        height: Int,
        context: CIContext
    ) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ExportError.failedToRenderImage
        }

        try renderRawImage(
            image,
            to: url,
            extent: extent,
            width: width,
            height: height,
            bytesPerPixel: 4,
            format: .RGBA8,
            colorSpace: colorSpace,
            context: context
        )
    }

    private static func renderRawImage(
        _ image: CIImage,
        to url: URL,
        extent: CGRect,
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        format: CIFormat,
        colorSpace: CGColorSpace,
        context: CIContext
    ) throws {
        let rowBytes = width * bytesPerPixel
        var data = Data(count: rowBytes * height)

        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                image,
                toBitmap: baseAddress,
                rowBytes: rowBytes,
                bounds: extent,
                format: format,
                colorSpace: colorSpace
            )
        }

        try data.write(to: url, options: .atomic)
    }

    private static func runUltraHDRTool(_ toolURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ExportError.failedUltraHDREncoding(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func runAVIFFFMpegTool(_ toolURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ExportError.failedAVIFEncoding(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func resolveTargetHDRHeadroom(
        imageInfo: ImageInfo,
        adjustments: ImageAdjustments,
        outputPreset: ExportOutputPreset
    ) -> Float? {
        guard outputPreset.isHDR else { return nil }

        let sourceHeadroom = imageInfo.hdrHeadroom ?? 1.0
        let adjustmentHeadroom = adjustments.isHDREnabled ? adjustments.hdrHeadroom : sourceHeadroom
        let targetHeadroom = max(
            adjustmentHeadroom,
            sourceHeadroom,
            Self.defaultHDRExportHeadroom
        )

        return Float(
            min(
                targetHeadroom,
                ImageAdjustments.hdrHeadroomRange.upperBound
            )
        )
    }

    private static func normalizedHDRImage(_ image: CIImage, targetHeadroom: Float?) -> CIImage {
        if #available(macOS 16.0, *) {
            let imageHeadroom = max(Float(image.contentHeadroom), 1.0)
            let resolvedHeadroom = max(targetHeadroom ?? imageHeadroom, imageHeadroom)

            return image.settingContentHeadroom(resolvedHeadroom)
        }

        return image
    }

    private static func makeSDRBaseImage(from image: CIImage) -> CIImage {
        if #available(macOS 16.0, *),
           let filter = CIFilter(name: "CISystemToneMap") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(1.0, forKey: "inputDisplayHeadroom")
            filter.setValue(CIDynamicRangeOption.standard.rawValue, forKey: "inputPreferredDynamicRange")

            if let outputImage = filter.outputImage {
                return outputImage
            }
        }

        return image.applyingFilter(
            "CIColorClamp",
            parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ]
        )
    }

    private static func exportDNG(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        context: CIContext
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.dng.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.failedToCreateDestination
        }

        // 使用 16-bit half float 格式以保留更多动态范围
        guard let cgImage = context.createCGImage(
            image,
            from: image.extent,
            format: .RGBAh,
            colorSpace: colorSpace
        )
        else {
            throw ExportError.failedToRenderImage
        }

        let properties: [String: Any] = [
            kCGImagePropertyDNGVersion as String: "1.4.0.0",
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyHasAlpha as String: false,
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw ExportError.failedToFinalizeExport
        }
    }
}

enum ExportError: LocalizedError {
    case failedToLoadImage
    case failedToCreateDestination
    case failedToCreateOutputDirectory(String, String)
    case failedToRenderImage
    case failedToFinalizeExport
    case invalidImageExtent
    case missingAVIFEncoderTool
    case missingUltraHDRTool
    case failedAVIFEncoding(String)
    case failedUltraHDREncoding(String)

    var errorDescription: String? {
        switch self {
        case .failedToLoadImage:
            "无法加载图片"
        case .failedToCreateDestination:
            "无法创建导出目标"
        case let .failedToCreateOutputDirectory(path, reason):
            "无法创建导出目录：\(path)。\(reason)"
        case .failedToRenderImage:
            "无法渲染图片"
        case .failedToFinalizeExport:
            "无法完成导出"
        case .invalidImageExtent:
            "图像尺寸无效，无法导出"
        case .missingAVIFEncoderTool:
            "无法导出 HDR AVIF：未找到 ffmpeg。请先安装 ffmpeg：brew install ffmpeg"
        case .missingUltraHDRTool:
            "无法导出 Ultra HDR JPEG：未找到 Ultra HDR 编码器。请先安装 libultrahdr：brew install libultrahdr"
        case let .failedAVIFEncoding(message):
            message.isEmpty ? "HDR AVIF 编码失败" : "HDR AVIF 编码失败：\(message)"
        case let .failedUltraHDREncoding(message):
            message.isEmpty ? "Ultra HDR JPEG 编码失败" : "Ultra HDR JPEG 编码失败：\(message)"
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
