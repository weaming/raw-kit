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

            VStack(spacing: 10) {
                SimpleSlider(
                    title: "左",
                    value: cropStartBinding(\.cropLeft, oppositeEnd: \.cropRight),
                    range: ImageAdjustments.cropCoordinateRange,
                    validRange: cropStartValidRange(oppositeEnd: adjustments.cropRight),
                    step: 0.001,
                    defaultValue: 0.0,
                    valueFormatter: percentFormatter
                )

                SimpleSlider(
                    title: "右",
                    value: cropEndBinding(\.cropRight, oppositeStart: \.cropLeft),
                    range: ImageAdjustments.cropCoordinateRange,
                    validRange: cropEndValidRange(oppositeStart: adjustments.cropLeft),
                    step: 0.001,
                    defaultValue: 1.0,
                    valueFormatter: percentFormatter
                )

                SimpleSlider(
                    title: "上",
                    value: cropStartBinding(\.cropTop, oppositeEnd: \.cropBottom),
                    range: ImageAdjustments.cropCoordinateRange,
                    validRange: cropStartValidRange(oppositeEnd: adjustments.cropBottom),
                    step: 0.001,
                    defaultValue: 0.0,
                    valueFormatter: percentFormatter
                )

                SimpleSlider(
                    title: "下",
                    value: cropEndBinding(\.cropBottom, oppositeStart: \.cropTop),
                    range: ImageAdjustments.cropCoordinateRange,
                    validRange: cropEndValidRange(oppositeStart: adjustments.cropTop),
                    step: 0.001,
                    defaultValue: 1.0,
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

    private func cropStartBinding(
        _ keyPath: WritableKeyPath<ImageAdjustments, Double>,
        oppositeEnd oppositeKeyPath: KeyPath<ImageAdjustments, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                adjustments[keyPath: keyPath]
            },
            set: { newValue in
                let endValue = 1.0 - adjustments[keyPath: oppositeKeyPath]
                let maximumValue = max(0.0, endValue - ImageAdjustments.minimumCropVisibleFraction)
                let clampedValue = min(
                    max(newValue, ImageAdjustments.cropCoordinateRange.lowerBound),
                    maximumValue
                )

                adjustments[keyPath: keyPath] = clampedValue
            }
        )
    }

    private func cropEndBinding(
        _ keyPath: WritableKeyPath<ImageAdjustments, Double>,
        oppositeStart oppositeKeyPath: KeyPath<ImageAdjustments, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                1.0 - adjustments[keyPath: keyPath]
            },
            set: { newValue in
                let startValue = adjustments[keyPath: oppositeKeyPath]
                let minimumValue = min(1.0, startValue + ImageAdjustments.minimumCropVisibleFraction)
                let clampedValue = min(
                    max(newValue, minimumValue),
                    ImageAdjustments.cropCoordinateRange.upperBound
                )

                adjustments[keyPath: keyPath] = 1.0 - clampedValue
            }
        )
    }

    private func cropStartValidRange(oppositeEnd cropEndInset: Double) -> ClosedRange<Double> {
        let endValue = 1.0 - cropEndInset
        let upperBound = max(
            ImageAdjustments.cropCoordinateRange.lowerBound,
            endValue - ImageAdjustments.minimumCropVisibleFraction
        )

        return ImageAdjustments.cropCoordinateRange.lowerBound ... upperBound
    }

    private func cropEndValidRange(oppositeStart startValue: Double) -> ClosedRange<Double> {
        let lowerBound = min(
            ImageAdjustments.cropCoordinateRange.upperBound,
            startValue + ImageAdjustments.minimumCropVisibleFraction
        )

        return lowerBound ... ImageAdjustments.cropCoordinateRange.upperBound
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
