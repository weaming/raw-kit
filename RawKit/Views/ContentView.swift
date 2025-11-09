import SwiftUI

struct ContentView: View {
    @StateObject private var imageManager = ImageManager()
    @State private var selectedIndices: Set<Int> = []
    @State private var displayedIndex: Int?
    @State private var adjustmentsCache: [UUID: ImageAdjustments] = [:]
    @State private var historyCache: [UUID: AdjustmentHistory] = [:]
    @State private var rightSidebarWidth: CGFloat = 400
    @State private var leftSidebarWidth: CGFloat = 250
    @State private var presetsExpanded = true
    @State private var lutExpanded = true
    @State private var showingExportDialog = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            ToolbarView(
                imageManager: imageManager,
                showingExportDialog: $showingExportDialog
            )

            Divider()

            // 主内容区域
            HStack(spacing: 0) {
                // 左侧边栏
                if !imageManager.images.isEmpty {
                    LeftSidebarView(
                        width: $leftSidebarWidth,
                        presetsExpanded: $presetsExpanded,
                        lutExpanded: $lutExpanded,
                        adjustments: getCurrentAdjustmentsBinding(),
                        onLoadPreset: { preset in
                            if let imageInfo = getCurrentImageInfo() {
                                adjustmentsCache[imageInfo.id] = preset
                            }
                        },
                        onLoadLUT: { url in
                            if let imageInfo = getCurrentImageInfo() {
                                var currentAdj = adjustmentsCache[imageInfo.id] ?? .default
                                currentAdj.lutURL = url
                                adjustmentsCache[imageInfo.id] = currentAdj
                            }
                        }
                    )
                }

                // 中间图片详情区域
                if let index = displayedIndex,
                   index < imageManager.images.count
                {
                    let imageInfo = imageManager.images[index]
                    ImageDetailView(
                        imageInfo: imageInfo,
                        savedAdjustments: adjustmentsCache[imageInfo.id],
                        sidebarWidth: $rightSidebarWidth,
                        onAdjustmentsChanged: { newAdjustments in
                            adjustmentsCache[imageInfo.id] = newAdjustments
                        },
                        history: getCurrentHistory()
                    )
                    .id(imageInfo.id)
                } else {
                    EmptyStateView()
                        .onTapGesture(count: 2) {
                            imageManager.openFileDialog()
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleDrop(providers: providers)
                            return true
                        }
                }
            }

            // 底部胶片栏
            if !imageManager.images.isEmpty {
                Divider()

                FilmstripView(
                    images: imageManager.images,
                    selectedIndices: $selectedIndices,
                    displayedIndex: $displayedIndex,
                    onDelete: handleDelete
                )
            }
        }
        .onChange(of: imageManager.images.count) { oldCount, newCount in
            // 当从空列表添加图片时，自动显示第一张
            if oldCount == 0, newCount > 0, displayedIndex == nil {
                displayedIndex = 0
                selectedIndices = [0]
            }
        }
        .sheet(isPresented: $showingExportDialog) {
            ExportDialog(
                imagesToExport: getImagesToExport(),
                adjustmentsCache: adjustmentsCache,
                onExport: { config in
                    Task {
                        await performExport(config: config)
                    }
                    showingExportDialog = false
                },
                onCancel: {
                    showingExportDialog = false
                }
            )
        }
        .background(
            ZStack {
                // 导出快捷键
                Button("") {
                    showingExportDialog = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .hidden()

                // 撤销快捷键
                Button("") {
                    handleUndo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .hidden()

                // 重做快捷键
                Button("") {
                    handleRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .hidden()

                // 删除快捷键
                Button("") {
                    handleDeleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
            }
        )
    }

    private func getImagesToExport() -> [ImageInfo] {
        if selectedIndices.isEmpty {
            // 没有选择，导出当前显示的图片
            if let index = displayedIndex, index < imageManager.images.count {
                return [imageManager.images[index]]
            }
            return []
        } else {
            // 导出所有选中的图片
            return selectedIndices.compactMap { index in
                index < imageManager.images.count ? imageManager.images[index] : nil
            }
        }
    }

    private func performExport(config: ExportConfig) async {
        let imagesToExport = getImagesToExport()

        for imageInfo in imagesToExport {
            let adjustments = adjustmentsCache[imageInfo.id] ?? .default

            do {
                let outputURL = try await ImageExporter.export(
                    imageInfo: imageInfo,
                    adjustments: adjustments,
                    config: config,
                    progress: { _ in }
                )
                print("导出成功: \(outputURL.path)")
            } catch {
                print("导出失败: \(error.localizedDescription)")
            }
        }
    }

    private func getCurrentImageInfo() -> ImageInfo? {
        guard let index = displayedIndex,
              index < imageManager.images.count else { return nil }
        return imageManager.images[index]
    }

    private func getCurrentHistory() -> AdjustmentHistory {
        guard let imageInfo = getCurrentImageInfo() else {
            return AdjustmentHistory()
        }

        if let history = historyCache[imageInfo.id] {
            return history
        }

        let newHistory = AdjustmentHistory()
        historyCache[imageInfo.id] = newHistory
        return newHistory
    }

    private func getCurrentAdjustmentsBinding() -> Binding<ImageAdjustments> {
        Binding(
            get: {
                if let imageInfo = getCurrentImageInfo() {
                    return adjustmentsCache[imageInfo.id] ?? .default
                }
                return .default
            },
            set: { newValue in
                if let imageInfo = getCurrentImageInfo() {
                    adjustmentsCache[imageInfo.id] = newValue
                }
            }
        )
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let wasEmpty = imageManager.images.isEmpty
            imageManager.addImages(from: urls)

            if wasEmpty, !imageManager.images.isEmpty {
                displayedIndex = 0
                selectedIndices = [0]
            }
        }
    }

    private func handleDelete(indices: Set<Int>) {
        let sortedIndices = indices.sorted(by: >)

        for index in sortedIndices {
            imageManager.removeImage(at: index)
        }

        selectedIndices.removeAll()

        if let currentDisplay = displayedIndex, indices.contains(currentDisplay) {
            displayedIndex = nil
        }
    }

    private func handleUndo() {
        guard let imageInfo = getCurrentImageInfo() else { return }
        let history = getCurrentHistory()

        if let adjustments = history.undo() {
            adjustmentsCache[imageInfo.id] = adjustments
        }
    }

    private func handleRedo() {
        guard let imageInfo = getCurrentImageInfo() else { return }
        let history = getCurrentHistory()

        if let adjustments = history.redo() {
            adjustmentsCache[imageInfo.id] = adjustments
        }
    }

    private func handleDeleteSelected() {
        if !selectedIndices.isEmpty {
            handleDelete(indices: selectedIndices)
        } else if let index = displayedIndex {
            handleDelete(indices: [index])
        }
    }
}

struct ToolbarView: View {
    @ObservedObject var imageManager: ImageManager
    @Binding var showingExportDialog: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                imageManager.openFileDialog()
            }) {
                Label("添加文件", systemImage: "doc.badge.plus")
            }

            Button(action: {
                imageManager.openDirectoryDialog()
            }) {
                Label("打开文件夹", systemImage: "folder.badge.plus")
            }

            Spacer()

            if !imageManager.images.isEmpty {
                Button(action: {
                    showingExportDialog = true
                }) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
            }

            if imageManager.isScanning {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
