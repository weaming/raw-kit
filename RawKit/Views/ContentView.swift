import Foundation
import SwiftUI
import UniformTypeIdentifiers

private final class FileURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    func values() -> [URL] {
        lock.lock()
        let result = storage
        lock.unlock()
        return result
    }
}

private struct ExportFailure {
    let fileName: String
    let reason: String
}

private enum ContentExportError: LocalizedError {
    case failedExports([ExportFailure])

    var errorDescription: String? {
        switch self {
        case let .failedExports(failures):
            let visibleFailures = failures.prefix(3)
            let failureSummary = visibleFailures
                .map { "\($0.fileName)：\($0.reason)" }
                .joined(separator: "\n")
            let remainingCount = failures.count - visibleFailures.count

            if remainingCount > 0 {
                return "有 \(failures.count) 张图片导出失败：\n\(failureSummary)\n另有 \(remainingCount) 张失败。"
            }

            return "有 \(failures.count) 张图片导出失败：\n\(failureSummary)"
        }
    }
}

struct ContentView: View {
    @StateObject private var imageManager = ImageManager()
    @StateObject private var thumbnailManager = ThumbnailManager()
    @State private var selectedIndices: Set<Int> = []
    @State private var displayedIndex: Int?
    @State private var editingSessions: [UUID: ImageEditingSession] = [:]
    @State private var rightSidebarWidth: CGFloat = 400
    @State private var adjustmentPanelExpandedSections = AdjustmentSection.defaultExpandedSections
    @AppStorage("LeftSidebarWidth") private var leftSidebarWidth: Double = 250
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
                if let currentSession = getCurrentSession() {
                    LeftSidebarView(
                        width: $leftSidebarWidth,
                        presetsExpanded: $presetsExpanded,
                        lutExpanded: $lutExpanded,
                        editingSessionID: currentSession.id,
                        editingState: currentSession.state,
                        onLoadPreset: { preset in
                            currentSession.apply(preset)
                        },
                        onLoadLUT: { url in
                            currentSession.applyLUT(url)
                        }
                    )
                }

