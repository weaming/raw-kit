import SwiftUI

struct ResizableAdjustmentPanel: View, Equatable {
    @Binding var adjustments: ImageAdjustments
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    @Binding var width: CGFloat
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode
    @State private var expandedSection: AdjustmentSection? = .basic
    @State private var isDragging = false

    static func == (lhs: ResizableAdjustmentPanel, rhs: ResizableAdjustmentPanel) -> Bool {
        // 只在 adjustments 或 width 变化时才重绘
        // adjustedCIImage 的变化不应该触发控制面板重绘
        lhs.adjustments == rhs.adjustments &&
        lhs.width == rhs.width &&
        lhs.whiteBalancePickMode == rhs.whiteBalancePickMode
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
                originalCIImage: originalCIImage,
                adjustedCIImage: adjustedCIImage,
                whiteBalancePickMode: $whiteBalancePickMode
            )
            .frame(width: width)
        }
    }
}

struct AdjustmentPanel: View {
    @Binding var adjustments: ImageAdjustments
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode
    @State private var expandedSections: Set<AdjustmentSection> = [.basic, .color]
    @State private var histogram: (red: [Int], green: [Int], blue: [Int])?
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
                    }

                    CollapsibleSection(
                        section: .color,
                        isExpanded: expandedSections.contains(.color),
                        hasChanges: adjustments.hasColorAdjustments,
                        onToggle: { toggleSection(.color) },
                        onReset: { adjustments.resetColor() }
                    ) {
                        ColorAdjustmentsView(
                            adjustments: $adjustments,
                            originalCIImage: originalCIImage,
                            adjustedCIImage: adjustedCIImage,
                            whiteBalancePickMode: $whiteBalancePickMode
                        )
                    }

                    CollapsibleSection(
                        section: .detail,
                        isExpanded: expandedSections.contains(.detail),
                        hasChanges: adjustments.hasDetailAdjustments,
                        onToggle: { toggleSection(.detail) },
                        onReset: { adjustments.resetDetail() }
                    ) {
                        DetailAdjustmentsView(adjustments: $adjustments)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top) // 忽略顶部安全区域，让直方图顶到窗口边缘
        .onChange(of: adjustedCIImage) { _, newValue in
            if newValue != nil {
                loadHistogram()
            }
        }
        .onAppear {
            if adjustedCIImage != nil {
                loadHistogram()
            }
        }
    }

    private func toggleSection(_ section: AdjustmentSection) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
        }
    }

    private func loadHistogram() {
        guard let adjustedCIImage else {
            print("AdjustmentPanel.loadHistogram: adjustedCIImage 为空")
            return
        }

        // 取消之前的任务
        histogramTask?.cancel()

        // 创建新任务，带防抖延迟
        histogramTask = Task {
            // 防抖：等待 100ms，如果期间没有新的更新，才计算
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            // 检查是否被取消
            guard !Task.isCancelled else { return }

            print("AdjustmentPanel.loadHistogram: 开始计算直方图")

            // 在后台线程计算直方图
            let newHistogram = await Task.detached(priority: .userInitiated) {
                calculateHistogram(from: adjustedCIImage)
            }.value

            // 检查是否被取消
            guard !Task.isCancelled else { return }

            // 更新 UI（在主线程）
            await MainActor.run {
                histogram = newHistogram
                if histogram != nil {
                    print("AdjustmentPanel.loadHistogram: 直方图加载成功")
                } else {
                    print("AdjustmentPanel.loadHistogram: 直方图加载失败")
                }
            }
        }
    }

    private nonisolated func calculateHistogram(from ciImage: CIImage) -> (
        red: [Int], green: [Int], blue: [Int]
    )? {
        let extent = ciImage.extent
        let bins = 256

        // 为了避免内存问题，将大图像缩小到合理尺寸再计算直方图
        let maxDimension: CGFloat = 2048
        let scale = min(1.0, maxDimension / max(extent.width, extent.height))

        let scaledImage: CIImage
        if scale < 1.0 {
            scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            print("直方图计算：图像缩小到 \(String(format: "%.1f", scale * 100))%")
        } else {
            scaledImage = ciImage
        }

        let scaledExtent = scaledImage.extent

        // 创建直方图计算滤镜
        guard
            let filter = CIFilter(
                name: "CIAreaHistogram",
                parameters: [
                    kCIInputImageKey: scaledImage,
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
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
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

struct BasicAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments

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

struct ColorAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode

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
                        Text(whiteBalancePickMode == .whiteBalance ? "取消(w)" : "白平衡(w)")
                    }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("w", modifiers: [])

                Button(action: {
                    applyAutoWhiteBalance()
                }) {
                    Text("自动")
                }
                .buttonStyle(.bordered)
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
                adjustedCIImage: adjustedCIImage,
                pickMode: $whiteBalancePickMode
            )
        }
        .padding(.horizontal, 16)
    }

    private func applyAutoWhiteBalance() {
        guard let originalCIImage else {
            print("自动白平衡: originalCIImage 为空")
            return
        }

        if let wb = ImageProcessor.calculateAutoWhiteBalance(from: originalCIImage) {
            adjustments.temperature = wb.temperature
            adjustments.tint = wb.tint
        }
    }
}

