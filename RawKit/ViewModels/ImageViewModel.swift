import CoreImage
import Foundation
import SwiftUI

// ViewModel: 统一管理图片查看器的所有状态和业务逻辑
@MainActor
class ImageViewModel: ObservableObject {
    // MARK: - 图片数据

    @Published var displayImage: NSImage?
    var originalCIImage: CIImage?
    var adjustedCIImage: CIImage?

    // MARK: - 视图状态

    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var isLoading = true

    // MARK: - 取色信息 (频繁更新,单独发布)

    @Published var currentPixelInfo: PixelInfo?

    // MARK: - 内部状态

    private var lastOffset: CGSize = .zero

    // MARK: - 事件处理

    func handleMouseMove(pixelPoint: CGPoint?, imageSize: CGSize) {
        guard let point = pixelPoint else {
            currentPixelInfo = nil
            return
        }

        guard let ciImage = adjustedCIImage ?? originalCIImage else {
            currentPixelInfo = nil
            return
        }

        // 采样颜色
        let newPixelInfo = sampleColor(at: point, from: ciImage, imageSize: imageSize)

        // 只在值变化时更新
        if currentPixelInfo != newPixelInfo {
            currentPixelInfo = newPixelInfo
        }
    }

    func handleScrollWheel(deltaY: CGFloat, location: CGPoint, viewSize: CGSize) {
        let zoomFactor: CGFloat = 1.0 + (deltaY * 0.01)
        let oldScale = scale
        let newScale = max(0.1, min(oldScale * zoomFactor, 10.0))

        guard oldScale != newScale else { return }

        let viewCenter = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let scaleChange = newScale / oldScale
        let offsetBeforeZoom = CGPoint(x: offset.width, y: offset.height)

        let pointRelativeToCenter = CGPoint(
            x: location.x - viewCenter.x,
            y: location.y - viewCenter.y
        )

        let newOffsetX = offsetBeforeZoom.x * scaleChange + pointRelativeToCenter
            .x * (1 - scaleChange)
        let newOffsetY = offsetBeforeZoom.y * scaleChange + pointRelativeToCenter
            .y * (1 - scaleChange)

        scale = newScale
        offset = CGSize(width: newOffsetX, height: newOffsetY)
        lastOffset = offset
    }

    func handleDragChanged(translation: CGSize) {
        offset = CGSize(
            width: lastOffset.width + translation.width,
            height: lastOffset.height + translation.height
        )
    }

    func handleDragEnded() {
        lastOffset = offset
    }

    func resetZoom() {
        scale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    // MARK: - 私有方法

    private func sampleColor(at point: CGPoint, from ciImage: CIImage,
                             imageSize: CGSize) -> PixelInfo?
    {
        let extent = ciImage.extent
        let normalizedX = point.x / imageSize.width
        let normalizedY = point.y / imageSize.height
        let x = extent.origin.x + normalizedX * extent.width
        let y = extent.origin.y + (1.0 - normalizedY) * extent.height

        let sampleSize: CGFloat = 3
        let sampleRect = CGRect(
            x: x - sampleSize / 2,
            y: y - sampleSize / 2,
            width: sampleSize,
            height: sampleSize
        )

        let clampedRect = sampleRect.intersection(extent)
        guard !clampedRect.isEmpty else { return nil }

        guard let averaged = ciImage.cropped(to: clampedRect)
            .applyingFilter(
                "CIAreaAverage",
                parameters: [kCIInputExtentKey: CIVector(cgRect: clampedRect)]
            ) as CIImage?
        else {
            return nil
        }

        var bitmap = [UInt16](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            averaged,
            toBitmap: &bitmap,
            rowBytes: 4 * MemoryLayout<UInt16>.size,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA16,
            colorSpace: nil
        )

        let linearR = Double(bitmap[0]) / 65535.0
        let linearG = Double(bitmap[1]) / 65535.0
        let linearB = Double(bitmap[2]) / 65535.0

        let gammaR = linearToGamma(linearR)
        let gammaG = linearToGamma(linearG)
        let gammaB = linearToGamma(linearB)

        let hsl = rgbToHSL(r: gammaR, g: gammaG, b: gammaB)

        return PixelInfo(
            gammaRGB: (r: gammaR, g: gammaG, b: gammaB),
            linearRGB: (r: linearR, g: linearG, b: linearB),
            hsl: hsl
        )
    }

    private func linearToGamma(_ linear: Double) -> Double {
        if linear <= 0.0031308 {
            linear * 12.92
        } else {
            1.055 * pow(linear, 1.0 / 2.2) - 0.055
        }
    }

    private func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        var h: Double = 0
        var s: Double = 0
        let l = (maxC + minC) / 2.0

        if delta > 0.0001 {
            s = l > 0.5 ? delta / (2.0 - maxC - minC) : delta / (maxC + minC)

            if maxC == r {
                h = ((g - b) / delta) + (g < b ? 6.0 : 0.0)
            } else if maxC == g {
                h = ((b - r) / delta) + 2.0
            } else {
                h = ((r - g) / delta) + 4.0
            }
            h /= 6.0
        }

        return (h: h * 360.0, s: s * 100.0, l: l * 100.0)
    }
}
