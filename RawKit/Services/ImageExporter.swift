import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

class ImageExporter {
    private static let defaultHDRExportHeadroom = 16.0
    private static let ultraHDRSDRWhiteNits = 203.0

    private static var exportContext: CIContext {
        CIContextManager.shared.getRenderContext()
    }

    /// 异步导出图片：所有重型滤镜、缩放与磁盘编码均在后台执行，避免阻塞主线程
    static func export(
        imageInfo: ImageInfo,
        adjustments: ImageAdjustments,
        config: ExportConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.1)

        guard let originalImage = await ImageProcessor.loadCIImage(from: imageInfo.url) else {
            throw ExportError.failedToLoadImage
        }

        progress(0.3)

        let outputURL = determineOutputURL(for: imageInfo, config: config)
        let targetHeadroom = resolveTargetHDRHeadroom(
            imageInfo: imageInfo,
            adjustments: adjustments,
            outputPreset: config.outputPreset
        )

        try await Task.detached(priority: .userInitiated) {
            let adjustedImage = ImageProcessor.applyAdjustments(
                to: originalImage,
                adjustments: adjustments
            )
            progress(0.5)

            let resizedImage: CIImage = if let maxDim = config.maxDimension {
                resizeImage(adjustedImage, maxDimension: maxDim)
            } else {
                adjustedImage
            }
            progress(0.7)

            try ensureOutputDirectoryExists(for: outputURL)
            try exportImage(
                resizedImage,
                to: outputURL,
                format: config.format,
                outputPreset: config.outputPreset,
                quality: config.quality,
                ultraHDRGainMapCompression: config.ultraHDRGainMapCompression,
                targetHDRHeadroom: targetHeadroom
            )
        }.value

        progress(1.0)
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
        let cgColorSpace = outputPreset.cgColorSpace

