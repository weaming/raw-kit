import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers
import simd

class ImageProcessor {
    private struct LUTCacheKey: Hashable {
        let path: String
        let modificationTime: TimeInterval
        let fileSize: Int64
    }

    private static var lutCache: [LUTCacheKey: (data: Data, size: Int)] = [:]
    private static var lutCacheOrder: [LUTCacheKey] = []
    private static let lutCacheLimit = 16
    private static let lutCacheLock = NSLock()

    private struct ChromaticityPoint {
        let x: Double
        let y: Double
    }

    private struct RGBPrimaries {
        let red: ChromaticityPoint
        let green: ChromaticityPoint
        let blue: ChromaticityPoint
        let white: ChromaticityPoint

        var rgbToXYZ: simd_double3x3 {
            let r = SIMD3<Double>(
                red.x / red.y,
                1.0,
                (1.0 - red.x - red.y) / red.y
            )
            let g = SIMD3<Double>(
                green.x / green.y,
                1.0,
                (1.0 - green.x - green.y) / green.y
            )
            let b = SIMD3<Double>(
                blue.x / blue.y,
                1.0,
                (1.0 - blue.x - blue.y) / blue.y
            )
            let whiteXYZ = SIMD3<Double>(
                white.x / white.y,
                1.0,
                (1.0 - white.x - white.y) / white.y
            )

            let primaries = simd_double3x3(columns: (r, g, b))
            let scale = simd_inverse(primaries) * whiteXYZ
            return simd_double3x3(columns: (
                r * scale.x,
                g * scale.y,
                b * scale.z
            ))
        }

        var xyzToRGB: simd_double3x3 {
            simd_inverse(rgbToXYZ)
        }
    }

    private struct AutoWhiteBalanceSample {
        let r: Double
        let g: Double
        let b: Double
        let luminance: Double
        let maxComponent: Double
        let chroma: Double
    }

    private struct AutoWhiteBalanceEstimate {
        let sample: (r: Double, g: Double, b: Double)
        let candidateCount: Int
        let luminanceRange: (lower: Double, upper: Double)
        let chromaCutoff: Double
    }

    private struct RawShootingMetadata {
        let neutralTemperature: Double?
        let neutralTint: Double?
        let ev: Double?
        let boost: Double?
        let baselineExposure: Double?
        let isVendorLensCorrectionEnabled: Bool?
    }

    private enum LUTTransferMode: Int {
        case linear = 0
        case sRGB = 1
        case gamma22 = 2
        case gamma24 = 3
        case gamma26 = 4
        case rec709 = 5
        case hlg = 6
        case pq = 7
        case fLog = 8
        case fLog2 = 9
        case fLog2C = 10
        case sLog2 = 11
        case sLog3 = 12
        case dLog = 13
        case canonLog3 = 14
        case vLog = 15

        init(_ transferFunction: LUTTransferFunction) {
            switch transferFunction {
            case .linear:
                self = .linear
            case .sRGB:
                self = .sRGB
            case .gamma22:
                self = .gamma22
            case .gamma24:
                self = .gamma24
            case .gamma26:
                self = .gamma26
            case .rec709:
                self = .rec709
            case .hlg:
                self = .hlg
            case .pq:
                self = .pq
            case .fLog:
                self = .fLog
            case .fLog2:
                self = .fLog2
            case .fLog2C:
                self = .fLog2C
            case .sLog2:
                self = .sLog2
            case .sLog3:
                self = .sLog3
            case .dLog:
                self = .dLog
            case .canonLog3:
                self = .canonLog3
            case .vLog:
                self = .vLog
            }
        }

        var kernelValue: CGFloat {
            CGFloat(rawValue)
        }
    }

