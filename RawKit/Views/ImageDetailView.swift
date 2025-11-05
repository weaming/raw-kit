import CoreImage
import SwiftUI

struct ImageDetailView: View {
    let imageInfo: ImageInfo
    let savedAdjustments: ImageAdjustments?
    @Binding var sidebarWidth: CGFloat
    let onAdjustmentsChanged: (ImageAdjustments) -> Void

    @State private var originalCIImage: CIImage?
    @State private var displayImage: NSImage?
    @State private var isLoading = true
    @State private var loadingStage: LoadingStage = .thumbnail
    @State private var scale: CGFloat = 1.0
    @State private var adjustments = ImageAdjustments.default
    @State private var showAdjustmentPanel = true

    enum LoadingStage {
        case thumbnail
        case mediumResolution
        case fullResolution
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("加载中...")
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = displayImage {
                    ZoomableImageView(image: image, scale: $scale)
                        .clipped()
                } else {
                    Text("无法加载图像")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ImageInfoBar(
                    imageInfo: imageInfo,
                    scale: scale,
                    showAdjustmentPanel: $showAdjustmentPanel
                )
            }
            .clipped()

            if showAdjustmentPanel {
                Divider()
                ResizableAdjustmentPanel(
                    adjustments: $adjustments,
                    width: $sidebarWidth
                )
            }
        }
        .task {
            if let saved = savedAdjustments {
                adjustments = saved
            }
            await loadImageProgressively()
        }
        .onChange(of: adjustments) { _, newValue in
            onAdjustmentsChanged(newValue)
            Task {
                await applyAdjustments(newValue)
            }
        }
    }

    private func loadImageProgressively() async {
        loadingStage = .thumbnail

        if let thumbnail = ImageProcessor.loadThumbnail(from: imageInfo.url) {
            displayImage = ImageProcessor.convertToNSImage(thumbnail)
            isLoading = false
        }

        loadingStage = .mediumResolution
        await Task.yield()

        if let mediumImage = ImageProcessor.loadMediumResolution(from: imageInfo.url) {
            originalCIImage = mediumImage
            displayImage = ImageProcessor.convertToNSImage(mediumImage)
        }

        loadingStage = .fullResolution
        await Task.yield()

        if let fullImage = await ImageProcessor.loadCIImage(from: imageInfo.url) {
            originalCIImage = fullImage
            displayImage = ImageProcessor.convertToNSImage(fullImage)
        }

        isLoading = false
    }

    private func applyAdjustments(_ adj: ImageAdjustments) async {
        guard let original = originalCIImage else { return }

        let adjusted = ImageProcessor.applyAdjustments(to: original, adjustments: adj)
        displayImage = ImageProcessor.convertToNSImage(adjusted)
    }
}

struct ImageInfoBar: View {
    let imageInfo: ImageInfo
    let scale: CGFloat
    @Binding var showAdjustmentPanel: Bool

    var body: some View {
        HStack {
            Text(imageInfo.filename)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if let size = imageInfo.dimensions {
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(String(format: "%.0f%%", scale * 100))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(minWidth: 50, alignment: .trailing)

            Button(action: { showAdjustmentPanel.toggle() }) {
                Image(systemName: showAdjustmentPanel ? "sidebar.right" : "sidebar.left")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(showAdjustmentPanel ? "隐藏调整面板" : "显示调整面板")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
