import SwiftUI

private struct HistogramData: Sendable {
    let red: [Int]
    let green: [Int]
    let blue: [Int]
    let luminance: [Int]
}

struct ResizableAdjustmentPanel: View, Equatable {
    @Binding var adjustments: ImageAdjustments
    @Binding var curvePickSamples: CurvePickSamples
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    let previewCIImage: CIImage?
    let previewRevision: Int
    @Binding var width: CGFloat
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode
    @State private var isDragging = false

    static func == (lhs: ResizableAdjustmentPanel, rhs: ResizableAdjustmentPanel) -> Bool {
        lhs.adjustments == rhs.adjustments &&
        lhs.curvePickSamples == rhs.curvePickSamples &&
        lhs.width == rhs.width &&
        lhs.whiteBalancePickMode == rhs.whiteBalancePickMode &&
        lhs.previewRevision == rhs.previewRevision &&
        (lhs.originalCIImage != nil) == (rhs.originalCIImage != nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isDragging ? Color.blue.opacity(0.3) : Color.clear)
                .frame(width: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            isDragging = true
                            let newWidth = width - value.translation.width
                            width = max(360, min(700, newWidth))
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }

            AdjustmentPanel(
                adjustments: $adjustments,
                curvePickSamples: $curvePickSamples,
                originalCIImage: originalCIImage,
                adjustedCIImage: adjustedCIImage,
                previewCIImage: previewCIImage,
                previewRevision: previewRevision,
                whiteBalancePickMode: $whiteBalancePickMode
            )
            .frame(width: width)
        }
    }
}

struct AdjustmentPanel: View {
    private struct HistogramInput: @unchecked Sendable {
        let image: CIImage
        let revision: Int
    }