        switch format {
        case .tiff:
            try writeAtomically(to: url) { stagedURL in
                try exportTIFF(exportReadyImage, to: stagedURL, colorSpace: cgColorSpace, context: context)
            }
        case .jpg:
            try writeAtomically(to: url) { stagedURL in
                try exportJPEG(
                    exportReadyImage,
                    to: stagedURL,
                    colorSpace: cgColorSpace,
                    quality: quality,
                    context: context
                )
            }
        case .heif:
            try writeAtomically(to: url) { stagedURL in
                try exportHEIF(
                    exportReadyImage,
                    to: stagedURL,
                    colorSpace: cgColorSpace,
                    quality: quality,
                    targetHeadroom: targetHDRHeadroom,
                    context: context
                )
            }
        case .avif:
            try writeAtomically(to: url) { stagedURL in
                try exportAVIF(
                    exportReadyImage,
                    to: stagedURL,
                    colorSpace: cgColorSpace,
                    outputPreset: outputPreset,
                    quality: quality,
                    targetHeadroom: targetHDRHeadroom,
                    context: context
                )
            }
        case .ultraHDRJPEG:
            try writeAtomically(to: url) { stagedURL in
                try exportUltraHDRJPEG(
                    exportReadyImage,
                    to: stagedURL,
                    outputPreset: outputPreset,
                    targetHeadroom: targetHDRHeadroom,
                    quality: quality,
                    compression: ultraHDRGainMapCompression,
                    context: context
                )
            }
        case .dng:
            throw ExportError.unsupportedDNGExport
        }
    }

    static func ensureUltraHDRJPEGHasXMPMetadata(at url: URL) throws {
        try UltraHDRMetadataPatcher.ensureXMPMetadata(at: url)
    }

    static func determineOutputURL(for imageInfo: ImageInfo, config: ExportConfig) -> URL {
        let baseDirectory = config.outputDirectory ?? imageInfo.url.deletingLastPathComponent()
        let baseName = imageInfo.url.deletingPathExtension().lastPathComponent
        let safePrefix = sanitizeFileNameComponent(config.prefix)
        let safeSuffix = sanitizeFileNameComponent(config.suffix)
        let fileName = "\(safePrefix)\(baseName)\(safeSuffix).\(config.format.fileExtension)"
        return baseDirectory.appendingPathComponent(fileName)
    }

    private static func sanitizeFileNameComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
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

    /// 统一原子发布：先写入同目录隐藏临时文件，全部成功后再原子替换目标路径，失败不损坏已有文件
    private static func writeAtomically(
        to destinationURL: URL,
        using writer: (URL) throws -> Void
    ) throws {
        let directory = destinationURL.deletingLastPathComponent()
        try ensureOutputDirectoryExists(for: destinationURL)

        let stagedName = ".\(destinationURL.lastPathComponent).rawkit-\(UUID().uuidString).tmp"
        let stagedURL = directory.appendingPathComponent(stagedName)
        defer {
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try? FileManager.default.removeItem(at: stagedURL)
            }
        }

        try writer(stagedURL)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    private static func resizeImage(_ image: CIImage, maxDimension: Int) -> CIImage {
        guard maxDimension > 0 else { return image }

        let extent = image.extent
        let maxDim = max(extent.width, extent.height)
        guard maxDim > CGFloat(maxDimension) else { return image }

        let scale = CGFloat(maxDimension) / maxDim
        return image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale),
            highQualityDownsample: true
        )
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

    private static func makeOpaqueImage(_ image: CIImage) -> CIImage {
        let bounds = image.extent
        let whiteBackground = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: bounds)

        return image
            .composited(over: whiteBackground)
            .cropped(to: bounds)
    }

    // MARK: - Format Encoders

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

        let opaqueImage = makeOpaqueImage(image)
        guard let cgImage = context.createCGImage(
            opaqueImage,
            from: opaqueImage.extent,
            format: .RGBA16,
            colorSpace: colorSpace
        ) else {
            throw ExportError.failedToRenderImage
        }

        let properties: [String: Any] = [
            kCGImagePropertyTIFFCompression as String: 5,
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
        let flattenedImage = makeOpaqueImage(image)

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
        guard let toolURL = findExternalTool(named: "avifenc") else {
            throw ExportError.missingAVIFTool
        }

        let outputImage = normalizedHDRImage(
            makeOpaqueImage(image),
            targetHeadroom: targetHeadroom
        )

        try withTemporaryDirectory(prefix: "RawKit-AVIF") { tempDirectory in
            let sourceURL = tempDirectory.appendingPathComponent("source.png")
            do {
                try context.writePNGRepresentation(
                    of: outputImage,
                    to: sourceURL,
                    format: .RGBA16,
                    colorSpace: colorSpace,
                    options: [
                        kCGImagePropertyHasAlpha as CIImageRepresentationOption: false,
                    ]
                )
            } catch {
                throw ExportError.failedAVIFSourceRender(error.localizedDescription)
            }

            guard let profileData = colorSpace.copyICCData() else {
                throw ExportError.failedAVIFSourceRender("无法取得输出色彩空间的 ICC 配置")
            }
            let profileURL = tempDirectory.appendingPathComponent("output.icc")
            try (profileData as Data).write(to: profileURL)

            let qualityValue = Int((quality * 100).rounded()).clamped(to: 1 ... 100)
            let arguments = [
                "--jobs", "all",
                "--speed", "6",
                "--qcolor", "\(qualityValue)",
                "--depth", "10",
                "--yuv", "444",
                "--range", "full",
                "--cicp", outputPreset.avifCICP,
                "--icc", profileURL.path,
                sourceURL.path,
                url.path,
            ]

            try runExternalTool(toolURL, arguments: arguments) { output in
                ExportError.failedAVIFEncoding(output)
            }
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
        guard let toolURL = findExternalTool(named: "ultrahdr_app") else {
            throw ExportError.missingUltraHDRTool
        }

        let headroom = Double(targetHeadroom ?? Float(defaultHDRExportHeadroom))
        guard headroom.isFinite, headroom >= 1 else {
            throw ExportError.failedUltraHDREncoding("HDR headroom 必须是大于等于 1 的有限数值")
        }
        let targetPeakNits = UltraHDRMetadataPatcher.formatNumber(
            min(max(headroom, 1.01) * ultraHDRSDRWhiteNits, 10_000.0)
        )

        let bounds = image.extent
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else {
            throw ExportError.invalidImageExtent
        }

        guard let hdrColorSpace = outputPreset.ultraHDRLinearColorSpace,
              let sdrColorSpace = outputPreset.ultraHDRSDRColorSpace else {
            throw ExportError.failedToRenderImage
        }

        try withTemporaryDirectory(prefix: "RawKit-UltraHDR") { tempDirectory in
            let hdrRawURL = tempDirectory.appendingPathComponent("hdr-rgba16f.raw")
            let sdrRawURL = tempDirectory.appendingPathComponent("sdr-rgba8.raw")
            let opaqueImage = makeOpaqueImage(image)
            let hdrImage = normalizedHDRImage(opaqueImage, targetHeadroom: targetHeadroom)
            let sdrImage = makeSDRBaseImage(from: hdrImage)

            try renderRawImage(
                hdrImage,
                to: hdrRawURL,
                extent: bounds,
                width: width,
                height: height,
                bytesPerPixel: 8,
                format: .RGBAh,
                colorSpace: hdrColorSpace,
                context: context
            )
            try renderRawImage(
                sdrImage,
                to: sdrRawURL,
                extent: bounds,
                width: width,
                height: height,
                bytesPerPixel: 4,
                format: .RGBA8,
                colorSpace: sdrColorSpace,
                context: context
            )

            let baseQuality = Int((quality * 100).rounded()).clamped(to: 1 ... 100)
            let gainMapQuality = Int((Double(baseQuality) * compression.gainMapQualityMultiplier).rounded())
                .clamped(to: 1 ... baseQuality)
            let gamutCode = outputPreset.ultraHDRGamutCode

            try runExternalTool(
                toolURL,
                arguments: [
                    "-m", "0",
                    "-p", hdrRawURL.path,
                    "-y", sdrRawURL.path,
                    "-w", "\(width)",
                    "-h", "\(height)",
                    "-a", "4",
                    "-b", "3",
                    "-C", gamutCode,
                    "-c", gamutCode,
                    "-t", "0",
                    "-R", "1",
                    "-q", "\(baseQuality)",
                    "-Q", "\(gainMapQuality)",
                    "-s", "\(compression.gainMapScaleFactor)",
                    "-M", compression.usesMultiChannelGainMap ? "1" : "0",
                    "-D", "1",
                    "-L", targetPeakNits,
                    "-z", url.path,
                ]
            ) { output in
                ExportError.failedUltraHDREncoding(output)
            }

            try UltraHDRMetadataPatcher.ensureXMPMetadata(at: url)
        }
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

    // MARK: - External Tool & Temp Directory Helpers

    private static func withTemporaryDirectory<T>(
        prefix: String,
        body: (URL) throws -> T
    ) throws -> T {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        return try body(tempDirectory)
    }

    private static func findExternalTool(named name: String) -> URL? {
        let candidates: [String?] = [
            Bundle.main.url(forResource: name, withExtension: nil)?.path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name).path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]

        for case let path? in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":").map(String.init) {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private static func runExternalTool(
        _ toolURL: URL,
        arguments: [String],
        onFailure: (String) -> Error
    ) throws {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // 先读取管道再 waitUntilExit，避免子进程写满管道缓冲区导致死锁
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = (String(data: outputData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw onFailure(output)
        }
    }

    // MARK: - HDR Helpers

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
            targetHeadroom = defaultHDRExportHeadroom
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

private extension ExportOutputPreset {
    var cgColorSpace: CGColorSpace {
        switch self {
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

    var avifCICP: String {
        switch self {
        case .sdrSRGB: "1/13/1"
        case .displayP3SDR: "12/13/1"
        case .displayP3HLGHDR: "12/18/1"
        case .displayP3PQHDR: "12/16/1"
        case .rec2020HLGHDR: "9/18/9"
        case .rec2020PQHDR: "9/16/9"
        }
    }

    var ultraHDRLinearColorSpace: CGColorSpace? {
        switch self {
        case .displayP3SDR, .displayP3HLGHDR, .displayP3PQHDR:
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .rec2020HLGHDR, .rec2020PQHDR:
            CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ??
                CGColorSpace(name: CGColorSpace.linearITUR_2020)
        case .sdrSRGB:
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ??
                CGColorSpace(name: CGColorSpace.linearSRGB)
        }
    }

    var ultraHDRSDRColorSpace: CGColorSpace? {
        let name: CFString = switch self {
        case .displayP3SDR, .displayP3HLGHDR, .displayP3PQHDR:
            CGColorSpace.displayP3
        case .rec2020HLGHDR, .rec2020PQHDR:
            CGColorSpace.itur_2020_sRGBGamma
        case .sdrSRGB:
            CGColorSpace.sRGB
        }
        return CGColorSpace(name: name)
    }

    var ultraHDRGamutCode: String {
        switch self {
        case .displayP3SDR, .displayP3HLGHDR, .displayP3PQHDR: "1"
        case .rec2020HLGHDR, .rec2020PQHDR: "2"
        case .sdrSRGB: "0"
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
