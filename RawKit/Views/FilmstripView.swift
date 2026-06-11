import AppKit
import SwiftUI

// Lightroom 风格的底部胶片栏
struct FilmstripView: View {
    let images: [ImageInfo]
    @Binding var selectedIndices: Set<Int>
    @Binding var displayedIndex: Int?
    let adjustmentsForImageID: (UUID) -> ImageAdjustments
    @ObservedObject var thumbnailManager: ThumbnailManager
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
                HorizontalWheelScrollContainer {
                    HStack(spacing: 4) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, imageInfo in
                            let adjustments = adjustmentsForImageID(imageInfo.id)

                            ThumbnailItemView(
                                imageInfo: imageInfo,
                                baseThumbnail: thumbnailManager.baseThumbnails[imageInfo.id],
                                adjustedThumbnail: thumbnailManager.adjustedThumbnails[imageInfo.id],
                                baseThumbnailIsHDR: thumbnailManager.baseThumbnailIsHDR[imageInfo.id] ?? false,
                                adjustedThumbnailIsHDR: thumbnailManager.adjustedThumbnailIsHDR[imageInfo.id] ?? false,
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
                                if imageInfo.thumbnail == nil || imageInfo.fileType == .raw(.x3f) {
                                    thumbnailManager.generateBaseThumbnail(for: imageInfo)
                                }

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

private struct HorizontalWheelScrollContainer<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: AnyView(content))
    }

    func makeNSView(context: Context) -> HorizontalWheelScrollView {
        let scrollView = HorizontalWheelScrollView()
        let hostingView = context.coordinator.hostingView

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            hostingView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            hostingView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ nsView: HorizontalWheelScrollView, context: Context) {
        context.coordinator.hostingView.rootView = AnyView(content)
        context.coordinator.hostingView.layoutSubtreeIfNeeded()
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
    }

    final class Coordinator {
        let hostingView: NSHostingView<AnyView>

        init(rootView: AnyView) {
            hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 13.0, *) {
                hostingView.sizingOptions = [.intrinsicContentSize]
            }
        }
    }
}

private final class HorizontalWheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              abs(event.scrollingDeltaY) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }

        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let clipView = contentView
        let maxOriginX = max(0, documentView.frame.width - clipView.bounds.width)
        guard maxOriginX > 0 else { return }

        let deltaScale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let horizontalDelta = event.scrollingDeltaY * deltaScale

        var newOrigin = clipView.bounds.origin
        newOrigin.x = min(max(newOrigin.x - horizontalDelta, 0), maxOriginX)

        clipView.scroll(to: newOrigin)
        reflectScrolledClipView(clipView)
    }
}

// 缩略图项
struct ThumbnailItemView: View {
    let imageInfo: ImageInfo
    let baseThumbnail: NSImage?
    let adjustedThumbnail: NSImage?
    let baseThumbnailIsHDR: Bool
    let adjustedThumbnailIsHDR: Bool
    let isSelected: Bool
    let isDisplayed: Bool
    let size: CGFloat

    var displayThumbnail: NSImage? {
        adjustedThumbnail ?? baseThumbnail ?? imageInfo.thumbnail
    }

    var isDisplayThumbnailHDR: Bool {
        if adjustedThumbnail != nil {
            return adjustedThumbnailIsHDR
        }

        if baseThumbnail != nil {
            return baseThumbnailIsHDR
        }

        return false
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let thumbnail = displayThumbnail {
                DynamicRangeThumbnailImage(
                    image: thumbnail,
                    isHDREnabled: isDisplayThumbnailHDR
                )
                    .frame(width: size, height: size)
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

private struct DynamicRangeThumbnailImage: NSViewRepresentable {
    let image: NSImage
    let isHDREnabled: Bool

    func makeNSView(context _: Context) -> DynamicRangeThumbnailNSView {
        let view = DynamicRangeThumbnailNSView()
        view.image = image
        view.isHDREnabled = isHDREnabled
        return view
    }

    func updateNSView(_ nsView: DynamicRangeThumbnailNSView, context _: Context) {
        nsView.image = image
        nsView.isHDREnabled = isHDREnabled
    }
}

private final class DynamicRangeThumbnailNSView: NSView {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            layer?.contents = image
        }
    }

    var isHDREnabled = false {
        didSet {
            guard isHDREnabled != oldValue else { return }
            applyDynamicRangePreference()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        applyDynamicRangePreference()
    }

    private func applyDynamicRangePreference() {
        if #available(macOS 26.0, *) {
            layer?.preferredDynamicRange = isHDREnabled ? .high : .standard
        }
    }
}
