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
    private enum ThumbnailTaskKind: Hashable {
        case base
        case adjusted
    }

    private struct ThumbnailTaskKey: Hashable {
        let imageID: UUID
        let kind: ThumbnailTaskKind
    }

    private var generationTasks: [ThumbnailTaskKey: Task<Void, Never>] = [:]

    private struct ThumbnailRenderResult {
        let image: NSImage
        let isHDR: Bool
    }

    func generateAdjustedThumbnail(
        for imageInfo: ImageInfo,
        with adjustments: ImageAdjustments
    ) {
        let taskKey = ThumbnailTaskKey(imageID: imageInfo.id, kind: .adjusted)
        generationTasks[taskKey]?.cancel()

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

        generationTasks[taskKey] = task
    }

    func generateBaseThumbnail(for imageInfo: ImageInfo) {
        guard imageInfo.thumbnail == nil || imageInfo.fileType == .raw(.x3f) else {
            return
        }

        let taskKey = ThumbnailTaskKey(imageID: imageInfo.id, kind: .base)
        generationTasks[taskKey]?.cancel()

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

        generationTasks[taskKey] = task
    }

    func prefetchNeighbors(
        images: [ImageInfo],
        currentIndex: Int,
        adjustmentsForImageID: (UUID) -> ImageAdjustments
    ) {
        guard images.indices.contains(currentIndex) else {
            return
        }

        for offset in [-1, 1] {
            let neighborIndex = currentIndex + offset
            guard images.indices.contains(neighborIndex) else {
                continue
            }

            let imageInfo = images[neighborIndex]
            let adjustments = adjustmentsForImageID(imageInfo.id)

            if imageInfo.thumbnail == nil || imageInfo.fileType == .raw(.x3f) {
                generateBaseThumbnail(for: imageInfo)
            }

            if adjustments.hasAdjustments || adjustments.lutURL != nil {
                generateAdjustedThumbnail(for: imageInfo, with: adjustments)
            }
        }
    }

    func clearThumbnail(for id: UUID) {
        for kind in [ThumbnailTaskKind.base, .adjusted] {
            let key = ThumbnailTaskKey(imageID: id, kind: kind)
            generationTasks[key]?.cancel()
            generationTasks.removeValue(forKey: key)
        }
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
