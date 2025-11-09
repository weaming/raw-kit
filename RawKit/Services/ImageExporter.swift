import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

class ImageExporter {
    static func export(
        imageInfo: ImageInfo,
        adjustments: ImageAdjustments,
        config: ExportConfig,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        progress(0.1)

        // 加载原始图片
        guard let originalImage = await ImageProcessor.loadCIImage(from: imageInfo.url) else {
            throw ExportError.failedToLoadImage
        }

        progress(0.3)

        // 应用调整
        let adjustedImage = await ImageProcessor.applyAdjustments(
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

        // 导出
        try exportImage(
            resizedImage,
            to: outputURL,
            format: config.format,
            colorSpace: config.colorSpace,
            quality: config.quality
        )

        progress(1.0)

        return outputURL
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
        colorSpace: ExportColorSpace,
        quality: Double
    ) throws {
        let context = CIContext()

        // 获取色彩空间
        let cgColorSpace = getColorSpace(for: colorSpace)

        switch format {
        case .jpg:
            try exportJPEG(
                image,
                to: url,
                colorSpace: cgColorSpace,
                quality: quality,
                context: context
            )
        case .heif:
            try exportHEIF(
                image,
                to: url,
                colorSpace: cgColorSpace,
                quality: quality,
                context: context
            )
        case .dng:
            try exportDNG(image, to: url, colorSpace: cgColorSpace, context: context)
        }
    }

    private static func getColorSpace(for exportSpace: ExportColorSpace) -> CGColorSpace {
        switch exportSpace {
        case .sRGB:
            CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3:
            CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB:
            CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case .proPhotoRGB:
            CGColorSpace(name: CGColorSpace.rommrgb)!
        }
    }

    private static func exportJPEG(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        quality: Double,
        context: CIContext
    ) throws {
        try context.writeJPEGRepresentation(
            of: image,
            to: url,
            colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality,
            ]
        )
    }

    private static func exportHEIF(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        quality: Double,
        context: CIContext
    ) throws {
        // 使用 RGBA8 格式，但系统会自动优化：如果图片不透明，不会保存 alpha 通道
        try context.writeHEIFRepresentation(
            of: image,
            to: url,
            format: .RGBA8,
            colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality,
            ]
        )
    }

    private static func exportDNG(
        _ image: CIImage,
        to url: URL,
        colorSpace: CGColorSpace,
        context: CIContext
    ) throws {
        // DNG 导出需要使用 ImageIO
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.dng.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.failedToCreateDestination
        }

        // 渲染为 CGImage
        // 注意：CIContext.createCGImage 会根据图片是否透明自动选择合适的格式
        // 使用 .RGBA8 格式，如果图片不透明，系统会优化
        guard let cgImage = context.createCGImage(
            image,
            from: image.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
        else {
            throw ExportError.failedToRenderImage
        }

        let properties: [String: Any] = [
            kCGImagePropertyDNGVersion as String: "1.4.0.0",
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyHasAlpha as String: false, // 明确标记为不透明图片，避免保存 alpha 通道
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
    case failedToRenderImage
    case failedToFinalizeExport

    var errorDescription: String? {
        switch self {
        case .failedToLoadImage:
            "无法加载图片"
        case .failedToCreateDestination:
            "无法创建导出目标"
        case .failedToRenderImage:
            "无法渲染图片"
        case .failedToFinalizeExport:
            "无法完成导出"
        }
    }
}