    @Binding var adjustments: ImageAdjustments
    @Binding var curvePickSamples: CurvePickSamples
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    let previewCIImage: CIImage?
    let previewRevision: Int
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode
    @State private var expandedSections: Set<AdjustmentSection> = [.basic, .color, .detail]
    @State private var histogram: HistogramData?
    @State private var histogramTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // 直方图（放在最顶部，无任何空白）- 始终显示以保持布局稳定
            Group {
                if let histogram {
                    HistogramView(histogram: histogram)
                } else {
                    // 占位符，保持布局稳定
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .frame(height: 120)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                Rectangle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            HStack {
                Text("调整")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Spacer()

                if adjustments.hasAdjustments {
                    Button("重置") {
                        adjustments.reset()
                        curvePickSamples.reset()
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 16)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))

            ScrollView {
                VStack(spacing: 0) {
                    CollapsibleSection(
                        section: .basic,
                        isExpanded: expandedSections.contains(.basic),
                        hasChanges: adjustments.hasBasicAdjustments,
                        onToggle: { toggleSection(.basic) },
                        onReset: { adjustments.resetBasic() }
                    ) {
                        BasicAdjustmentsView(adjustments: $adjustments)
                            .equatable()
                    }

                    CollapsibleSection(
                        section: .color,
                        isExpanded: expandedSections.contains(.color),
                        hasChanges: adjustments.hasColorAdjustments,
                        onToggle: { toggleSection(.color) },
                        onReset: {
                            adjustments.resetColor()
                            curvePickSamples.reset()
                        }
                    ) {
                        ColorAdjustmentsView(
                            adjustments: $adjustments,
                            curvePickSamples: $curvePickSamples,
                            originalCIImage: originalCIImage,
                            adjustedCIImage: adjustedCIImage,
                            previewRevision: previewRevision,
                            whiteBalancePickMode: $whiteBalancePickMode
                        )
                        .equatable()
                    }

                    CollapsibleSection(
                        section: .detail,
                        isExpanded: expandedSections.contains(.detail),
                        hasChanges: adjustments.hasDetailAdjustments,
                        onToggle: { toggleSection(.detail) },
                        onReset: { adjustments.resetDetail() }
                    ) {
                        DetailAdjustmentsView(adjustments: $adjustments)
                            .equatable()
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top) // 忽略顶部安全区域，让直方图顶到窗口边缘
        .onAppear {
            scheduleHistogramLoad()
        }
        .onChange(of: previewRevision) { _, _ in
            scheduleHistogramLoad()
        }
        .onDisappear {
            histogramTask?.cancel()
        }
    }

    private func toggleSection(_ section: AdjustmentSection) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
        }
    }

    private func scheduleHistogramLoad() {
        guard let previewCIImage else {
            histogramTask?.cancel()
            histogram = nil
            return
        }

        histogramTask?.cancel()
        let input = HistogramInput(image: previewCIImage, revision: previewRevision)

        histogramTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }

            let newHistogram = await Task.detached(priority: .utility) {
                Self.calculateHistogram(from: input.image)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard previewRevision == input.revision else { return }
                histogram = newHistogram
            }
        }
    }

    private nonisolated static var histogramContext: CIContext {
        CIContextManager.shared.getHistogramContext()
    }

    private nonisolated static func prepareDisplayHistogramImage(_ image: CIImage) -> CIImage {
        image
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter(
                "CIColorClamp",
                parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ]
            )
    }

    private nonisolated static func renderHistogram(from histogramImage: CIImage) -> (
        red: [Int], green: [Int], blue: [Int]
    )? {
        let bins = 256
        let scaledExtent = histogramImage.extent

        // 创建直方图计算滤镜
        guard
            let filter = CIFilter(
                name: "CIAreaHistogram",
                parameters: [
                    kCIInputImageKey: histogramImage,
                    kCIInputExtentKey: CIVector(cgRect: scaledExtent),
                    "inputCount": bins,
                    "inputScale": 1.0,
                ]
            ),
            let outputImage = filter.outputImage
        else {
            print("直方图滤镜创建失败")
            return nil
        }

        // 渲染直方图数据 - CIAreaHistogram 输出的是 256x1 的图像，每个像素是 RGBA 格式
        var bitmap = [Float](repeating: 0, count: bins * 4)
        // 优化：使用专用的静态 context，避免每次创建
        Self.histogramContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: bins * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        // 提取各通道数据并转换为整数
        var red = [Int](repeating: 0, count: bins)
        var green = [Int](repeating: 0, count: bins)
        var blue = [Int](repeating: 0, count: bins)

        for i in 0 ..< bins {
            red[i] = Int(bitmap[i * 4] * 10_000_000)
            green[i] = Int(bitmap[i * 4 + 1] * 10_000_000)
            blue[i] = Int(bitmap[i * 4 + 2] * 10_000_000)
        }

        print("直方图计算完成: R前5个值=\(Array(red.prefix(5))), max=\(red.max() ?? 0)")

        return (red: red, green: green, blue: blue)
    }

    private nonisolated static func calculateHistogram(from ciImage: CIImage) -> HistogramData? {
        let extent = ciImage.extent

        // 优化：采样尺寸从 2048 降低到 1024（速度提升 4 倍，精度足够）
        let maxDimension: CGFloat = 1024
        let scale = min(1.0, maxDimension / max(extent.width, extent.height))

        let scaledImage: CIImage
        if scale < 1.0 {
            scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            print("直方图计算：图像缩小到 \(String(format: "%.1f", scale * 100))%")
        } else {
            scaledImage = ciImage
        }

        let displayImage = Self.prepareDisplayHistogramImage(scaledImage)
        let luminanceImage = displayImage.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 0.0]
        )

        guard let rgbHistogram = Self.renderHistogram(from: displayImage),
              let luminanceHistogram = Self.renderHistogram(from: luminanceImage) else {
            return nil
        }

        return HistogramData(
            red: rgbHistogram.red,
            green: rgbHistogram.green,
            blue: rgbHistogram.blue,
            luminance: luminanceHistogram.red
        )
    }
}

struct CollapsibleSection<Content: View>: View {
    let section: AdjustmentSection
    let isExpanded: Bool
    let hasChanges: Bool
    let onToggle: () -> Void
    let onReset: () -> Void
    let content: Content

