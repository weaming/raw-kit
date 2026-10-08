import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

class ImageExporter {
    private static let defaultHDRExportHeadroom = 16.0
    private static let ULTRA_HDR_SDR_WHITE_NITS = 203.0
    private static let avifToolCandidates: [String?] = [
        Bundle.main.url(forResource: "avifenc", withExtension: nil)?.path,
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("avifenc").path,
        "/opt/homebrew/bin/avifenc",
        "/usr/local/bin/avifenc",
    ]
    private static let ultraHDRToolCandidates: [String?] = [
        Bundle.main.url(forResource: "ultrahdr_app", withExtension: nil)?.path,
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ultrahdr_app").path,
        "/opt/homebrew/bin/ultrahdr_app",
        "/usr/local/bin/ultrahdr_app",
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

    static func exportImage(
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
        case .ultraHDRJPEG:
            try exportUltraHDRJPEG(
                exportReadyImage,
                to: url,
                outputPreset: outputPreset,
                targetHeadroom: targetHDRHeadroom,
                quality: quality,
                compression: ultraHDRGainMapCompression,
                context: context
            )
        case .dng:
            throw ExportError.unsupportedDNGExport
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
            CGColorSpace(name: CGColorSpace.displayP3_HLG)!
        case .displayP3PQHDR:
            CGColorSpace(name: CGColorSpace.displayP3_PQ)!
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
        guard let toolURL = findAVIFTool() else {
            throw ExportError.missingAVIFTool
        }

        let outputImage = normalizedHDRImage(
            makeOpaqueImageForJPEG(image),
            targetHeadroom: targetHeadroom
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKit-AVIF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let sourceURL = tempDirectory.appendingPathComponent("source.png")
        try renderAVIFSourcePNG(
            outputImage,
            to: sourceURL,
            colorSpace: colorSpace,
            context: context
        )

        guard let profileData = colorSpace.copyICCData() else {
            throw ExportError.failedAVIFSourceRender("无法取得输出色彩空间的 ICC 配置")
        }
        let profileURL = tempDirectory.appendingPathComponent("output.icc")
        try (profileData as Data).write(to: profileURL)

        let encodedURL = tempDirectory.appendingPathComponent("output.avif")
        let qualityValue = Int((quality * 100).rounded()).clamped(to: 1 ... 100)
        let cicpValue = avifCICPValue(for: outputPreset)

        let arguments = [
            "--jobs", "all",
            "--speed", "6",
            "--qcolor", "\(qualityValue)",
            "--depth", "10",
            "--yuv", "444",
            "--range", "full",
            "--cicp", cicpValue,
            "--icc", profileURL.path,
        ]

        try runAVIFTool(
            toolURL,
            arguments: arguments + [sourceURL.path, encodedURL.path]
        )

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: encodedURL, to: url)
    }

    private static func renderAVIFSourcePNG(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        context: CIContext
    ) throws {
        do {
            try context.writePNGRepresentation(
                of: image,
                to: url,
                format: .RGBA16,
                colorSpace: colorSpace,
                options: [
                    kCGImagePropertyHasAlpha as CIImageRepresentationOption: false,
                ]
            )
        } catch {
            throw ExportError.failedAVIFSourceRender(error.localizedDescription)
        }
    }

    private static func avifCICPValue(for outputPreset: ExportOutputPreset) -> String {
        switch outputPreset {
        case .sdrSRGB:
            "1/13/1"
        case .displayP3SDR:
            "12/13/1"
        case .displayP3HLGHDR:
            "12/18/1"
        case .displayP3PQHDR:
            "12/16/1"
        case .rec2020HLGHDR:
            "9/18/9"
        case .rec2020PQHDR:
            "9/16/9"
        }
    }

    private static func findAVIFTool() -> URL? {
        for optionalPath in avifToolCandidates {
            guard let path = optionalPath else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }

            return URL(fileURLWithPath: path)
        }

        return findExecutableInPATH(named: "avifenc")
    }

    private static func findExecutableInPATH(named name: String) -> URL? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = pathValue.split(separator: ":").map(String.init)

