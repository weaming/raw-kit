import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

@MainActor
class ImageProcessor {
    private static let renderQueue = DispatchQueue(
        label: "com.bitsflow.rawkit.render",
        qos: .userInteractive
    )

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

        // 尝试使用 x3f-extract 加载（用于 X3F 等不被 Core Image 支持的格式）
        if let x3fImage = await loadWithX3fExtract(from: url) {
            print("ImageProcessor: ✓ x3f-extract 加载成功")
            return x3fImage
        }

        return NSImage(contentsOf: url)
    }

    static func loadCIImage(from url: URL) async -> CIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        if let ciImage = loadWithCoreImage(from: url) {
            return ciImage
        }

        // 尝试使用 x3f-extract 加载，然后转换为 CIImage
        if let x3fImage = await loadWithX3fExtract(from: url),
           let cgImage = x3fImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CIImage(cgImage: cgImage)
        }

        return nil
    }

    static func convertToNSImage(_ ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent
        guard !extent.isEmpty, extent.isInfinite == false else {
            return nil
        }

        var cgImage: CGImage?
        renderQueue.sync {
            cgImage = ciContext.createCGImage(ciImage, from: extent)
        }

        guard let cgImage else {
            return nil
        }

        let size = NSSize(width: extent.width, height: extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    static func convertToCGImage(_ ciImage: CIImage) -> CGImage? {
        let extent = ciImage.extent
        guard !extent.isEmpty, extent.isInfinite == false else {
            return nil
        }

        var cgImage: CGImage?
        renderQueue.sync {
            cgImage = ciContext.createCGImage(ciImage, from: extent)
        }

        return cgImage
    }

    private static func loadWithCoreImage(from url: URL) -> CIImage? {
        print("ImageProcessor: 尝试加载图片: \(url.lastPathComponent)")

        // 对于 X3F 格式，跳过 CIImage 加载，直接使用 x3f-extract
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "x3f" {
            print("ImageProcessor: X3F 格式，跳过 CIImage 加载")
            return nil
        }

        let options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .properties: [:],
        ]

        if let ciImage = CIImage(contentsOf: url, options: options) {
            print("ImageProcessor: ✓ CIImage 直接加载成功")
            return ciImage
        }

        print("ImageProcessor: CIImage 直接加载失败，尝试 CGImageSource")

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            print("ImageProcessor: ✗ 无法创建 CGImageSource")
            return nil
        }

        let imageType = CGImageSourceGetType(imageSource)
        print("ImageProcessor: 图片类型: \(imageType ?? "unknown" as CFString)")

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("ImageProcessor: ✗ 无法从 CGImageSource 创建 CGImage")
            return nil
        }

        print("ImageProcessor: ✓ CGImageSource 加载成功")
        return CIImage(cgImage: cgImage)
    }

    private static func loadWithX3fExtract(from url: URL) async -> NSImage? {
        print("ImageProcessor: 尝试使用 x3f-extract 加载: \(url.lastPathComponent)")

        // 获取应用包内的 x3f-extract 路径
        guard let x3fPath = Bundle.main.path(forResource: "x3f-extract", ofType: nil) else {
            print("ImageProcessor: ✗ 找不到 x3f-extract 工具")
            return nil
        }

        print("ImageProcessor: x3f-extract 路径: \(x3fPath)")

        // 创建临时目录用于输出
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // x3f-extract 会生成 .dng 文件
        let outputFileName = "\(url.lastPathComponent).dng"
        let expectedOutputPath = tempDir.appendingPathComponent(outputFileName)

        // 执行 x3f-extract 命令
        // 参数: -dng -o <输出目录> <输入文件>
        let process = Process()
        process.executableURL = URL(fileURLWithPath: x3fPath)
        process.arguments = ["-dng", "-o", tempDir.path, url.path]

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
                let outputMsg = String(data: outputData, encoding: .utf8) ?? ""
                print("ImageProcessor: ✗ x3f-extract 执行失败，状态码: \(process.terminationStatus)")
                print("ImageProcessor: 输出: \(outputMsg)")
                print("ImageProcessor: 错误信息: \(errorMsg)")
                return nil
            }

            // 加载生成的 DNG 文件
            if FileManager.default.fileExists(atPath: expectedOutputPath.path),
               let image = NSImage(contentsOf: expectedOutputPath) {
                print("ImageProcessor: ✓ x3f-extract 加载成功，图片尺寸: \(image.size)")
                return image
            } else {
                print("ImageProcessor: ✗ 无法加载 x3f-extract 生成的 DNG 文件")
                print("ImageProcessor: 期望路径: \(expectedOutputPath.path)")
                // 列出临时目录中的文件以调试
                if let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
                    print("ImageProcessor: 临时目录内容: \(files)")
                }
                return nil
            }
        } catch {
            print("ImageProcessor: ✗ x3f-extract 执行错误: \(error)")
            return nil
        }
    }

    static func applyAdjustments(to image: CIImage, adjustments: ImageAdjustments) -> CIImage {
        var result = image

        // 首先应用变换（旋转和镜像）
        if adjustments.rotation != 0 || adjustments.flipHorizontal || adjustments.flipVertical {
            result = applyTransform(
                to: result,
                rotation: adjustments.rotation,
                flipHorizontal: adjustments.flipHorizontal,
                flipVertical: adjustments.flipVertical
            )
        }

        if adjustments.exposure != 0.0 {
            result = applyExposure(to: result, value: adjustments.exposure)
        }

        if adjustments.linearExposure != 0.0 {
            result = applyLinearExposure(to: result, value: adjustments.linearExposure)
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

        if adjustments.highlights != 1.0 || adjustments.shadows != 0.0 || adjustments
            .whites != 0.0 || adjustments.blacks != 0.0 {
            result = applyHighlightsShadows(
                to: result,
                highlights: adjustments.highlights,
                shadows: adjustments.shadows,
                whites: adjustments.whites,
                blacks: adjustments.blacks
            )
        }

        if adjustments.temperature != 6500.0 || adjustments.tint != 0.0 {
            result = applyWhiteBalance(
                to: result,
                temperature: adjustments.temperature,
                tint: adjustments.tint
            )
        }

        if adjustments.clarity != 0.0 {
            result = applyClarity(to: result, value: adjustments.clarity)
        }

        if adjustments.dehaze != 0.0 {
            result = applyDehaze(to: result, value: adjustments.dehaze)
        }

        // Photoshop 的曲线应用顺序：
        // 1. RGB 复合曲线（同时应用到 R、G、B 三个通道）
        // 2. R/G/B 单独曲线（只影响各自通道）
        // 3. 亮度曲线

        if adjustments.rgbCurve.hasPoints {
            // RGB 曲线应该应用到所有三个颜色通道
            result = adjustments.rgbCurve.applyToRGB(to: result)
        }

        if adjustments.redCurve.hasPoints {
            result = adjustments.redCurve.apply(to: result, channel: .red)
        }

        if adjustments.greenCurve.hasPoints {
            result = adjustments.greenCurve.apply(to: result, channel: .green)
        }

        if adjustments.blueCurve.hasPoints {
            result = adjustments.blueCurve.apply(to: result, channel: .blue)
        }

        if adjustments.luminanceCurve.hasPoints {
            result = adjustments.luminanceCurve.apply(to: result, channel: .luminance)
        }

        if adjustments.sharpness != 0.0 {
            result = applySharpness(to: result, value: adjustments.sharpness)
        }

        if let lutURL = adjustments.lutURL {
            result = applyLUT(
                to: result,
                lutURL: lutURL,
                alpha: adjustments.lutAlpha,
                lutColorSpace: adjustments.lutColorSpace
            )
        }

        return result
    }

    // 线性曝光调整 - 真实摄影曝光算法
    // 基于 EV (Exposure Value) 光圈档位
    // 每增加 1 EV，亮度翻倍；每减少 1 EV，亮度减半
    // 公式：output = input * 2^EV
    // 范围：[-5, +5] EV，相当于 10 档光圈
    private static func applyLinearExposure(to image: CIImage, value: Double) -> CIImage {
        if value == 0.0 { return image }

        // 真实摄影曝光算法：
        // 基于 EV (Exposure Value) 光圈档位
        // 公式：亮度 = 原始亮度 × 2^EV
        // EV +1 -> 2x 亮度
        // EV +2 -> 4x 亮度
        // EV -1 -> 0.5x 亮度

        guard let filter = CIFilter(name: "CIExposureAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // CIExposureAdjust 的 inputEV 参数就是 EV 值
        // 它内部使用的就是 2^EV 的公式
        filter.setValue(value, forKey: kCIInputEVKey)

        return filter.outputImage ?? image
    }

    // Capture One 风格的曝光调整
    // C1 的曝光更加智能，不会让高光过曝或阴影死黑
    // 使用渐进式曲线而不是简单的线性调整
    private static func applyExposure(to image: CIImage, value: Double) -> CIImage {
        if value == 0.0 { return image }

        // C1 的曝光算法：使用参数化曲线实现智能曝光
        // 在中间调应用更多调整，在高光和阴影应用较少调整
        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // 计算曲线关键点
        // value 范围 [-2, 2]
        let strength = value * 0.5 // 降低强度，更温和

        // 5个关键点：黑、暗、中、亮、白
        let black = max(0, min(1, 0.0 + strength * 0.2)) // 黑点轻微调整
        let shadow = max(0, min(1, 0.25 + strength * 0.4)) // 阴影较多调整
        let mid = max(0, min(1, 0.5 + strength)) // 中间调最多调整
        let highlight = max(0, min(1, 0.75 + strength * 0.4)) // 高光较多调整
        let white = max(0, min(1, 1.0 + strength * 0.2)) // 白点轻微调整

        filter.setValue(CIVector(x: 0, y: black), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: shadow), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: mid), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: highlight), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1, y: white), forKey: "inputPoint4")

        return filter.outputImage ?? image
    }

    // Capture One 风格的亮度调整
    // C1 的亮度调整保留高光和阴影细节，主要影响中间调
    // 使用 S 曲线的变体，避免端点过度
    private static func applyBrightness(to image: CIImage, value: Double) -> CIImage {
        if value == 0.0 { return image }

        // C1 的亮度算法：使用曲线实现智能亮度调整
        // 中间调调整最多，两端调整较少
        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // 计算曲线关键点
        // value 范围 [-1, 1]
        let strength = value * 0.3 // 更温和的调整

        // 使用抛物线式调整：中间调整最多，两端调整最少
        let black = max(0, min(1, 0.0 + strength * 0.1))
        let shadow = max(0, min(1, 0.25 + strength * 0.7))
        let mid = max(0, min(1, 0.5 + strength))
        let highlight = max(0, min(1, 0.75 + strength * 0.7))
        let white = max(0, min(1, 1.0 + strength * 0.1))

        filter.setValue(CIVector(x: 0, y: black), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: shadow), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: mid), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: highlight), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1, y: white), forKey: "inputPoint4")

        return filter.outputImage ?? image
    }

    // Photoshop 风格的对比度调整
    // 对比度围绕中点（0.5）进行 S 曲线调整
    private static func applyContrast(to image: CIImage, value: Double) -> CIImage {
        if value == 1.0 { return image }

        // Photoshop 的对比度算法：output = (input - 0.5) * contrast + 0.5
        // 这样可以保证中点不变
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

    // Photoshop/Lightroom 风格的高光、阴影、白色、黑色调整
    // 这些调整使用参数化曲线，针对不同亮度范围进行调整
    private static func applyHighlightsShadows(
        to image: CIImage,
        highlights: Double,
        shadows: Double,
        whites: Double,
        blacks: Double
    ) -> CIImage {
        // 如果所有参数都是默认值，直接返回
        if highlights == 1.0, shadows == 0.0, whites == 0.0, blacks == 0.0 {
            return image
        }

        // 使用 CIToneCurve 构建复杂的曲线来模拟 Photoshop 的算法
        // Photoshop 的算法特点：
        // - 高光 (Highlights): 影响 0.5-0.9 范围，中心在 0.7
        // - 阴影 (Shadows): 影响 0.1-0.5 范围，中心在 0.3
        // - 白色 (Whites): 影响 0.8-1.0 范围
        // - 黑色 (Blacks): 影响 0.0-0.2 范围

        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // 计算曲线上的关键点
        // 黑色点 (input: 0.05, 受 blacks 影响)
        let blackPoint = 0.05 + blacks * 0.05

        // 阴影点 (input: 0.25, 受 shadows 和 blacks 影响)
        let shadowPoint = 0.25 + shadows * 0.15 + blacks * 0.03

        // 中点 (input: 0.5, 受所有参数轻微影响)
        let midPoint = 0.5 + (shadows * 0.05) + (highlights - 1.0) * 0.05

        // 高光点 (input: 0.75, 受 highlights 和 whites 影响)
        let highlightPoint = 0.75 + (highlights - 1.0) * 0.15 + whites * 0.03

        // 白色点 (input: 0.95, 受 whites 影响)
        let whitePoint = 0.95 + whites * 0.05

        // 设置曲线的 5 个控制点
        filter.setValue(CIVector(x: 0, y: max(0, min(1, blackPoint))), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: max(0, min(1, shadowPoint))), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: max(0, min(1, midPoint))), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: max(0, min(1, highlightPoint))), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1, y: max(0, min(1, whitePoint))), forKey: "inputPoint4")

        return filter.outputImage ?? image
    }

    private static func applyWhiteBalance(
        to image: CIImage,
        temperature: Double,
        tint: Double
    ) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // CIVector(x: 色温, y: 色调)
        // neutral: 源图片的白点（采样点测得的色温和色调）
        // targetNeutral: 目标白点（6500K 中性色温 + 0 色调）
        let neutralPoint = CIVector(x: temperature, y: tint)
        let targetPoint = CIVector(x: 6500, y: 0)

        filter.setValue(neutralPoint, forKey: "inputNeutral")
        filter.setValue(targetPoint, forKey: "inputTargetNeutral")

        return filter.outputImage ?? image
    }

    private static func applyClarity(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIUnsharpMask") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        let radius = abs(value) * 10.0
        let intensity = value > 0 ? value * 2.0 : value

        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(intensity, forKey: kCIInputIntensityKey)

        return filter.outputImage ?? image
    }

    private static func applyDehaze(to image: CIImage, value: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        let contrastAdjust = 1.0 + (value * 0.3)
        let saturationAdjust = 1.0 + (value * 0.2)
        let brightnessAdjust = value * 0.1

        filter.setValue(contrastAdjust, forKey: kCIInputContrastKey)
        filter.setValue(saturationAdjust, forKey: kCIInputSaturationKey)
        filter.setValue(brightnessAdjust, forKey: kCIInputBrightnessKey)

        return filter.outputImage ?? image
    }

    private static func applySharpness(to image: CIImage, value: Double) -> CIImage {
        if value < 0 {
            guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(abs(value) * 2.0, forKey: kCIInputRadiusKey)
            return filter.outputImage ?? image
        } else {
            guard let filter = CIFilter(name: "CISharpenLuminance") else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(value, forKey: kCIInputSharpnessKey)
            return filter.outputImage ?? image
        }
    }

    static func applyFilter(
        _ filterName: String,
        to image: CIImage,
        parameters: [String: Any] = [:]
    ) -> CIImage? {
        guard let filter = CIFilter(name: filterName) else {
            return nil
        }

        filter.setValue(image, forKey: kCIInputImageKey)

        for (key, value) in parameters {
            filter.setValue(value, forKey: key)
        }

        return filter.outputImage
    }

    private static func applyLUT(
        to image: CIImage,
        lutURL: URL,
        alpha: Double,
        lutColorSpace: String
    ) -> CIImage {
        let fileExtension = lutURL.pathExtension.lowercased()

        let cubeData: (data: Data, size: Int)? = switch fileExtension {
        case "cube":
            parseCubeLUT(from: lutURL)
        case "3dl":
            parse3DLLUT(from: lutURL)
        case "lut":
            parseBinaryLUT(from: lutURL)
        default:
            parseCubeLUT(from: lutURL)
        }

        guard let (data, size) = cubeData else {
            return image
        }

        // 如果是 sRGB 色彩空间，直接应用 LUT，无需转换
        if lutColorSpace == "sRGB" {
            guard let filter = CIFilter(name: "CIColorCube") else {
                return image
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(size, forKey: "inputCubeDimension")
            filter.setValue(data, forKey: "inputCubeData")
            guard let lutApplied = filter.outputImage else {
                return image
            }
            return applyLUTAlpha(original: image, lutApplied: lutApplied, alpha: alpha)
        }

        // 对于非 sRGB 色彩空间，需要进行转换
        guard let targetColorSpace = getLUTColorSpace(from: lutColorSpace) else {
            guard let filter = CIFilter(name: "CIColorCube") else {
                return image
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(size, forKey: "inputCubeDimension")
            filter.setValue(data, forKey: "inputCubeData")
            guard let lutApplied = filter.outputImage else {
                return image
            }
            return applyLUTAlpha(original: image, lutApplied: lutApplied, alpha: alpha)
        }

        // 转换到 LUT 色彩空间
        let imageInLUTSpace = convertColorSpace(image, to: targetColorSpace)

        guard let filter = CIFilter(name: "CIColorCube") else {
            return image
        }

        filter.setValue(imageInLUTSpace, forKey: kCIInputImageKey)
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")

        guard let lutAppliedInLUTSpace = filter.outputImage else {
            return image
        }

        // 转换回 sRGB 工作空间
        guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return lutAppliedInLUTSpace
        }
        let lutApplied = convertColorSpace(lutAppliedInLUTSpace, to: sRGBColorSpace)

        return applyLUTAlpha(original: image, lutApplied: lutApplied, alpha: alpha)
    }

    // 应用LUT的alpha混合
    private static func applyLUTAlpha(
        original: CIImage,
        lutApplied: CIImage,
        alpha: Double
    ) -> CIImage {
        // 如果alpha接近1，直接返回LUT结果
        if abs(alpha - 1.0) < 0.001 {
            return lutApplied
        }

        // 使用 CIBlendWithMask 或直接插值
        guard let blendFilter = CIFilter(name: "CISourceOverCompositing") else {
            return lutApplied
        }

        // 调整 LUT 结果的不透明度
        let alphaFilter = CIFilter(name: "CIColorMatrix")
        alphaFilter?.setValue(lutApplied, forKey: kCIInputImageKey)
        alphaFilter?.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        alphaFilter?.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        alphaFilter?.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        alphaFilter?.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha)), forKey: "inputAVector")

        guard let alphaAdjusted = alphaFilter?.outputImage else {
            return lutApplied
        }

        blendFilter.setValue(alphaAdjusted, forKey: kCIInputImageKey)
        blendFilter.setValue(original, forKey: kCIInputBackgroundImageKey)

        return blendFilter.outputImage ?? original
    }

    // 解析 .cube 格式 LUT（Adobe 标准格式）
    private static func parseCubeLUT(from url: URL) -> (data: Data, size: Int)? {
        guard let lutString = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let lines = lutString.components(separatedBy: .newlines)
        var cubeSize: Int?
        var floatData: [Float] = []

        // 解析 LUT_3D_SIZE
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2, let size = Int(parts[1]) {
                    cubeSize = size
                    break
                }
            }
        }

        guard let size = cubeSize else {
            return nil
        }

        // 解析数据
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") ||
                trimmed.hasPrefix("LUT_") || trimmed.hasPrefix("DOMAIN_") {
                continue
            }

            let values = trimmed.components(separatedBy: .whitespaces).compactMap { Float($0) }
            if values.count == 3 {
                floatData.append(values[0])
                floatData.append(values[1])
                floatData.append(values[2])
                floatData.append(1.0)
            }
        }

        let expectedCount = size * size * size * 4
        guard floatData.count == expectedCount else {
            return nil
        }

        let data = Data(bytes: floatData, count: floatData.count * MemoryLayout<Float>.size)
        return (data, size)
    }

    // 解析 .3dl 格式 LUT（Autodesk/Lustre 格式）
    private static func parse3DLLUT(from url: URL) -> (data: Data, size: Int)? {
        guard let lutString = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let lines = lutString.components(separatedBy: .newlines)
        var floatData: [Float] = []
        var meshSize: Int?

        // 查找 Mesh 行
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Mesh") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2, let size = Int(parts[1]) {
                    meshSize = size
                }
            }
        }

        let size = meshSize ?? 32

        // 解析数据行
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("Mesh") {
                continue
            }

            let values = trimmed.components(separatedBy: .whitespaces).compactMap { Float($0) }
            if values.count == 3 {
                // .3dl 格式值范围是 0-1023 或 0-4095，需要归一化
                let maxValue: Float = values.max() ?? 1.0
                let scale = maxValue > 10.0 ? maxValue : 1.0

                floatData.append(values[0] / scale)
                floatData.append(values[1] / scale)
                floatData.append(values[2] / scale)
                floatData.append(1.0)
            }
        }

        let expectedCount = size * size * size * 4
        guard floatData.count == expectedCount else {
            return nil
        }

        let data = Data(bytes: floatData, count: floatData.count * MemoryLayout<Float>.size)
        return (data, size)
    }

    // 解析二进制 .lut 格式
    private static func parseBinaryLUT(from url: URL) -> (data: Data, size: Int)? {
        guard let rawData = try? Data(contentsOf: url) else {
            return nil
        }

        // 常见的二进制 LUT 格式：64x64x64 或 32x32x32
        // 尝试推断尺寸
        let dataSize = rawData.count

        let possibleSizes = [64, 33, 32, 17, 16]
        var cubeSize: Int?

        for size in possibleSizes {
            let expectedBytes = size * size * size * 3 * MemoryLayout<Float>.size
            if dataSize == expectedBytes {
                cubeSize = size
                break
            }
        }

        guard let size = cubeSize else {
            return nil
        }

        // 读取并转换数据
        var floatData: [Float] = []
        let floatCount = size * size * size * 3

        rawData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let floatPtr = ptr.bindMemory(to: Float.self)
            for i in 0 ..< floatCount {
                if i % 3 == 0, i > 0 {
                    floatData.append(1.0)
                }
                floatData.append(floatPtr[i])
            }
            floatData.append(1.0)
        }

        let data = Data(bytes: floatData, count: floatData.count * MemoryLayout<Float>.size)
        return (data, size)
    }

    private static func applyTransform(
        to image: CIImage,
        rotation: Int,
        flipHorizontal: Bool,
        flipVertical: Bool
    ) -> CIImage {
        var result = image
        let extent = result.extent

        // 构建变换矩阵
        var transform = CGAffineTransform.identity

        // 1. 移动到原点（以中心为基准）
        let centerX = extent.midX
        let centerY = extent.midY
        transform = transform.translatedBy(x: centerX, y: centerY)

        // 2. 应用镜像
        if flipHorizontal {
            transform = transform.scaledBy(x: -1, y: 1)
        }
        if flipVertical {
            transform = transform.scaledBy(x: 1, y: -1)
        }

        // 3. 应用旋转
        if rotation != 0 {
            let radians = Double(rotation) * .pi / 180.0
            transform = transform.rotated(by: radians)
        }

        // 4. 移回中心
        transform = transform.translatedBy(x: -centerX, y: -centerY)

        // 应用变换
        result = result.transformed(by: transform)

        // 调整 extent 以确保图片居中显示
        let transformedExtent = result.extent

        // 如果旋转了 90 或 270 度，需要调整最终的 extent
        if rotation == 90 || rotation == 270 {
            let offsetX = (transformedExtent.width - extent.height) / 2
            let offsetY = (transformedExtent.height - extent.width) / 2
            let finalTransform = CGAffineTransform(translationX: -offsetX, y: -offsetY)
            result = result.transformed(by: finalTransform)
        }

        return result
    }

    // 获取LUT对应的CGColorSpace
    private static func getLUTColorSpace(from name: String) -> CGColorSpace? {
        switch name {
        case "sRGB":
            CGColorSpace(name: CGColorSpace.sRGB)
        case "Linear":
            CGColorSpace(name: CGColorSpace.linearSRGB)
        case "Rec.709":
            CGColorSpace(name: CGColorSpace.itur_709)
        case "Rec.2020":
            CGColorSpace(name: CGColorSpace.itur_2020)
        default:
            CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    // 将图像转换到目标色彩空间
    private static func convertColorSpace(
        _ image: CIImage,
        to targetColorSpace: CGColorSpace
    ) -> CIImage {
        // 使用 matchedToWorkingSpace 进行色彩空间匹配
        // 这个方法会保持原始精度，不会强制渲染到8位
        let convertedImage = image
            .matchedToWorkingSpace(from: image
                .colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)!
            .matchedFromWorkingSpace(to: targetColorSpace)!

        return convertedImage
    }
}