    init(
        section: AdjustmentSection,
        isExpanded: Bool,
        hasChanges: Bool,
        onToggle: @escaping () -> Void,
        onReset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.isExpanded = isExpanded
        self.hasChanges = hasChanges
        self.onToggle = onToggle
        self.onReset = onReset
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Text(section.title)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Spacer()

                        if hasChanges {
                            Button(action: onReset) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.body)
                            }
                            .buttonStyle(.borderless)
                            .help("重置此组")
                        }

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            content
                .padding(.vertical, 12)
                .frame(maxHeight: isExpanded ? nil : 0)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)

            Divider()
        }
    }
}

enum AdjustmentSection: Hashable {
    case basic
    case color
    case detail

    var title: String {
        switch self {
        case .basic: "基础"
        case .color: "色彩"
        case .detail: "细节"
        }
    }

    func view(
        isExpanded: Bool,
        hasChanges: Bool,
        onToggle: @escaping () -> Void,
        onReset: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Spacer()

                        if hasChanges {
                            Button(action: onReset) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.body)
                            }
                            .buttonStyle(.borderless)
                            .help("重置此组")
                        }

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            if isExpanded {
                content()
                    .padding(.vertical, 12)
            }

            Divider()
        }
    }
}

struct BasicAdjustmentsView: View, Equatable {
    @Binding var adjustments: ImageAdjustments

    // 优化：只在基础调整变化时才重绘
    static func == (lhs: BasicAdjustmentsView, rhs: BasicAdjustmentsView) -> Bool {
        lhs.adjustments.exposure == rhs.adjustments.exposure &&
        lhs.adjustments.linearExposure == rhs.adjustments.linearExposure &&
        lhs.adjustments.brightness == rhs.adjustments.brightness &&
        lhs.adjustments.contrast == rhs.adjustments.contrast &&
        lhs.adjustments.highlights == rhs.adjustments.highlights &&
        lhs.adjustments.shadows == rhs.adjustments.shadows &&
        lhs.adjustments.whites == rhs.adjustments.whites &&
        lhs.adjustments.blacks == rhs.adjustments.blacks
    }

    var body: some View {
        VStack(spacing: 16) {
            SliderControl(
                title: "曝光",
                value: $adjustments.exposure,
                range: ImageAdjustments.exposureRange,
                step: 0.01
            )

            SliderControl(
                title: "线性曝光",
                value: $adjustments.linearExposure,
                range: ImageAdjustments.linearExposureRange,
                step: 0.1
            )

            SliderControl(
                title: "亮度",
                value: $adjustments.brightness,
                range: ImageAdjustments.brightnessRange,
                step: 0.01
            )

            SliderControl(
                title: "对比度",
                value: $adjustments.contrast,
                range: ImageAdjustments.contrastRange,
                step: 0.01
            )

            SliderControl(
                title: "白色",
                value: $adjustments.whites,
                range: ImageAdjustments.whitesRange,
                step: 0.01
            )

            SliderControl(
                title: "高光",
                value: $adjustments.highlights,
                range: ImageAdjustments.highlightsRange,
                step: 0.01
            )

            SliderControl(
                title: "阴影",
                value: $adjustments.shadows,
                range: ImageAdjustments.shadowsRange,
                step: 0.01
            )

            SliderControl(
                title: "黑色",
                value: $adjustments.blacks,
                range: ImageAdjustments.blacksRange,
                step: 0.01
            )
        }
        .padding(.horizontal, 16)
    }
}

struct ColorAdjustmentsView: View, Equatable {
    @Binding var adjustments: ImageAdjustments
    @Binding var curvePickSamples: CurvePickSamples
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    let previewRevision: Int
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode

