import SwiftUI

struct ContentView: View {
    @StateObject private var imageManager = ImageManager()
    @State private var selectedIndices: Set<Int> = []
    @State private var displayedIndex: Int?
    @State private var adjustmentsCache: [UUID: ImageAdjustments] = [:]
    @State private var sidebarWidth: CGFloat = 280

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ToolbarView(imageManager: imageManager)

                ImageListView(
                    images: imageManager.images,
                    selectedIndices: $selectedIndices,
                    displayedIndex: $displayedIndex,
                    onDelete: handleDelete
                )
            }
        } detail: {
            if let index = displayedIndex,
               index < imageManager.images.count
            {
                let imageInfo = imageManager.images[index]
                ImageDetailView(
                    imageInfo: imageInfo,
                    savedAdjustments: adjustmentsCache[imageInfo.id],
                    sidebarWidth: $sidebarWidth,
                    onAdjustmentsChanged: { newAdjustments in
                        adjustmentsCache[imageInfo.id] = newAdjustments
                    }
                )
                .id(imageInfo.id)
            } else {
                EmptyStateView()
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers: providers)
                        return true
                    }
            }
        }
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
}

struct ToolbarView: View {
    @ObservedObject var imageManager: ImageManager

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