// 白平衡和曲线调整包装视图
// 将 CurveAdjustmentView 嵌入到面板中
struct WhiteBalanceAndCurveView: View {
    @Binding var adjustments: ImageAdjustments
    let adjustedCIImage: CIImage?
    @Binding var pickMode: CurveAdjustmentView.PickMode

    var body: some View {
        CurveAdjustmentView(
            adjustments: $adjustments,
            ciImage: adjustedCIImage,
            pickMode: $pickMode
        )
        .padding(0)
    }
}

struct DetailAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments

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

    static func == (lhs: SliderControl, rhs: SliderControl) -> Bool {
        lhs.title == rhs.title &&
        lhs.value == rhs.value &&
        lhs.range == rhs.range &&
        lhs.step == rhs.step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text(formatValue(value))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 50, alignment: .trailing)
            }

            HStack(spacing: 8) {
                SliderWithDoubleTap(
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            let steppedValue = round(newValue / step) * step
                            value = steppedValue
                        }
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
        case "曝光": return value == defaultAdjustments.exposure
        case "线性曝光": return value == defaultAdjustments.linearExposure
        case "亮度": return value == defaultAdjustments.brightness
        case "对比度": return value == defaultAdjustments.contrast
        case "饱和度": return value == defaultAdjustments.saturation
        case "高光": return value == defaultAdjustments.highlights
        case "阴影": return value == defaultAdjustments.shadows
        case "白色": return value == defaultAdjustments.whites
        case "黑色": return value == defaultAdjustments.blacks
        case "清晰度": return value == defaultAdjustments.clarity
        case "去雾": return value == defaultAdjustments.dehaze
        case "色温": return abs(value - defaultAdjustments.temperature) < AppConfig.whitePointTolerance
        case "色调": return value == defaultAdjustments.tint
        case "自然饱和度": return value == defaultAdjustments.vibrance
        case "锐化": return value == defaultAdjustments.sharpness
        default: return false
        }
    }

    private func resetToDefault() {
        let defaultAdjustments = ImageAdjustments.default

        switch title {
        case "曝光": value = defaultAdjustments.exposure
        case "线性曝光": value = defaultAdjustments.linearExposure
        case "亮度": value = defaultAdjustments.brightness
        case "对比度": value = defaultAdjustments.contrast
        case "饱和度": value = defaultAdjustments.saturation
        case "高光": value = defaultAdjustments.highlights
        case "阴影": value = defaultAdjustments.shadows
        case "白色": value = defaultAdjustments.whites
        case "黑色": value = defaultAdjustments.blacks
        case "清晰度": value = defaultAdjustments.clarity
        case "去雾": value = defaultAdjustments.dehaze
        case "色温": value = defaultAdjustments.temperature
        case "色调": value = defaultAdjustments.tint
        case "自然饱和度": value = defaultAdjustments.vibrance
        case "锐化": value = defaultAdjustments.sharpness
        default: break
        }
    }
}