    static func == (lhs: ColorAdjustmentsView, rhs: ColorAdjustmentsView) -> Bool {
        lhs.adjustments.temperature == rhs.adjustments.temperature &&
        lhs.adjustments.tint == rhs.adjustments.tint &&
        lhs.adjustments.saturation == rhs.adjustments.saturation &&
        lhs.adjustments.vibrance == rhs.adjustments.vibrance &&
        lhs.adjustments.redCurve == rhs.adjustments.redCurve &&
        lhs.adjustments.greenCurve == rhs.adjustments.greenCurve &&
        lhs.adjustments.blueCurve == rhs.adjustments.blueCurve &&
        lhs.adjustments.rgbCurve == rhs.adjustments.rgbCurve &&
        lhs.curvePickSamples == rhs.curvePickSamples &&
        lhs.whiteBalancePickMode == rhs.whiteBalancePickMode &&
        lhs.previewRevision == rhs.previewRevision &&
        (lhs.originalCIImage != nil) == (rhs.originalCIImage != nil)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 白平衡工具栏
            HStack(spacing: 8) {
                Button(action: {
                    whiteBalancePickMode = whiteBalancePickMode == .whiteBalance ? .none :
                        .whiteBalance
                }) {
                    HStack {
                        Image(systemName: "eyedropper")
                        Text(whiteBalancePickMode == .whiteBalance ? "取消" : "白平衡")
                    }
                }
                .buttonStyle(.bordered)
                .help(whiteBalancePickMode == .whiteBalance ? "取消白平衡吸管 (w)" : "使用吸管选取白平衡 (w)")
                .keyboardShortcut("w", modifiers: [])

                Button(action: {
                    applyAutoWhiteBalance()
                }) {
                    Text("自动")
                }
                .buttonStyle(.bordered)
                .disabled(originalCIImage == nil)
                .help(originalCIImage == nil ? "等待图片加载..." : "自动白平衡")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            if whiteBalancePickMode == .whiteBalance {
                Text("点击图片中的白色或中性灰色区域")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, -8)
            }

            SliderControl(
                title: "色温",
                value: $adjustments.temperature,
                range: ImageAdjustments.temperatureRange,
                step: 1
            )

            SliderControl(
                title: "色调",
                value: $adjustments.tint,
                range: ImageAdjustments.tintRange,
                step: 1
            )

            Divider()
                .padding(.vertical, 8)

            SliderControl(
                title: "饱和度",
                value: $adjustments.saturation,
                range: ImageAdjustments.saturationRange,
                step: 0.01
            )

            SliderControl(
                title: "自然饱和度",
                value: $adjustments.vibrance,
                range: ImageAdjustments.vibranceRange,
                step: 0.01
            )

            Divider()
                .padding(.vertical, 8)

            // 曲线调整
            WhiteBalanceAndCurveView(
                adjustments: $adjustments,
                curvePickSamples: $curvePickSamples,
                adjustedCIImage: adjustedCIImage,
                pickMode: $whiteBalancePickMode
            )
        }
        .padding(.horizontal, 16)
    }

    private func applyAutoWhiteBalance() {
        print("自动白平衡: 开始计算，originalCIImage = \(originalCIImage != nil ? "有值" : "nil")")

        guard let originalCIImage else {
            print("自动白平衡: ✗ originalCIImage 为空，无法计算")
            return
        }

        print("自动白平衡: 调用 ImageProcessor.calculateAutoWhiteBalance")
        if let wb = ImageProcessor.calculateAutoWhiteBalance(from: originalCIImage) {
            print("自动白平衡: ✓ 计算成功 - 色温: \(wb.temperature)K, 色调: \(wb.tint)")
            adjustments.temperature = wb.temperature
            adjustments.tint = wb.tint
        } else {
            print("自动白平衡: ✗ 计算失败")
        }
    }
}

// 白平衡和曲线调整包装视图
// 将 CurveAdjustmentView 嵌入到面板中
struct WhiteBalanceAndCurveView: View {
    @Binding var adjustments: ImageAdjustments
    @Binding var curvePickSamples: CurvePickSamples
    let adjustedCIImage: CIImage?
    @Binding var pickMode: CurveAdjustmentView.PickMode

    var body: some View {
        CurveAdjustmentView(
            adjustments: $adjustments,
            ciImage: adjustedCIImage,
            pickMode: $pickMode,
            curvePickSamples: $curvePickSamples
        )
        .padding(0)
    }
}

