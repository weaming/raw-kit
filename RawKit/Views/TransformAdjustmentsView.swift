import SwiftUI

struct TransformAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments
    @Binding var isCropModeEnabled: Bool
    let onStartCrop: () -> Void
    let onApplyCrop: () -> Void
    let onCancelCrop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: rotateLeft) {
                    Image(systemName: "rotate.left")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .help("向左旋转90°")
                .keyboardShortcut("[", modifiers: .command)

                Button(action: rotateRight) {
                    Image(systemName: "rotate.right")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .help("向右旋转90°")
                .keyboardShortcut("]", modifiers: .command)

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

                if isCropModeEnabled {
                    Button(action: onCancelCrop) {
                        Image(systemName: "xmark")
                            .font(.title3)
                    }
                    .buttonStyle(.bordered)
                    .help("取消裁切")
                    .accessibilityLabel("取消裁切")
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: onApplyCrop) {
                        Image(systemName: "checkmark")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .help("应用裁切")
                    .accessibilityLabel("应用裁切")
                    .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button(action: onStartCrop) {
                        Image(systemName: "crop")
                            .font(.title3)
                            .foregroundColor(hasCrop ? .blue : .primary)
                    }
                    .buttonStyle(.bordered)
                    .help("裁切")
                    .accessibilityLabel("裁切")
                }

                Spacer()
            }

            SimpleSlider(
                title: "旋转",
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

    private func rotateLeft() {
        adjustments.rotation = (adjustments.rotation + 90) % 360
    }

    private func rotateRight() {
        adjustments.rotation = (adjustments.rotation - 90 + 360) % 360
    }

}
