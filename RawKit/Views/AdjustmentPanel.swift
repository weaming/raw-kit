import SwiftUI

struct ResizableAdjustmentPanel: View {
    @Binding var adjustments: ImageAdjustments
    @Binding var width: CGFloat
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
                            width = max(200, min(500, newWidth))
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

            AdjustmentPanel(adjustments: $adjustments)
                .frame(width: width)
        }
    }
}

struct AdjustmentPanel: View {
    @Binding var adjustments: ImageAdjustments
    @State private var expandedSection: AdjustmentSection? = .basic

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
                        isExpanded: expandedSection == .basic,
                        onToggle: { toggleSection(.basic) }
                    ) {
                        BasicAdjustmentsView(adjustments: $adjustments)
                    }

                    AdjustmentSection.color.view(
                        isExpanded: expandedSection == .color,
                        onToggle: { toggleSection(.color) }
                    ) {
                        ColorAdjustmentsView(adjustments: $adjustments)
                    }

                    AdjustmentSection.detail.view(
                        isExpanded: expandedSection == .detail,
                        onToggle: { toggleSection(.detail) }
                    ) {
                        DetailAdjustmentsView(adjustments: $adjustments)
                    }
                }
            }
        }
    }

    private func toggleSection(_ section: AdjustmentSection) {
        expandedSection = expandedSection == section ? nil : section
    }
}

enum AdjustmentSection {
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
        onToggle: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        }
        .padding(.horizontal, 16)
    }
}

struct ColorAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments

    var body: some View {
        VStack(spacing: 16) {
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
        }
        .padding(.horizontal, 16)
    }
}

struct DetailAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments

    var body: some View {
        VStack(spacing: 16) {
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
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)

                Button(action: { resetToDefault() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .frame(width: 20, height: 20)
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
        case "亮度": return value == defaultAdjustments.brightness
        case "对比度": return value == defaultAdjustments.contrast
        case "饱和度": return value == defaultAdjustments.saturation
        case "高光": return value == defaultAdjustments.highlights
        case "阴影": return value == defaultAdjustments.shadows
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
        case "亮度": value = defaultAdjustments.brightness
        case "对比度": value = defaultAdjustments.contrast
        case "饱和度": value = defaultAdjustments.saturation
        case "高光": value = defaultAdjustments.highlights
        case "阴影": value = defaultAdjustments.shadows
        case "色温": value = defaultAdjustments.temperature
        case "色调": value = defaultAdjustments.tint
        case "自然饱和度": value = defaultAdjustments.vibrance
        case "锐化": value = defaultAdjustments.sharpness
        default: break
        }
    }
}
