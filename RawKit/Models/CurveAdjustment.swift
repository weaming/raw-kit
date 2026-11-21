import CoreImage
import Foundation

struct CurveAdjustment: Equatable, Codable {
    nonisolated(unsafe) private static let curveImageCache = NSCache<NSString, CIImage>()
    private static let curveTableSize = 256

    private static let curveMetalKernelSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" namespace coreimage {
        float encodeSRGB(float value) {
            float v = max(value, 0.0);
            if (v <= 0.0031308) {
                return 12.92 * v;
            }
            return 1.055 * pow(v, 1.0 / 2.4) - 0.055;
        }

        float decodeSRGB(float value) {
            float v = max(value, 0.0);
            if (v <= 0.04045) {
                return v / 12.92;
            }
            return pow((v + 0.055) / 1.055, 2.4);
        }

        float sampleCurve1D(sampler curveTex, float x) {
            float clamped = clamp(x, 0.0, 1.0);
            float coordX = clamped * 255.0 + 0.5;
            return curveTex.sample(curveTex.transform(float2(coordX, 0.5))).r;
        }

        float mapLinearChannelWithPerceptualCurve(float linearValue, sampler curveTex) {
            if (linearValue < 0.0) {
                float blackOut = decodeSRGB(sampleCurve1D(curveTex, 0.0));
                return linearValue + blackOut;
            }

            if (linearValue <= 1.0) {
                float encoded = encodeSRGB(linearValue);
                float mappedEncoded = sampleCurve1D(curveTex, encoded);
                return decodeSRGB(mappedEncoded);
            }

            // HDR 高光 (> 1.0)：锚定在 1.0 处的曲线输出，平滑延续超白动态范围，避免截断 HDR
            float whiteOut = decodeSRGB(sampleCurve1D(curveTex, 1.0));
            return whiteOut + (linearValue - 1.0);
        }

