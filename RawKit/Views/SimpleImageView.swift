import AppKit
import SwiftUI

// 代理协议:视图通过代理通知事件,不持有业务逻辑
protocol ImageViewDelegate: AnyObject {
    func imageView(_ view: SimpleImageView, didMoveMouseTo point: CGPoint?, imageSize: CGSize)
    func imageView(
        _ view: SimpleImageView,
        didScrollWithDelta delta: CGFloat,
        at location: CGPoint,
        viewSize: CGSize
    )
    func imageView(_ view: SimpleImageView, didDragWithTranslation translation: CGSize)
    func imageView(_ view: SimpleImageView, didEndDragWithTranslation translation: CGSize)
}

// 简化的图片视图:纯渲染,不持有业务状态
struct SimpleImageView: NSViewRepresentable {
    let image: NSImage
    let scale: CGFloat
    let offset: CGSize
    weak var delegate: ImageViewDelegate?

    func makeNSView(context: Context) -> ImageNSView {
        let view = ImageNSView()
        view.imageView.image = image
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ImageNSView, context _: Context) {
        // 只在图片变化时更新
        if nsView.imageView.image !== image {
            nsView.imageView.image = image
        }

        // 检查变化
        let scaleChanged = abs(nsView.currentScale - scale) > 0.0001
        let offsetChanged = abs(nsView.currentOffset.width - offset.width) > 0.0001 ||
            abs(nsView.currentOffset.height - offset.height) > 0.0001

        // 更新当前值(用于坐标转换)
        nsView.currentScale = scale
        nsView.currentOffset = offset

        // 只在变化时应用 transform
        if scaleChanged || offsetChanged {
            let transform = CGAffineTransform.identity
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: offset.width / scale, y: offset.height / scale)

            nsView.imageView.layer?.setAffineTransform(transform)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(delegate: delegate)
    }

    class Coordinator: ImageNSViewDelegate {
        weak var delegate: ImageViewDelegate?
        var parentView: SimpleImageView?

        init(delegate: ImageViewDelegate?) {
            self.delegate = delegate
        }

        func imageNSView(_: ImageNSView, didMoveMouseTo point: CGPoint?, imageSize: CGSize) {
            guard let parentView else { return }
            delegate?.imageView(parentView, didMoveMouseTo: point, imageSize: imageSize)
        }

        func imageNSView(
            _: ImageNSView,
            didScrollWithDelta delta: CGFloat,
            at location: CGPoint,
            viewSize: CGSize
        ) {
            guard let parentView else { return }
            delegate?.imageView(
                parentView,
                didScrollWithDelta: delta,
                at: location,
                viewSize: viewSize
            )
        }

        func imageNSView(_: ImageNSView, didDragWithTranslation translation: CGSize) {
            guard let parentView else { return }
            delegate?.imageView(parentView, didDragWithTranslation: translation)
        }

        func imageNSView(_: ImageNSView, didEndDragWithTranslation translation: CGSize) {
            guard let parentView else { return }
            delegate?.imageView(parentView, didEndDragWithTranslation: translation)
        }
    }
}

// NSView 代理协议
protocol ImageNSViewDelegate: AnyObject {
    func imageNSView(_ view: ImageNSView, didMoveMouseTo point: CGPoint?, imageSize: CGSize)
    func imageNSView(
        _ view: ImageNSView,
        didScrollWithDelta delta: CGFloat,
        at location: CGPoint,
        viewSize: CGSize
    )
    func imageNSView(_ view: ImageNSView, didDragWithTranslation translation: CGSize)
    func imageNSView(_ view: ImageNSView, didEndDragWithTranslation translation: CGSize)
}

// AppKit 视图:只负责事件捕获和基础渲染
class ImageNSView: NSView {
    let imageView = NSImageView()
    weak var delegate: ImageNSViewDelegate?

    var currentScale: CGFloat = 1.0
    var currentOffset: CGSize = .zero

    private var isDragging = false
    private var dragStartPoint: NSPoint = .zero
    private var dragStartOffset: CGSize = .zero
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addSubview(imageView)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let image = imageView.image else { return }

        let locationInView = convert(event.locationInWindow, from: nil)
        let pixelPoint = viewPointToImagePixel(locationInView, imageSize: image.size)

        delegate?.imageNSView(self, didMoveMouseTo: pixelPoint, imageSize: image.size)
    }

    override func scrollWheel(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let flippedLocation = CGPoint(x: locationInView.x, y: bounds.height - locationInView.y)
        delegate?.imageNSView(
            self,
            didScrollWithDelta: event.deltaY,
            at: flippedLocation,
            viewSize: bounds.size
        )
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartPoint = convert(event.locationInWindow, from: nil)
        dragStartOffset = currentOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: currentPoint.x - dragStartPoint.x,
            height: currentPoint.y - dragStartPoint.y
        )

        delegate?.imageNSView(self, didDragWithTranslation: translation)
    }

    override func mouseUp(with _: NSEvent) {
        if isDragging {
            isDragging = false
            let translation = CGSize(
                width: currentOffset.width - dragStartOffset.width,
                height: currentOffset.height - dragStartOffset.height
            )
            delegate?.imageNSView(self, didEndDragWithTranslation: translation)
        }
    }

    // 坐标转换:视图坐标 -> 图片像素坐标
    private func viewPointToImagePixel(_ viewPoint: CGPoint, imageSize: CGSize) -> CGPoint? {
        let viewSize = bounds.size

        // 计算基础 fit ratio
        let widthRatio = viewSize.width / imageSize.width
        let heightRatio = viewSize.height / imageSize.height
        let fitRatio = min(widthRatio, heightRatio)
        let baseWidth = imageSize.width * fitRatio
        let baseHeight = imageSize.height * fitRatio

        // 视图中心
        let centerX = viewSize.width / 2
        let centerY = viewSize.height / 2

        // 相对于中心的位置
        let relativeX = viewPoint.x - centerX
        let relativeY = viewPoint.y - centerY

        // 逆变换
        let transformedX = relativeX - currentOffset.width
        let transformedY = relativeY - currentOffset.height
        let unscaledX = transformedX / currentScale
        let unscaledY = transformedY / currentScale

        // 归一化坐标
        let normalizedX = unscaledX / baseWidth
        let normalizedY = unscaledY / baseHeight

        // 边界检查
        guard abs(normalizedX) <= 0.5, abs(normalizedY) <= 0.5 else {
            return nil
        }

        // 像素坐标
        let pixelX = (normalizedX + 0.5) * imageSize.width
        let pixelY = (0.5 - normalizedY) * imageSize.height

        return CGPoint(x: pixelX, y: pixelY)
    }
}
