import SwiftUI

// Lightroom 风格的底部胶片栏
struct FilmstripView: View {
    let images: [ImageInfo]
    @Binding var selectedIndices: Set<Int>
    @Binding var displayedIndex: Int?
    let adjustmentsCache: [UUID: ImageAdjustments]
    let thumbnailManager: ThumbnailManager
    let onDelete: (Set<Int>) -> Void

    @State private var isExpanded = true
    private let thumbnailSize: CGFloat = 80
    private let expandedHeight: CGFloat = 120
    private let collapsedHeight: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            // 展开/折叠控制条
            HStack {
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 8)

                if isExpanded {
                    Text("\(images.count) 张图片")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .frame(height: 24)
            .background(Color(nsColor: .controlBackgroundColor))

            if isExpanded {
                Divider()

                // 水平滚动的缩略图列表
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, imageInfo in
                            ThumbnailItemView(
                                imageInfo: imageInfo,
                                adjustedThumbnail: thumbnailManager.adjustedThumbnails[imageInfo.id],
                                isSelected: selectedIndices.contains(index),
                                isDisplayed: displayedIndex == index,
                                size: thumbnailSize
                            )
                            .onTapGesture {
                                handleTap(index: index)
                            }
                            .contextMenu {
                                Button("删除") {
                                    onDelete([index])
                                }
                            }
                            .onAppear {
                                let adjustments = adjustmentsCache[imageInfo.id] ?? .default
                                if adjustments.hasAdjustments || adjustments.lutURL != nil {
                                    thumbnailManager.generateAdjustedThumbnail(
                                        for: imageInfo,
                                        with: adjustments
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(height: expandedHeight - 24)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(height: isExpanded ? expandedHeight : collapsedHeight)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private func handleTap(index: Int) {
        let modifierFlags = NSEvent.modifierFlags

        if modifierFlags.contains(.command) {
            // Command + 点击：多选
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
        } else if modifierFlags.contains(.shift), let lastSelected = selectedIndices.max() {
            // Shift + 点击：范围选择
            let range = min(lastSelected, index) ... max(lastSelected, index)
            selectedIndices.formUnion(range)
        } else {
            // 普通点击：单选并显示
            selectedIndices = [index]
            displayedIndex = index
        }
    }
}

// 缩略图项
struct ThumbnailItemView: View {
    let imageInfo: ImageInfo
    let adjustedThumbnail: NSImage?
    let isSelected: Bool
    let isDisplayed: Bool
    let size: CGFloat

    var displayThumbnail: NSImage? {
        adjustedThumbnail ?? imageInfo.thumbnail
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let thumbnail = displayThumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(borderColor, lineWidth: borderWidth)
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: size, height: size)
                    .cornerRadius(4)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.7)
                    )
            }

            // 选中标记
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .background(Color.white.clipShape(Circle()))
                    .padding(4)
            }
        }
    }

    private var borderColor: Color {
        if isDisplayed {
            .blue
        } else if isSelected {
            .gray
        } else {
            .clear
        }
    }

    private var borderWidth: CGFloat {
        if isDisplayed {
            3
        } else if isSelected {
            2
        } else {
            0
        }
    }
}