    private static let colorKernelHelpers = """
    float positive(float value) {
        return max(value, 0.0);
    }

    float encodeSRGBValue(float value) {
        float v = positive(value);
        if (v <= 0.0031308) {
            return 12.92 * v;
        }
        return 1.055 * pow(v, 1.0 / 2.4) - 0.055;
    }

    float decodeSRGBValue(float value) {
        float v = positive(value);
        if (v <= 0.04045) {
            return v / 12.92;
        }
        return pow((v + 0.055) / 1.055, 2.4);
    }

    float encodeGammaValue(float value, float gamma) {
        return pow(positive(value), 1.0 / gamma);
    }

    float decodeGammaValue(float value, float gamma) {
        return pow(positive(value), gamma);
    }

    float encodeRec709Value(float value) {
        float v = positive(value);
        if (v < 0.018) {
            return 4.5 * v;
        }
        return 1.099 * pow(v, 0.45) - 0.099;
    }

    float decodeRec709Value(float value) {
        float v = positive(value);
        if (v < 0.081) {
            return v / 4.5;
        }
        return pow((v + 0.099) / 1.099, 1.0 / 0.45);
    }

    float encodeHLGValue(float value) {
        float v = positive(value);
        if (v <= (1.0 / 12.0)) {
            return sqrt(3.0 * v);
        }
        return 0.17883277 * log(12.0 * v - 0.28466892) + 0.55991073;
    }

    float decodeHLGValue(float value) {
        float v = positive(value);
        if (v <= 0.5) {
            return (v * v) / 3.0;
        }
        return (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
    }

    float encodePQValue(float value) {
        float v = positive(value);
        float m1 = 0.1593017578125;
        float m2 = 78.84375;
        float c1 = 0.8359375;
        float c2 = 18.8515625;
        float c3 = 18.6875;
        float powered = pow(v, m1);
        float numerator = c1 + c2 * powered;
        float denominator = 1.0 + c3 * powered;
        return pow(numerator / denominator, m2);
    }

    float decodePQValue(float value) {
        float v = positive(value);
        float m1 = 0.1593017578125;
        float m2 = 78.84375;
        float c1 = 0.8359375;
        float c2 = 18.8515625;
        float c3 = 18.6875;
        float powered = pow(v, 1.0 / m2);
        float numerator = max(powered - c1, 0.0);
        float denominator = c2 - c3 * powered;
        return pow(numerator / denominator, 1.0 / m1);
    }

    float encodeFLogValue(float value) {
        float v = positive(value);
        if (v >= 0.00089) {
            return 0.344676 * log(0.555556 * v + 0.009468) / log(10.0) + 0.790453;
        }
        return 8.735631 * v + 0.092864;
    }

    float decodeFLogValue(float value) {
        float v = positive(value);
        if (v >= 0.100537775223865) {
            return exp(((v - 0.790453) / 0.344676) * log(10.0)) / 0.555556 - 0.009468 / 0.555556;
        }
        return (v - 0.092864) / 8.735631;
    }

    float encodeFLog2Value(float value) {
        float v = positive(value);
        if (v >= 0.000889) {
            return 0.245281 * log(5.555556 * v + 0.064829) / log(10.0) + 0.384316;
        }
        return 8.799461 * v + 0.092864;
    }

    float decodeFLog2Value(float value) {
        float v = positive(value);
        if (v >= 0.100686685370811) {
            return exp(((v - 0.384316) / 0.245281) * log(10.0)) / 5.555556 - 0.064829 / 5.555556;
        }
        return (v - 0.092864) / 8.799461;
    }

    float encodeSLog2Value(float value) {
        float v = value;
        if (v >= 0.0) {
            return 0.432699 * log(155.0 * v / 219.0 + 0.037584) / log(10.0) + 0.646596;
        }
        return v * 3.53881278538813 + 0.030001222851889303;
    }

    float decodeSLog2Value(float value) {
        float v = positive(value);
        if (v >= 0.030001222851889303) {
            return 219.0 * (pow(10.0, (v - 0.646596) / 0.432699) - 0.037584) / 155.0;
        }
        return (v - 0.030001222851889303) / 3.53881278538813;
    }

    float encodeSLog3Value(float value) {
        float v = positive(value);
        if (v >= 0.01125) {
            return (420.0 + log((v + 0.01) / 0.19) / log(10.0) * 261.5) / 1023.0;
        }
        return (v * (171.2102946929 - 95.0) / 0.01125 + 95.0) / 1023.0;
    }

    float decodeSLog3Value(float value) {
        float v = positive(value);
        if (v >= 171.2102946929 / 1023.0) {
            return pow(10.0, (v * 1023.0 - 420.0) / 261.5) * 0.19 - 0.01;
        }
        return (v * 1023.0 - 95.0) * 0.01125 / (171.2102946929 - 95.0);
    }

    float encodeDLogValue(float value) {
        float v = positive(value);
        if (v <= 0.0078) {
            return 6.025 * v + 0.0929;
        }
        return log(v * 0.9892 + 0.0108) / log(10.0) * 0.256663 + 0.584555;
    }

    float decodeDLogValue(float value) {
        float v = positive(value);
        if (v <= 0.14) {
            return (v - 0.0929) / 6.025;
        }
        return (pow(10.0, 3.89616 * v - 2.27752) - 0.0108) / 0.9892;
    }

    float encodeCanonLog3Value(float value) {
        float v = positive(value);
        if (v < 0.014) {
            return 2.3069815 * v + 0.12512219;
        }
        return log(14.98325 * v + 1.0) / log(10.0) * 0.36726845 + 0.12783901;
    }

    float decodeCanonLog3Value(float value) {
        float v = positive(value);
        if (v < 0.15742) {
            return (v - 0.12512219) / 2.3069815;
        }
        return (pow(10.0, (v - 0.12783901) / 0.36726845) - 1.0) / 14.98325;
    }

    float encodeVLogValue(float value) {
        float v = positive(value);
        if (v < 0.01) {
            return 5.6 * v + 0.125;
        }
        return 0.241514 * log(v + 0.00873) / log(10.0) + 0.598206;
    }

    float decodeVLogValue(float value) {
        float v = positive(value);
        if (v < 0.181) {
            return (v - 0.125) / 5.6;
        }
        return pow(10.0, (v - 0.598206) / 0.241514) - 0.00873;
    }

    float encodeTransferValue(float value, float mode) {
        if (mode < 0.5) {
            return value;
        }
        if (mode < 1.5) {
            return encodeSRGBValue(value);
        }
        if (mode < 2.5) {
            return encodeGammaValue(value, 2.2);
        }
        if (mode < 3.5) {
            return encodeGammaValue(value, 2.4);
        }
        if (mode < 4.5) {
            return encodeGammaValue(value, 2.6);
        }
        if (mode < 5.5) {
            return encodeRec709Value(value);
        }
        if (mode < 6.5) {
            return encodeHLGValue(value);
        }
        if (mode < 7.5) {
            return encodePQValue(value);
        }
        if (mode < 8.5) {
            return encodeFLogValue(value);
        }
        if (mode < 10.5) {
            return encodeFLog2Value(value);
        }
        if (mode < 11.5) {
            return encodeSLog2Value(value);
        }
        if (mode < 12.5) {
            return encodeSLog3Value(value);
        }
        if (mode < 13.5) {
            return encodeDLogValue(value);
        }
        if (mode < 14.5) {
            return encodeCanonLog3Value(value);
        }
        if (mode < 15.5) {
            return encodeVLogValue(value);
        }
        return value;
    }

    float decodeTransferValue(float value, float mode) {
        if (mode < 0.5) {
            return value;
        }
        if (mode < 1.5) {
            return decodeSRGBValue(value);
        }
        if (mode < 2.5) {
            return decodeGammaValue(value, 2.2);
        }
        if (mode < 3.5) {
            return decodeGammaValue(value, 2.4);
        }
        if (mode < 4.5) {
            return decodeGammaValue(value, 2.6);
        }
        if (mode < 5.5) {
            return decodeRec709Value(value);
        }
        if (mode < 6.5) {
            return decodeHLGValue(value);
        }
        if (mode < 7.5) {
            return decodePQValue(value);
        }
        if (mode < 8.5) {
            return decodeFLogValue(value);
        }
        if (mode < 10.5) {
            return decodeFLog2Value(value);
        }
        if (mode < 11.5) {
            return decodeSLog2Value(value);
        }
        if (mode < 12.5) {
            return decodeSLog3Value(value);
        }
        if (mode < 13.5) {
            return decodeDLogValue(value);
        }
        if (mode < 14.5) {
            return decodeCanonLog3Value(value);
        }
        if (mode < 15.5) {
            return decodeVLogValue(value);
        }
        return value;
    }

    vec3 applyMatrix(vec3 color, vec3 row0, vec3 row1, vec3 row2) {
        return vec3(
            dot(color, row0),
            dot(color, row1),
            dot(color, row2)
        );
    }

    vec3 encodeTransfer(vec3 color, float mode) {
        return vec3(
            encodeTransferValue(color.r, mode),
            encodeTransferValue(color.g, mode),
            encodeTransferValue(color.b, mode)
        );
    }

    vec3 decodeTransfer(vec3 color, float mode) {
        return vec3(
            decodeTransferValue(color.r, mode),
            decodeTransferValue(color.g, mode),
            decodeTransferValue(color.b, mode)
        );
    }

    float sceneLuminance(vec3 color) {
        vec3 safeColor = max(color, vec3(0.0));
        return dot(safeColor, vec3(0.2126, 0.7152, 0.0722));
    }

    float compressPerceptualLuminance(float value) {
        float v = positive(value);
        return v / (1.0 + v);
    }

    float expandPerceptualLuminance(float value) {
        float v = clamp(value, 0.0, 0.99999);
        return v / max(1.0 - v, 1e-5);
    }

    float logitValue(float value) {
        float v = clamp(value, 1e-4, 0.9999);
        return log(v / (1.0 - v));
    }

    float logisticValue(float value) {
        return 1.0 / (1.0 + exp(-value));
    }

    float tonalWeight(float displayLuma, float pivot, float sigma) {
        if (sigma <= 0.0) {
            float lifted = smoothstep(0.03, 0.16, displayLuma);
            float rolled = 1.0 - smoothstep(0.84, 0.97, displayLuma);
            return 0.45 + 0.55 * lifted * rolled;
        }

        float delta = (displayLuma - pivot) / max(sigma, 1e-4);
        return exp(-0.5 * delta * delta);
    }
    """

