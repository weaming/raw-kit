import SwiftUI

// 左侧边栏，包含多个可折叠的面板
struct LeftSidebarView: View {
    @Binding var width: CGFloat
    @Binding var presetsExpanded: Bool
    @Binding var lutExpanded: Bool

    @Binding var adjustments: ImageAdjustments
    let onLoadPreset: (ImageAdjustments) -> Void
    let onLoadLUT: (URL?) -> Void

    private let minWidth: CGFloat = 200
    private let maxWidth: CGFloat = 400

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    CollapsiblePanel(
                        title: "调整预设",
                        isExpanded: $presetsExpanded
                    ) {
                        PresetsPanel(
                            currentAdjustments: adjustments,
                            onLoadPreset: onLoadPreset
                        )
                    }

                    Divider()

                    CollapsiblePanel(
                        title: "LUT",
                        isExpanded: $lutExpanded
                    ) {
                        LUTPanel(
                            onLoadLUT: onLoadLUT,
                            lutAlpha: $adjustments.lutAlpha,
                            currentLUTURL: $adjustments.lutURL,
                            adjustments: $adjustments
                        )
                    }
                }
            }
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // 拖动条
            Rectangle()
                .fill(Color.clear)
                .frame(width: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newWidth = width + value.translation.width
                            width = min(max(newWidth, minWidth), maxWidth)
                        }
                )
                .cursor(.resizeLeftRight)
        }
    }
}

// 可折叠面板容器
struct CollapsiblePanel<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor))

            if isExpanded {
                content
                    .padding(.vertical, 8)
            }
        }
    }
}

// NSView 扩展：添加鼠标指针
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
