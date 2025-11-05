import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

@MainActor
class ImageProcessor {
    private static let ciContext: CIContext = {
        var options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .cacheIntermediates: true,
            .priorityRequestLow: false,
        ]

        #if DEBUG
            options[.name] = "RawKit-CIContext"
        #endif

        return CIContext(options: options)
    }()

    static func loadThumbnail(from url: URL) -> CIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        return CIImage(cgImage: thumbnail)
    }

    static func loadMediumResolution(from url: URL) -> CIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        return CIImage(cgImage: cgImage)
    }

    static func loadImage(from url: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        if let ciImage = loadWithCoreImage(from: url) {
            return convertToNSImage(ciImage)
        }

        return NSImage(contentsOf: url)
    }

    static func loadCIImage(from url: URL) async -> CIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return loadWithCoreImage(from: url)
    }

    static func convertToNSImage(_ ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent
        guard !extent.isEmpty, extent.isInfinite == false else {
            return nil
        }

        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else {
            return nil
        }

        let size = NSSize(width: extent.width, height: extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func loadWithCoreImage(from url: URL) -> CIImage? {
        let options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .properties: [:],
        ]

        if let ciImage = CIImage(contentsOf: url, options: options) {
            return ciImage
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            return nil
        }

        return CIImage(cgImage: cgImage)
    }

    static func applyAdjustments(to image: CIImage, adjustments: ImageAdjustments) -> CIImage {
        var result = image

        if adjustments.exposure != 0.0 {
            result = applyExposure(to: result, value: adjustments.exposure)
        }

        if adjustments.brightness != 0.0 {
            result = applyBrightness(to: result, value: adjustments.brightness)
        }

        if adjustments.contrast != 1.0 {
            result = applyContrast(to: result, value: adjustments.contrast)
        }

        if adjustments.saturation != 1.0 {
            result = applySaturation(to: result, value: adjustments.saturation)
        }

        if adjustments.vibrance != 0.0 {
            result = applyVibrance(to: result, value: adjustments.vibrance)
        }

        if adjustments.highlights != 1.0 || adjustments.shadows != 0.0 {
            result = applyHighlightsShadows(
                to: result,
                highlights: adjustments.highlights,
                shadows: adjustments.shadows
            )
        }

        if adjustments.temperature != 6500.0 || adjustments.tint != 0.0 {
            result = applyWhiteBalance(
                to: result,
                temperature: adjustments.temperature,
                tint: adjustments.tint
            )
        }

        if adjustments.sharpness > 0.0 {
            result = applySharpness(to: result, value: adjustments.sharpness)
        }

        return result
    }

    private static func applyExposure(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIExposureAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(value, forKey: kCIInputEVKey)
        return filter.outputImage ?? image
    }

    private static func applyBrightness(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(value, forKey: kCIInputBrightnessKey)
        return filter.outputImage ?? image
    }

    private static func applyContrast(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(value, forKey: kCIInputContrastKey)
        return filter.outputImage ?? image
    }

    private static func applySaturation(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(value, forKey: kCIInputSaturationKey)
        return filter.outputImage ?? image
    }

    private static func applyVibrance(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIVibrance") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(value, forKey: "inputAmount")
        return filter.outputImage ?? image
    }

    private static func applyHighlightsShadows(
        to image: CIImage,
        highlights: Double,
        shadows: Double
    ) -> CIImage {
        guard let filter = CIFilter(name: "CIHighlightShadowAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(highlights, forKey: "inputHighlightAmount")
        filter.setValue(shadows, forKey: "inputShadowAmount")
        return filter.outputImage ?? image
    }

    private static func applyWhiteBalance(
        to image: CIImage,
        temperature: Double,
        tint: Double
    ) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        let neutralTemp = CIVector(x: temperature, y: 0)
        let targetTemp = CIVector(x: 6500, y: tint)

        filter.setValue(neutralTemp, forKey: "inputNeutral")
        filter.setValue(targetTemp, forKey: "inputTargetNeutral")

        return filter.outputImage ?? image
    }

    private static func applySharpness(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(value, forKey: kCIInputSharpnessKey)
        return filter.outputImage ?? image
    }

    static func applyFilter(_ filterName: String, to image: CIImage,
                            parameters: [String: Any] = [:]) -> CIImage?
    {
        guard let filter = CIFilter(name: filterName) else {
            return nil
        }

        filter.setValue(image, forKey: kCIInputImageKey)

        for (key, value) in parameters {
            filter.setValue(value, forKey: key)
        }

        return filter.outputImage
    }
}
