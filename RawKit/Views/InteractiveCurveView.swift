import SwiftUI

struct InteractiveCurveView: View {
    @Binding var curve: CurveAdjustment
    let channel: CurveAdjustment.Channel
    var referenceCurves: [CurveAdjustment.Channel: CurveAdjustment]?

    @State private var draggedPointId: UUID?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                drawGrid(in: geometry.size)
                drawDiagonal(in: geometry.size)

                // 在 RGB 模式下显示其他通道的参考曲线
                if channel == .rgb, let references = referenceCurves {
                    drawReferenceCurves(in: geometry.size, curves: references)
                }

                drawCurve(in: geometry.size)
                drawPoints(in: geometry.size)
                drawAxisLabels(in: geometry.size)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .border(Color.gray.opacity(0.3), width: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value: value, in: geometry.size)
                    }
                    .onEnded { _ in
                        draggedPointId = nil
                    }
            )
        }
        .frame(height: 250)
    }

    private func handleDrag(value: DragGesture.Value, in size: CGSize) {
        let location = value.location

        let input = max(0, min(1, location.x / size.width))
        let output = max(0, min(1, 1.0 - (location.y / size.height)))

        if draggedPointId == nil {
            if let existingPoint = curve.points.first(where: { point in
                let pointX = size.width * CGFloat(point.input)
                let pointY = size.height * (1 - CGFloat(point.output))
                let dx = pointX - location.x
                let dy = pointY - location.y
                let distance = sqrt(dx * dx + dy * dy)
                return distance < 10
            }) {
                draggedPointId = existingPoint.id
            } else {
                // addPoint 现在返回新添加点的 ID
                let newPointId = curve.addPoint(input: input, output: output)
                draggedPointId = newPointId
            }
        }

        if let pointId = draggedPointId {
            // 支持同时调整输入值和输出值（像 Photoshop 一样）
            curve.updatePoint(id: pointId, input: input, output: output)
        }
    }

    private func drawGrid(in size: CGSize) -> some View {
        Path { path in
            let divisions = 4

            for i in 1 ..< divisions {
                let x = size.width * CGFloat(i) / CGFloat(divisions)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))

                let y = size.height * CGFloat(i) / CGFloat(divisions)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
    }

    private func drawDiagonal(in size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
    }

    private func drawReferenceCurves(
        in size: CGSize,
        curves: [CurveAdjustment.Channel: CurveAdjustment]
    ) -> some View {
        ZStack {
            // 绘制红色通道参考线
            if let redCurve = curves[.red], redCurve.hasPoints {
                drawReferenceCurve(curve: redCurve, color: .red.opacity(0.4), in: size)
            }

            // 绘制绿色通道参考线
            if let greenCurve = curves[.green], greenCurve.hasPoints {
                drawReferenceCurve(curve: greenCurve, color: .green.opacity(0.4), in: size)
            }

            // 绘制蓝色通道参考线
            if let blueCurve = curves[.blue], blueCurve.hasPoints {
                drawReferenceCurve(curve: blueCurve, color: .blue.opacity(0.4), in: size)
            }
        }
    }

    private func drawReferenceCurve(
        curve: CurveAdjustment,
        color: Color,
        in size: CGSize
    ) -> some View {
        let curveValues = generateCurveValues(for: curve)

        return Path { path in
            guard !curveValues.isEmpty else { return }

            let firstPoint = CGPoint(
                x: 0,
                y: size.height * (1 - curveValues[0])
            )
            path.move(to: firstPoint)

            for (index, value) in curveValues.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(curveValues.count - 1)
                let y = size.height * (1 - value)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        .stroke(color, lineWidth: 1.5)
    }

    private func drawCurve(in size: CGSize) -> some View {
        let curveValues = generateCurveValues()

        return Path { path in
            guard !curveValues.isEmpty else { return }

            let firstPoint = CGPoint(
                x: 0,
                y: size.height * (1 - curveValues[0])
            )
            path.move(to: firstPoint)

            for (index, value) in curveValues.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(curveValues.count - 1)
                let y = size.height * (1 - value)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        .stroke(channelColor, lineWidth: 2)
    }

    private func drawPoints(in size: CGSize) -> some View {
        ForEach(curve.points) { point in
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(channelColor, lineWidth: 2)
                )
                .position(
                    x: size.width * point.input,
                    y: size.height * (1 - point.output)
                )
                .onTapGesture(count: 2) {
                    curve.removePoint(id: point.id)
                }
                .contextMenu {
                    Button("删除点") {
                        curve.removePoint(id: point.id)
                    }
                }
        }
    }

    private var channelColor: Color {
        switch channel {
        case .rgb, .luminance:
            .white
        case .red:
            .red
        case .green:
            .green
        case .blue:
            .blue
        }
    }

    private func generateCurveValues() -> [CGFloat] {
        generateCurveValues(for: curve)
    }

    private func generateCurveValues(for curve: CurveAdjustment) -> [CGFloat] {
        // 如果没有用户添加的点，返回线性曲线（对角线）
        if curve.points.isEmpty {
            var curveValues = [CGFloat](repeating: 0, count: 100)
            for i in 0 ..< 100 {
                curveValues[i] = CGFloat(i) / 99.0
            }
            return curveValues
        }

        var allPoints: [(input: Double, output: Double)] = [(0, 0)]

        for point in curve.points {
            allPoints.append((point.input, point.output))
        }

        allPoints.append((1, 1))
        allPoints.sort { $0.input < $1.input }

        var curveValues = [CGFloat](repeating: 0, count: 100)

        for i in 0 ..< 100 {
            let x = Double(i) / 99.0
            let y = interpolate(x: x, points: allPoints)
            curveValues[i] = CGFloat(y)
        }

        return curveValues
    }

    // Photoshop 的曲线插值算法：自然三次样条插值 (Natural Cubic Spline)
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

    // 绘制坐标轴标签（起点和终点值）
    private func drawAxisLabels(in size: CGSize) -> some View {
        ZStack {
            // 右下角：输入终点 (255)
            Text("255")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .position(x: size.width - 15, y: size.height - 8)

            // 左上角：输出终点 (255)
            Text("255")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .position(x: 15, y: 8)
        }
    }
}