// 支持双击重置的滑块
struct SliderWithDoubleTap: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onDoubleTap: () -> Void
    let enableThrottle: Bool  // 是否启用节流

    init(value: Binding<Double>, range: ClosedRange<Double>, onDoubleTap: @escaping () -> Void, enableThrottle: Bool = false) {
        self._value = value
        self.range = range
        self.onDoubleTap = onDoubleTap
        self.enableThrottle = enableThrottle
    }

    func makeNSView(context: Context) -> DragOnlySlider {
        let slider = DragOnlySlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true  // 保持连续模式，配合节流机制

        // 添加双击手势
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleClick.numberOfClicksRequired = 2
        slider.addGestureRecognizer(doubleClick)

        return slider
    }

    func updateNSView(_ nsView: DragOnlySlider, context: Context) {
        // 只在值真正不同时才更新，避免干扰用户交互
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onDoubleTap: onDoubleTap, enableThrottle: enableThrottle)
    }

    class Coordinator: NSObject {
        @Binding var value: Double
        let onDoubleTap: () -> Void
        let enableThrottle: Bool

        private var lastUpdateTime: TimeInterval = 0
        private var pendingValue: Double?
        private var updateTimer: Timer?
        private let throttleInterval: TimeInterval = 0.033  // 30fps，避免过于频繁的渲染

        init(value: Binding<Double>, onDoubleTap: @escaping () -> Void, enableThrottle: Bool) {
            _value = value
            self.onDoubleTap = onDoubleTap
            self.enableThrottle = enableThrottle
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let newValue = sender.doubleValue
            let now = CACurrentMediaTime()

            // 如果禁用节流，立即更新
            guard enableThrottle else {
                value = newValue
                return
            }

            // 节流更新（限制 30fps）
            let elapsed = now - lastUpdateTime
            if elapsed >= throttleInterval {
                // 距离上次更新足够久，立即更新
                lastUpdateTime = now
                pendingValue = nil
                value = newValue
            } else {
                // 太频繁，记录待处理值，稍后更新
                pendingValue = newValue

                // 如果已有定时器在等待，不创建新的
                guard updateTimer == nil else { return }

                // 创建定时器确保最终值被应用
                let remainingTime = throttleInterval - elapsed
                updateTimer = Timer.scheduledTimer(withTimeInterval: remainingTime, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    if let pending = self.pendingValue {
                        self.value = pending
                        self.pendingValue = nil
                        self.lastUpdateTime = CACurrentMediaTime()
                    }
                    self.updateTimer = nil
                }
            }
        }

        @objc func handleDoubleTap(_ sender: NSClickGestureRecognizer) {
            onDoubleTap()
        }
    }
}

// 直方图视图组件
struct HistogramView: View {
    let histogram: (red: [Int], green: [Int], blue: [Int])

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            // 计算综合亮度直方图（使用感知亮度公式）
            let luminanceHistogram = calculateLuminanceHistogram()

            // 找到最大值用于归一化
            let maxValue = max(
                luminanceHistogram.max() ?? 1,
                histogram.red.max() ?? 1,
                histogram.green.max() ?? 1,
                histogram.blue.max() ?? 1
            )

            ZStack {
                // 绘制综合亮度直方图（灰色）
                drawHistogramBars(
                    histogram: luminanceHistogram,
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

    // 计算亮度直方图
    private func calculateLuminanceHistogram() -> [Int] {
        var luminanceHistogram = [Int](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            let r = histogram.red[i]
            let g = histogram.green[i]
            let b = histogram.blue[i]
            // 使用感知亮度公式的权重
            luminanceHistogram[i] = Int(
                Double(r) * 0.299 + Double(g) * 0.587 + Double(b) * 0.114
            )
        }
        return luminanceHistogram
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