    private static let colorMetalKernelSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" namespace coreimage {
    """ + colorKernelHelpers + """
    [[ stitchable ]] float4 lutInputTransform(sample_t image, float3 row0, float3 row1, float3 row2, float transferMode) {
        float3 linearColor = applyMatrix(image.rgb, row0, row1, row2);
        float3 encodedColor = encodeTransfer(linearColor, transferMode);
        return float4(encodedColor, image.a);
    }

    [[ stitchable ]] float4 lutOutputTransform(sample_t image, float3 row0, float3 row1, float3 row2, float transferMode) {
        float3 linearColor = decodeTransfer(image.rgb, transferMode);
        float3 workingColor = applyMatrix(linearColor, row0, row1, row2);
        return float4(workingColor, image.a);
    }

    [[ stitchable ]] float4 perceptualLuminanceShift(sample_t image, float amount, float pivot, float focusSigma, float maxShift) {
        float3 safeColor = max(image.rgb, float3(0.0));
        float luminance = sceneLuminance(safeColor);

        if (luminance <= 1e-6 || fabs(amount) <= 1e-6) {
            return float4(safeColor, image.a);
        }

        float compressedLuma = compressPerceptualLuminance(luminance);
        float displayLuma = encodeSRGBValue(compressedLuma);
        float weight = tonalWeight(displayLuma, pivot, focusSigma);
        float shiftedDisplayLuma = logisticValue(logitValue(displayLuma) + amount * maxShift * weight);
        float shiftedCompressedLuma = decodeSRGBValue(shiftedDisplayLuma);
        float shiftedLuminance = expandPerceptualLuminance(shiftedCompressedLuma);
        float scale = shiftedLuminance / max(luminance, 1e-6);

        return float4(safeColor * scale, image.a);
    }

