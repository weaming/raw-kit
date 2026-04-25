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
            kCGImageDestinationEncodeRequest as String: outputPreset.isHDR
                ? kCGImageDestinationEncodeToISOHDR
                : kCGImageDestinationEncodeToSDR,
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw ExportError.failedToFinalizeExport
        }

        if outputPreset.isHDR {
            try normalizeHDRAVIFColorMetadata(at: url)
        }
    }

    private static func normalizeHDRAVIFColorMetadata(at url: URL) throws {
        var fileData = try Data(contentsOf: url)
        var patchedBoxCount = 0

        patchAVIFColorBoxes(
            in: &fileData,
            range: 0 ..< fileData.count,
            patchedBoxCount: &patchedBoxCount
        )

        guard patchedBoxCount > 0 else { return }

        try fileData.write(to: url, options: .atomic)
    }

    private static func patchAVIFColorBoxes(
        in fileData: inout Data,
        range: Range<Int>,
        patchedBoxCount: inout Int
    ) {
        var boxOffset = range.lowerBound

        while boxOffset + 8 <= range.upperBound {
            guard let baseBoxSize = readBigEndianUInt32(fileData, at: boxOffset) else { return }

            var headerSize = 8
            var boxSize = UInt64(baseBoxSize)
            if baseBoxSize == 1 {
                guard let extendedBoxSize = readBigEndianUInt64(fileData, at: boxOffset + 8) else { return }

                headerSize = 16
                boxSize = extendedBoxSize
            } else if baseBoxSize == 0 {
                boxSize = UInt64(range.upperBound - boxOffset)
            }

            guard boxSize >= UInt64(headerSize) else { return }
            guard boxSize <= UInt64(Int.max - boxOffset) else { return }

            let boxEnd = boxOffset + Int(boxSize)
            guard boxEnd <= range.upperBound else { return }

            if boxTypeEquals(fileData, at: boxOffset + 4, type: "colr") {
                patchAVIFNCLXColorBox(
                    in: &fileData,
                    boxOffset: boxOffset,
                    headerSize: headerSize,
                    boxEnd: boxEnd,
                    patchedBoxCount: &patchedBoxCount
                )
            } else if boxTypeEquals(fileData, at: boxOffset + 4, type: "mdat") {
                patchAV1ColorMetadata(
                    in: &fileData,
                    range: (boxOffset + headerSize) ..< boxEnd,
                    patchedFieldCount: &patchedBoxCount
                )
            } else if canContainAVIFChildBoxes(fileData, at: boxOffset + 4) {
                let childOffset = boxOffset + headerSize + (boxTypeEquals(fileData, at: boxOffset + 4, type: "meta") ? 4 : 0)
                if childOffset < boxEnd {
                    patchAVIFColorBoxes(
                        in: &fileData,
                        range: childOffset ..< boxEnd,
                        patchedBoxCount: &patchedBoxCount
                    )
                }
            }

            boxOffset = boxEnd
        }
    }

    private static func patchAVIFNCLXColorBox(
        in fileData: inout Data,
        boxOffset: Int,
        headerSize: Int,
        boxEnd: Int,
        patchedBoxCount: inout Int
    ) {
        let colorTypeOffset = boxOffset + headerSize
        let colorPrimariesOffset = colorTypeOffset + 4
        let transferOffset = colorPrimariesOffset + 2
        let matrixOffset = transferOffset + 2
        let fullRangeOffset = matrixOffset + 2

        guard fullRangeOffset < boxEnd else { return }
        guard boxTypeEquals(fileData, at: colorTypeOffset, type: "nclx") else { return }
        guard let colorPrimaries = readBigEndianUInt16(fileData, at: colorPrimariesOffset),
              let transferCharacteristics = readBigEndianUInt16(fileData, at: transferOffset),
              let matrixCoefficients = readBigEndianUInt16(fileData, at: matrixOffset) else {
            return
        }

        let isBT2020 = colorPrimaries == 9
        let isHDRTransfer = transferCharacteristics == 16 || transferCharacteristics == 18
        guard isBT2020, isHDRTransfer, matrixCoefficients == 1 else { return }

        fileData[matrixOffset] = 0
        fileData[matrixOffset + 1] = 9
        patchedBoxCount += 1
    }

    private static func patchAV1ColorMetadata(
        in fileData: inout Data,
        range: Range<Int>,
        patchedFieldCount: inout Int
    ) {
        var obuOffset = range.lowerBound

        while obuOffset < range.upperBound {
            guard obuOffset + 1 <= range.upperBound else { return }

            let obuHeader = fileData[obuOffset]
            obuOffset += 1

            let obuType = (obuHeader >> 3) & 0x0f
            let hasExtension = (obuHeader & 0x04) != 0
            let hasSize = (obuHeader & 0x02) != 0
            guard (obuHeader & 0x80) == 0, (obuHeader & 0x01) == 0 else { return }

            if hasExtension {
                guard obuOffset + 1 <= range.upperBound else { return }
                obuOffset += 1
            }

            guard hasSize else { return }
            guard let (payloadSize, payloadSizeByteCount) = readLEB128UInt(fileData, at: obuOffset, end: range.upperBound) else {
                return
            }

            obuOffset += payloadSizeByteCount
            guard payloadSize <= UInt64(range.upperBound - obuOffset) else { return }

            let payloadEnd = obuOffset + Int(payloadSize)
            if obuType == 1 {
                patchAV1SequenceHeaderColorMetadata(
                    in: &fileData,
                    payloadRange: obuOffset ..< payloadEnd,
                    patchedFieldCount: &patchedFieldCount
                )
            }

            obuOffset = payloadEnd
        }
    }

    private static func patchAV1SequenceHeaderColorMetadata(
        in fileData: inout Data,
        payloadRange: Range<Int>,
        patchedFieldCount: inout Int
    ) {
        let lowerBitOffset = payloadRange.lowerBound * 8
        let upperBitOffset = payloadRange.upperBound * 8
        guard lowerBitOffset + 24 <= upperBitOffset else { return }

        var bitOffset = lowerBitOffset
        while bitOffset + 24 <= upperBitOffset {
            let colorPrimaries = readBits(fileData, at: bitOffset, count: 8)
            let transferCharacteristics = readBits(fileData, at: bitOffset + 8, count: 8)
            let matrixCoefficients = readBits(fileData, at: bitOffset + 16, count: 8)

            if colorPrimaries == 9,
               transferCharacteristics == 16 || transferCharacteristics == 18,
               matrixCoefficients == 1 {
                writeBits(&fileData, at: bitOffset + 16, count: 8, value: 9)
                patchedFieldCount += 1
            }

            bitOffset += 1
        }
    }

    private static func canContainAVIFChildBoxes(_ fileData: Data, at offset: Int) -> Bool {
        boxTypeEquals(fileData, at: offset, type: "meta") ||
            boxTypeEquals(fileData, at: offset, type: "iprp") ||
            boxTypeEquals(fileData, at: offset, type: "ipco")
    }

    private static func boxTypeEquals(_ fileData: Data, at offset: Int, type: StaticString) -> Bool {
        guard offset + 4 <= fileData.count else { return false }
        guard type.utf8CodeUnitCount == 4 else { return false }

        return fileData[offset] == type.utf8Start[0] &&
            fileData[offset + 1] == type.utf8Start[1] &&
            fileData[offset + 2] == type.utf8Start[2] &&
            fileData[offset + 3] == type.utf8Start[3]
    }

    private static func readBigEndianUInt16(_ fileData: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= fileData.count else { return nil }

        return UInt16(fileData[offset]) << 8 |
            UInt16(fileData[offset + 1])
    }

    private static func readBigEndianUInt32(_ fileData: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= fileData.count else { return nil }

        return UInt32(fileData[offset]) << 24 |
            UInt32(fileData[offset + 1]) << 16 |
            UInt32(fileData[offset + 2]) << 8 |
            UInt32(fileData[offset + 3])
    }

    private static func readBigEndianUInt64(_ fileData: Data, at offset: Int) -> UInt64? {
        guard let highBits = readBigEndianUInt32(fileData, at: offset),
              let lowBits = readBigEndianUInt32(fileData, at: offset + 4) else {
            return nil
        }

        return UInt64(highBits) << 32 | UInt64(lowBits)
    }

    private static func readLEB128UInt(_ fileData: Data, at offset: Int, end: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift = 0
        var byteOffset = offset

        while byteOffset < end {
            let byteValue = fileData[byteOffset]
            value |= UInt64(byteValue & 0x7f) << shift
            byteOffset += 1

            if (byteValue & 0x80) == 0 {
                return (value, byteOffset - offset)
            }

            shift += 7
            guard shift < 64 else { return nil }
        }

        return nil
    }

    private static func readBits(_ fileData: Data, at bitOffset: Int, count: Int) -> UInt32? {
        guard count > 0, count <= 32 else { return nil }
        guard bitOffset >= 0, bitOffset + count <= fileData.count * 8 else { return nil }

        var value: UInt32 = 0
        for bitIndex in 0 ..< count {
            let absoluteBitOffset = bitOffset + bitIndex
            let byteOffset = absoluteBitOffset / 8
            let bitInByte = 7 - (absoluteBitOffset % 8)
            let bitValue = (fileData[byteOffset] >> UInt8(bitInByte)) & 1

            value = (value << 1) | UInt32(bitValue)
        }

        return value
    }

    private static func writeBits(_ fileData: inout Data, at bitOffset: Int, count: Int, value: UInt32) {
        guard count > 0, count <= 32 else { return }
        guard bitOffset >= 0, bitOffset + count <= fileData.count * 8 else { return }

        for bitIndex in 0 ..< count {
            let absoluteBitOffset = bitOffset + bitIndex
            let byteOffset = absoluteBitOffset / 8
            let bitInByte = 7 - (absoluteBitOffset % 8)
            let mask = UInt8(1 << bitInByte)
            let bitValue = (value >> UInt32(count - bitIndex - 1)) & 1

            if bitValue == 1 {
                fileData[byteOffset] |= mask
            } else {
                fileData[byteOffset] &= ~mask
            }
        }
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

        try ensureUltraHDRJPEGHasXMPMetadata(at: url)
    }

    private static func findUltraHDRTool() -> URL? {
        for optionalPath in ultraHDRToolCandidates {
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

    private static func ensureUltraHDRJPEGHasXMPMetadata(at url: URL) throws {
        var fileData = try Data(contentsOf: url)
        let gainMapNamespace = Data("http://ns.adobe.com/hdr-gain-map/1.0/".utf8)
        let hasGainMapXMP = fileData.range(of: gainMapNamespace) != nil

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

        guard let gainMapMetadata = normalizeISOGainMapMetadata(
            in: &fileData,
            imageStart: secondaryImageStart,
            imageEnd: secondaryImageEnd
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("无法读取 ISO 21496-1 gain map 元数据")
        }

        if hasGainMapXMP {
            updateMPFEntries(
                in: &fileData,
                entries: mpfEntries,
                primaryImageLength: primaryImageLength,
                secondaryImageStart: secondaryImageStart,
                secondaryImageLength: secondaryImageLength
            )
            try fileData.write(to: url, options: .atomic)
            return
        }

        let secondaryXMPData = makeJPEGAPP1XMPData(
            xml: makeUltraHDRSecondaryXMP(metadata: gainMapMetadata)
        )
        let patchedSecondaryImageLength = secondaryImageLength + secondaryXMPData.count

        let primaryXMPData = makeJPEGAPP1XMPData(
            xml: makeUltraHDRPrimaryXMP(secondaryImageLength: patchedSecondaryImageLength)
        )
        let patchedPrimaryImageLength = primaryImageLength + primaryXMPData.count
        let patchedSecondaryImageStart = secondaryImageStart + primaryXMPData.count

        updateMPFEntries(
            in: &fileData,
            entries: mpfEntries,
            primaryImageLength: patchedPrimaryImageLength,
            secondaryImageStart: patchedSecondaryImageStart,
            secondaryImageLength: patchedSecondaryImageLength,
            tiffStartOffsetAdjustment: primaryXMPData.count
        )

        fileData.insert(contentsOf: secondaryXMPData, at: secondaryImageStart + 2)
        fileData.insert(contentsOf: primaryXMPData, at: 2)

        try fileData.write(to: url, options: .atomic)
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

    private struct UltraHDRISORationalField {
        let numeratorOffset: Int
        let denominator: UInt32
    }

    private struct UltraHDRISOGainMapPatch {
        let gainMapMinFields: [UltraHDRISORationalField]
        let hdrCapacityMinField: UltraHDRISORationalField
        let hdrCapacityMaxField: UltraHDRISORationalField
    }

    private struct UltraHDRISOGainMapMetadata {
        let metadata: UltraHDRGainMapMetadata
        let patch: UltraHDRISOGainMapPatch
    }

    private static func findJPEGImageEnd(in data: Data, start: Int) -> Int? {
        guard start >= 0,
              start + 1 < data.count,
              data[start] == 0xff,
              data[start + 1] == 0xd8 else {
            return nil
        }

        var offset = start + 2
        while offset + 1 < data.count {
            guard data[offset] == 0xff else {
                offset += 1
                continue
            }

            while offset < data.count, data[offset] == 0xff {
                offset += 1
            }
            guard offset < data.count else { return nil }

            let marker = data[offset]
            let markerStart = offset - 1
            offset += 1

            if marker == 0xd9 {
                return offset
            }

            if marker == 0xda {
                guard markerStart + 3 < data.count,
                      let segmentLength = readUInt16(data, at: markerStart + 2, byteOrder: .bigEndian) else {
                    return nil
                }

                offset = markerStart + 2 + Int(segmentLength)
                while offset + 1 < data.count {
                    if data[offset] != 0xff {
                        offset += 1
                        continue
                    }

                    var markerOffset = offset + 1
                    while markerOffset < data.count, data[markerOffset] == 0xff {
                        markerOffset += 1
                    }
                    guard markerOffset < data.count else { return nil }

                    let entropyMarker = data[markerOffset]
                    if entropyMarker == 0x00 || (0xd0 ... 0xd7).contains(entropyMarker) {
                        offset = markerOffset + 1
                        continue
                    }
                    if entropyMarker == 0xd9 {
                        return markerOffset + 1
                    }

                    offset = markerOffset + 1
                }

                return nil
            }

            if (0xd0 ... 0xd7).contains(marker) || marker == 0x01 {
                continue
            }

            guard markerStart + 3 < data.count,
                  let segmentLength = readUInt16(data, at: markerStart + 2, byteOrder: .bigEndian),
                  segmentLength >= 2 else {
                return nil
            }

            offset = markerStart + 2 + Int(segmentLength)
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

    private static func updateMPFEntries(
        in data: inout Data,
        entries: MPFEntryPositions,
        primaryImageLength: Int,
        secondaryImageStart: Int,
        secondaryImageLength: Int,
        tiffStartOffsetAdjustment: Int = 0
    ) {
        let patchedTIFFStart = entries.tiffStart + tiffStartOffsetAdjustment
        let secondaryRelativeStart = max(0, secondaryImageStart - patchedTIFFStart)

        writeUInt32(
            &data,
            at: entries.primaryLengthOffset,
            value: UInt32(primaryImageLength),
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
            value: UInt32(secondaryImageLength),
            byteOrder: entries.byteOrder
        )
        writeUInt32(
            &data,
            at: entries.secondaryStartOffset,
            value: UInt32(secondaryRelativeStart),
            byteOrder: entries.byteOrder
        )
    }

    private static func normalizeISOGainMapMetadata(
        in data: inout Data,
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

                let normalizedMetadata = normalizedUltraHDRGainMapMetadata(isoMetadata.metadata)
                patchISOGainMapMetadata(
                    in: &data,
                    patch: isoMetadata.patch,
                    normalizedMetadata: normalizedMetadata
                )

                return normalizedMetadata
            }

            offset = segmentEnd
        }

        return nil
    }

    private static func parseISOGainMapMetadata(
        in data: Data,
        start: Int,
        end: Int
    ) -> UltraHDRISOGainMapMetadata? {
        var offset = start

        guard offset + 5 <= end else { return nil }
        guard readUInt16(data, at: offset, byteOrder: .bigEndian) == 0 else { return nil }
        offset += 4

        let flags = data[offset]
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
        var gainMapMinFields: [UltraHDRISORationalField] = []
        let hdrCapacityMinField: UltraHDRISORationalField
        let hdrCapacityMaxField: UltraHDRISORationalField

        if usesCommonDenominator {
            guard offset + 12 + channelCount * 20 <= end,
                  let denominator = readUInt32(data, at: offset, byteOrder: .bigEndian),
                  denominator != 0,
                  let baseHeadroomNumerator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian),
                  let alternateHeadroomNumerator = readUInt32(data, at: offset + 8, byteOrder: .bigEndian) else {
                return nil
            }

            hdrCapacityMinField = UltraHDRISORationalField(
                numeratorOffset: offset + 4,
                denominator: denominator
            )
            hdrCapacityMaxField = UltraHDRISORationalField(
                numeratorOffset: offset + 8,
                denominator: denominator
            )
            offset += 12

            hdrCapacityMin = fractionValue(baseHeadroomNumerator, denominator)
            hdrCapacityMax = fractionValue(alternateHeadroomNumerator, denominator)

            for channelIndex in 0 ..< channelCount {
                gainMapMinFields.append(
                    UltraHDRISORationalField(
                        numeratorOffset: offset,
                        denominator: denominator
                    )
                )

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

            hdrCapacityMinField = UltraHDRISORationalField(
                numeratorOffset: offset,
                denominator: baseHeadroomDenominator
            )
            hdrCapacityMaxField = UltraHDRISORationalField(
                numeratorOffset: offset + 8,
                denominator: alternateHeadroomDenominator
            )
            offset += 16

            hdrCapacityMin = fractionValue(baseHeadroomNumerator, baseHeadroomDenominator)
            hdrCapacityMax = fractionValue(alternateHeadroomNumerator, alternateHeadroomDenominator)

            for channelIndex in 0 ..< channelCount {
                guard let minDenominator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian) else {
                    return nil
                }
                gainMapMinFields.append(
                    UltraHDRISORationalField(
                        numeratorOffset: offset,
                        denominator: minDenominator
                    )
                )

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

        let metadata = UltraHDRGainMapMetadata(
            gainMapMin: gainMapMin[0],
            gainMapMax: gainMapMax[0],
            gamma: gamma[0],
            offsetSDR: offsetSDR[0],
            offsetHDR: offsetHDR[0],
            hdrCapacityMin: hdrCapacityMin,
            hdrCapacityMax: hdrCapacityMax
        )
        let patch = UltraHDRISOGainMapPatch(
            gainMapMinFields: gainMapMinFields,
            hdrCapacityMinField: hdrCapacityMinField,
            hdrCapacityMaxField: hdrCapacityMaxField
        )

        return UltraHDRISOGainMapMetadata(metadata: metadata, patch: patch)
    }

    private static func normalizedUltraHDRGainMapMetadata(
        _ metadata: UltraHDRGainMapMetadata
    ) -> UltraHDRGainMapMetadata {
        let gainMapMin = min(metadata.gainMapMin, 0.0)
        let gainMapMax = max(metadata.gainMapMax, gainMapMin)
        let hdrCapacityMin = max(gainMapMin, 0.0)
        let hdrCapacityMax = max(gainMapMax, hdrCapacityMin + 0.000001)

        return UltraHDRGainMapMetadata(
            gainMapMin: gainMapMin,
            gainMapMax: gainMapMax,
            gamma: metadata.gamma,
            offsetSDR: metadata.offsetSDR,
            offsetHDR: metadata.offsetHDR,
            hdrCapacityMin: hdrCapacityMin,
            hdrCapacityMax: hdrCapacityMax
        )
    }

    private static func patchISOGainMapMetadata(
        in data: inout Data,
        patch: UltraHDRISOGainMapPatch,
        normalizedMetadata: UltraHDRGainMapMetadata
    ) {
        for field in patch.gainMapMinFields {
            writeSignedRationalNumerator(
                &data,
                field: field,
                value: normalizedMetadata.gainMapMin
            )
        }

        writeUnsignedRationalNumerator(
            &data,
            field: patch.hdrCapacityMinField,
            value: normalizedMetadata.hdrCapacityMin
        )
        writeUnsignedRationalNumerator(
            &data,
            field: patch.hdrCapacityMaxField,
            value: normalizedMetadata.hdrCapacityMax
        )
    }

    private static func makeJPEGAPP1XMPData(xml: String) -> Data {
        let xmpNamespace = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
        let xmlData = Data(xml.utf8)
        let segmentLength = UInt16(2 + xmpNamespace.count + xmlData.count)

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
        String(format: "%.9g", value)
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

    private static func writeSignedRationalNumerator(
        _ data: inout Data,
        field: UltraHDRISORationalField,
        value: Double
    ) {
        guard field.denominator != 0, value.isFinite else { return }

        let numerator = (value * Double(field.denominator)).rounded()
            .clamped(to: Double(Int32.min) ... Double(Int32.max))
        let signedValue = Int32(numerator)
        writeUInt32(
            &data,
            at: field.numeratorOffset,
            value: UInt32(bitPattern: signedValue),
            byteOrder: .bigEndian
        )
    }

    private static func writeUnsignedRationalNumerator(
        _ data: inout Data,
        field: UltraHDRISORationalField,
        value: Double
    ) {
        guard field.denominator != 0, value.isFinite else { return }

        let numerator = (value * Double(field.denominator)).rounded()
            .clamped(to: 0 ... Double(UInt32.max))
        writeUInt32(
            &data,
            at: field.numeratorOffset,
            value: UInt32(numerator),
            byteOrder: .bigEndian
        )
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
