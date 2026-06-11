import AppKit
import CoreImage
import Foundation

@MainActor
class ThumbnailManager: ObservableObject {
    @Published var baseThumbnails: [UUID: NSImage] = [:]
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

    func generateBaseThumbnail(for imageInfo: ImageInfo) {
        guard imageInfo.thumbnail == nil || imageInfo.fileType == .raw(.x3f) else {
            return
        }

        generationTasks[imageInfo.id]?.cancel()

        let task = Task {
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            let thumbnail = await createBaseThumbnail(from: imageInfo.url)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if let thumbnail {
                    self.baseThumbnails[imageInfo.id] = thumbnail
                }
            }
        }

        generationTasks[imageInfo.id] = task
    }

    func clearThumbnail(for id: UUID) {
        generationTasks[id]?.cancel()
        generationTasks.removeValue(forKey: id)
        baseThumbnails.removeValue(forKey: id)
        adjustedThumbnails.removeValue(forKey: id)
    }

    func clearAll() {
        for task in generationTasks.values {
            task.cancel()
        }
        generationTasks.removeAll()
        baseThumbnails.removeAll()
        adjustedThumbnails.removeAll()
    }

    private func createBaseThumbnail(from url: URL) async -> NSImage? {
        if url.pathExtension.lowercased() == "x3f" {
            return await ImageProcessor.loadX3FPreviewImage(from: url)
        }

        guard let thumbnailImage = ImageProcessor.loadSquareThumbnail(from: url) else {
            return nil
        }

        return ImageProcessor.convertToNSImage(thumbnailImage)
    }

    private func createAdjustedThumbnail(
        from url: URL,
        with adjustments: ImageAdjustments
    ) async -> NSImage? {
        let fileExtension = url.pathExtension.lowercased()

        let thumbnailSource: CIImage?
        if fileExtension == "x3f" {
            thumbnailSource = await ImageProcessor.loadCIImage(from: url)
        } else {
            thumbnailSource = ImageProcessor.loadFullImageThumbnail(from: url, maxPixelSize: 512)
        }

        guard var thumbnailImage = thumbnailSource else {
            return nil
        }

        if adjustments.hasAdjustments || adjustments.lutURL != nil {
            thumbnailImage = ImageProcessor.applyAdjustments(
                to: thumbnailImage,
                adjustments: adjustments
            )
        }

        thumbnailImage = ImageProcessor.cropToCenteredSquare(thumbnailImage)

        let cgImage = ImageProcessor.convertToDisplayCGImage(
            thumbnailImage,
            adjustments: adjustments
        )?.cgImage

        guard let cgImage else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: thumbnailSize, height: thumbnailSize)
        )
    }
}