                // 中间图片详情区域
                if let index = displayedIndex,
                   index < imageManager.images.count,
                   let session = session(for: imageManager.images[index].id) {
                    let imageInfo = imageManager.images[index]
                    ImageDetailView(
                        imageInfo: imageInfo,
                        session: session,
                        editingState: session.state,
                        thumbnailManager: thumbnailManager,
                        sidebarWidth: $rightSidebarWidth,
                        adjustmentPanelExpandedSections: $adjustmentPanelExpandedSections,
                        syncTargetCount: syncTargetIndices(for: index).count,
                        onSyncAdjustments: { groups in
                            syncCurrentAdjustments(
                                from: index,
                                to: syncTargetIndices(for: index),
                                groups: groups
                            )
                        },
                        onFilesDrop: { urls in
                            addImagesAndDisplayFirst(from: urls)
                        }
                    )
                    .id(imageInfo.id)
                } else {
                    EmptyStateView()
                        .onTapGesture(count: 2) {
                            imageManager.openImportDialog()
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
                    adjustmentsForImageID: adjustments(for:),
                    thumbnailManager: thumbnailManager,
                    onDelete: handleDelete
                )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .onChange(of: imageManager.images.count) { oldCount, newCount in
            // 当从空列表添加图片时，自动显示第一张
            if oldCount == 0, newCount > 0, displayedIndex == nil {
                displayedIndex = 0
                selectedIndices = [0]
            }
        }
        .onAppear {
            syncEditingSessions(for: imageManager.images)
        }
        .onChange(of: imageManager.images.map(\.id)) { _, _ in
            syncEditingSessions(for: imageManager.images)
        }
        .sheet(isPresented: $showingExportDialog) {
                ExportDialog(
                    imagesToExport: getImagesToExport(),
                    adjustmentsForImageID: adjustments(for:),
                    onExport: { config, progress in
                        try await performExport(
                            config: config,
                            progress: progress
                        )
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

                // 全选照片快捷键
                Button("") {
                    handleSelectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(imageManager.images.isEmpty)
                .hidden()

                Button("") {
                    navigateImage(by: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(imageManager.images.count <= 1)
                .hidden()

                Button("") {
                    navigateImage(by: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(imageManager.images.count <= 1)
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

    private func performExport(
        config: ExportConfig,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let imagesToExport = getImagesToExport()
        guard !imagesToExport.isEmpty else {
            await MainActor.run {
                progress(1.0)
            }
            return
        }

        await MainActor.run {
            progress(0.0)
        }

        var failures: [ExportFailure] = []

        for (index, imageInfo) in imagesToExport.enumerated() {
            let adjustments = adjustments(for: imageInfo.id)

            do {
                let outputURL = try await ImageExporter.export(
                    imageInfo: imageInfo,
                    adjustments: adjustments,
                    config: config,
                    progress: { imageProgress in
                        let overallProgress =
                            (Double(index) + imageProgress) / Double(imagesToExport.count)

                        Task { @MainActor in
                            progress(overallProgress)
                        }
                    }
                )
                print("导出成功: \(outputURL.path)")
            } catch {
                let reason = error.localizedDescription
                print("导出失败: \(reason)")
                failures.append(
                    ExportFailure(
                        fileName: imageInfo.url.lastPathComponent,
                        reason: reason
                    )
                )
            }

            let completedProgress = Double(index + 1) / Double(imagesToExport.count)
            await MainActor.run {
                progress(completedProgress)
            }
        }

        if !failures.isEmpty {
            throw ContentExportError.failedExports(failures)
        }
    }

    private func getCurrentImageInfo() -> ImageInfo? {
        guard let index = displayedIndex,
              index < imageManager.images.count else { return nil }
        return imageManager.images[index]
    }

    private func getCurrentSession() -> ImageEditingSession? {
        guard let imageInfo = getCurrentImageInfo() else { return nil }
        return session(for: imageInfo.id)
    }

    private func session(for imageID: UUID) -> ImageEditingSession? {
        editingSessions[imageID]
    }

    private func adjustments(for imageID: UUID) -> ImageAdjustments {
        session(for: imageID)?.currentAdjustments ?? .default
    }

    private func syncTargetIndices(for sourceIndex: Int) -> [Int] {
        selectedIndices
            .filter { $0 != sourceIndex && $0 >= 0 && $0 < imageManager.images.count }
            .sorted()
    }

    private func syncCurrentAdjustments(
        from sourceIndex: Int,
        to targetIndices: [Int],
        groups: Set<AdjustmentSyncGroup>
    ) {
        guard !groups.isEmpty else { return }
        guard sourceIndex >= 0,
              sourceIndex < imageManager.images.count,
              let sourceSession = session(for: imageManager.images[sourceIndex].id) else {
            return
        }

        sourceSession.flushPendingEdits()
        let sourceAdjustments = sourceSession.currentAdjustments

        for targetIndex in targetIndices {
            let imageInfo = imageManager.images[targetIndex]
            guard let targetSession = session(for: imageInfo.id) else { continue }

            targetSession.flushPendingEdits()
            let updated = targetSession.currentAdjustments.synced(
                with: sourceAdjustments,
                groups: groups
            )

            guard updated != targetSession.currentAdjustments else { continue }
            targetSession.apply(updated)
        }
    }

    private func syncEditingSessions(for images: [ImageInfo]) {
        let validIDs = Set(images.map(\.id))

        for removedID in editingSessions.keys.filter({ !validIDs.contains($0) }) {
            editingSessions.removeValue(forKey: removedID)
            thumbnailManager.clearThumbnail(for: removedID)
        }

        for imageInfo in images where editingSessions[imageInfo.id] == nil {
            let initialAdjustments = initialAdjustments(for: imageInfo)
            editingSessions[imageInfo.id] = ImageEditingSession(
                imageInfo: imageInfo,
                initialAdjustments: initialAdjustments,
                thumbnailManager: thumbnailManager
            )
        }
    }

    private func initialAdjustments(for imageInfo: ImageInfo) -> ImageAdjustments {
        ImageAdjustments.sourceHDRBaseline(headroom: imageInfo.hdrHeadroom)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let urls = FileURLCollector()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }

            group.enter()
            loadDroppedURL(from: provider) { url in
                if let url {
                    urls.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let droppedURLs = urls.values()
            guard !droppedURLs.isEmpty else {
                return
            }

            addImagesAndDisplayFirst(from: droppedURLs)
        }
    }

    private func addImagesAndDisplayFirst(from urls: [URL]) {
        imageManager.addImages(from: urls) { addedImages in
            guard let firstAddedImage = addedImages.first,
                  let firstAddedIndex = imageManager.images.firstIndex(where: { $0.id == firstAddedImage.id }) else {
                return
            }

            displayedIndex = firstAddedIndex
            selectedIndices = [firstAddedIndex]
        }
    }

    private func loadDroppedURL(
        from provider: NSItemProvider,
        completion: @escaping (URL?) -> Void
    ) {
        let fileURLType = UTType.fileURL.identifier

        provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { data, _ in
            if let data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                completion(url)
                return
            }

            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                completion(extractDroppedURL(from: item))
            }
        }
    }

    private func extractDroppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }

        if let string = item as? String {
            if let url = URL(string: string) {
                return url
            }
            return URL(fileURLWithPath: string)
        }

        if let nsString = item as? NSString {
            let string = nsString as String
            if let url = URL(string: string) {
                return url
            }
            return URL(fileURLWithPath: string)
        }

        return nil
    }

    private func handleDelete(indices: Set<Int>) {
        let imageCountBeforeDelete = imageManager.images.count
        let validDeletedIndices = Set(
            indices.filter { index in
                index >= 0 && index < imageCountBeforeDelete
            }
        )
        guard !validDeletedIndices.isEmpty else { return }

        let nextDisplayIndex = displayIndexAfterDelete(
            deletedIndices: validDeletedIndices,
            imageCountBeforeDelete: imageCountBeforeDelete
        )
        let sortedIndices = validDeletedIndices.sorted(by: >)

        for index in sortedIndices {
            imageManager.removeImage(at: index)
        }

        displayedIndex = nextDisplayIndex
        selectedIndices = nextDisplayIndex.map { [$0] } ?? []
    }

    private func displayIndexAfterDelete(
        deletedIndices: Set<Int>,
        imageCountBeforeDelete: Int
    ) -> Int? {
        let imageCountAfterDelete = imageCountBeforeDelete - deletedIndices.count
        guard imageCountAfterDelete > 0 else { return nil }

        guard let currentDisplay = displayedIndex,
              currentDisplay >= 0,
              currentDisplay < imageCountBeforeDelete else {
            let firstDeletedIndex = deletedIndices.min() ?? 0
            return min(firstDeletedIndex, imageCountAfterDelete - 1)
        }

        if deletedIndices.contains(currentDisplay) {
            return min(currentDisplay, imageCountAfterDelete - 1)
        }

        let deletedBeforeCurrent = deletedIndices.filter { $0 < currentDisplay }.count
        return currentDisplay - deletedBeforeCurrent
    }

    private func handleUndo() {
        getCurrentSession()?.undo()
    }

    private func handleRedo() {
        getCurrentSession()?.redo()
    }

    private func handleDeleteSelected() {
        if !selectedIndices.isEmpty {
            handleDelete(indices: selectedIndices)
        } else if let index = displayedIndex {
            handleDelete(indices: [index])
        }
    }

    private func handleSelectAll() {
        guard !imageManager.images.isEmpty else { return }

        selectedIndices = Set(imageManager.images.indices)

        if displayedIndex == nil || displayedIndex! >= imageManager.images.count {
            displayedIndex = 0
        }
    }

    private func navigateImage(by offset: Int) {
        guard !imageManager.images.isEmpty else { return }

        let currentIndex = displayedIndex ?? selectedIndices.sorted().first ?? 0
        let lastIndex = imageManager.images.count - 1
        let targetIndex = min(max(currentIndex + offset, 0), lastIndex)
        guard targetIndex != displayedIndex else { return }

        displayedIndex = targetIndex
        selectedIndices = [targetIndex]
    }
}

struct ToolbarView: View {
    @ObservedObject var imageManager: ImageManager
    @Binding var showingExportDialog: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 为窗口控制按钮留出空间
            Spacer()
                .frame(width: 45)

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
