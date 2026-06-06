import SwiftUI

struct TransformAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: rotateLeft) {
                    Image(systemName: "rotate.left")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .help("向左旋转90°")

                Button(action: rotateRight) {
                    Image(systemName: "rotate.right")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .help("向右旋转90°")

                Button(action: { adjustments.flipHorizontal.toggle() }) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.title3)
                        .foregroundColor(adjustments.flipHorizontal ? .blue : .primary)
                }
                .buttonStyle(.bordered)
                .help("水平镜像")

                Button(action: { adjustments.flipVertical.toggle() }) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.title3)
                        .foregroundColor(adjustments.flipVertical ? .blue : .primary)
                }
                .buttonStyle(.bordered)
                .help("垂直镜像")

                Spacer()
            }

            SimpleSlider(
                title: "拉直",
                value: $adjustments.straightenAngle,
                range: ImageAdjustments.straightenAngleRange,
                step: 0.1,
                defaultValue: 0.0,
                valueFormatter: { String(format: "%.1f°", $0) }
            )

            HStack {
                Text("比例")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Picker("", selection: $adjustments.cropAspectRatio) {
                    ForEach(CropAspectRatio.allCases) { ratio in
                        Text(ratio.title).tag(ratio)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
            }

            VStack(spacing: 10) {
                SimpleSlider(
                    title: "左",
                    value: $adjustments.cropLeft,
                    range: cropLeftRange,
                    step: 0.001,
                    defaultValue: 0.0,
                    valueFormatter: percentFormatter
                )

                SimpleSlider(
                    title: "上",
                    value: $adjustments.cropTop,
                    range: cropTopRange,
                    step: 0.001,
                    defaultValue: 0.0,
                    valueFormatter: percentFormatter
                )

                SimpleSlider(
                    title: "右",
                    value: $adjustments.cropRight,
                    range: cropRightRange,
                    step: 0.001,
                    defaultValue: 0.0,
                    valueFormatter: percentFormatter
                )

                SimpleSlider(
                    title: "下",
                    value: $adjustments.cropBottom,
                    range: cropBottomRange,
                    step: 0.001,
                    defaultValue: 0.0,
                    valueFormatter: percentFormatter
                )
            }

            HStack {
                Button("重置裁切") {
                    adjustments.resetCrop()
                }
                .buttonStyle(.borderless)
                .disabled(!hasCrop)

                Spacer()

                Button("重置构图") {
                    adjustments.resetTransform()
                }
                .buttonStyle(.borderless)
                .disabled(!adjustments.hasTransformAdjustments)
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
    }

    private var hasCrop: Bool {
        adjustments.cropLeft > 0.0001 ||
            adjustments.cropTop > 0.0001 ||
            adjustments.cropRight > 0.0001 ||
            adjustments.cropBottom > 0.0001 ||
            adjustments.cropAspectRatio != .free
    }

    private var cropLeftRange: ClosedRange<Double> {
        0.0 ... max(0.0, 0.95 - adjustments.cropRight)
    }

    private var cropTopRange: ClosedRange<Double> {
        0.0 ... max(0.0, 0.95 - adjustments.cropBottom)
    }

    private var cropRightRange: ClosedRange<Double> {
        0.0 ... max(0.0, 0.95 - adjustments.cropLeft)
    }

    private var cropBottomRange: ClosedRange<Double> {
        0.0 ... max(0.0, 0.95 - adjustments.cropTop)
    }

    private func rotateLeft() {
        adjustments.rotation = (adjustments.rotation + 90) % 360
    }

    private func rotateRight() {
        adjustments.rotation = (adjustments.rotation - 90 + 360) % 360
    }

    private func percentFormatter(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100.0)
    }
}
