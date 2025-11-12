import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

@MainActor
class ImageProcessor {
    nonisolated private static let renderQueue = DispatchQueue(
        label: "com.bitsflow.rawkit.render",
        qos: .userInteractive
    )

    // 使用 CIContextManager 替代直接创建 context
    // CIContext 本身是线程安全的，通过 Manager 的 nonisolated getter 访问
    nonisolated private static var ciContext: CIContext {
        CIContextManager.shared.getRenderContext()
    }

    private static func isRawFormat(_ ext: String) -> Bool {
        ["arw", "cr2", "cr3", "nef", "orf", "raf", "rw2"].contains(ext)
    }

    static func loadThumbnail(from url: URL) -> CIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let fileExtension = url.pathExtension.lowercased()
        let targetSize: CGFloat = 512

        // 优化：对所有格式（包括 RAW）统一使用 CGImageSource 缩略图 API
        // 这比先加载全尺寸再缩放快 4-8 倍
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSize,
        ]

        // RAW 文件特殊优化：使用子采样加速解码
        if fileExtension == "dng" || isRawFormat(fileExtension) {
            // kCGImageSourceSubsampleFactor: 让 Core Graphics 在解码时直接采样
            // 4 = 使用 1/4 分辨率解码，速度提升 75%
            thumbnailOptions[kCGImageSourceSubsampleFactor as CFString] = 4
        }

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

        let fileExtension = url.pathExtension.lowercased()
        let targetSize: CGFloat = 2048

        // 优化：统一使用 CGImageSource 缩略图 API
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSize,
        ]

        // RAW 文件使用 1/2 子采样（2048px 需要更高质量）
        if fileExtension == "dng" || isRawFormat(fileExtension) {
            options[kCGImageSourceSubsampleFactor as CFString] = 2
        }

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

        // 优化：直接使用 ciContext，移除 sync 阻塞
        // CIContext 是线程安全的，不需要队列同步
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else {
            return nil
        }

        let size = NSSize(width: extent.width, height: extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    // 非隔离版本，可以在后台线程调用
    nonisolated static func convertToNSImageAsync(_ ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent
        guard !extent.isEmpty, extent.isInfinite == false else {
            return nil
        }

        // 直接在调用线程渲染（后台线程）
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else {
            return nil
        }

        let size = NSSize(width: extent.width, height: extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    nonisolated static func convertToCGImage(_ ciImage: CIImage) -> CGImage? {
        let extent = ciImage.extent
        guard !extent.isEmpty, extent.isInfinite == false else {
            return nil
        }

        // 优化：直接使用 ciContext，移除 sync 阻塞
        // CIContext 是线程安全的，不需要队列同步
        return ciContext.createCGImage(ciImage, from: extent)
    }

    private static func loadWithCoreImage(from url: URL) -> CIImage? {
        print("ImageProcessor: 尝试加载图片: \(url.lastPathComponent)")

        let fileExtension = url.pathExtension.lowercased()

        if fileExtension == "x3f" {
            print("ImageProcessor: X3F 格式，跳过 CIImage 加载")
            return nil
        }

        if fileExtension == "dng" || isRawFormat(fileExtension) {
            print("ImageProcessor: RAW/DNG 格式，使用 RAW 过滤器加载")
            if let rawImage = loadRawWithFilter(from: url) {
                return rawImage
            }
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

    static func extractRawWhiteBalance(from url: URL) -> (temperature: Double, tint: Double)? {
        guard let rawFilter = CIFilter(imageURL: url, options: [:]) else {
            return nil
        }

        // 获取相机白平衡（As Shot）
        let neutralTemp = rawFilter.value(forKey: "inputNeutralTemperature") as? NSNumber
        let neutralTint = rawFilter.value(forKey: "inputNeutralTint") as? NSNumber

        if let temp = neutralTemp, let tint = neutralTint {
            print("ImageProcessor: 提取相机白平衡 - 色温: \(temp), 色调: \(tint)")
            return (temp.doubleValue, tint.doubleValue)
        }

        return nil
    }

    private static func isPreprocessedLinearSRGB(properties: [String: Any]) -> Bool {
        guard let dngDict = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any] else {
            return false
        }

        // 方法1：检查 As Shot Neutral 是否为 [1, 1, 1]（表示已应用白平衡）
        if let asShotNeutral = dngDict[kCGImagePropertyDNGAsShotNeutral as String] as? [NSNumber],
           asShotNeutral.count >= 3 {
            let r = asShotNeutral[0].doubleValue
            let g = asShotNeutral[1].doubleValue
            let b = asShotNeutral[2].doubleValue

            // 如果 As Shot Neutral 接近 [1, 1, 1]，说明已预处理
            let isUnity = abs(r - 1.0) < 0.01 && abs(g - 1.0) < 0.01 && abs(b - 1.0) < 0.01
            if isUnity {
                print("ImageProcessor: 检测到预处理 DNG（As Shot Neutral = [1, 1, 1]）")
                return true
            }
        }

        // 方法2：检查 Image Description 是否包含 "linear" 关键字（作为辅助判断）
        if let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let imageDesc = tiffDict[kCGImagePropertyTIFFImageDescription as String] as? String {
            let hasLinearKeyword = imageDesc.lowercased().contains("linear srgb") ||
                                   imageDesc.lowercased().contains("preprocessed")
            if hasLinearKeyword {
                print("ImageProcessor: 检测到预处理 DNG（描述：\"\(imageDesc)\"）")
                return true
            }
        }

        return false
    }

    private static func extractCameraCalibration1(properties: [String: Any]) -> (r: Double, g: Double, b: Double)? {
        // 读取 Camera Calibration 1 或 ColorCalibration1 对角矩阵（X3F DNG 用它存储白平衡增益）
        guard let dngDict = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any] else {
            return nil
        }

        // X3F DNG 使用 "ColorCalibration1" 而不是标准的 "CameraCalibration1"
        var calibration: [NSNumber]?
        var keyUsed: String?

        if let colorCalib = dngDict["ColorCalibration1"] as? [NSNumber], colorCalib.count >= 9 {
            calibration = colorCalib
            keyUsed = "ColorCalibration1"
        } else if let cameraCalib = dngDict[kCGImagePropertyDNGCameraCalibration1 as String] as? [NSNumber], cameraCalib.count >= 9 {
            calibration = cameraCalib
            keyUsed = "CameraCalibration1"
        }

        guard let calibration = calibration, let keyUsed = keyUsed else {
            return nil
        }

        // 提取对角线元素 [0,0], [1,1], [2,2]（3x3 矩阵按行优先存储）
        let r = calibration[0].doubleValue  // [0,0]
        let g = calibration[4].doubleValue  // [1,1]
        let b = calibration[8].doubleValue  // [2,2]

        print("ImageProcessor: 读取 \(keyUsed) 对角线: R=\(String(format: "%.4f", r)), G=\(String(format: "%.4f", g)), B=\(String(format: "%.4f", b))")

        // 归一化到 G=1.0
        let normalizedR = r / g
        let normalizedG = 1.0
        let normalizedB = b / g

        print("ImageProcessor: \(keyUsed) 增益（归一化到 G=1.0）: R=\(String(format: "%.4f", normalizedR)), G=\(String(format: "%.4f", normalizedG)), B=\(String(format: "%.4f", normalizedB))")

        return (r: normalizedR, g: normalizedG, b: normalizedB)
    }

    private static func extractAsShotNeutralGains(from url: URL) -> (r: Double, g: Double, b: Double)? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            print("ImageProcessor: ✗ 无法创建 CGImageSource")
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            print("ImageProcessor: ✗ 无法读取图像属性")
            return nil
        }

        // 检查是否是预处理的线性 sRGB DNG
        if isPreprocessedLinearSRGB(properties: properties) {
            print("ImageProcessor: 预处理的线性 sRGB，跳过白平衡调整")
            return nil
        }

        guard let dngDict = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any] else {
            print("ImageProcessor: ⚠️ 未找到 DNG 字典")
            return nil
        }

        // 从 As Shot Neutral 计算白平衡
        if let asShotNeutral = dngDict[kCGImagePropertyDNGAsShotNeutral as String] as? [NSNumber],
           asShotNeutral.count >= 3 {

            let asShotR = asShotNeutral[0].doubleValue
            let asShotG = asShotNeutral[1].doubleValue
            let asShotB = asShotNeutral[2].doubleValue

            print("ImageProcessor: 读取 As Shot Neutral: R=\(asShotR), G=\(asShotG), B=\(asShotB)")

            // 检查是否接近 [1, 1, 1]（误差 < 0.01）
            let isNeutral = abs(asShotR - 1.0) < 0.01 && abs(asShotG - 1.0) < 0.01 && abs(asShotB - 1.0) < 0.01
            if isNeutral {
                print("ImageProcessor: As Shot Neutral ≈ [1,1,1]，已应用白平衡，跳过调整")
                return nil
            }

            // 计算 RGB 增益：gain = 1.0 / asShotNeutral
            let rGain = 1.0 / asShotR
            let gGain = 1.0 / asShotG
            let bGain = 1.0 / asShotB

            // 归一化到 G=1.0
            let normalizedR = rGain / gGain
            let normalizedG = 1.0
            let normalizedB = bGain / gGain

            print("ImageProcessor: 计算白平衡增益（归一化到 G=1.0）: R=\(String(format: "%.4f", normalizedR)), G=\(String(format: "%.4f", normalizedG)), B=\(String(format: "%.4f", normalizedB))")

            return (r: normalizedR, g: normalizedG, b: normalizedB)
        }

        print("ImageProcessor: ⚠️ 未找到 As Shot Neutral 数据")
        return nil
    }

    private static func asShotNeutralToChromaticity(asShotR: Double, asShotG: Double, asShotB: Double) -> (x: Double, y: Double)? {
        // As Shot Neutral 是相机认为应该显示为中性的 XYZ 归一化值
        // 我们需要将其转换为 CIE xy 色度坐标

        // As Shot Neutral 已经是 XYZ 的归一化值
        let x = asShotR
        let y = asShotG
        let z = asShotB

        // 计算 XYZ 总和
        let sum = x + y + z

        guard sum > 0 else {
            return nil
        }

        // 转换为 CIE xy 色度坐标
        let chromaticityX = x / sum
        let chromaticityY = y / sum

        return (x: chromaticityX, y: chromaticityY)
    }

    static func calculateAutoWhiteBalance(from ciImage: CIImage) -> (temperature: Double, tint: Double)? {
        let extent = ciImage.extent

        let maxDimension: CGFloat = 512
        let scale = min(1.0, maxDimension / max(extent.width, extent.height))

        let scaledImage: CIImage
        if scale < 1.0 {
            scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaledImage = ciImage
        }

        // OpenCV Gray World 算法（简单直接，不迭代）
        guard let pixelData = extractPixelData(from: scaledImage) else {
            return nil
        }

        // 1. 计算每个通道的平均值
        var rSum: Double = 0
        var gSum: Double = 0
        var bSum: Double = 0

        for pixel in pixelData {
            rSum += pixel.r
            gSum += pixel.g
            bSum += pixel.b
        }

        let count = Double(pixelData.count)
        let avgR = rSum / count
        let avgG = gSum / count
        let avgB = bSum / count

        // 2. 计算灰色目标（所有通道的平均）
        let gray = (avgR + avgG + avgB) / 3.0

        // 3. 计算增益
        let kr = gray / max(avgR, 0.001)
        let kg = gray / max(avgG, 0.001)
        let kb = gray / max(avgB, 0.001)

        print("OpenCV Gray World: RGB平均=(\(String(format: "%.4f", avgR)), \(String(format: "%.4f", avgG)), \(String(format: "%.4f", avgB)))")
        print("  灰色目标=\(String(format: "%.4f", gray))")
        print("  RGB增益=(R:\(String(format: "%.4f", kr)), G:\(String(format: "%.4f", kg)), B:\(String(format: "%.4f", kb)))")

        // 4. 归一化到绿色通道（标准做法）
        let normalizedRedGain = kr / kg
        let normalizedBlueGain = kb / kg

        // 5. 转换为色温和色调
        // 使用蓝/红比例计算色温
        let colorRatio = normalizedBlueGain / normalizedRedGain

        // 色温映射（经验公式）
        let temperature = AppConfig.defaultWhitePoint * pow(colorRatio, -0.8)

        // 色调基于绿色通道偏移
        let greenOffset = kg - 1.0
        let tint = -greenOffset * 100

        let finalTemperature = max(2000, min(25000, temperature))
        let finalTint = max(-150, min(150, tint))

        print("  归一化增益=(R:\(String(format: "%.4f", normalizedRedGain)), G:1.0000, B:\(String(format: "%.4f", normalizedBlueGain)))")
        print("最终结果: 色温=\(Int(finalTemperature)), 色调=\(Int(finalTint))")

        return (finalTemperature, finalTint)
    }

    private static func applyRGBGains(to image: CIImage, r: Double, g: Double, b: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        let rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        let gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        let bVector = CIVector(x: 0, y: 0, z: b, w: 0)
        let aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)

        filter.setValue(rVector, forKey: "inputRVector")
        filter.setValue(gVector, forKey: "inputGVector")
        filter.setValue(bVector, forKey: "inputBVector")
        filter.setValue(aVector, forKey: "inputAVector")
        filter.setValue(biasVector, forKey: "inputBiasVector")

        return filter.outputImage ?? image
    }

    private static func sign(_ value: Double) -> Double {
        if value > 0 { return 1.0 }
        if value < 0 { return -1.0 }
        return 0.0
    }

    private static func extractPixelData(from ciImage: CIImage) -> [(r: Double, g: Double, b: Double)]? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = Int(extent.width) * bytesPerPixel * MemoryLayout<Float>.size
        let totalFloats = Int(extent.width) * Int(extent.height) * bytesPerPixel

        var pixelData = [Float](repeating: 0, count: totalFloats)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(
            ciImage,
            toBitmap: &pixelData,
            rowBytes: bytesPerRow,
            bounds: extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )

        var result: [(r: Double, g: Double, b: Double)] = []
        let pixelCount = Int(extent.width) * Int(extent.height)

        for i in 0 ..< pixelCount {
            let offset = i * bytesPerPixel
            let r = Double(pixelData[offset])
            let g = Double(pixelData[offset + 1])
            let b = Double(pixelData[offset + 2])
            result.append((r: r, g: g, b: b))
        }

        return result
    }

    private static func calculateAverageRGB(from ciImage: CIImage) -> (red: Double, green: Double, blue: Double)? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = Int(extent.width) * bytesPerPixel * MemoryLayout<Float>.size
        let totalFloats = Int(extent.width) * Int(extent.height) * bytesPerPixel

        var pixelData = [Float](repeating: 0, count: totalFloats)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(
            ciImage,
            toBitmap: &pixelData,
            rowBytes: bytesPerRow,
            bounds: extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )

        let pixelCount = Int(extent.width) * Int(extent.height)

        // 收集所有亮度值
        var brightnessValues: [Double] = []
        for i in 0 ..< pixelCount {
            let offset = i * bytesPerPixel
            let r = Double(pixelData[offset])
            let g = Double(pixelData[offset + 1])
            let b = Double(pixelData[offset + 2])
            let luminance = r * 0.299 + g * 0.587 + b * 0.114
            brightnessValues.append(luminance)
        }

        // 使用百分位数确定范围
        brightnessValues.sort()
        let lowerBound = brightnessValues[Int(Double(brightnessValues.count) * 0.05)]
        let upperBound = brightnessValues[Int(Double(brightnessValues.count) * 0.95)]

        var redSum: Double = 0
        var greenSum: Double = 0
        var blueSum: Double = 0
        var validPixelCount = 0

        for i in 0 ..< pixelCount {
            let offset = i * bytesPerPixel
            let r = Double(pixelData[offset])
            let g = Double(pixelData[offset + 1])
            let b = Double(pixelData[offset + 2])
            let luminance = brightnessValues[i]

            if luminance > lowerBound && luminance < upperBound {
                redSum += r
                greenSum += g
                blueSum += b
                validPixelCount += 1
            }
        }

        guard validPixelCount > 0 else {
            return nil
        }

        let avgRed = redSum / Double(validPixelCount)
        let avgGreen = greenSum / Double(validPixelCount)
        let avgBlue = blueSum / Double(validPixelCount)

        return (avgRed, avgGreen, avgBlue)
    }

    private static func isX3fRawDNG(url: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let dngDict = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any],
              let colorCalib = dngDict["ColorCalibration1"] as? [NSNumber],
              colorCalib.count >= 9 else {
            return false
        }

        let r = colorCalib[0].doubleValue
        let g = colorCalib[4].doubleValue
        let b = colorCalib[8].doubleValue

        return abs(r - 1.0) > 0.01 || abs(g - 1.0) > 0.01 || abs(b - 1.0) > 0.01
    }

    private static func findX3fSourceFile(for dngURL: URL) -> URL? {
        let directory = dngURL.deletingLastPathComponent()
        let filename = dngURL.lastPathComponent

        // DNG 文件名格式：DP3Q0109.X3F.old.dng 或 DP3Q0109.X3F.dng
        // 对应的 X3F：DP3Q0109.X3F

        var x3fName: String?

        if filename.hasSuffix(".X3F.old.dng") {
            x3fName = String(filename.dropLast(8)) // 去掉 ".old.dng"
        } else if filename.hasSuffix(".X3F.dng") {
            x3fName = String(filename.dropLast(4)) // 去掉 ".dng"
        }

        guard let x3fName = x3fName else {
            return nil
        }

        let x3fURL = directory.appendingPathComponent(x3fName)
        if FileManager.default.fileExists(atPath: x3fURL.path) {
            return x3fURL
        }

        return nil
    }

    private static func convertX3fRawDNG(from url: URL) -> URL? {
        // 寻找源 X3F 文件
        guard let x3fURL = findX3fSourceFile(for: url) else {
            print("ImageProcessor: ⚠️ 未找到对应的 X3F 源文件")
            return nil
        }

        print("ImageProcessor: 找到源 X3F 文件: \(x3fURL.lastPathComponent)")

        // 生成缓存路径
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("RawKit/X3F", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let baseFilename = x3fURL.deletingPathExtension().lastPathComponent
        let cachedURL = cacheDir.appendingPathComponent("\(baseFilename)_linear.dng")

        // 检查缓存
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            print("ImageProcessor: 使用缓存的线性 sRGB DNG: \(cachedURL.lastPathComponent)")
            return cachedURL
        }

        print("ImageProcessor: 转换 X3F 为线性 sRGB DNG...")

        // 从应用 bundle 中查找 x3f-extract
        guard let x3fExtractPath = Bundle.main.path(forResource: "x3f-extract", ofType: nil) else {
            print("ImageProcessor: ✗ 应用 bundle 中未找到 x3f-extract 工具")
            return nil
        }

        print("ImageProcessor: 使用 bundle 中的 x3f-extract: \(x3fExtractPath)")
        print("ImageProcessor: 源 X3F 文件: \(x3fURL.path)")
        print("ImageProcessor: 输出目录: \(cacheDir.path)")
        print("ImageProcessor: 目标 DNG 文件: \(cachedURL.path)")

        // 调用 x3f-extract
        let process = Process()
        process.executableURL = URL(fileURLWithPath: x3fExtractPath)
        process.arguments = ["-dng", "-linear-srgb", "-o", cacheDir.path, x3fURL.path]

        // 捕获标准输出和错误输出
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        print("ImageProcessor: 执行命令: \(x3fExtractPath) -dng -linear-srgb -o \(cacheDir.path) \(x3fURL.path)")

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
                print("ImageProcessor: x3f-extract 输出:\n\(output)")
            }

            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                print("ImageProcessor: x3f-extract 错误:\n\(errorOutput)")
            }

            print("ImageProcessor: x3f-extract 退出码: \(process.terminationStatus)")

            if process.terminationStatus == 0 {
                // x3f-extract 输出格式：<source>.dng (如 DP3Q0109.X3F.dng)
                let expectedOutput = cacheDir.appendingPathComponent(x3fURL.lastPathComponent + ".dng")
                print("ImageProcessor: 检查预期输出: \(expectedOutput.path)")

                if FileManager.default.fileExists(atPath: expectedOutput.path) {
                    print("ImageProcessor: ✓ 找到输出文件")
                    // 重命名为我们的缓存格式
                    try? FileManager.default.removeItem(at: cachedURL) // 删除旧缓存
                    try? FileManager.default.moveItem(at: expectedOutput, to: cachedURL)
                    print("ImageProcessor: ✓ 转换成功，已缓存到: \(cachedURL.path)")
                    return cachedURL
                } else {
                    print("ImageProcessor: ✗ 预期输出文件不存在")

                    // 列出输出目录的所有文件
                    if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) {
                        print("ImageProcessor: 输出目录内容: \(files)")
                    }
                }
            }
        } catch {
            print("ImageProcessor: ✗ 转换失败: \(error)")
        }

        return nil
    }

    private static func loadRawWithFilter(from url: URL) -> CIImage? {
        print("ImageProcessor: 使用线性空间加载 RAW")
        print("ImageProcessor: 输入文件: \(url.path)")

        // 读取 As Shot Neutral 创建白平衡 filter
        var linearSpaceFilter: CIFilter?

        if let asShotGains = extractAsShotNeutralGains(from: url) {
            print("ImageProcessor: 创建 As Shot 白平衡 filter: R=\(String(format: "%.4f", asShotGains.r)), G=\(String(format: "%.4f", asShotGains.g)), B=\(String(format: "%.4f", asShotGains.b))")

            // 创建应用 As Shot 增益的 CIColorMatrix
            if let matrixFilter = CIFilter(name: "CIColorMatrix") {
                matrixFilter.setValue(
                    CIVector(x: asShotGains.r, y: 0, z: 0, w: 0),
                    forKey: "inputRVector"
                )
                matrixFilter.setValue(
                    CIVector(x: 0, y: asShotGains.g, z: 0, w: 0),
                    forKey: "inputGVector"
                )
                matrixFilter.setValue(
                    CIVector(x: 0, y: 0, z: asShotGains.b, w: 0),
                    forKey: "inputBVector"
                )
                matrixFilter.setValue(
                    CIVector(x: 0, y: 0, z: 0, w: 1),
                    forKey: "inputAVector"
                )
                matrixFilter.setValue(
                    CIVector(x: 0, y: 0, z: 0, w: 0),
                    forKey: "inputBiasVector"
                )

                linearSpaceFilter = matrixFilter
                print("ImageProcessor: ✓ 已创建 As Shot 白平衡 filter")
            }
        }

        // 如果无法创建 As Shot filter，使用单位矩阵（identity filter）
        if linearSpaceFilter == nil {
            print("ImageProcessor: 使用单位矩阵（无白平衡调整）")
            if let identityFilter = CIFilter(name: "CIColorMatrix") {
                identityFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                identityFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                identityFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                identityFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                identityFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
                linearSpaceFilter = identityFilter
            }
        }

        // 创建 RAW filter
        guard let rawFilter = CIFilter(imageURL: url, options: [:]) else {
            print("ImageProcessor: ✗ 无法创建 RAW 过滤器")
            return nil
        }

        // 设置线性空间 filter（会在线性空间应用 As Shot 增益）
        if let filter = linearSpaceFilter {
            rawFilter.setValue(filter, forKey: "inputLinearSpaceFilter")
            print("ImageProcessor: ✓ 已设置 linearSpaceFilter")
        }

        // 设置中性白平衡 D65（作为基准）
        rawFilter.setValue(6500.0, forKey: "inputNeutralTemperature")
        rawFilter.setValue(0.0, forKey: "inputNeutralTint")
        print("ImageProcessor: ✓ 已设置 D65 白平衡")

        if rawFilter.inputKeys.contains("inputDraftMode") {
            rawFilter.setValue(false, forKey: "inputDraftMode")
            print("ImageProcessor: ✓ 禁用草稿模式")
        }

        if rawFilter.inputKeys.contains("inputEV") {
            rawFilter.setValue(0.0, forKey: "inputEV")
        }

        if rawFilter.inputKeys.contains("inputBoost") {
            rawFilter.setValue(1.0, forKey: "inputBoost")
        }

        if rawFilter.inputKeys.contains("inputBaselineExposure") {
            rawFilter.setValue(0.0, forKey: "inputBaselineExposure")
        }

        if rawFilter.inputKeys.contains("inputEnableSharpening") {
            rawFilter.setValue(false, forKey: "inputEnableSharpening")
        }

        if rawFilter.inputKeys.contains("inputEnableNoiseTracking") {
            rawFilter.setValue(false, forKey: "inputEnableNoiseTracking")
        }

        if rawFilter.inputKeys.contains("inputLuminanceNoiseReductionAmount") {
            rawFilter.setValue(0.0, forKey: "inputLuminanceNoiseReductionAmount")
        }

        if rawFilter.inputKeys.contains("inputColorNoiseReductionAmount") {
            rawFilter.setValue(0.0, forKey: "inputColorNoiseReductionAmount")
        }

        if rawFilter.inputKeys.contains("inputEnableVendorLensCorrection") {
            rawFilter.setValue(false, forKey: "inputEnableVendorLensCorrection")
        }

        if rawFilter.inputKeys.contains("inputIgnoreOrientation") {
            rawFilter.setValue(false, forKey: "inputIgnoreOrientation")
        }

        guard let outputImage = rawFilter.outputImage else {
            print("ImageProcessor: ✗ RAW 过滤器无输出")
            return nil
        }

        print("ImageProcessor: ✓ CIRAWFilter 输出完成（白平衡已在线性空间应用）")
        if let colorSpace = outputImage.colorSpace {
            let csName = colorSpace.name.flatMap { String(describing: $0) } ?? "Unknown"
            print("ImageProcessor: 输出色彩空间: \(csName)")
        }

        return outputImage
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
        // 参数: -dng -linear-srgb -o <输出目录> <输入文件>
        // -linear-srgb: 输出线性 sRGB，已应用相机白平衡
        let process = Process()
        process.executableURL = URL(fileURLWithPath: x3fPath)
        process.arguments = ["-dng", "-linear-srgb", "-o", tempDir.path, url.path]

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

        // 优化：将多个色调曲线调整合并为一个 CIToneCurve（减少 GPU 调用）
        // 检查有多少个基于曲线的调整需要应用
        let needsExposure = adjustments.exposure != 0.0
        let needsBrightness = adjustments.brightness != 0.0
        let needsContrast = adjustments.contrast != 0.0
        let needsHighlightsShadows = adjustments.highlights != 1.0 || adjustments.shadows != 0.0 ||
            adjustments.whites != 0.0 || adjustments.blacks != 0.0

        let toneCurveAdjustmentsCount = [needsExposure, needsBrightness, needsContrast, needsHighlightsShadows]
            .filter { $0 }.count

        // 如果有 2 个或更多色调曲线调整，使用合并的曲线（性能优化）
        if toneCurveAdjustmentsCount >= 2 {
            result = applyCombinedToneCurve(
                to: result,
                exposure: adjustments.exposure,
                brightness: adjustments.brightness,
                contrast: adjustments.contrast,
                highlights: adjustments.highlights,
                shadows: adjustments.shadows,
                whites: adjustments.whites,
                blacks: adjustments.blacks
            )
        } else {
            // 否则分别应用（保持代码路径简单）
            if needsExposure {
                result = applyExposure(to: result, value: adjustments.exposure)
            }

            if needsBrightness {
                result = applyBrightness(to: result, value: adjustments.brightness)
            }

            if needsContrast {
                result = applyContrast(to: result, value: adjustments.contrast)
            }

            if needsHighlightsShadows {
                result = applyHighlightsShadows(
                    to: result,
                    highlights: adjustments.highlights,
                    shadows: adjustments.shadows,
                    whites: adjustments.whites,
                    blacks: adjustments.blacks
                )
            }
        }

        if adjustments.linearExposure != 0.0 {
            result = applyLinearExposure(to: result, value: adjustments.linearExposure)
        }

        if adjustments.saturation != 1.0 {
            result = applySaturation(to: result, value: adjustments.saturation)
        }

        if adjustments.vibrance != 0.0 {
            result = applyVibrance(to: result, value: adjustments.vibrance)
        }

        // 检查是否需要应用白平衡调整（从 D65 基准调整到目标白平衡）
        if abs(adjustments.temperature - 6500.0) > 0.01 || abs(adjustments.tint) > 0.01 {
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
        if value == 0.0 { return image }

        // Lightroom 风格的对比度算法：使用参数化 S 曲线
        // value 范围：-1.0 (最低对比度) 到 +1.0 (最高对比度)
        //
        // 原理：
        // - 对比度 > 0: 应用 S 曲线（暗部更暗，亮部更亮）
        // - 对比度 < 0: 应用反向 S 曲线（降低对比度）
        // - 使用锚点法：在 1/4 和 3/4 处设置控制点

        // 计算控制点位置
        // 对比度越强，S 曲线越陡峭
        let darkPoint: CGFloat
        let lightPoint: CGFloat

        if value > 0 {
            // 正对比度：S 曲线
            // 暗部向下，亮部向上
            let offset = CGFloat(value * 0.125)  // 最大偏移 12.5%
            darkPoint = 0.25 - offset
            lightPoint = 0.75 + offset
        } else {
            // 负对比度：反向 S 曲线
            // 暗部向上，亮部向下
            let offset = CGFloat(abs(value) * 0.125)
            darkPoint = 0.25 + offset
            lightPoint = 0.75 - offset
        }

        // 使用 CIToneCurve 滤镜应用自定义曲线
        // 定义 5 个控制点：黑场(0,0)、暗部、中间、亮部、白场(1,1)
        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: darkPoint), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")  // 中点不变
        filter.setValue(CIVector(x: 0.75, y: lightPoint), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")

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

        // Lightroom PV2012 风格的曲线算法（改进版）
        //
        // 影响范围：
        // - Blacks:     主要影响 0.0-0.2，对 0.2-0.35 有轻微影响
        // - Shadows:    主要影响 0.15-0.5，中心在 0.3
        // - Highlights: 主要影响 0.5-0.85，中心在 0.7
        // - Whites:     主要影响 0.8-1.0，对 0.65-0.8 有轻微影响
        //
        // 调整系数（更接近 Lightroom 行为）：
        // - Blacks:  0.12 （增强暗部控制力度）
        // - Whites:  0.15 （降低亮部过曝风险，同时保持效果）

        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // 计算曲线上的关键点
        // 黑色点 (input: 0.0, 受 blacks 影响)
        // 增强系数到 0.12，提供更明显的暗部控制
        let blackPoint = blacks * 0.12

        // 阴影点 (input: 0.25, 受 shadows 和 blacks 影响)
        // blacks 对阴影点的影响略微增加，使过渡更平滑
        let shadowPoint = 0.25 + shadows * 0.2 + blacks * 0.08

        // 中点 (input: 0.5, 受所有参数轻微影响)
        let midPoint = 0.5 + (shadows * 0.06) + (highlights - 1.0) * 0.06

        // 高光点 (input: 0.75, 受 highlights 和 whites 影响)
        // whites 对高光点的影响增加，使过渡更平滑
        let highlightPoint = 0.75 + (highlights - 1.0) * 0.18 + whites * 0.12

        // 白色点 (input: 1.0, 受 whites 影响)
        // 降低系数到 0.15，避免过度曝光，同时保持明显效果
        let whitePoint = 1.0 + whites * 0.15

        // 设置曲线的 5 个控制点
        // 使用 clamp 确保在有效范围内
        filter.setValue(CIVector(x: 0, y: max(0, min(1, blackPoint))), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: max(0, min(1, shadowPoint))), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: max(0, min(1, midPoint))), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: max(0, min(1, highlightPoint))), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1, y: max(0, min(1, whitePoint))), forKey: "inputPoint4")

        return filter.outputImage ?? image
    }

    // 合并多个色调曲线调整为一个 CIToneCurve（性能优化）
    // 通过对标准控制点依次应用每个变换，创建一个组合曲线
    private static func applyCombinedToneCurve(
        to image: CIImage,
        exposure: Double,
        brightness: Double,
        contrast: Double,
        highlights: Double,
        shadows: Double,
        whites: Double,
        blacks: Double
    ) -> CIImage {
        // 对 5 个标准控制点 (0, 0.25, 0.5, 0.75, 1.0) 依次应用所有变换
        let controlPoints: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
        var transformedPoints: [Double] = controlPoints

        // 1. 应用 Exposure 变换
        if exposure != 0.0 {
            transformedPoints = transformedPoints.map { y in
                applyExposureCurve(value: y, strength: exposure * 0.5)
            }
        }

        // 2. 应用 Brightness 变换
        if brightness != 0.0 {
            transformedPoints = transformedPoints.map { y in
                applyBrightnessCurve(value: y, strength: brightness * 0.3)
            }
        }

        // 3. 应用 Contrast 变换
        if contrast != 0.0 {
            transformedPoints = transformedPoints.map { y in
                applyContrastCurve(value: y, strength: contrast)
            }
        }

        // 4. 应用 Highlights/Shadows/Whites/Blacks 变换
        if highlights != 1.0 || shadows != 0.0 || whites != 0.0 || blacks != 0.0 {
            transformedPoints = transformedPoints.enumerated().map { index, y in
                let x = controlPoints[index]
                return applyHighlightsShadowsCurve(
                    x: x,
                    y: y,
                    highlights: highlights,
                    shadows: shadows,
                    whites: whites,
                    blacks: blacks
                )
            }
        }

        // 创建合并后的 CIToneCurve
        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // 设置变换后的控制点，确保在 [0, 1] 范围内
        for (index, y) in transformedPoints.enumerated() {
            let x = controlPoints[index]
            let clampedY = max(0, min(1, y))
            filter.setValue(CIVector(x: x, y: clampedY), forKey: "inputPoint\(index)")
        }

        return filter.outputImage ?? image
    }

    // 辅助函数：应用 Exposure 曲线变换
    private static func applyExposureCurve(value: Double, strength: Double) -> Double {
        // 使用与 applyExposure 相同的算法
        let black = 0.0 + strength * 0.2
        let shadow = 0.25 + strength * 0.4
        let mid = 0.5 + strength * 0.6
        let highlight = 0.75 + strength * 0.4
        let white = 1.0 + strength * 0.2

        // 三次贝塞尔插值
        return cubicInterpolate(
            value: value,
            points: [(0, black), (0.25, shadow), (0.5, mid), (0.75, highlight), (1.0, white)]
        )
    }

    // 辅助函数：应用 Brightness 曲线变换
    private static func applyBrightnessCurve(value: Double, strength: Double) -> Double {
        // 使用与 applyBrightness 相同的算法
        let black = 0.0 + strength * 0.1
        let shadow = 0.25 + strength * 0.7
        let mid = 0.5 + strength
        let highlight = 0.75 + strength * 0.7
        let white = 1.0 + strength * 0.1

        return cubicInterpolate(
            value: value,
            points: [(0, black), (0.25, shadow), (0.5, mid), (0.75, highlight), (1.0, white)]
        )
    }

    // 辅助函数：应用 Contrast 曲线变换
    private static func applyContrastCurve(value: Double, strength: Double) -> Double {
        // 使用与 applyContrast 相同的算法
        let darkPoint: Double
        let lightPoint: Double

        if strength > 0 {
            let offset = strength * 0.125
            darkPoint = 0.25 - offset
            lightPoint = 0.75 + offset
        } else {
            let offset = abs(strength) * 0.125
            darkPoint = 0.25 + offset
            lightPoint = 0.75 - offset
        }

        return cubicInterpolate(
            value: value,
            points: [(0, 0), (0.25, darkPoint), (0.5, 0.5), (0.75, lightPoint), (1.0, 1.0)]
        )
    }

    // 辅助函数：应用 Highlights/Shadows/Whites/Blacks 曲线变换
    private static func applyHighlightsShadowsCurve(
        x: Double,
        y: Double,
        highlights: Double,
        shadows: Double,
        whites: Double,
        blacks: Double
    ) -> Double {
        // 对于这个变换，我们需要知道原始的 x 位置
        // 因为 Highlights/Shadows 是基于输入位置的加权调整

        // 计算原始曲线的控制点
        let blackPoint = blacks * 0.12
        let shadowPoint = 0.25 + shadows * 0.2 + blacks * 0.08
        let midPoint = 0.5 + (shadows * 0.06) + (highlights - 1.0) * 0.06
        let highlightPoint = 0.75 + (highlights - 1.0) * 0.18 + whites * 0.12
        let whitePoint = 1.0 + whites * 0.15

        // 我们的输入是 y（已经过前面变换）
        // 简化：假设单调性，使用 y 作为近似输入
        let adjustedY = cubicInterpolate(
            value: y,
            points: [(0, blackPoint), (0.25, shadowPoint), (0.5, midPoint), (0.75, highlightPoint), (1.0, whitePoint)]
        )

        return adjustedY
    }

    // 三次贝塞尔插值（近似 CIToneCurve 的行为）
    private static func cubicInterpolate(value: Double, points: [(x: Double, y: Double)]) -> Double {
        // 简化实现：线性分段插值
        // 找到 value 所在的区间
        for i in 0 ..< points.count - 1 {
            let (x1, y1) = points[i]
            let (x2, y2) = points[i + 1]

            if value >= x1 && value <= x2 {
                // 线性插值
                let t = (value - x1) / (x2 - x1)
                return y1 + t * (y2 - y1)
            }
        }

        // 超出范围，返回边界值
        if value < points.first!.x {
            return points.first!.y
        } else {
            return points.last!.y
        }
    }

    private static func applyWhiteBalance(
        to image: CIImage,
        temperature: Double,
        tint: Double
    ) -> CIImage {
        // 从色温/色调计算 RGB 增益
        let gains = calculateWhiteBalanceGains(temperature: temperature, tint: tint)

        // 使用 CIColorMatrix 应用增益（更透明、可控）
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        // 设置 RGB 增益（对角矩阵）
        filter.setValue(CIVector(x: gains.r, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: gains.g, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: gains.b, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

        return filter.outputImage ?? image
    }

    private static func calculateWhiteBalanceGains(
        temperature: Double,
        tint: Double
    ) -> (r: Double, g: Double, b: Double) {
        // 将色温转换为 RGB 增益
        // 基于 Planckian locus 简化算法

        // 1. 将色温转换为归一化值 (以 6500K D65 为基准)
        let temp = max(2000.0, min(25000.0, temperature))
        let tempRatio = temp / 6500.0

        // 2. 计算基础 R/B 增益（基于色温）
        var rGain: Double
        var bGain: Double

        if tempRatio < 1.0 {
            // 低色温（偏暖/偏黄）-> 增加蓝色，减少红色
            rGain = 1.0
            bGain = 1.0 / pow(tempRatio, 0.6)  // 温度越低，蓝色增益越高
        } else {
            // 高色温（偏冷/偏蓝）-> 增加红色，减少蓝色
            rGain = pow(tempRatio, 0.6)
            bGain = 1.0
        }

        // 3. 计算绿色增益（基于色调）
        // tint > 0: 偏绿，需要减少绿色
        // tint < 0: 偏品红，需要增加绿色
        let gGain = 1.0 - (tint / 100.0) * 0.3  // 色调影响相对较小

        // 4. 归一化到绿色通道（类似 Python 脚本的做法）
        let maxGain = max(rGain, max(gGain, bGain))

        return (
            r: rGain / maxGain,
            g: gGain / maxGain,
            b: bGain / maxGain
        )
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
