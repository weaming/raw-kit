import AppKit
import CoreImage
import Foundation

@MainActor
class ThumbnailManager: ObservableObject {
    @Published var adjustedThumbnails: [UUID: NSImage] = [:]

    private let thumbnailSize: CGFloat = 120
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    func generateAdjustedThumbnail(
        for imageInfo: ImageInfo,
        with adjustments: ImageAdjustments
    ) {
        generationTasks[imageInfo.id]?.cancel()

        let task = Task {
            guard !Task.isCancelled else { return }

            let thumbnail = await createAdjustedThumbnail(
                from: imageInfo.url,
                with: adjustments
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.adjustedThumbnails[imageInfo.id] = thumbnail
            }
        }

        generationTasks[imageInfo.id] = task
    }

    func clearThumbnail(for id: UUID) {
        generationTasks[id]?.cancel()
        generationTasks.removeValue(forKey: id)
        adjustedThumbnails.removeValue(forKey: id)
    }

    func clearAll() {
        for task in generationTasks.values {
            task.cancel()
        }
        generationTasks.removeAll()
        adjustedThumbnails.removeAll()
    }

    private func createAdjustedThumbnail(
        from url: URL,
        with adjustments: ImageAdjustments
    ) async -> NSImage? {
        guard var thumbnailImage = ImageProcessor.loadThumbnail(from: url) else {
            return nil
        }

        if adjustments.hasAdjustments || adjustments.lutURL != nil {
            thumbnailImage = ImageProcessor.applyAdjustments(
                to: thumbnailImage,
                adjustments: adjustments
            )
        }

        guard let cgImage = ImageProcessor.convertToCGImage(thumbnailImage) else {
            return nil
        }

        let size = NSSize(width: thumbnailSize, height: thumbnailSize)
        return NSImage(cgImage: cgImage, size: size)
    }
}
