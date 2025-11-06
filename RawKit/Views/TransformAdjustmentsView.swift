import SwiftUI

struct TransformAdjustmentsView: View {
    @Binding var adjustments: ImageAdjustments

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button(action: {
                    adjustments.rotation = (adjustments.rotation - 90 + 360) % 360
                }) {
                    Image(systemName: "rotate.left")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .help("向左旋转90°")

                Button(action: {
                    adjustments.rotation = (adjustments.rotation + 90) % 360
                }) {
                    Image(systemName: "rotate.right")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .help("向右旋转90°")

                Spacer()

                if adjustments.rotation != 0 {
                    Button(action: {
                        adjustments.rotation = 0
                    }) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("重置旋转")
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: {
                    adjustments.flipHorizontal.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.title2)
                        if adjustments.flipHorizontal {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .help("水平镜像")

                Button(action: {
                    adjustments.flipVertical.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.and.down")
                            .font(.title2)
                        if adjustments.flipVertical {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .help("垂直镜像")

                Spacer()

                if adjustments.flipHorizontal || adjustments.flipVertical {
                    Button(action: {
                        adjustments.flipHorizontal = false
                        adjustments.flipVertical = false
                    }) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("重置镜像")
                }
            }
        }
        .padding(.horizontal, 16)
    }
}
