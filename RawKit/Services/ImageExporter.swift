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
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