struct DetailAdjustmentsView: View, Equatable {
    @Binding var adjustments: ImageAdjustments

    // 优化：只在细节调整变化时才重绘
    static func == (lhs: DetailAdjustmentsView, rhs: DetailAdjustmentsView) -> Bool {
        lhs.adjustments.clarity == rhs.adjustments.clarity &&
        lhs.adjustments.dehaze == rhs.adjustments.dehaze &&
        lhs.adjustments.sharpness == rhs.adjustments.sharpness
    }

    var body: some View {
        VStack(spacing: 16) {
            SliderControl(
                title: "清晰度",
                value: $adjustments.clarity,
                range: ImageAdjustments.clarityRange,
                step: 0.01
            )

            SliderControl(
                title: "去雾",
                value: $adjustments.dehaze,
                range: ImageAdjustments.dehazeRange,
                step: 0.01
            )

            SliderControl(
                title: "锐化",
                value: $adjustments.sharpness,
                range: ImageAdjustments.sharpnessRange,
                step: 0.01
            )
        }
        .padding(.horizontal, 16)
    }
}

struct SliderControl: View, Equatable {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @State private var displayValue: Double

    static func == (lhs: SliderControl, rhs: SliderControl) -> Bool {
        lhs.title == rhs.title &&
        lhs.value == rhs.value &&
        lhs.range == rhs.range &&
        lhs.step == rhs.step
    }

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self._displayValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text(formatValue(displayValue))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .trailing)
            }

            HStack(spacing: 8) {
                SliderWithDoubleTap(
                    value: Binding(
                        get: { displayValue },
                        set: handleDisplayValueChange
                    ),
                    range: range,
                    onDoubleTap: { resetToDefault() }
                )

                Button(action: { resetToDefault() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)
                .opacity(isDefaultValue ? 0.3 : 1.0)
                .disabled(isDefaultValue)
            }
        }
        .onChange(of: value) { _, newValue in
            if abs(displayValue - newValue) > 0.0001 {
                displayValue = newValue
            }
        }
    }

    private func formatValue(_ value: Double) -> String {
        if range.upperBound > 100 {
            String(format: "%.0f", value)
        } else if step >= 1 {
            String(format: "%.0f", value)
        } else {
            String(format: "%.2f", value)
        }
    }

    private var isDefaultValue: Bool {
        let defaultAdjustments = ImageAdjustments.default

        switch title {
        case "曝光": return displayValue == defaultAdjustments.exposure
        case "线性曝光": return displayValue == defaultAdjustments.linearExposure
        case "亮度": return displayValue == defaultAdjustments.brightness
        case "对比度": return displayValue == defaultAdjustments.contrast
        case "饱和度": return displayValue == defaultAdjustments.saturation
        case "高光": return displayValue == defaultAdjustments.highlights
        case "阴影": return displayValue == defaultAdjustments.shadows
        case "白色": return displayValue == defaultAdjustments.whites
        case "黑色": return displayValue == defaultAdjustments.blacks
        case "清晰度": return displayValue == defaultAdjustments.clarity
        case "去雾": return displayValue == defaultAdjustments.dehaze
        case "色温": return abs(displayValue - defaultAdjustments.temperature) < AppConfig.whitePointTolerance
        case "色调": return displayValue == defaultAdjustments.tint
        case "自然饱和度": return displayValue == defaultAdjustments.vibrance
        case "锐化": return displayValue == defaultAdjustments.sharpness
        default: return false
        }
    }

    private func handleDisplayValueChange(_ newValue: Double) {
        let steppedValue = round(newValue / step) * step
        if abs(displayValue - steppedValue) > 0.0001 {
            displayValue = steppedValue
        }

        let binding = _value
        DispatchQueue.main.async {
            if abs(binding.wrappedValue - steppedValue) > 0.0001 {
                binding.wrappedValue = steppedValue
            }
        }
    }

    private func resetToDefault() {
        let defaultAdjustments = ImageAdjustments.default

        let resetValue: Double
        switch title {
        case "曝光": resetValue = defaultAdjustments.exposure
        case "线性曝光": resetValue = defaultAdjustments.linearExposure
        case "亮度": resetValue = defaultAdjustments.brightness
        case "对比度": resetValue = defaultAdjustments.contrast
        case "饱和度": resetValue = defaultAdjustments.saturation
        case "高光": resetValue = defaultAdjustments.highlights
        case "阴影": resetValue = defaultAdjustments.shadows
        case "白色": resetValue = defaultAdjustments.whites
        case "黑色": resetValue = defaultAdjustments.blacks
        case "清晰度": resetValue = defaultAdjustments.clarity
        case "去雾": resetValue = defaultAdjustments.dehaze
        case "色温": resetValue = defaultAdjustments.temperature
        case "色调": resetValue = defaultAdjustments.tint
        case "自然饱和度": resetValue = defaultAdjustments.vibrance
        case "锐化": resetValue = defaultAdjustments.sharpness
        default: return
        }

        displayValue = resetValue
        let binding = _value
        DispatchQueue.main.async {
            binding.wrappedValue = resetValue
        }
    }
}

