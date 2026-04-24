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

            try? await Task.sleep(nanoseconds: 200_000_000)
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

        let cgImage = if adjustments.isHDREnabled {
            ImageProcessor.convertToDisplayCGImage(thumbnailImage, adjustments: adjustments)
        } else {
            ImageProcessor.convertToCGImage(thumbnailImage)
        }

        guard let cgImage else {
            return nil
        }

        let extent = thumbnailImage.extent
        let maxDimension = max(extent.width, extent.height)
        guard maxDimension > 0 else {
            return nil
        }

        let scale = thumbnailSize / maxDimension
        let size = NSSize(
            width: max(extent.width * scale, 1),
            height: max(extent.height * scale, 1)
        )

        return NSImage(cgImage: cgImage, size: size)
    }
}
