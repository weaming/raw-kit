import CoreImage
import Foundation

struct CurveAdjustment: Equatable {
    enum Channel {
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

    struct CurvePoint: Equatable, Identifiable {
        let id = UUID()
        var input: Double
        var output: Double

        init(input: Double, output: Double) {
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

        let curveValues = generateCurveValues()

        switch channel {
        case .rgb, .luminance:
            return applyToneCurve(to: image, values: curveValues)
        case .red:
            return applyColorMatrixCurve(to: image, values: curveValues, channel: 0)
        case .green:
            return applyColorMatrixCurve(to: image, values: curveValues, channel: 1)
        case .blue:
            return applyColorMatrixCurve(to: image, values: curveValues, channel: 2)
        }
    }

    // Photoshop 的 RGB 复合曲线
    // RGB 曲线应该同时应用到 R、G、B 三个通道，而不是只应用到亮度
    func applyToRGB(to image: CIImage) -> CIImage {
        guard hasPoints else { return image }

        let curveValues = generateCurveValues()

        // 使用 CIColorCube 来同时应用曲线到 R、G、B 三个通道
        // 这是 Photoshop RGB 复合曲线的正确实现方式
        let cubeSize = 64
        var cubeData = [Float](repeating: 0, count: cubeSize * cubeSize * cubeSize * 4)

        for z in 0 ..< cubeSize {
            for y in 0 ..< cubeSize {
                for x in 0 ..< cubeSize {
                    let r = Float(x) / Float(cubeSize - 1)
                    let g = Float(y) / Float(cubeSize - 1)
                    let b = Float(z) / Float(cubeSize - 1)

                    // 对每个通道应用曲线
                    let rIndex = Int(r * 255.0)
                    let gIndex = Int(g * 255.0)
                    let bIndex = Int(b * 255.0)

                    let rOut = Float(curveValues[min(rIndex, 255)])
                    let gOut = Float(curveValues[min(gIndex, 255)])
                    let bOut = Float(curveValues[min(bIndex, 255)])

                    let offset = (z * cubeSize * cubeSize + y * cubeSize + x) * 4
                    cubeData[offset + 0] = rOut
                    cubeData[offset + 1] = gOut
                    cubeData[offset + 2] = bOut
                    cubeData[offset + 3] = 1.0 // alpha
                }
            }
        }

        let data = Data(bytes: cubeData, count: cubeData.count * MemoryLayout<Float>.size)

        guard let filter = CIFilter(name: "CIColorCube") else {
            return image
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cubeSize, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")

        return filter.outputImage ?? image
    }

    private func applyToneCurve(to image: CIImage, values: [CGFloat]) -> CIImage {
        guard let filter = CIFilter(name: "CIToneCurve") else {
            return image
        }

        filter.setValue(image, forKey: kCIInputImageKey)

        let points = stride(from: 0, to: values.count, by: values.count / 5).map { i in
            CIVector(x: CGFloat(i) / CGFloat(values.count - 1), y: values[i])
        }

        if points.count >= 1 { filter.setValue(points[0], forKey: "inputPoint0") }
        if points.count >= 2 { filter.setValue(points[1], forKey: "inputPoint1") }
        if points.count >= 3 { filter.setValue(points[2], forKey: "inputPoint2") }
        if points.count >= 4 { filter.setValue(points[3], forKey: "inputPoint3") }
        if points.count >= 5 { filter.setValue(points[4], forKey: "inputPoint4") }

        return filter.outputImage ?? image
    }

    // Photoshop 的单通道曲线实现
    // 只调整指定通道的值，保持其他通道不变
    private func applyColorMatrixCurve(to image: CIImage, values: [CGFloat],
                                       channel: Int) -> CIImage
    {
        // 使用 CIColorCube 来只调整指定通道
        let cubeSize = 64
        var cubeData = [Float](repeating: 0, count: cubeSize * cubeSize * cubeSize * 4)

        for z in 0 ..< cubeSize {
            for y in 0 ..< cubeSize {
                for x in 0 ..< cubeSize {
                    let r = Float(x) / Float(cubeSize - 1)
                    let g = Float(y) / Float(cubeSize - 1)
                    let b = Float(z) / Float(cubeSize - 1)

                    var rOut = r
                    var gOut = g
                    var bOut = b

                    // 只对指定通道应用曲线
                    switch channel {
                    case 0: // Red
                        let rIndex = Int(r * 255.0)
                        rOut = Float(values[min(rIndex, 255)])
                    case 1: // Green
                        let gIndex = Int(g * 255.0)
                        gOut = Float(values[min(gIndex, 255)])
                    case 2: // Blue
                        let bIndex = Int(b * 255.0)
                        bOut = Float(values[min(bIndex, 255)])
                    default:
                        break
                    }

                    let offset = (z * cubeSize * cubeSize + y * cubeSize + x) * 4
                    cubeData[offset + 0] = rOut
                    cubeData[offset + 1] = gOut
                    cubeData[offset + 2] = bOut
                    cubeData[offset + 3] = 1.0
                }
            }
        }

        let data = Data(bytes: cubeData, count: cubeData.count * MemoryLayout<Float>.size)

        guard let filter = CIFilter(name: "CIColorCube") else {
            return image
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cubeSize, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")

        return filter.outputImage ?? image
    }

    private func generateCurveValues() -> [CGFloat] {
        // 如果没有用户添加的点，返回线性曲线（对角线）
        if points.isEmpty {
            var curveValues = [CGFloat](repeating: 0, count: 256)
            for i in 0 ..< 256 {
                curveValues[i] = CGFloat(i) / 255.0
            }
            return curveValues
        }

        var allPoints: [(input: Double, output: Double)] = [(0, 0)]

        for point in points {
            allPoints.append((point.input, point.output))
        }

        allPoints.append((1, 1))

        allPoints.sort { $0.input < $1.input }

        var curveValues = [CGFloat](repeating: 0, count: 256)

        for i in 0 ..< 256 {
            let x = Double(i) / 255.0
            let y = interpolate(x: x, points: allPoints)
            curveValues[i] = CGFloat(y)
        }

        return curveValues
    }

    // Photoshop 的曲线插值算法：自然三次样条插值 (Natural Cubic Spline)
    // 这是 Photoshop 实际使用的算法，比 Hermite 插值更平滑自然
    private func interpolate(x: Double, points: [(input: Double, output: Double)]) -> Double {
        guard points.count >= 2 else { return x }

        if x <= points.first!.input {
            return points.first!.output
        }

        if x >= points.last!.input {
            return points.last!.output
        }

        let n = points.count

        // 计算三次样条的二阶导数
        var a = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)

        for i in 0 ..< n {
            a[i] = points[i].output
        }

        // 计算差分
        var h = [Double](repeating: 0, count: n - 1)
        for i in 0 ..< (n - 1) {
            h[i] = points[i + 1].input - points[i].input
        }

        // 构建三对角矩阵（自然样条边界条件：两端二阶导数为 0）
        var alpha = [Double](repeating: 0, count: n)
        for i in 1 ..< (n - 1) {
            alpha[i] = (3.0 / h[i]) * (a[i + 1] - a[i]) - (3.0 / h[i - 1]) * (a[i] - a[i - 1])
        }

        // 求解三对角矩阵
        var l = [Double](repeating: 0, count: n)
        var mu = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)

        l[0] = 1.0
        mu[0] = 0.0
        z[0] = 0.0

        for i in 1 ..< (n - 1) {
            l[i] = 2.0 * (points[i + 1].input - points[i - 1].input) - h[i - 1] * mu[i - 1]
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }

        l[n - 1] = 1.0
        z[n - 1] = 0.0
        c[n - 1] = 0.0

        // 反向替换
        for j in (0 ..< (n - 1)).reversed() {
            c[j] = z[j] - mu[j] * c[j + 1]
            b[j] = (a[j + 1] - a[j]) / h[j] - h[j] * (c[j + 1] + 2.0 * c[j]) / 3.0
            d[j] = (c[j + 1] - c[j]) / (3.0 * h[j])
        }

        // 找到 x 所在的区间并计算插值
        for i in 0 ..< (n - 1) {
            if x >= points[i].input, x <= points[i + 1].input {
                let dx = x - points[i].input
                let result = a[i] + b[i] * dx + c[i] * dx * dx + d[i] * dx * dx * dx
                return max(0, min(1, result))
            }
        }

        return max(0, min(1, x))
    }
}
