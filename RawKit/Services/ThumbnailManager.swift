import AppKit
import CoreImage
import Foundation

@MainActor
class ThumbnailManager: ObservableObject {
    @Published var baseThumbnails: [UUID: NSImage] = [:]
    @Published var adjustedThumbnails: [UUID: NSImage] = [:]
    @Published var baseThumbnailIsHDR: [UUID: Bool] = [:]
    @Published var adjustedThumbnailIsHDR: [UUID: Bool] = [:]

    private let thumbnailSize: CGFloat = 120
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    private struct ThumbnailRenderResult {
        let image: NSImage
        let isHDR: Bool
    }

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
                guard let thumbnail else {
                    print("ThumbnailManager: adjusted thumbnail render failed, keeping previous thumbnail")
                    return
                }

                self.adjustedThumbnails[imageInfo.id] = thumbnail.image
                self.adjustedThumbnailIsHDR[imageInfo.id] = thumbnail.isHDR
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

            let thumbnail = await createBaseThumbnail(
                from: imageInfo.url,
                sourceHDRHeadroom: imageInfo.hdrHeadroom
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if let thumbnail {
                    self.baseThumbnails[imageInfo.id] = thumbnail.image
                    self.baseThumbnailIsHDR[imageInfo.id] = thumbnail.isHDR
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
        baseThumbnailIsHDR.removeValue(forKey: id)
        adjustedThumbnailIsHDR.removeValue(forKey: id)
    }

    func clearAll() {
        for task in generationTasks.values {
            task.cancel()
        }
        generationTasks.removeAll()
        baseThumbnails.removeAll()
        adjustedThumbnails.removeAll()
        baseThumbnailIsHDR.removeAll()
        adjustedThumbnailIsHDR.removeAll()
    }

    func updateAdjustedThumbnail(
        for imageID: UUID,
        from previewCGImage: CGImage,
        isHDR: Bool
    ) {
        guard let squareCGImage = cropCGImageToCenteredSquare(previewCGImage) else {
            return
        }

        adjustedThumbnails[imageID] = NSImage(
            cgImage: squareCGImage,
            size: NSSize(width: thumbnailSize, height: thumbnailSize)
        )
        adjustedThumbnailIsHDR[imageID] = isHDR
    }

    private func createBaseThumbnail(
        from url: URL,
        sourceHDRHeadroom: Double?
    ) async -> ThumbnailRenderResult? {
        if url.pathExtension.lowercased() == "x3f" {
            return await ImageProcessor.loadX3FPreviewImage(from: url).map {
                ThumbnailRenderResult(image: $0, isHDR: false)
            }
        }

        guard let thumbnailImage = ImageProcessor.loadSquareThumbnail(from: url) else {
            return nil
        }

        let displayAdjustments = ImageAdjustments.sourceHDRBaseline(headroom: sourceHDRHeadroom)
        return makeThumbnailRenderResult(from: thumbnailImage, adjustments: displayAdjustments)
    }

    private func createAdjustedThumbnail(
        from url: URL,
        with adjustments: ImageAdjustments
    ) async -> ThumbnailRenderResult? {
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

        return makeThumbnailRenderResult(from: thumbnailImage, adjustments: adjustments)
    }

    private func makeThumbnailRenderResult(
        from image: CIImage,
        adjustments: ImageAdjustments
    ) -> ThumbnailRenderResult? {
        guard let displayResult = ImageProcessor.convertToDisplayCGImage(
            image,
            adjustments: adjustments
        ) else {
            return nil
        }

        let thumbnail = NSImage(
            cgImage: displayResult.cgImage,
            size: NSSize(width: thumbnailSize, height: thumbnailSize)
        )

        return ThumbnailRenderResult(image: thumbnail, isHDR: displayResult.isHDR)
    }

    private func cropCGImageToCenteredSquare(_ image: CGImage) -> CGImage? {
        let squareLength = min(image.width, image.height)
        guard squareLength > 0 else {
            return nil
        }

        let squareLengthValue = CGFloat(squareLength)
        let cropRect = CGRect(
            x: CGFloat(image.width - squareLength) / 2.0,
            y: CGFloat(image.height - squareLength) / 2.0,
            width: squareLengthValue,
            height: squareLengthValue
        )

        return image.cropping(to: cropRect)
    }
}