        for directory in directories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }

            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private static func runAVIFTool(_ toolURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ExportError.failedAVIFEncoding(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func exportUltraHDRJPEG(
        _ image: CIImage,
        to url: URL,
        outputPreset: ExportOutputPreset,
        targetHeadroom: Float?,
        quality: Double,
        compression: UltraHDRGainMapCompression,
        context: CIContext
    ) throws {
        guard let toolURL = findUltraHDRTool() else {
            throw ExportError.missingUltraHDRTool
        }

        let headroom = Double(targetHeadroom ?? Float(defaultHDRExportHeadroom))
        guard headroom.isFinite, headroom >= 1 else {
            throw ExportError.failedUltraHDREncoding("HDR headroom 必须是大于等于 1 的有限数值")
        }
        let targetPeakNits = formatXMPNumber(
            min(max(headroom, 1.01) * ULTRA_HDR_SDR_WHITE_NITS, 10_000.0)
        )

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
        let sdrImage = makeSDRBaseImage(from: hdrImage)

        try renderHDRRawImage(
            hdrImage,
            to: hdrRawURL,
            extent: renderBounds,
            width: width,
            height: height,
            outputPreset: outputPreset,
            context: context
        )
        try renderSDRRawImage(
            sdrImage,
            to: sdrRawURL,
            extent: renderBounds,
            width: width,
            height: height,
            outputPreset: outputPreset,
            context: context
        )

        let baseQuality = Int((quality * 100).rounded()).clamped(to: 1 ... 100)
        let gainMapQuality = Int((Double(baseQuality) * compression.gainMapQualityMultiplier).rounded())
            .clamped(to: 1 ... baseQuality)
        let qualityValue = String(baseQuality)
        let gainMapQualityValue = String(gainMapQuality)
        let gainMapScaleFactor = String(compression.gainMapScaleFactor)
        let usesMultiChannelGainMap = compression.usesMultiChannelGainMap ? "1" : "0"
        let hdrColorGamut = ultraHDRColorGamutValue(for: outputPreset)

        let encodedURL = tempDirectory.appendingPathComponent("output.jpg")
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
                "-C", hdrColorGamut,
                "-c", hdrColorGamut,
                "-t", "0",
                "-R", "1",
                "-q", qualityValue,
                "-Q", gainMapQualityValue,
                "-s", gainMapScaleFactor,
                "-M", usesMultiChannelGainMap,
                "-D", "1",
                "-L", targetPeakNits,
                "-z", encodedURL.path,
            ]
        )

        try ensureUltraHDRJPEGHasXMPMetadata(at: encodedURL)
        try Data(contentsOf: encodedURL).write(to: url, options: .atomic)
    }

    private static func findUltraHDRTool() -> URL? {
        for optionalPath in ultraHDRToolCandidates {
            guard let path = optionalPath else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }

            return URL(fileURLWithPath: path)
        }

        return findExecutableInPATH(named: "ultrahdr_app")
    }

    private static func renderHDRRawImage(
        _ image: CIImage,
        to url: URL,
        extent: CGRect,
        width: Int,
        height: Int,
        outputPreset: ExportOutputPreset,
        context: CIContext
    ) throws {
        guard let colorSpace = ultraHDRLinearColorSpace(for: outputPreset) else {
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

    private static func ultraHDRLinearColorSpace(for outputPreset: ExportOutputPreset) -> CGColorSpace? {
        switch outputPreset {
        case .displayP3HLGHDR, .displayP3PQHDR:
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .rec2020HLGHDR, .rec2020PQHDR:
            CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ??
                CGColorSpace(name: CGColorSpace.linearITUR_2020)
        case .sdrSRGB, .displayP3SDR:
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ??
                CGColorSpace(name: CGColorSpace.linearSRGB)
        }
    }

    private static func ultraHDRColorGamutValue(for outputPreset: ExportOutputPreset) -> String {
        switch outputPreset {
        case .displayP3HLGHDR, .displayP3PQHDR:
            "1"
        case .rec2020HLGHDR, .rec2020PQHDR:
            "2"
        case .sdrSRGB, .displayP3SDR:
            "0"
        }
    }

    private static func renderSDRRawImage(
        _ image: CIImage,
        to url: URL,
        extent: CGRect,
        width: Int,
        height: Int,
        outputPreset: ExportOutputPreset,
        context: CIContext
    ) throws {
        let colorSpaceName: CFString
        switch outputPreset {
        case .displayP3SDR, .displayP3HLGHDR, .displayP3PQHDR:
            colorSpaceName = CGColorSpace.displayP3
        case .rec2020HLGHDR, .rec2020PQHDR:
            colorSpaceName = CGColorSpace.itur_2020_sRGBGamma
        case .sdrSRGB:
            colorSpaceName = CGColorSpace.sRGB
        }
        guard let colorSpace = CGColorSpace(name: colorSpaceName) else {
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
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ExportError.failedUltraHDREncoding(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func ensureUltraHDRJPEGHasXMPMetadata(at url: URL) throws {
        var fileData = try Data(contentsOf: url)

        try removeUltraHDRXMPSegments(in: &fileData)

        guard let primaryImageEnd = findJPEGImageEnd(in: fileData, start: 0),
              primaryImageEnd + 1 < fileData.count,
              fileData[primaryImageEnd] == 0xff,
              fileData[primaryImageEnd + 1] == 0xd8,
              let secondaryImageEnd = findJPEGImageEnd(in: fileData, start: primaryImageEnd) else {
            throw ExportError.failedUltraHDRMetadataPatch("无法定位 Ultra HDR JPEG 的 MPF 双图像结构")
        }

        let primaryImageLength = primaryImageEnd
        let secondaryImageStart = primaryImageEnd
        let secondaryImageLength = secondaryImageEnd - secondaryImageStart

        guard let mpfEntries = findMPFEntryPositions(in: fileData, primaryImageEnd: primaryImageEnd) else {
            throw ExportError.failedUltraHDRMetadataPatch("无法定位 MPF 图像目录")
        }

        guard let gainMapMetadata = readISOGainMapMetadata(
            in: fileData,
            imageStart: secondaryImageStart,
            imageEnd: secondaryImageEnd
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("ISO gain map 元数据无效，或无法无损表示为 SDR 基底、基底色域的单通道 XMP")
        }

        guard let secondaryXMPData = makeJPEGAPP1XMPData(
            xml: makeUltraHDRSecondaryXMP(metadata: gainMapMetadata)
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("gain map XMP 超出 JPEG APP1 段长度限制")
        }
        let patchedSecondaryImageLength = secondaryImageLength + secondaryXMPData.count

        guard let primaryXMPData = makeJPEGAPP1XMPData(
            xml: makeUltraHDRPrimaryXMP(secondaryImageLength: patchedSecondaryImageLength)
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("主图 XMP 超出 JPEG APP1 段长度限制")
        }
        let patchedPrimaryImageLength = primaryImageLength + primaryXMPData.count
        let patchedSecondaryImageStart = secondaryImageStart + primaryXMPData.count

        guard updateMPFEntries(
            in: &fileData,
            entries: mpfEntries,
            primaryImageLength: patchedPrimaryImageLength,
            secondaryImageStart: patchedSecondaryImageStart,
            secondaryImageLength: patchedSecondaryImageLength,
            tiffStartOffsetAdjustment: primaryXMPData.count
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("MPF 图像长度或偏移超出可表示范围")
        }

        fileData.insert(contentsOf: secondaryXMPData, at: secondaryImageStart + 2)
        fileData.insert(contentsOf: primaryXMPData, at: 2)

        try fileData.write(to: url, options: .atomic)
    }

    private static func removeUltraHDRXMPSegments(in data: inout Data) throws {
        guard let primaryImageEnd = findJPEGImageEnd(in: data, start: 0),
              primaryImageEnd + 1 < data.count,
              data[primaryImageEnd] == 0xff,
              data[primaryImageEnd + 1] == 0xd8,
              let secondaryImageEnd = findJPEGImageEnd(in: data, start: primaryImageEnd) else {
            throw ExportError.failedUltraHDRMetadataPatch("无法定位 Ultra HDR JPEG 的 MPF 双图像结构")
        }

        try removeJPEGGainMapXMPSegments(
            in: &data,
            imageStart: primaryImageEnd,
            imageEnd: secondaryImageEnd
        )

        guard let refreshedPrimaryImageEnd = findJPEGImageEnd(in: data, start: 0),
              refreshedPrimaryImageEnd + 1 < data.count,
              data[refreshedPrimaryImageEnd] == 0xff,
              data[refreshedPrimaryImageEnd + 1] == 0xd8,
              let refreshedSecondaryImageEnd = findJPEGImageEnd(
                  in: data,
                  start: refreshedPrimaryImageEnd
              ) else {
            throw ExportError.failedUltraHDRMetadataPatch("移除旧 XMP 后无法重新定位 JPEG 双图像结构")
        }

        try removeJPEGGainMapXMPSegments(
            in: &data,
            imageStart: 0,
            imageEnd: refreshedPrimaryImageEnd
        )

        guard findJPEGImageEnd(in: data, start: 0) != nil,
              refreshedSecondaryImageEnd > refreshedPrimaryImageEnd else {
            throw ExportError.failedUltraHDRMetadataPatch("移除旧 XMP 后 JPEG 结构无效")
        }
    }

    private static func removeJPEGGainMapXMPSegments(
        in data: inout Data,
        imageStart: Int,
        imageEnd: Int
    ) throws {
        let xmpNamespace = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
        let gainMapNamespace = Data("http://ns.adobe.com/hdr-gain-map/1.0/".utf8)
        var ranges: [Range<Int>] = []
        var offset = imageStart + 2

        while offset + 3 < imageEnd {
            guard data[offset] == 0xff else {
                throw ExportError.failedUltraHDRMetadataPatch("JPEG marker 无效")
            }

            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 {
                break
            }

            guard let segmentLength = readUInt16(data, at: offset + 2, byteOrder: .bigEndian),
                  segmentLength >= 2 else {
                throw ExportError.failedUltraHDRMetadataPatch("JPEG APP 段长度无效")
            }

            let payloadStart = offset + 4
            let segmentEnd = payloadStart + Int(segmentLength) - 2
            guard segmentEnd <= imageEnd else {
                throw ExportError.failedUltraHDRMetadataPatch("JPEG APP 段越界")
            }

            if marker == 0xe1,
               segmentEnd - payloadStart >= xmpNamespace.count,
               data[payloadStart ..< payloadStart + xmpNamespace.count].elementsEqual(xmpNamespace),
               data[payloadStart ..< segmentEnd].range(of: gainMapNamespace) != nil {
                ranges.append(offset ..< segmentEnd)
            }

            offset = segmentEnd
        }

        for range in ranges.reversed() {
            data.removeSubrange(range)
        }
    }

    private enum TIFFByteOrder {
        case bigEndian
        case littleEndian
    }

    private struct MPFEntryPositions {
        let byteOrder: TIFFByteOrder
        let tiffStart: Int
        let primaryLengthOffset: Int
        let primaryStartOffset: Int
        let secondaryLengthOffset: Int
        let secondaryStartOffset: Int
    }

    private struct UltraHDRGainMapMetadata {
        let gainMapMin: Double
        let gainMapMax: Double
        let gamma: Double
        let offsetSDR: Double
        let offsetHDR: Double
        let hdrCapacityMin: Double
        let hdrCapacityMax: Double
    }

    private static func findJPEGImageEnd(in data: Data, start: Int) -> Int? {
        guard start >= 0, start + 2 <= data.count,
              data[start] == 0xff, data[start + 1] == 0xd8 else { return nil }

        var offset = start + 2
        var isEntropyData = false
        while offset < data.count {
            if isEntropyData {
                while offset < data.count, data[offset] != 0xff { offset += 1 }
            }
            guard offset < data.count, data[offset] == 0xff else { return nil }
            while offset < data.count, data[offset] == 0xff { offset += 1 }
            guard offset < data.count else { return nil }
            let marker = data[offset]
            offset += 1

            if marker == 0x00 || (0xd0 ... 0xd7).contains(marker) {
                guard isEntropyData else { return nil }
                continue
            }
            if marker == 0xd9 { return offset }
            if marker == 0xd8 { return nil }
            if marker == 0x01 { continue }

            guard let length = readUInt16(data, at: offset, byteOrder: .bigEndian),
                  length >= 2, offset + Int(length) <= data.count else { return nil }
            offset += Int(length)
            isEntropyData = marker == 0xda
        }
        return nil
    }

    private static func findMPFEntryPositions(in data: Data, primaryImageEnd: Int) -> MPFEntryPositions? {
        var offset = 2
        while offset + 3 < primaryImageEnd {
            guard data[offset] == 0xff else { return nil }

            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 {
                return nil
            }

            guard let segmentLength = readUInt16(data, at: offset + 2, byteOrder: .bigEndian),
                  segmentLength >= 2 else {
                return nil
            }

            let payloadStart = offset + 4
            let payloadLength = Int(segmentLength) - 2
            let segmentEnd = payloadStart + payloadLength
            guard segmentEnd <= primaryImageEnd else { return nil }

            if marker == 0xe2,
               payloadLength >= 4,
               data[payloadStart ..< payloadStart + 4].elementsEqual(Data("MPF\u{0}".utf8)) {
                return parseMPFEntryPositions(in: data, payloadStart: payloadStart, payloadEnd: segmentEnd)
            }

            offset = segmentEnd
        }

        return nil
    }

    private static func parseMPFEntryPositions(
        in data: Data,
        payloadStart: Int,
        payloadEnd: Int
    ) -> MPFEntryPositions? {
        let tiffStart = payloadStart + 4
        guard tiffStart + 8 <= payloadEnd else { return nil }

        let byteOrder: TIFFByteOrder
        if data[tiffStart] == 0x4d, data[tiffStart + 1] == 0x4d {
            byteOrder = .bigEndian
        } else if data[tiffStart] == 0x49, data[tiffStart + 1] == 0x49 {
            byteOrder = .littleEndian
        } else {
            return nil
        }

        guard readUInt16(data, at: tiffStart + 2, byteOrder: byteOrder) == 42,
              let ifdOffset = readUInt32(data, at: tiffStart + 4, byteOrder: byteOrder) else {
            return nil
        }

        let ifdStart = tiffStart + Int(ifdOffset)
        guard ifdStart + 2 <= payloadEnd,
              let entryCount = readUInt16(data, at: ifdStart, byteOrder: byteOrder) else {
            return nil
        }

        for entryIndex in 0 ..< Int(entryCount) {
            let entryStart = ifdStart + 2 + entryIndex * 12
            guard entryStart + 12 <= payloadEnd,
                  readUInt16(data, at: entryStart, byteOrder: byteOrder) == 0xb002,
                  let valueCount = readUInt32(data, at: entryStart + 4, byteOrder: byteOrder),
                  let valueOffset = readUInt32(data, at: entryStart + 8, byteOrder: byteOrder) else {
                continue
            }

            let mpEntryStart = tiffStart + Int(valueOffset)
            guard valueCount >= 32,
                  mpEntryStart + Int(valueCount) <= payloadEnd else {
                return nil
            }

            return MPFEntryPositions(
                byteOrder: byteOrder,
                tiffStart: tiffStart,
                primaryLengthOffset: mpEntryStart + 4,
                primaryStartOffset: mpEntryStart + 8,
                secondaryLengthOffset: mpEntryStart + 20,
                secondaryStartOffset: mpEntryStart + 24
            )
        }

        return nil
    }

    /// 写入 MPF 目录的图像长度和相对偏移；任一数值超出 UInt32 可表示范围时返回 false 且不修改数据
    private static func updateMPFEntries(
        in data: inout Data,
        entries: MPFEntryPositions,
        primaryImageLength: Int,
        secondaryImageStart: Int,
        secondaryImageLength: Int,
        tiffStartOffsetAdjustment: Int = 0
    ) -> Bool {
        let patchedTIFFStart = entries.tiffStart + tiffStartOffsetAdjustment
        guard secondaryImageStart >= patchedTIFFStart,
              let primaryLength = UInt32(exactly: primaryImageLength),
              let secondaryLength = UInt32(exactly: secondaryImageLength),
              let secondaryRelativeStart = UInt32(exactly: secondaryImageStart - patchedTIFFStart)
        else {
            return false
        }

        writeUInt32(
            &data,
            at: entries.primaryLengthOffset,
            value: primaryLength,
            byteOrder: entries.byteOrder
        )
        writeUInt32(
            &data,
            at: entries.primaryStartOffset,
            value: 0,
            byteOrder: entries.byteOrder
        )
        writeUInt32(
            &data,
            at: entries.secondaryLengthOffset,
            value: secondaryLength,
            byteOrder: entries.byteOrder
        )
        writeUInt32(
            &data,
            at: entries.secondaryStartOffset,
            value: secondaryRelativeStart,
            byteOrder: entries.byteOrder
        )

        return true
    }

    private static func readISOGainMapMetadata(
        in data: Data,
        imageStart: Int,
        imageEnd: Int
    ) -> UltraHDRGainMapMetadata? {
        let isoNamespaceData = Data("urn:iso:std:iso:ts:21496:-1\u{0}".utf8)
        var offset = imageStart + 2

        while offset + 3 < imageEnd {
            guard data[offset] == 0xff else { return nil }

            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 {
                return nil
            }

            guard let segmentLength = readUInt16(data, at: offset + 2, byteOrder: .bigEndian),
                  segmentLength >= 2 else {
                return nil
            }

            let payloadStart = offset + 4
            let payloadLength = Int(segmentLength) - 2
            let segmentEnd = payloadStart + payloadLength
            guard segmentEnd <= imageEnd else { return nil }

            if marker == 0xe2,
               payloadLength > isoNamespaceData.count,
               data[payloadStart ..< payloadStart + isoNamespaceData.count].elementsEqual(isoNamespaceData) {
                guard let isoMetadata = parseISOGainMapMetadata(
                    in: data,
                    start: payloadStart + isoNamespaceData.count,
                    end: segmentEnd
                ) else {
                    return nil
                }

                return isoMetadata
            }

            offset = segmentEnd
        }

        return nil
    }

    private static func parseISOGainMapMetadata(
        in data: Data,
        start: Int,
        end: Int
    ) -> UltraHDRGainMapMetadata? {
        var offset = start

        guard offset + 5 <= end else { return nil }
        // 按 ISO 21496-1 v0 硬编码解析：min_version 与 writer_version 均为 0，随后一个字节是 flags
        guard readUInt16(data, at: offset, byteOrder: .bigEndian) == 0,
              readUInt16(data, at: offset + 2, byteOrder: .bigEndian) == 0 else { return nil }
        offset += 4

        let flags = data[offset]
        guard flags & 0x40 != 0, flags & 0x37 == 0 else { return nil }
        offset += 1

        let channelCount = (flags & 0x80) == 0 ? 1 : 3
        let usesCommonDenominator = (flags & 0x08) != 0

        var gainMapMin = [Double](repeating: 0, count: 3)
        var gainMapMax = [Double](repeating: 0, count: 3)
        var gamma = [Double](repeating: 1, count: 3)
        var offsetSDR = [Double](repeating: 0, count: 3)
        var offsetHDR = [Double](repeating: 0, count: 3)
        var hdrCapacityMin = 0.0
        var hdrCapacityMax = 0.0

        if usesCommonDenominator {
            guard offset + 12 + channelCount * 20 <= end,
                  let denominator = readUInt32(data, at: offset, byteOrder: .bigEndian),
                  denominator != 0,
                  let baseHeadroomNumerator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian),
                  let alternateHeadroomNumerator = readUInt32(data, at: offset + 8, byteOrder: .bigEndian) else {
                return nil
            }

            offset += 12

            hdrCapacityMin = fractionValue(baseHeadroomNumerator, denominator)
            hdrCapacityMax = fractionValue(alternateHeadroomNumerator, denominator)

            for channelIndex in 0 ..< channelCount {
                guard let minNumerator = readInt32(data, at: offset, byteOrder: .bigEndian),
                      let maxNumerator = readInt32(data, at: offset + 4, byteOrder: .bigEndian),
                      let gammaNumerator = readUInt32(data, at: offset + 8, byteOrder: .bigEndian),
                      let offsetSDRNumerator = readInt32(data, at: offset + 12, byteOrder: .bigEndian),
                      let offsetHDRNumerator = readInt32(data, at: offset + 16, byteOrder: .bigEndian) else {
                    return nil
                }

                gainMapMin[channelIndex] = fractionValue(minNumerator, denominator)
                gainMapMax[channelIndex] = fractionValue(maxNumerator, denominator)
                gamma[channelIndex] = fractionValue(gammaNumerator, denominator)
                offsetSDR[channelIndex] = fractionValue(offsetSDRNumerator, denominator)
                offsetHDR[channelIndex] = fractionValue(offsetHDRNumerator, denominator)
                offset += 20
            }
        } else {
            guard offset + 16 + channelCount * 40 <= end,
                  let baseHeadroomNumerator = readUInt32(data, at: offset, byteOrder: .bigEndian),
                  let baseHeadroomDenominator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian),
                  let alternateHeadroomNumerator = readUInt32(data, at: offset + 8, byteOrder: .bigEndian),
                  let alternateHeadroomDenominator = readUInt32(data, at: offset + 12, byteOrder: .bigEndian),
                  baseHeadroomDenominator != 0,
                  alternateHeadroomDenominator != 0 else {
                return nil
            }

            offset += 16

            hdrCapacityMin = fractionValue(baseHeadroomNumerator, baseHeadroomDenominator)
            hdrCapacityMax = fractionValue(alternateHeadroomNumerator, alternateHeadroomDenominator)

            for channelIndex in 0 ..< channelCount {
                guard let minDenominator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian) else {
                    return nil
                }

                guard let minNumerator = readInt32(data, at: offset, byteOrder: .bigEndian),
                      let maxNumerator = readInt32(data, at: offset + 8, byteOrder: .bigEndian),
                      let maxDenominator = readUInt32(data, at: offset + 12, byteOrder: .bigEndian),
                      let gammaNumerator = readUInt32(data, at: offset + 16, byteOrder: .bigEndian),
                      let gammaDenominator = readUInt32(data, at: offset + 20, byteOrder: .bigEndian),
                      let offsetSDRNumerator = readInt32(data, at: offset + 24, byteOrder: .bigEndian),
                      let offsetSDRDenominator = readUInt32(data, at: offset + 28, byteOrder: .bigEndian),
                      let offsetHDRNumerator = readInt32(data, at: offset + 32, byteOrder: .bigEndian),
                      let offsetHDRDenominator = readUInt32(data, at: offset + 36, byteOrder: .bigEndian),
                      minDenominator != 0,
                      maxDenominator != 0,
                      gammaDenominator != 0,
                      offsetSDRDenominator != 0,
                      offsetHDRDenominator != 0 else {
                    return nil
                }

                gainMapMin[channelIndex] = fractionValue(minNumerator, minDenominator)
                gainMapMax[channelIndex] = fractionValue(maxNumerator, maxDenominator)
                gamma[channelIndex] = fractionValue(gammaNumerator, gammaDenominator)
                offsetSDR[channelIndex] = fractionValue(offsetSDRNumerator, offsetSDRDenominator)
                offsetHDR[channelIndex] = fractionValue(offsetHDRNumerator, offsetHDRDenominator)
                offset += 40
            }
        }

        if channelCount == 1 {
            gainMapMin[1] = gainMapMin[0]
            gainMapMin[2] = gainMapMin[0]
            gainMapMax[1] = gainMapMax[0]
            gainMapMax[2] = gainMapMax[0]
            gamma[1] = gamma[0]
            gamma[2] = gamma[0]
            offsetSDR[1] = offsetSDR[0]
            offsetSDR[2] = offsetSDR[0]
            offsetHDR[1] = offsetHDR[0]
            offsetHDR[2] = offsetHDR[0]
        }

        guard gainMapMin.allSatisfy({ $0 == gainMapMin[0] }),
              gainMapMax.allSatisfy({ $0 == gainMapMax[0] }),
              gamma.allSatisfy({ $0 == gamma[0] && $0 > 0 }),
              offsetSDR.allSatisfy({ $0 == offsetSDR[0] }),
              offsetHDR.allSatisfy({ $0 == offsetHDR[0] }),
              gainMapMax[0] >= gainMapMin[0],
              hdrCapacityMax > hdrCapacityMin else { return nil }

        let metadata = UltraHDRGainMapMetadata(
            gainMapMin: gainMapMin[0],
            gainMapMax: gainMapMax[0],
            gamma: gamma[0],
            offsetSDR: offsetSDR[0],
            offsetHDR: offsetHDR[0],
            hdrCapacityMin: hdrCapacityMin,
            hdrCapacityMax: hdrCapacityMax
        )
        return metadata
    }

    private static func makeJPEGAPP1XMPData(xml: String) -> Data? {
        let xmpNamespace = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
        let xmlData = Data(xml.utf8)
        let segmentLength = 2 + xmpNamespace.count + xmlData.count
        guard segmentLength <= Int(UInt16.max) else { return nil }

        var segmentData = Data([0xff, 0xe1])
        segmentData.append(UInt8(segmentLength >> 8))
        segmentData.append(UInt8(segmentLength & 0xff))
        segmentData.append(xmpNamespace)
        segmentData.append(xmlData)

        return segmentData
    }

    private static func makeUltraHDRPrimaryXMP(secondaryImageLength: Int) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.2"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="\(secondaryImageLength)"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    private static func makeUltraHDRSecondaryXMP(metadata: UltraHDRGainMapMetadata) -> String {
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.2"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0" hdrgm:GainMapMin="\(formatXMPNumber(metadata.gainMapMin))" hdrgm:GainMapMax="\(formatXMPNumber(metadata.gainMapMax))" hdrgm:Gamma="\(formatXMPNumber(metadata.gamma))" hdrgm:OffsetSDR="\(formatXMPNumber(metadata.offsetSDR))" hdrgm:OffsetHDR="\(formatXMPNumber(metadata.offsetHDR))" hdrgm:HDRCapacityMin="\(formatXMPNumber(metadata.hdrCapacityMin))" hdrgm:HDRCapacityMax="\(formatXMPNumber(metadata.hdrCapacityMax))" hdrgm:BaseRenditionIsHDR="False"/></rdf:RDF></x:xmpmeta>
        """
    }

    private static func formatXMPNumber(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func fractionValue(_ numerator: UInt32, _ denominator: UInt32) -> Double {
        Double(numerator) / Double(denominator)
    }

    private static func fractionValue(_ numerator: Int32, _ denominator: UInt32) -> Double {
        Double(numerator) / Double(denominator)
    }

    private static func readUInt16(_ data: Data, at offset: Int, byteOrder: TIFFByteOrder) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }

        switch byteOrder {
        case .bigEndian:
            return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        case .littleEndian:
            return UInt16(data[offset + 1]) << 8 | UInt16(data[offset])
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, byteOrder: TIFFByteOrder) -> UInt32? {
        guard offset >= 0, offset + 3 < data.count else { return nil }

        switch byteOrder {
        case .bigEndian:
            return UInt32(data[offset]) << 24 |
                UInt32(data[offset + 1]) << 16 |
                UInt32(data[offset + 2]) << 8 |
                UInt32(data[offset + 3])
        case .littleEndian:
            return UInt32(data[offset + 3]) << 24 |
                UInt32(data[offset + 2]) << 16 |
                UInt32(data[offset + 1]) << 8 |
                UInt32(data[offset])
        }
    }

    private static func readInt32(_ data: Data, at offset: Int, byteOrder: TIFFByteOrder) -> Int32? {
        guard let unsignedValue = readUInt32(data, at: offset, byteOrder: byteOrder) else {
            return nil
        }

        return Int32(bitPattern: unsignedValue)
    }

    private static func writeUInt32(
        _ data: inout Data,
        at offset: Int,
        value: UInt32,
        byteOrder: TIFFByteOrder
    ) {
        guard offset >= 0, offset + 3 < data.count else { return }

        switch byteOrder {
        case .bigEndian:
            data[offset] = UInt8((value >> 24) & 0xff)
            data[offset + 1] = UInt8((value >> 16) & 0xff)
            data[offset + 2] = UInt8((value >> 8) & 0xff)
            data[offset + 3] = UInt8(value & 0xff)
        case .littleEndian:
            data[offset] = UInt8(value & 0xff)
            data[offset + 1] = UInt8((value >> 8) & 0xff)
            data[offset + 2] = UInt8((value >> 16) & 0xff)
            data[offset + 3] = UInt8((value >> 24) & 0xff)
        }
    }

    private static func resolveTargetHDRHeadroom(
        imageInfo: ImageInfo,
        adjustments: ImageAdjustments,
        outputPreset: ExportOutputPreset
    ) -> Float? {
        guard outputPreset.isHDR else { return nil }

        let sourceHeadroom = imageInfo.hdrHeadroom ?? 1.0
        let targetHeadroom: Double

        if adjustments.isHDREnabled {
            targetHeadroom = adjustments.hdrHeadroom
        } else if sourceHeadroom > 1.01 {
            targetHeadroom = sourceHeadroom
        } else {
            targetHeadroom = Self.defaultHDRExportHeadroom
        }

        return Float(targetHeadroom.clamped(to: ImageAdjustments.hdrHeadroomRange))
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

}

enum ExportError: LocalizedError {
    case failedToLoadImage
    case failedToCreateDestination
    case failedToCreateOutputDirectory(String, String)
    case failedToRenderImage
    case failedToFinalizeExport
    case invalidImageExtent
    case missingAVIFTool
    case failedAVIFSourceRender(String)
    case failedAVIFEncoding(String)
    case unsupportedDNGExport
    case missingUltraHDRTool
    case failedUltraHDREncoding(String)
    case failedUltraHDRMetadataPatch(String)

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
        case .missingAVIFTool:
            "无法导出 AVIF：未找到 libavif 编码器 avifenc。请先安装 libavif：brew install libavif"
        case let .failedAVIFSourceRender(message):
            message.isEmpty ? "AVIF 中间图渲染失败" : "AVIF 中间图渲染失败：\(message)"
        case let .failedAVIFEncoding(message):
            message.isEmpty ? "AVIF 编码失败" : "AVIF 编码失败：\(message)"
        case .unsupportedDNGExport:
            "当前 macOS ImageIO 不支持写入 DNG，已隐藏该导出选项"
        case .missingUltraHDRTool:
            "无法导出 Ultra HDR JPEG：未找到 Ultra HDR 编码器。请先安装 libultrahdr：brew install libultrahdr"
        case let .failedUltraHDREncoding(message):
            message.isEmpty ? "Ultra HDR JPEG 编码失败" : "Ultra HDR JPEG 编码失败：\(message)"
        case let .failedUltraHDRMetadataPatch(message):
            "Ultra HDR JPEG 元数据修复失败：\(message)"
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
