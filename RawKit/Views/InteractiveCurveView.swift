import SwiftUI

struct InteractiveCurveView: View {
    private enum Layout {
        static let topInset: CGFloat = 12
        static let leadingInset: CGFloat = 14
        static let trailingInset: CGFloat = 18
        static let bottomInset: CGFloat = 22
        static let pointSize: CGFloat = 12
        static let selectedPointSize: CGFloat = 15
        static let hitRadius: CGFloat = 14
        static let curveSamples = 256
        static let minimumInputSpacing = 0.002
    }

    @Binding var curve: CurveAdjustment
    let channel: CurveAdjustment.Channel
    var referenceCurves: [CurveAdjustment.Channel: CurveAdjustment]?

    @State private var draggedPointId: UUID?
    @State private var selectedPointId: UUID?
    @State private var hoveredPointId: UUID?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let plotRect = plotRect(in: geometry.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundGradient)

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 1)

                drawGrid(in: plotRect)
                drawDiagonal(in: plotRect)

                if channel == .rgb, let references = referenceCurves {
                    drawReferenceCurves(in: plotRect, curves: references)
                }

                drawCurve(in: plotRect)
                drawHoverGuides(in: plotRect)
                drawPoints(in: plotRect)
                drawAxisLabels(in: geometry.size, plotRect: plotRect)
                drawActivePointBadge()
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                handleHover(phase, in: plotRect)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value: value, in: plotRect)
                    }
                    .onEnded { _ in
                        draggedPointId = nil
                    }
            )
        }
        .frame(height: 260)
    }

    private func handleDrag(value: DragGesture.Value, in plotRect: CGRect) {
        let location = clamp(value.location, to: plotRect)
        let input = normalizedInput(for: location.x, in: plotRect)
        let output = normalizedOutput(for: location.y, in: plotRect)

        if draggedPointId == nil {
            if let existingPoint = nearestPoint(to: location, in: plotRect) {
                draggedPointId = existingPoint.id
                selectedPointId = existingPoint.id
            } else {
                let newPointId = curve.addPoint(input: input, output: output)
                draggedPointId = newPointId
                selectedPointId = newPointId
            }
        }

        guard let pointId = draggedPointId else { return }

        let clampedInput = clampedInput(for: pointId, proposed: input)
        curve.updatePoint(id: pointId, input: clampedInput, output: output)
        hoveredPointId = pointId
        hoverLocation = pointLocation(for: pointId, in: plotRect)
    }

    private func handleHover(_ phase: HoverPhase, in plotRect: CGRect) {
        switch phase {
        case let .active(location):
            guard plotRect.contains(location) else {
                hoveredPointId = nil
                hoverLocation = nil
                return
            }

            hoverLocation = location
            hoveredPointId = nearestPoint(to: location, in: plotRect)?.id
        case .ended:
            hoveredPointId = nil
            hoverLocation = nil
        }
    }

    private func drawGrid(in plotRect: CGRect) -> some View {
        Path { path in
            let divisions = 4

            for index in 0 ... divisions {
                let x = plotRect.minX + (plotRect.width * CGFloat(index) / CGFloat(divisions))
                path.move(to: CGPoint(x: x, y: plotRect.minY))
                path.addLine(to: CGPoint(x: x, y: plotRect.maxY))

                let y = plotRect.minY + (plotRect.height * CGFloat(index) / CGFloat(divisions))
                path.move(to: CGPoint(x: plotRect.minX, y: y))
                path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            }
        }
        .stroke(gridColor, lineWidth: 1)
    }

    private func drawDiagonal(in plotRect: CGRect) -> some View {
        Path { path in
            path.move(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.minY))
        }
        .stroke(diagonalColor, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
    }

    private func drawReferenceCurves(
        in plotRect: CGRect,
        curves: [CurveAdjustment.Channel: CurveAdjustment]
    ) -> some View {
        ZStack {
            if let redCurve = curves[.red], redCurve.hasPoints {
                drawReferenceCurve(curve: redCurve, color: .red.opacity(0.45), in: plotRect)
            }

            if let greenCurve = curves[.green], greenCurve.hasPoints {
                drawReferenceCurve(curve: greenCurve, color: .green.opacity(0.45), in: plotRect)
            }

            if let blueCurve = curves[.blue], blueCurve.hasPoints {
                drawReferenceCurve(curve: blueCurve, color: .blue.opacity(0.45), in: plotRect)
            }
        }
    }

    private func drawReferenceCurve(
        curve: CurveAdjustment,
        color: Color,
        in plotRect: CGRect
    ) -> some View {
        let curveValues = generateCurveValues(for: curve)

        return Path { path in
            guard let firstValue = curveValues.first else { return }

            path.move(to: CGPoint(x: plotRect.minX, y: yPosition(for: firstValue, in: plotRect)))

            for (index, value) in curveValues.enumerated() {
                let x = plotRect.minX + (plotRect.width * CGFloat(index) / CGFloat(curveValues.count - 1))
                path.addLine(to: CGPoint(x: x, y: yPosition(for: value, in: plotRect)))
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func drawCurve(in plotRect: CGRect) -> some View {
        let curveValues = generateCurveValues()

        return Path { path in
            guard let firstValue = curveValues.first else { return }

            path.move(to: CGPoint(x: plotRect.minX, y: yPosition(for: firstValue, in: plotRect)))

            for (index, value) in curveValues.enumerated() {
                let x = plotRect.minX + (plotRect.width * CGFloat(index) / CGFloat(curveValues.count - 1))
                path.addLine(to: CGPoint(x: x, y: yPosition(for: value, in: plotRect)))
            }
        }
        .stroke(
            channelColor,
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )
        .shadow(color: channelColor.opacity(0.28), radius: 5, y: 1)
    }

    private func drawHoverGuides(in plotRect: CGRect) -> some View {
        Group {
            if let location = hoverLocation, plotRect.contains(location) {
                Path { path in
                    path.move(to: CGPoint(x: location.x, y: plotRect.minY))
                    path.addLine(to: CGPoint(x: location.x, y: plotRect.maxY))
                    path.move(to: CGPoint(x: plotRect.minX, y: location.y))
                    path.addLine(to: CGPoint(x: plotRect.maxX, y: location.y))
                }
                .stroke(channelColor.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    private func drawPoints(in plotRect: CGRect) -> some View {
        ForEach(curve.points) { point in
            let pointIsSelected = isSelected(point)
            let pointPosition = pointLocation(point, in: plotRect)

            Circle()
                .fill(pointFillColor(for: point))
                .frame(
                    width: pointIsSelected ? Layout.selectedPointSize : Layout.pointSize,
                    height: pointIsSelected ? Layout.selectedPointSize : Layout.pointSize
                )
                .overlay(
                    Circle()
                        .stroke(pointStrokeColor(for: point), lineWidth: pointIsSelected ? 2.5 : 2)
                )
                .shadow(color: .black.opacity(pointIsSelected ? 0.25 : 0.12), radius: pointIsSelected ? 5 : 2)
                .position(pointPosition)
                .onTapGesture(count: 2) {
                    removePoint(point.id)
                }
                .contextMenu {
                    Button("删除点") {
                        removePoint(point.id)
                    }
                }
        }
    }

    private func drawAxisLabels(in size: CGSize, plotRect: CGRect) -> some View {
        ZStack {
            axisLabel("255")
                .position(x: plotRect.minX + 14, y: plotRect.minY - 2)

            axisLabel("0")
                .position(x: plotRect.minX + 8, y: plotRect.maxY + 10)

            axisLabel("255")
                .position(x: plotRect.maxX - 12, y: plotRect.maxY + 10)

            if channel == .luminance {
                axisLabel("Y")
                    .foregroundColor(channelColor.opacity(0.9))
                    .position(x: size.width - 12, y: plotRect.minY + 10)
            }
        }
    }

    private func drawActivePointBadge() -> some View {
        let activePoint = self.activePoint

        return Group {
            if let activePoint {
                HStack(spacing: 8) {
                    Circle()
                        .fill(channelColor)
                        .frame(width: 8, height: 8)

                    Text(
                        "输入 \(Int((activePoint.input * 255).rounded()))  输出 \(Int((activePoint.output * 255).rounded()))"
                    )
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .padding(.leading, 10)
            }
        }
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary.opacity(0.9))
    }

    private var activePoint: CurveAdjustment.CurvePoint? {
        if let draggedPointId, let point = curve.points.first(where: { $0.id == draggedPointId }) {
            return point
        }

        if let selectedPointId, let point = curve.points.first(where: { $0.id == selectedPointId }) {
            return point
        }

        if let hoveredPointId, let point = curve.points.first(where: { $0.id == hoveredPointId }) {
            return point
        }

        return nil
    }

    private var channelColor: Color {
        switch channel {
        case .rgb:
            return Color.white.opacity(0.96)
        case .red:
            return Color(red: 1.0, green: 0.40, blue: 0.40)
        case .green:
            return Color(red: 0.47, green: 0.94, blue: 0.52)
        case .blue:
            return Color(red: 0.42, green: 0.72, blue: 1.0)
        case .luminance:
            return Color(red: 1.0, green: 0.84, blue: 0.32)
        }
    }

    private var backgroundGradient: LinearGradient {
        switch channel {
        case .rgb:
            return LinearGradient(
                colors: [
                    Color(red: 0.23, green: 0.24, blue: 0.27),
                    Color(red: 0.13, green: 0.14, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .red:
            return LinearGradient(
                colors: [
                    Color(red: 0.27, green: 0.14, blue: 0.15),
                    Color(red: 0.16, green: 0.09, blue: 0.10),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .green:
            return LinearGradient(
                colors: [
                    Color(red: 0.17, green: 0.25, blue: 0.17),
                    Color(red: 0.10, green: 0.15, blue: 0.11),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .blue:
            return LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.19, blue: 0.27),
                    Color(red: 0.09, green: 0.12, blue: 0.17),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .luminance:
            return LinearGradient(
                colors: [
                    Color(red: 0.29, green: 0.25, blue: 0.14),
                    Color(red: 0.17, green: 0.15, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderColor: Color {
        channelColor.opacity(channel == .rgb ? 0.18 : 0.28)
    }

    private var gridColor: Color {
        Color.white.opacity(0.12)
    }

    private var diagonalColor: Color {
        Color.white.opacity(0.24)
    }

    private func pointFillColor(for point: CurveAdjustment.CurvePoint) -> Color {
        if point.id == selectedPointId || point.id == draggedPointId {
            return channelColor
        }

        if point.id == hoveredPointId {
            return Color.white.opacity(0.95)
        }

        return Color.black.opacity(0.72)
    }

    private func pointStrokeColor(for point: CurveAdjustment.CurvePoint) -> Color {
        if point.id == selectedPointId || point.id == draggedPointId {
            return Color.white
        }

        return channelColor
    }

    private func isSelected(_ point: CurveAdjustment.CurvePoint) -> Bool {
        point.id == selectedPointId || point.id == draggedPointId || point.id == hoveredPointId
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: Layout.leadingInset,
            y: Layout.topInset,
            width: max(1, size.width - Layout.leadingInset - Layout.trailingInset),
            height: max(1, size.height - Layout.topInset - Layout.bottomInset)
        )
    }

    private func pointLocation(_ point: CurveAdjustment.CurvePoint, in plotRect: CGRect) -> CGPoint {
        CGPoint(
            x: plotRect.minX + plotRect.width * point.input,
            y: plotRect.maxY - plotRect.height * point.output
        )
    }

    private func pointLocation(for pointId: UUID, in plotRect: CGRect) -> CGPoint? {
        guard let point = curve.points.first(where: { $0.id == pointId }) else { return nil }
        return pointLocation(point, in: plotRect)
    }

    private func normalizedInput(for xPosition: CGFloat, in plotRect: CGRect) -> Double {
        Double((xPosition - plotRect.minX) / plotRect.width)
    }

    private func normalizedOutput(for yPosition: CGFloat, in plotRect: CGRect) -> Double {
        Double(1 - ((yPosition - plotRect.minY) / plotRect.height))
    }

    private func yPosition(for normalizedValue: CGFloat, in plotRect: CGRect) -> CGFloat {
        plotRect.maxY - (plotRect.height * normalizedValue)
    }

    private func clamp(_ location: CGPoint, to plotRect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(location.x, plotRect.minX), plotRect.maxX),
            y: min(max(location.y, plotRect.minY), plotRect.maxY)
        )
    }

    private func nearestPoint(
        to location: CGPoint,
        in plotRect: CGRect,
        maxDistance: CGFloat = Layout.hitRadius
    ) -> CurveAdjustment.CurvePoint? {
        curve.points.min { lhs, rhs in
            pointDistance(lhs, to: location, in: plotRect) < pointDistance(rhs, to: location, in: plotRect)
        }
        .flatMap { point in
            pointDistance(point, to: location, in: plotRect) <= maxDistance ? point : nil
        }
    }

    private func pointDistance(
        _ point: CurveAdjustment.CurvePoint,
        to location: CGPoint,
        in plotRect: CGRect
    ) -> CGFloat {
        let pointLocation = pointLocation(point, in: plotRect)
        let dx = pointLocation.x - location.x
        let dy = pointLocation.y - location.y
        return sqrt((dx * dx) + (dy * dy))
    }

    private func clampedInput(for pointId: UUID, proposed input: Double) -> Double {
        let sortedPoints = curve.points.sorted { $0.input < $1.input }

        guard let index = sortedPoints.firstIndex(where: { $0.id == pointId }) else {
            return max(0, min(1, input))
        }

        var lowerBound = 0.0
        var upperBound = 1.0

        if index > 0 {
            lowerBound = sortedPoints[index - 1].input + Layout.minimumInputSpacing
        }

        if index < sortedPoints.count - 1 {
            upperBound = sortedPoints[index + 1].input - Layout.minimumInputSpacing
        }

        if lowerBound > upperBound {
            return max(0, min(1, input))
        }

        return max(lowerBound, min(upperBound, input))
    }

    private func removePoint(_ pointId: UUID) {
        curve.removePoint(id: pointId)

        if selectedPointId == pointId {
            selectedPointId = nil
        }

        if hoveredPointId == pointId {
            hoveredPointId = nil
        }

        if draggedPointId == pointId {
            draggedPointId = nil
        }
    }

    private func generateCurveValues() -> [CGFloat] {
        generateCurveValues(for: curve)
    }

    private func generateCurveValues(for curve: CurveAdjustment) -> [CGFloat] {
        if curve.points.isEmpty {
            return (0 ..< Layout.curveSamples).map { CGFloat($0) / CGFloat(Layout.curveSamples - 1) }
        }

        var allPoints: [(input: Double, output: Double)] = [(0, 0)]
        allPoints.append(contentsOf: curve.points.map { ($0.input, $0.output) })
        allPoints.append((1, 1))
        allPoints.sort { $0.input < $1.input }

        return (0 ..< Layout.curveSamples).map { index in
            let x = Double(index) / Double(Layout.curveSamples - 1)
            return CGFloat(interpolate(x: x, points: allPoints))
        }
    }

    private func interpolate(x: Double, points: [(input: Double, output: Double)]) -> Double {
        guard points.count >= 2 else { return x }

        if x <= points.first!.input {
            return points.first!.output
        }

        if x >= points.last!.input {
            return points.last!.output
        }

        let count = points.count
        var a = [Double](repeating: 0, count: count)
        var b = [Double](repeating: 0, count: count)
        var c = [Double](repeating: 0, count: count)
        var d = [Double](repeating: 0, count: count)

        for index in 0 ..< count {
            a[index] = points[index].output
        }

        var h = [Double](repeating: 0, count: count - 1)
        for index in 0 ..< (count - 1) {
            h[index] = points[index + 1].input - points[index].input
        }

        var alpha = [Double](repeating: 0, count: count)
        for index in 1 ..< (count - 1) {
            alpha[index] = (3.0 / h[index]) * (a[index + 1] - a[index]) -
                (3.0 / h[index - 1]) * (a[index] - a[index - 1])
        }

        var l = [Double](repeating: 0, count: count)
        var mu = [Double](repeating: 0, count: count)
        var z = [Double](repeating: 0, count: count)

        l[0] = 1.0

        for index in 1 ..< (count - 1) {
            l[index] = 2.0 * (points[index + 1].input - points[index - 1].input) - h[index - 1] * mu[index - 1]
            mu[index] = h[index] / l[index]
            z[index] = (alpha[index] - h[index - 1] * z[index - 1]) / l[index]
        }

        l[count - 1] = 1.0

        for index in (0 ..< (count - 1)).reversed() {
            c[index] = z[index] - mu[index] * c[index + 1]
            b[index] = (a[index + 1] - a[index]) / h[index] -
                h[index] * (c[index + 1] + (2.0 * c[index])) / 3.0
            d[index] = (c[index + 1] - c[index]) / (3.0 * h[index])
        }

        for index in 0 ..< (count - 1) {
            if x >= points[index].input, x <= points[index + 1].input {
                let dx = x - points[index].input
                let result = a[index] + (b[index] * dx) + (c[index] * dx * dx) + (d[index] * dx * dx * dx)
                return max(0, min(1, result))
            }
        }

        return max(0, min(1, x))
    }
}