        [[ stitchable ]] float4 applyPerceptualCurveKernel(sampler image, sampler curveTex, float mode) {
            float4 pixel = image.sample(image.coord());
            float3 rgb = pixel.rgb;

            // mode: 0 = RGB, 1 = Red, 2 = Green, 3 = Blue, 4 = Luminance
            if (mode < 0.5) {
                rgb.r = mapLinearChannelWithPerceptualCurve(rgb.r, curveTex);
                rgb.g = mapLinearChannelWithPerceptualCurve(rgb.g, curveTex);
                rgb.b = mapLinearChannelWithPerceptualCurve(rgb.b, curveTex);
                return float4(rgb, pixel.a);
            }

            if (mode < 1.5) {
                rgb.r = mapLinearChannelWithPerceptualCurve(rgb.r, curveTex);
                return float4(rgb, pixel.a);
            }

            if (mode < 2.5) {
                rgb.g = mapLinearChannelWithPerceptualCurve(rgb.g, curveTex);
                return float4(rgb, pixel.a);
            }

            if (mode < 3.5) {
                rgb.b = mapLinearChannelWithPerceptualCurve(rgb.b, curveTex);
                return float4(rgb, pixel.a);
            }

            float luminance = max(dot(rgb, float3(0.2126, 0.7152, 0.0722)), 0.0);
            if (luminance <= 1e-5) {
                float blackLift = decodeSRGB(sampleCurve1D(curveTex, 0.0));
                return float4(rgb + float3(blackLift), pixel.a);
            }

            float mappedLuminance = mapLinearChannelWithPerceptualCurve(luminance, curveTex);
            float scale = mappedLuminance / luminance;
            return float4(rgb * scale, pixel.a);
        }
    }
    """

    private static let perceptualCurveKernel: CIKernel? = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: curveMetalKernelSource)
            return kernels.first { $0.name == "applyPerceptualCurveKernel" }
        } catch {
            print("CurveAdjustment: ⚠️ Metal kernel 编译失败: \(error)")
            return nil
        }
    }()

    enum Channel: String, Codable {
        case rgb
        case red
        case green
        case blue
        case luminance
    }

    var points: [CurvePoint] = []
    var channel: Channel = .rgb

    static func == (lhs: CurveAdjustment, rhs: CurveAdjustment) -> Bool {
        lhs.channel == rhs.channel && lhs.points == rhs.points
    }

    struct CurvePoint: Equatable, Identifiable, Codable {
        let id: UUID
        var input: Double
        var output: Double

        init(input: Double, output: Double) {
            id = UUID()
            self.input = max(0, min(1, input))
            self.output = max(0, min(1, output))
        }

        static func == (lhs: CurvePoint, rhs: CurvePoint) -> Bool {
            lhs.input == rhs.input && lhs.output == rhs.output
        }
    }

    var hasPoints: Bool {
        !points.isEmpty
    }

    mutating func reset() {
        points.removeAll()
    }

    mutating func addPoint(input: Double, output: Double) -> UUID {
        let newPoint = CurvePoint(input: input, output: output)

        if let existingIndex = points.firstIndex(where: { abs($0.input - input) < 0.01 }) {
            points[existingIndex] = newPoint
            return points[existingIndex].id
        } else {
            points.append(newPoint)
            points.sort { $0.input < $1.input }
            return newPoint.id
        }
    }

    mutating func updatePoint(id: UUID, output: Double) {
        if let index = points.firstIndex(where: { $0.id == id }) {
            points[index].output = max(0, min(1, output))
        }
    }

    mutating func updatePoint(id: UUID, input: Double, output: Double) {
        if let index = points.firstIndex(where: { $0.id == id }) {
            points[index].input = max(0, min(1, input))
            points[index].output = max(0, min(1, output))
            // 重新排序以保持输入值的顺序
            points.sort { $0.input < $1.input }
        }
    }

    mutating func removePoint(id: UUID) {
        points.removeAll { $0.id == id }
    }

    func apply(to image: CIImage, channel: Channel) -> CIImage {
        guard hasPoints else { return image }

        let mode: CGFloat = switch channel {
        case .rgb: 0.0
        case .red: 1.0
        case .green: 2.0
        case .blue: 3.0
        case .luminance: 4.0
        }

        return applyPerceptualCurve(to: image, mode: mode)
    }

    // Photoshop 的 RGB 复合曲线
    // RGB 曲线同时应用到 R、G、B 三个通道，并在感知 sRGB 域执行，保留 HDR 与广色域
    func applyToRGB(to image: CIImage) -> CIImage {
        apply(to: image, channel: .rgb)
    }

    private func applyPerceptualCurve(to image: CIImage, mode: CGFloat) -> CIImage {
        guard let kernel = Self.perceptualCurveKernel else {
            return image
        }

        let curveTex = cachedCurveImage()
        let curveExtent = curveTex.extent

        return kernel.apply(
            extent: image.extent,
            roiCallback: { index, rect in
                index == 0 ? rect : curveExtent
            },
            arguments: [image, curveTex, mode]
        ) ?? image
    }

    private func cachedCurveImage() -> CIImage {
        let key = curveCacheKey()
        if let cached = Self.curveImageCache.object(forKey: key) {
            return cached
        }

        let curveValues = generateCurveValues()
        let width = Self.curveTableSize
        var pixels = [Float](repeating: 0, count: width * 4)

        for i in 0 ..< width {
            let v = Float(curveValues[i])
            let offset = i * 4
            pixels[offset + 0] = v
            pixels[offset + 1] = v
            pixels[offset + 2] = v
            pixels[offset + 3] = 1.0
        }

        let data = Data(bytes: pixels, count: pixels.count * MemoryLayout<Float>.size)
        let curveImage = CIImage(
            bitmapData: data,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        Self.curveImageCache.setObject(curveImage, forKey: key)
        return curveImage
    }

    private func curveCacheKey() -> NSString {
        let pointKey = points
            .sorted { $0.input < $1.input }
            .map { String(format: "%.6f:%.6f", $0.input, $0.output) }
            .joined(separator: "|")

        return "curve1d:\(Self.curveTableSize):\(pointKey)" as NSString
    }

    func generateCurveValues() -> [CGFloat] {
        // 如果没有用户添加的点，返回线性曲线（对角线）
        if points.isEmpty {
            var curveValues = [CGFloat](repeating: 0, count: Self.curveTableSize)
            for i in 0 ..< Self.curveTableSize {
                curveValues[i] = CGFloat(i) / CGFloat(Self.curveTableSize - 1)
            }
            return curveValues
        }

        let sortedUserPoints = points.sorted { $0.input < $1.input }
        var deduplicatedPoints: [(input: Double, output: Double)] = []
        let minStep = 1e-4

        for point in sortedUserPoints {
            if let last = deduplicatedPoints.last, abs(point.input - last.input) < minStep {
                deduplicatedPoints[deduplicatedPoints.count - 1] = (point.input, point.output)
            } else {
                deduplicatedPoints.append((point.input, point.output))
            }
        }

        var allPoints: [(input: Double, output: Double)] = []
        if let first = deduplicatedPoints.first, first.input > minStep {
            allPoints.append((0.0, 0.0))
        }
        allPoints.append(contentsOf: deduplicatedPoints)
        if let last = deduplicatedPoints.last, last.input < 1.0 - minStep {
            allPoints.append((1.0, 1.0))
        }

        var curveValues = [CGFloat](repeating: 0, count: Self.curveTableSize)

        for i in 0 ..< Self.curveTableSize {
            let x = Double(i) / Double(Self.curveTableSize - 1)
            let y = interpolate(x: x, points: allPoints)
            curveValues[i] = CGFloat(y.isFinite ? max(0, min(1, y)) : x)
        }

        return curveValues
    }

    // 自然三次样条插值 (Natural Cubic Spline)
    private func interpolate(x: Double, points: [(input: Double, output: Double)]) -> Double {
        guard points.count >= 2 else { return points.first?.output ?? x }

        if x <= points.first!.input {
            return points.first!.output
        }

        if x >= points.last!.input {
            return points.last!.output
        }

        let n = points.count

        var a = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)

        for i in 0 ..< n {
            a[i] = points[i].output
        }

        var h = [Double](repeating: 0, count: n - 1)
        for i in 0 ..< (n - 1) {
            h[i] = max(points[i + 1].input - points[i].input, 1e-6)
        }

        var alpha = [Double](repeating: 0, count: n)
        for i in 1 ..< (n - 1) {
            alpha[i] = (3.0 / h[i]) * (a[i + 1] - a[i]) - (3.0 / h[i - 1]) * (a[i] - a[i - 1])
        }

        var l = [Double](repeating: 0, count: n)
        var mu = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)

        l[0] = 1.0
        mu[0] = 0.0
        z[0] = 0.0

        for i in 1 ..< (n - 1) {
            let denom = 2.0 * (h[i - 1] + h[i]) - h[i - 1] * mu[i - 1]
            l[i] = abs(denom) > 1e-9 ? denom : 1e-9
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }

        l[n - 1] = 1.0
        z[n - 1] = 0.0
        c[n - 1] = 0.0

        for j in (0 ..< (n - 1)).reversed() {
            c[j] = z[j] - mu[j] * c[j + 1]
            b[j] = (a[j + 1] - a[j]) / h[j] - h[j] * (c[j + 1] + 2.0 * c[j]) / 3.0
            d[j] = (c[j + 1] - c[j]) / (3.0 * h[j])
        }

        for i in 0 ..< (n - 1) {
            if x >= points[i].input, x <= points[i + 1].input {
                let dx = x - points[i].input
                let result = a[i] + b[i] * dx + c[i] * dx * dx + d[i] * dx * dx * dx
                return result.isFinite ? max(0, min(1, result)) : max(0, min(1, x))
            }
        }

        return max(0, min(1, x))
    }
}
