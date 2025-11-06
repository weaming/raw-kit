import SwiftUI

struct ResizableAdjustmentPanel: View {
    @Binding var adjustments: ImageAdjustments
    let ciImage: CIImage?
    @Binding var width: CGFloat
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode
    @State private var expandedSection: AdjustmentSection? = .basic
    @State private var isDragging = false

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
                ciImage: ciImage,
                whiteBalancePickMode: $whiteBalancePickMode
            )
            .frame(width: width)
        }
    }
}

struct AdjustmentPanel: View {
    @Binding var adjustments: ImageAdjustments
    let ciImage: CIImage?
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode
    @State private var expandedSections: Set<AdjustmentSection> = [.basic, .color]

    var body: some View {
        VStack(spacing: 0) {
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
                    AdjustmentSection.basic.view(
                        isExpanded: expandedSections.contains(.basic),
                        hasChanges: adjustments.hasBasicAdjustments,
                        onToggle: { toggleSection(.basic) },
                        onReset: { adjustments.resetBasic() }
                    ) {
                        BasicAdjustmentsView(adjustments: $adjustments)
                    }

                    AdjustmentSection.color.view(
                        isExpanded: expandedSections.contains(.color),
                        hasChanges: adjustments.hasColorAdjustments,
                        onToggle: { toggleSection(.color) },
                        onReset: { adjustments.resetColor() }
                    ) {
                        ColorAdjustmentsView(
                            adjustments: $adjustments,
                            ciImage: ciImage,
                            whiteBalancePickMode: $whiteBalancePickMode
                        )
                    }

                    AdjustmentSection.detail.view(
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
    }

    private func toggleSection(_ section: AdjustmentSection) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
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
    let ciImage: CIImage?
    @Binding var whiteBalancePickMode: CurveAdjustmentView.PickMode

    var body: some View {
        VStack(spacing: 16) {
            // 白平衡取色器
            VStack(alignment: .leading, spacing: 8) {
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

                if whiteBalancePickMode == .whiteBalance {
                    Text("点击图片中的白色或中性灰色区域")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            SliderControl(
                title: "色温",
                value: $adjustments.temperature,
                range: ImageAdjustments.temperatureRange,
                step: 100
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
                ciImage: ciImage,
                pickMode: $whiteBalancePickMode
            )
        }
        .padding(.horizontal, 16)
    }
}

// 白平衡和曲线调整包装视图
// 将 CurveAdjustmentView 嵌入到面板中
struct WhiteBalanceAndCurveView: View {
    @Binding var adjustments: ImageAdjustments
    let ciImage: CIImage?
    @Binding var pickMode: CurveAdjustmentView.PickMode

    var body: some View {
        CurveAdjustmentView(
            adjustments: $adjustments,
            ciImage: ciImage,
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

struct SliderControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(formatValue(value))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 50, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .onTapGesture(count: 2) {
                        // 双击滑块重置为默认值
                        resetToDefault()
                    }

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
        case "色温": return value == defaultAdjustments.temperature
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