// 支持双击重置的滑块
struct SliderWithDoubleTap: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onDoubleTap: () -> Void

    init(value: Binding<Double>, range: ClosedRange<Double>, onDoubleTap: @escaping () -> Void) {
        self._value = value
        self.range = range
        self.onDoubleTap = onDoubleTap
    }

    func makeNSView(context: Context) -> TrackClickableSlider {
        let slider = TrackClickableSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true  // 保持连续模式，配合节流机制
        slider.onDoubleClick = onDoubleTap

        return slider
    }

    func updateNSView(_ nsView: TrackClickableSlider, context: Context) {
        // 只在值真正不同时才更新，避免干扰用户交互
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onDoubleTap: onDoubleTap)
    }

    class Coordinator: NSObject {
        @Binding var value: Double
        let onDoubleTap: () -> Void

        init(value: Binding<Double>, onDoubleTap: @escaping () -> Void) {
            _value = value
            self.onDoubleTap = onDoubleTap
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value = sender.doubleValue
        }
    }
}

// 直方图视图组件
private struct HistogramView: View {
    let histogram: HistogramData

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            // 找到最大值用于归一化
            let maxValue = max(
                histogram.luminance.max() ?? 1,
                histogram.red.max() ?? 1,
                histogram.green.max() ?? 1,
                histogram.blue.max() ?? 1
            )

            ZStack {
                // 绘制综合亮度直方图（灰色）
                drawHistogramBars(
                    histogram: histogram.luminance,
                    maxValue: maxValue,
                    color: Color.white.opacity(0.5),
                    size: size
                )

                // 绘制 RGB 三个通道（叠加显示）
                drawHistogramBars(
                    histogram: histogram.red,
                    maxValue: maxValue,
                    color: Color.red.opacity(0.6),
                    size: size
                )
                drawHistogramBars(
                    histogram: histogram.green,
                    maxValue: maxValue,
                    color: Color.green.opacity(0.6),
                    size: size
                )
                drawHistogramBars(
                    histogram: histogram.blue,
                    maxValue: maxValue,
                    color: Color.blue.opacity(0.6),
                    size: size
                )
            }
        }
    }

    // 绘制单个通道的直方图柱状图
    private func drawHistogramBars(
        histogram: [Int],
        maxValue: Int,
        color: Color,
        size: CGSize
    ) -> some View {
        Path { path in
            guard maxValue > 0, histogram.count == 256 else { return }

            // 每个 bin 对应一个 x 位置（0-255）
            let barWidth = size.width / 256.0

            for (index, value) in histogram.enumerated() {
                guard value > 0 else { continue }

                let normalizedHeight = CGFloat(value) / CGFloat(maxValue) * size.height
                let x = CGFloat(index) * barWidth
                let y = size.height - normalizedHeight

                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        .stroke(color, lineWidth: max(0.5, min(2.0, size.width / 256.0)))
    }
}