    [[ stitchable ]] float4 hdrDisplayBoost(sample_t image, float brightness, float highlights, float whites, float headroom) {
        float3 safeColor = max(image.rgb, float3(0.0));
        float luminance = sceneLuminance(safeColor);

        if (luminance <= 1e-6) {
            return float4(safeColor, image.a);
        }

        float displayLuma = encodeSRGBValue(compressPerceptualLuminance(luminance));
        float highlightWeight = smoothstep(0.48, 0.88, displayLuma);
        float whiteWeight = smoothstep(0.76, 0.98, displayLuma);

        float baseScale = pow(2.0, brightness * 0.65);
        float highlightScale = 1.0 + highlights * 1.10 * highlightWeight;
        float whiteScale = 1.0 + whites * 1.60 * whiteWeight;
        float combinedScale = max(0.05, baseScale * max(0.05, highlightScale) * max(0.05, whiteScale));

        float3 boostedColor = safeColor * combinedScale;
        float safeHeadroom = max(headroom, 1.0);
        float3 shoulder = safeHeadroom * boostedColor / (boostedColor + safeHeadroom);
        float3 protectedColor = mix(boostedColor, shoulder, smoothstep(safeHeadroom * 0.72, safeHeadroom * 1.35, boostedColor));

        return float4(min(protectedColor, float3(safeHeadroom)), image.a);
    }
    }
    """

    private static let colorKernels: [String: CIColorKernel] = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: colorMetalKernelSource)
            return kernels.reduce(into: [String: CIColorKernel]()) { result, kernel in
                if let colorKernel = kernel as? CIColorKernel {
                    result[colorKernel.name] = colorKernel
                }
            }
        } catch {
            print("ImageProcessor: ⚠️ Metal kernel 编译失败: \(error)")
            return [:]
        }
    }()

    private static let lutInputTransformKernel: CIColorKernel? = colorKernels["lutInputTransform"]

    private static let lutOutputTransformKernel: CIColorKernel? = colorKernels["lutOutputTransform"]

    private static let perceptualLuminanceShiftKernel: CIColorKernel? = colorKernels["perceptualLuminanceShift"]

    private static let hdrDisplayBoostKernel: CIColorKernel? = colorKernels["hdrDisplayBoost"]

    // 使用 CIContextManager 替代直接创建 context
    // CIContext 本身是线程安全的，通过 Manager 的 nonisolated getter 访问
    private static var ciContext: CIContext {
        CIContextManager.shared.getRenderContext()
    }

    private static var standardDisplayColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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

    static func loadSquareThumbnail(from url: URL, maxPixelSize: CGFloat = 512) -> CIImage? {
        let fileExtension = url.pathExtension.lowercased()
        let thumbnail: CIImage?

        if fileExtension == "dng" || isRawFormat(fileExtension) {
            thumbnail = loadThumbnail(from: url)
        } else {
            thumbnail = loadFullImageThumbnail(from: url, maxPixelSize: maxPixelSize)
        }

        guard let thumbnail else {
            return nil
        }

        let squareImage = cropToCenteredSquare(thumbnail)
        let extent = squareImage.extent
        let maxDimension = max(extent.width, extent.height)

        guard maxDimension > 0, maxPixelSize > 0 else {
            return squareImage
        }

        let scale = min(1.0, maxPixelSize / maxDimension)
        guard scale < 1.0 else {
            return squareImage
        }

        return squareImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale),
            highQualityDownsample: true
        )
    }

    private static func loadFullImageThumbnail(from url: URL, maxPixelSize: CGFloat) -> CIImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize * 2, maxPixelSize),
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

    static func cropToCenteredSquare(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let sideLength = min(extent.width, extent.height)

        guard sideLength > 0,
              extent.isEmpty == false,
              extent.isInfinite == false else {
            return image
        }

        let cropRect = CGRect(
            x: extent.midX - sideLength / 2,
            y: extent.midY - sideLength / 2,
            width: sideLength,
            height: sideLength
        )

        return image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
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

    static func loadX3FPreviewImage(from url: URL) async -> NSImage? {
        guard url.pathExtension.lowercased() == "x3f" else {
            return nil
        }

        return await loadWithX3fExtract(from: url)
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

        guard let cgImage = createStandardDisplayCGImage(ciImage, from: extent) else {
            return nil
        }

        let size = NSSize(width: extent.width, height: extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    // 非隔离版本，可以在后台线程调用
    static func convertToNSImageAsync(_ ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent
        guard !extent.isEmpty, extent.isInfinite == false else {
            return nil
        }

        guard let cgImage = createStandardDisplayCGImage(ciImage, from: extent) else {
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

        return createStandardDisplayCGImage(ciImage, from: extent)
    }

    private static func createStandardDisplayCGImage(_ ciImage: CIImage, from extent: CGRect) -> CGImage? {
        ciContext.createCGImage(
            ciImage,
            from: extent,
            format: .RGBA8,
            colorSpace: standardDisplayColorSpace
        )
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
            .toneMapHDRtoSDR: false,
            .expandToHDR: true,
        ]

        if let expandedImage = loadHDRGainMapImage(from: url, baseOptions: options) {
            print("ImageProcessor: ✓ HDR gain map 已融合")
            return expandedImage
        }

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

        let cgImageOptions: [CFString: Any] = [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            kCGImageSourceDecodeRequestOptions: [
                kCGImageSourceGenerateImageSpecificLumaScaling: true,
            ],
        ]

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            cgImageOptions as CFDictionary
        ) else {
            print("ImageProcessor: ✗ 无法从 CGImageSource 创建 CGImage")
            return nil
        }

        print("ImageProcessor: ✓ CGImageSource 加载成功")
        return applyImageOrientation(to: CIImage(cgImage: cgImage), from: imageSource)
    }

    private static func applyImageOrientation(to image: CIImage, from imageSource: CGImageSource) -> CIImage {
        guard let orientation = readImageOrientation(from: imageSource) else {
            return image
        }

        return image.oriented(orientation)
    }

    private static func readImageOrientation(from imageSource: CGImageSource) -> CGImagePropertyOrientation? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let orientationNumber = properties[kCGImagePropertyOrientation] as? NSNumber,
            let orientationValue = UInt32(exactly: orientationNumber),
            let orientation = CGImagePropertyOrientation(rawValue: orientationValue)
        else {
            return nil
        }

        return orientation
    }

    private static func loadHDRGainMapImage(
        from url: URL,
        baseOptions: [CIImageOption: Any]
    ) -> CIImage? {
        let gainMapOptions: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .auxiliaryHDRGainMap: true,
        ]

        guard let gainMap = CIImage(contentsOf: url, options: gainMapOptions) else {
            return nil
        }

        var sdrBaseOptions = baseOptions
        sdrBaseOptions[.expandToHDR] = false
        sdrBaseOptions[.toneMapHDRtoSDR] = false
        sdrBaseOptions[.auxiliaryHDRGainMap] = false

        guard let sdrBaseImage = CIImage(contentsOf: url, options: sdrBaseOptions) else {
            return nil
        }

        let expandedImage = sdrBaseImage.applyingGainMap(gainMap)
        let resolvedHeadroom = max(
            Float(expandedImage.contentHeadroom),
            Float(sdrBaseImage.contentHeadroom),
            Float(gainMap.contentHeadroom),
            2.0
        )

        if #available(macOS 16.0, *) {
            return expandedImage.settingContentHeadroom(
                resolvedHeadroom
            )
        }

        return expandedImage
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

    static func calculateAutoWhiteBalance(from ciImage: CIImage) -> (temperature: Double, tint: Double)? {
        guard let samples = extractAutoWhiteBalanceSamples(from: ciImage, maxDimension: 256),
              samples.count >= 64 else {
            return nil
        }

        let estimate = estimateAutoWhiteBalanceNeutralSample(from: samples)
            ?? fallbackAutoWhiteBalanceEstimate(from: samples)

        guard let estimate,
              let whiteBalance = whiteBalanceFromNeutralSample(linearRGB: estimate.sample) else {
            return nil
        }

        print(
            "自动白平衡: 线性域候选 \(estimate.candidateCount)/\(samples.count), 亮度范围 \(String(format: "%.3f", estimate.luminanceRange.lower))-\(String(format: "%.3f", estimate.luminanceRange.upper)), 色差阈值 \(String(format: "%.3f", estimate.chromaCutoff))"
        )
        print(
            "  估计中性色样本=(\(String(format: "%.4f", estimate.sample.r)), \(String(format: "%.4f", estimate.sample.g)), \(String(format: "%.4f", estimate.sample.b)))"
        )
        print("  最终结果: 色温=\(Int(whiteBalance.temperature)), 色调=\(String(format: "%.1f", whiteBalance.tint))")

        return whiteBalance
    }

    private static func extractAutoWhiteBalanceSamples(
        from ciImage: CIImage,
        maxDimension: CGFloat
    ) -> [AutoWhiteBalanceSample]? {
        let extent = ciImage.extent
        guard !extent.isEmpty else {
            return nil
        }

        let scale = min(1.0, maxDimension / max(extent.width, extent.height))
        let scaledImage: CIImage
        if scale < 1.0 {
            scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaledImage = ciImage
        }

        let scaledExtent = scaledImage.extent.integral
        let width = max(Int(scaledExtent.width), 1)
        let height = max(Int(scaledExtent.height), 1)
        let bytesPerPixel = 4
        let rowBytes = width * bytesPerPixel * MemoryLayout<Float>.size
        let totalFloats = width * height * bytesPerPixel

        var pixelData = [Float](repeating: 0, count: totalFloats)
        let translatedImage = scaledImage.transformed(
            by: CGAffineTransform(
                translationX: -scaledExtent.origin.x,
                y: -scaledExtent.origin.y
            )
        )

        ciContext.render(
            translatedImage,
            toBitmap: &pixelData,
            rowBytes: rowBytes,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )

        var samples: [AutoWhiteBalanceSample] = []
        samples.reserveCapacity(width * height)

        for pixelIndex in 0 ..< (width * height) {
            let offset = pixelIndex * bytesPerPixel
            let alpha = Double(pixelData[offset + 3])
            guard alpha > 0.01 else { continue }

            let r = max(Double(pixelData[offset]), 0.0)
            let g = max(Double(pixelData[offset + 1]), 0.0)
            let b = max(Double(pixelData[offset + 2]), 0.0)

            guard r.isFinite, g.isFinite, b.isFinite else { continue }

            let maxComponent = max(r, max(g, b))
            guard maxComponent > 0.0005 else { continue }

            let minComponent = min(r, min(g, b))
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard luminance.isFinite, luminance > 0.001 else { continue }

            let chroma = (maxComponent - minComponent) / max(maxComponent, 0.000_01)
            guard chroma.isFinite else { continue }

            samples.append(
                AutoWhiteBalanceSample(
                    r: r,
                    g: g,
                    b: b,
                    luminance: luminance,
                    maxComponent: maxComponent,
                    chroma: chroma
                )
            )
        }

        return samples.isEmpty ? nil : samples
    }

    private static func estimateAutoWhiteBalanceNeutralSample(
        from samples: [AutoWhiteBalanceSample]
    ) -> AutoWhiteBalanceEstimate? {
        let sortedLuminance = samples.map(\.luminance).sorted()
        let sortedHighlights = samples.map(\.maxComponent).sorted()

        let luminanceLower = percentile(sortedLuminance, fraction: 0.12)
        let luminanceUpper = percentile(sortedLuminance, fraction: 0.98)
        let highlightLimit = percentile(sortedHighlights, fraction: 0.995)

        let exposureFiltered = samples.filter { sample in
            sample.luminance >= luminanceLower &&
                sample.luminance <= luminanceUpper &&
                sample.maxComponent <= highlightLimit
        }

        guard exposureFiltered.count >= 32 else {
            return nil
        }

        let sortedChroma = exposureFiltered.map(\.chroma).sorted()
        let strictChromaCutoff = min(
            0.35,
            max(0.03, percentile(sortedChroma, fraction: 0.35) * 1.25)
        )
        let relaxedChromaCutoff = min(
            0.45,
            max(strictChromaCutoff, percentile(sortedChroma, fraction: 0.55) * 1.2)
        )

        var candidateSamples = exposureFiltered.filter { $0.chroma <= strictChromaCutoff }
        var chromaCutoff = strictChromaCutoff

        let minimumCandidateCount = max(64, exposureFiltered.count / 20)
        if candidateSamples.count < minimumCandidateCount {
            chromaCutoff = relaxedChromaCutoff
            candidateSamples = exposureFiltered.filter { $0.chroma <= relaxedChromaCutoff }
        }

        if candidateSamples.count < minimumCandidateCount {
            let targetCount = min(max(minimumCandidateCount, exposureFiltered.count / 6), exposureFiltered.count)
            candidateSamples = Array(
                exposureFiltered.sorted { lhs, rhs in
                    if abs(lhs.chroma - rhs.chroma) > 0.000_01 {
                        return lhs.chroma < rhs.chroma
                    }
                    return lhs.luminance > rhs.luminance
                }
                .prefix(targetCount)
            )
            chromaCutoff = candidateSamples.last?.chroma ?? chromaCutoff
        }

        guard let neutralSample = weightedNeutralSample(
            from: candidateSamples,
            luminanceRange: (lower: luminanceLower, upper: luminanceUpper),
            chromaCutoff: chromaCutoff,
            favorNeutrality: true
        ) else {
            return nil
        }

        return AutoWhiteBalanceEstimate(
            sample: neutralSample,
            candidateCount: candidateSamples.count,
            luminanceRange: (lower: luminanceLower, upper: luminanceUpper),
            chromaCutoff: chromaCutoff
        )
    }

    private static func fallbackAutoWhiteBalanceEstimate(
        from samples: [AutoWhiteBalanceSample]
    ) -> AutoWhiteBalanceEstimate? {
        let sortedLuminance = samples.map(\.luminance).sorted()
        let luminanceLower = percentile(sortedLuminance, fraction: 0.08)
        let luminanceUpper = percentile(sortedLuminance, fraction: 0.97)

        let filteredSamples = samples.filter { sample in
            sample.luminance >= luminanceLower && sample.luminance <= luminanceUpper
        }

        guard let neutralSample = weightedNeutralSample(
            from: filteredSamples,
            luminanceRange: (lower: luminanceLower, upper: luminanceUpper),
            chromaCutoff: 1.0,
            favorNeutrality: false
        ) else {
            return nil
        }

        return AutoWhiteBalanceEstimate(
            sample: neutralSample,
            candidateCount: filteredSamples.count,
            luminanceRange: (lower: luminanceLower, upper: luminanceUpper),
            chromaCutoff: 1.0
        )
    }

    private static func weightedNeutralSample(
        from samples: [AutoWhiteBalanceSample],
        luminanceRange: (lower: Double, upper: Double),
        chromaCutoff: Double,
        favorNeutrality: Bool
    ) -> (r: Double, g: Double, b: Double)? {
        guard !samples.isEmpty else {
            return nil
        }

        let luminanceSpan = max(luminanceRange.upper - luminanceRange.lower, 0.000_01)
        let effectiveChromaCutoff = max(chromaCutoff, 0.000_01)
        var weightedLogR = 0.0
        var weightedLogG = 0.0
        var weightedLogB = 0.0
        var totalWeight = 0.0

        for sample in samples {
            let normalizedLuminance = min(
                max((sample.luminance - luminanceRange.lower) / luminanceSpan, 0.0),
                1.0
            )
            let luminanceWeight = 0.35 + (0.65 * sqrt(normalizedLuminance))

            let neutralityWeight: Double
            if favorNeutrality {
                let neutrality = max(0.0, 1.0 - (sample.chroma / effectiveChromaCutoff))
                neutralityWeight = 0.2 + (0.8 * neutrality * neutrality)
            } else {
                neutralityWeight = 1.0
            }

            let weight = luminanceWeight * neutralityWeight
            guard weight.isFinite, weight > 0 else { continue }

            weightedLogR += weight * log(max(sample.r, 0.000_01))
            weightedLogG += weight * log(max(sample.g, 0.000_01))
            weightedLogB += weight * log(max(sample.b, 0.000_01))
            totalWeight += weight
        }

        guard totalWeight > 0 else {
            return nil
        }

        let rgb = (
            r: exp(weightedLogR / totalWeight),
            g: exp(weightedLogG / totalWeight),
            b: exp(weightedLogB / totalWeight)
        )

        return normalizedWhiteBalanceSample(from: rgb)
    }

    private static func normalizedWhiteBalanceSample(
        from rgb: (r: Double, g: Double, b: Double)
    ) -> (r: Double, g: Double, b: Double)? {
        let luminance = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
        let maxComponent = max(rgb.r, max(rgb.g, rgb.b))
        guard luminance.isFinite, luminance > 0, maxComponent.isFinite, maxComponent > 0 else {
            return nil
        }

        let targetLuminance = 0.25
        var scale = targetLuminance / luminance
        if maxComponent * scale > 0.9 {
            scale = 0.9 / maxComponent
        }

        guard scale.isFinite, scale > 0 else {
            return nil
        }

        return (
            r: rgb.r * scale,
            g: rgb.g * scale,
            b: rgb.b * scale
        )
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard let first = sortedValues.first else {
            return 0.0
        }

        guard sortedValues.count > 1 else {
            return first
        }

        let clampedFraction = min(max(fraction, 0.0), 1.0)
        let position = clampedFraction * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))

        guard lowerIndex != upperIndex else {
            return sortedValues[lowerIndex]
        }

        let interpolation = position - Double(lowerIndex)
        return sortedValues[lowerIndex] * (1.0 - interpolation) +
            sortedValues[upperIndex] * interpolation
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
        let pathHash = stablePathHash(for: x3fURL)
        let cachedURL = cacheDir.appendingPathComponent("\(baseFilename)_\(pathHash)_linear.dng")

        // 检查缓存
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            if isConvertedCacheFresh(cacheURL: cachedURL, sourceURL: x3fURL) {
                print("ImageProcessor: 使用缓存的线性 sRGB DNG: \(cachedURL.lastPathComponent)")
                return cachedURL
            } else {
                try? FileManager.default.removeItem(at: cachedURL)
                print("ImageProcessor: 缓存已过期，重新转换 X3F")
            }
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

    private static func stablePathHash(for url: URL) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in url.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func isConvertedCacheFresh(cacheURL: URL, sourceURL: URL) -> Bool {
        guard
            let cacheValues = try? cacheURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
            ]),
            let sourceValues = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]),
            let cacheDate = cacheValues.contentModificationDate,
            let sourceDate = sourceValues.contentModificationDate,
            (cacheValues.fileSize ?? 0) > 0
        else {
            return false
        }

        return cacheDate >= sourceDate
    }

    private static func loadRawWithFilter(from url: URL) -> CIImage? {
        print("ImageProcessor: 使用拍摄元信息加载 RAW")
        print("ImageProcessor: 输入文件: \(url.path)")

        guard let rawFilter = CIFilter(imageURL: url, options: [:]) else {
            print("ImageProcessor: ✗ 无法创建 RAW 过滤器")
            return nil
        }

        let shootingMetadata = readRawShootingMetadata(from: rawFilter)
        applyRawShootingMetadata(shootingMetadata, to: rawFilter)
        logRawShootingMetadata(shootingMetadata)

        if rawFilter.inputKeys.contains("inputDraftMode") {
            rawFilter.setValue(false, forKey: "inputDraftMode")
            print("ImageProcessor: ✓ 禁用草稿模式")
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

    private static func readRawShootingMetadata(from rawFilter: CIFilter) -> RawShootingMetadata {
        RawShootingMetadata(
            neutralTemperature: doubleFilterValue("inputNeutralTemperature", in: rawFilter),
            neutralTint: doubleFilterValue("inputNeutralTint", in: rawFilter),
            ev: doubleFilterValue("inputEV", in: rawFilter),
            boost: doubleFilterValue("inputBoost", in: rawFilter),
            baselineExposure: doubleFilterValue("inputBaselineExposure", in: rawFilter),
            isVendorLensCorrectionEnabled: boolFilterValue(
                "inputEnableVendorLensCorrection",
                in: rawFilter
            )
        )
    }

    private static func applyRawShootingMetadata(
        _ metadata: RawShootingMetadata,
        to rawFilter: CIFilter
    ) {
        setFilterValue(metadata.neutralTemperature, forKey: "inputNeutralTemperature", in: rawFilter)
        setFilterValue(metadata.neutralTint, forKey: "inputNeutralTint", in: rawFilter)
        setFilterValue(metadata.ev, forKey: "inputEV", in: rawFilter)
        setFilterValue(metadata.boost, forKey: "inputBoost", in: rawFilter)
        setFilterValue(metadata.baselineExposure, forKey: "inputBaselineExposure", in: rawFilter)
        setFilterValue(
            metadata.isVendorLensCorrectionEnabled,
            forKey: "inputEnableVendorLensCorrection",
            in: rawFilter
        )
    }

    private static func logRawShootingMetadata(_ metadata: RawShootingMetadata) {
        let temperatureText = metadata.neutralTemperature.map { "\(Int($0))K" } ?? "无"
        let tintText = metadata.neutralTint.map { String(format: "%.2f", $0) } ?? "无"
        let evText = metadata.ev.map { String(format: "%.2f", $0) } ?? "无"
        let boostText = metadata.boost.map { String(format: "%.2f", $0) } ?? "无"
        let baselineExposureText = metadata.baselineExposure.map { String(format: "%.2f", $0) } ?? "无"
        let lensCorrectionText = metadata.isVendorLensCorrectionEnabled.map { $0 ? "开" : "关" } ?? "无"

        print(
            "ImageProcessor: RAW 拍摄元信息 - 白平衡 \(temperatureText), 色调 \(tintText), EV \(evText), Boost \(boostText), BaselineExposure \(baselineExposureText), 镜头校正 \(lensCorrectionText)"
        )
    }

    private static func doubleFilterValue(_ key: String, in filter: CIFilter) -> Double? {
        guard filter.inputKeys.contains(key) else {
            return nil
        }

        return (filter.value(forKey: key) as? NSNumber)?.doubleValue
    }

    private static func boolFilterValue(_ key: String, in filter: CIFilter) -> Bool? {
        guard filter.inputKeys.contains(key) else {
            return nil
        }

        return (filter.value(forKey: key) as? NSNumber)?.boolValue
    }

    private static func setFilterValue(_ value: Double?, forKey key: String, in filter: CIFilter) {
        guard filter.inputKeys.contains(key),
              let value
        else {
            return
        }

        filter.setValue(value, forKey: key)
    }

    private static func setFilterValue(_ value: Bool?, forKey key: String, in filter: CIFilter) {
        guard filter.inputKeys.contains(key),
              let value
        else {
            return
        }

        filter.setValue(value, forKey: key)
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

        if adjustments.exposure != 0.0 {
            result = applyExposure(to: result, value: adjustments.exposure)
        }

        if adjustments.perceptualExposure != 0.0 {
            result = applyPerceptualExposure(to: result, value: adjustments.perceptualExposure)
        }

        if adjustments.contrast != 0.0 {
            result = applyContrast(to: result, value: adjustments.contrast)
        }

        if adjustments.highlights != 1.0 || adjustments.shadows != 0.0 ||
            adjustments.whites != 0.0 || adjustments.blacks != 0.0
        {
            result = applyHighlightsShadows(
                to: result,
                highlights: adjustments.highlights,
                shadows: adjustments.shadows,
                whites: adjustments.whites,
                blacks: adjustments.blacks
            )
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
                profile: adjustments.lutColorProfile
            )
        }

        if adjustments.isHDREnabled,
           adjustments.isHDRAutoAdjustmentEnabled ||
           abs(adjustments.hdrBrightness) > 0.0001 ||
           abs(adjustments.hdrHighlights) > 0.0001 ||
           abs(adjustments.hdrWhites) > 0.0001 {
            result = applyHDRDisplayBoost(to: result, adjustments: adjustments)
        } else if adjustments.isHDREnabled, #available(macOS 16.0, *) {
            result = result.settingContentHeadroom(Float(adjustments.hdrHeadroom))
        }

        return result
    }

    static func convertToDisplayCGImage(_ ciImage: CIImage, adjustments: ImageAdjustments) -> CGImage? {
        guard adjustments.isHDREnabled else {
            return convertToCGImage(ciImage)
        }

        let extent = ciImage.extent
        guard !extent.isEmpty, extent.isInfinite == false else {
            return nil
        }

        let outputImage: CIImage
        if #available(macOS 16.0, *) {
            outputImage = ciImage.settingContentHeadroom(Float(adjustments.hdrHeadroom))
        } else {
            outputImage = ciImage
        }

        let hdrColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG) ??
            CGColorSpace(name: CGColorSpace.displayP3_HLG)

        guard let hdrColorSpace else {
            return convertToCGImage(ciImage)
        }

        return ciContext.createCGImage(
            outputImage,
            from: extent,
            format: .RGBAh,
            colorSpace: hdrColorSpace
        )
    }

    // 摄影曝光调整 - 真实 EV 曝光
    // 基于 EV (Exposure Value) 光圈档位
    // 每增加 1 EV，亮度翻倍；每减少 1 EV，亮度减半
    // 公式：output = input * 2^EV
    // 范围：[-5, +5] EV，相当于 10 档光圈
    private static func applyExposure(to image: CIImage, value: Double) -> CIImage {
        if value == 0.0 { return image }

        guard let filter = CIFilter(name: "CIExposureAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)

        filter.setValue(value, forKey: kCIInputEVKey)

        return filter.outputImage ?? image
    }

    // 感知曝光：在显示参考亮度上整体提亮/压暗，
    // 同时通过 sigmoid 保护端点，并以亮度比例缩放 RGB 保持色相稳定。
    private static func applyPerceptualExposure(to image: CIImage, value: Double) -> CIImage {
        if value == 0.0 { return image }

        return applyPerceptualLuminanceShift(
            to: image,
            value: value,
            focusSigma: 0.0,
            maxShift: 0.25
        )
    }

    private static let perceptualMidGrayPivot: CGFloat = 0.425

    private static func applyPerceptualLuminanceShift(
        to image: CIImage,
        value: Double,
        focusSigma: CGFloat,
        maxShift: CGFloat
    ) -> CIImage {
        guard let kernel = perceptualLuminanceShiftKernel else {
            return image
        }

        return kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                CGFloat(value),
                perceptualMidGrayPivot,
                focusSigma,
                maxShift,
            ]
        ) ?? image
    }

    private static func applyHDRDisplayBoost(to image: CIImage, adjustments: ImageAdjustments) -> CIImage {
        guard let kernel = hdrDisplayBoostKernel else {
            return image
        }

        let headroom = min(
            max(adjustments.hdrHeadroom, ImageAdjustments.hdrHeadroomRange.lowerBound),
            ImageAdjustments.hdrHeadroomRange.upperBound
        )

        let output = kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                CGFloat(adjustments.hdrBrightness),
                CGFloat(adjustments.hdrHighlights),
                CGFloat(adjustments.hdrWhites),
                CGFloat(headroom),
            ]
        ) ?? image

        if #available(macOS 16.0, *) {
            return output.settingContentHeadroom(Float(headroom))
        }

        return output
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

    static func whiteBalanceFromNeutralSample(
        linearRGB: (r: Double, g: Double, b: Double)
    ) -> (temperature: Double, tint: Double)? {
        let r = max(linearRGB.r, 0.000_01)
        let g = max(linearRGB.g, 0.000_01)
        let b = max(linearRGB.b, 0.000_01)

        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luminance > 0.02, max(r, max(g, b)) < 0.99 else {
            return nil
        }

        let inverseGains = (r: 1.0 / r, g: 1.0 / g, b: 1.0 / b)
        let maxGain = max(inverseGains.r, max(inverseGains.g, inverseGains.b))
        guard maxGain > 0 else { return nil }

        let normalizedGains = (
            r: inverseGains.r / maxGain,
            g: inverseGains.g / maxGain,
            b: inverseGains.b / maxGain
        )

        let rbRatio = normalizedGains.r / max(normalizedGains.b, 0.000_01)
        let unclampedTemperature = AppConfig.defaultWhitePoint * pow(rbRatio, 1.0 / 0.6)
        let temperature = max(
            ImageAdjustments.temperatureRange.lowerBound,
            min(ImageAdjustments.temperatureRange.upperBound, unclampedTemperature)
        )

        let tempRatio = temperature / AppConfig.defaultWhitePoint
        let tempPower = pow(tempRatio, 0.6)
        let redBase = tempRatio <= 1.0 ? 1.0 : tempPower

        let greenBase = (normalizedGains.g / max(normalizedGains.r, 0.000_01)) * redBase
        let unclampedTint = ((1.0 - greenBase) / 0.3) * 100.0
        let tint = max(
            ImageAdjustments.tintRange.lowerBound,
            min(ImageAdjustments.tintRange.upperBound, unclampedTint)
        )

        return (temperature, tint)
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
        profile: LUTColorProfile
    ) -> CIImage {
        guard let (data, size) = cachedLUTData(from: lutURL) else {
            return image
        }

        let workingToInputGamut = gamutTransformMatrix(
            from: .sRGB,
            to: profile.inputGamut
        )
        let outputToWorkingGamut = gamutTransformMatrix(
            from: profile.outputGamut,
            to: .sRGB
        )

        guard let imageInLUTSpace = applyLUTInputTransform(
            to: image,
            gamutTransform: workingToInputGamut,
            transferFunction: profile.inputTransfer
        ) else {
            print("ImageProcessor: ⚠️ 无法创建 LUT 输入变换，跳过 LUT")
            return image
        }

        guard let filter = CIFilter(name: "CIColorCube") else {
            return image
        }

        filter.setValue(imageInLUTSpace, forKey: kCIInputImageKey)
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")

        guard let lutAppliedInLUTSpace = filter.outputImage else {
            return image
        }

        guard let lutApplied = applyLUTOutputTransform(
            to: lutAppliedInLUTSpace,
            gamutTransform: outputToWorkingGamut,
            transferFunction: profile.outputTransfer
        ) else {
            print("ImageProcessor: ⚠️ 无法创建 LUT 输出变换，跳过 LUT")
            return image
        }

        return applyLUTAlpha(original: image, lutApplied: lutApplied, alpha: alpha)
    }

    private static func cachedLUTData(from url: URL) -> (data: Data, size: Int)? {
        guard let key = lutCacheKey(for: url) else {
            return parseLUTData(from: url)
        }

        if let cached = cachedLUTData(for: key) {
            return cached
        }

        guard let parsed = parseLUTData(from: url) else {
            return nil
        }

        storeLUTData(parsed, for: key)

        return parsed
    }

    private static func cachedLUTData(for key: LUTCacheKey) -> (data: Data, size: Int)? {
        lutCacheLock.lock()
        defer { lutCacheLock.unlock() }
        return lutCache[key]
    }

    private static func storeLUTData(_ parsed: (data: Data, size: Int), for key: LUTCacheKey) {
        lutCacheLock.lock()
        defer { lutCacheLock.unlock() }

        lutCache[key] = parsed
        lutCacheOrder.removeAll { $0 == key }
        lutCacheOrder.append(key)

        while lutCacheOrder.count > lutCacheLimit {
            let oldestKey = lutCacheOrder.removeFirst()
            lutCache.removeValue(forKey: oldestKey)
        }
    }

    private static func lutCacheKey(for url: URL) -> LUTCacheKey? {
        let resourceValues = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])

        return LUTCacheKey(
            path: url.standardizedFileURL.path,
            modificationTime: resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            fileSize: Int64(resourceValues?.fileSize ?? 0)
        )
    }

    private static func parseLUTData(from url: URL) -> (data: Data, size: Int)? {
        let fileExtension = url.pathExtension.lowercased()

        return switch fileExtension {
        case "cube":
            parseCubeLUT(from: url)
        case "3dl":
            parse3DLLUT(from: url)
        case "lut":
            parseBinaryLUT(from: url)
        default:
            parseCubeLUT(from: url)
        }
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
        var rawTriples: [(Float, Float, Float)] = []
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
                rawTriples.append((values[0], values[1], values[2]))
            }
        }

        // .3dl 格式值范围常见为 0-1023 或 0-4095。必须用全局范围归一化，
        // 不能按每一行单独归一化，否则会破坏 LUT 的色彩关系。
        let maxValue = rawTriples
            .map { max($0.0, max($0.1, $0.2)) }
            .max() ?? 1.0
        let scale = maxValue > 1.0 ? maxValue : 1.0

        var floatData: [Float] = []
        floatData.reserveCapacity(rawTriples.count * 4)
        for values in rawTriples {
            floatData.append(values.0 / scale)
            floatData.append(values.1 / scale)
            floatData.append(values.2 / scale)
            floatData.append(1.0)
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

    private static func gamutTransformMatrix(
        from source: LUTGamut,
        to target: LUTGamut
    ) -> simd_double3x3 {
        if source == target {
            return matrix_identity_double3x3
        }

        let sourceSpace = primaries(for: source)
        let targetSpace = primaries(for: target)
        return targetSpace.xyzToRGB * sourceSpace.rgbToXYZ
    }

    private static func primaries(for gamut: LUTGamut) -> RGBPrimaries {
        switch gamut {
        case .sRGB:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.64, y: 0.33),
                green: ChromaticityPoint(x: 0.30, y: 0.60),
                blue: ChromaticityPoint(x: 0.15, y: 0.06),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .displayP3:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.68, y: 0.32),
                green: ChromaticityPoint(x: 0.265, y: 0.69),
                blue: ChromaticityPoint(x: 0.15, y: 0.06),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .rec709:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.64, y: 0.33),
                green: ChromaticityPoint(x: 0.30, y: 0.60),
                blue: ChromaticityPoint(x: 0.15, y: 0.06),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .dciP3:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.68, y: 0.32),
                green: ChromaticityPoint(x: 0.265, y: 0.69),
                blue: ChromaticityPoint(x: 0.15, y: 0.06),
                white: ChromaticityPoint(x: 0.314, y: 0.351)
            )
        case .rec2020:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.708, y: 0.292),
                green: ChromaticityPoint(x: 0.170, y: 0.797),
                blue: ChromaticityPoint(x: 0.131, y: 0.046),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .fGamut:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.708, y: 0.292),
                green: ChromaticityPoint(x: 0.170, y: 0.797),
                blue: ChromaticityPoint(x: 0.131, y: 0.046),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .fGamutC:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.7347, y: 0.2653),
                green: ChromaticityPoint(x: 0.0263, y: 0.9737),
                blue: ChromaticityPoint(x: 0.1173, y: -0.0224),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .sonySGamut:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.730, y: 0.280),
                green: ChromaticityPoint(x: 0.140, y: 0.855),
                blue: ChromaticityPoint(x: 0.100, y: -0.050),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .sonySGamut3Cine:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.766, y: 0.275),
                green: ChromaticityPoint(x: 0.225, y: 0.800),
                blue: ChromaticityPoint(x: 0.089, y: -0.087),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .djiDGamut:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.710, y: 0.310),
                green: ChromaticityPoint(x: 0.210, y: 0.880),
                blue: ChromaticityPoint(x: 0.090, y: -0.080),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .canonCinemaGamut:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.740, y: 0.270),
                green: ChromaticityPoint(x: 0.170, y: 1.140),
                blue: ChromaticityPoint(x: 0.080, y: -0.100),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        case .panasonicVGamut:
            RGBPrimaries(
                red: ChromaticityPoint(x: 0.730, y: 0.280),
                green: ChromaticityPoint(x: 0.165, y: 0.840),
                blue: ChromaticityPoint(x: 0.100, y: -0.030),
                white: ChromaticityPoint(x: 0.3127, y: 0.3290)
            )
        }
    }

    private static func applyLUTInputTransform(
        to image: CIImage,
        gamutTransform: simd_double3x3,
        transferFunction: LUTTransferFunction
    ) -> CIImage? {
        guard let kernel = lutInputTransformKernel else {
            return nil
        }

        let rows = matrixRows(from: gamutTransform)
        return kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                rows.0,
                rows.1,
                rows.2,
                LUTTransferMode(transferFunction).kernelValue,
            ]
        )
    }

    private static func applyLUTOutputTransform(
        to image: CIImage,
        gamutTransform: simd_double3x3,
        transferFunction: LUTTransferFunction
    ) -> CIImage? {
        guard let kernel = lutOutputTransformKernel else {
            return nil
        }

        let rows = matrixRows(from: gamutTransform)
        return kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                rows.0,
                rows.1,
                rows.2,
                LUTTransferMode(transferFunction).kernelValue,
            ]
        )
    }

    private static func matrixRows(from matrix: simd_double3x3) -> (
        CIVector,
        CIVector,
        CIVector
    ) {
        let row0 = CIVector(
            x: CGFloat(matrix[0].x),
            y: CGFloat(matrix[1].x),
            z: CGFloat(matrix[2].x)
        )
        let row1 = CIVector(
            x: CGFloat(matrix[0].y),
            y: CGFloat(matrix[1].y),
            z: CGFloat(matrix[2].y)
        )
        let row2 = CIVector(
            x: CGFloat(matrix[0].z),
            y: CGFloat(matrix[1].z),
            z: CGFloat(matrix[2].z)
        )
        return (row0, row1, row2)
    }
}
