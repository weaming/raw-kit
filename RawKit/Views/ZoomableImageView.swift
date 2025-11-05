import AppKit
import SwiftUI

struct ZoomableImageView: View {
    let image: NSImage
    @Binding var scale: CGFloat
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZoomableImageRepresentable(
                image: image,
                scale: $scale,
                offset: $offset,
                lastOffset: $lastOffset,
                onScrollWheel: { deltaY, location in
                    handleScrollWheel(deltaY: deltaY, location: location, geometry: geometry)
                }
            )
        }
        .focusable(false)
        .focused($isFocused)
        .onAppear {
            isFocused = true
        }
        .onKeyPress(keys: ["+", "=", "-", "_"]) { keyPress in
            handleKeyPress(keyPress)
            return .handled
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) {
        let zoomFactor: CGFloat = 0.1
        let newScale: CGFloat

        if keyPress.characters == "+" || keyPress.characters == "=" {
            newScale = min(scale + zoomFactor, 10.0)
        } else if keyPress.characters == "-" || keyPress.characters == "_" {
            newScale = max(scale - zoomFactor, 0.1)
        } else {
            return
        }

        withAnimation(.easeInOut(duration: 0.1)) {
            scale = newScale
        }
    }

    private func handleScrollWheel(
        deltaY: CGFloat,
        location: CGPoint,
        geometry: GeometryProxy
    ) {
        let zoomFactor: CGFloat = 1.0 + (deltaY * 0.01)
        let oldScale = scale
        let newScale = max(0.1, min(oldScale * zoomFactor, 10.0))

        if oldScale == newScale {
            return
        }

        let viewCenter = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

        let imageRect = calculateImageRect(in: geometry)
        let isMouseOverImage = imageRect.contains(location)

        let zoomPoint = isMouseOverImage ? location : viewCenter

        let scaleChange = newScale / oldScale

        let offsetBeforeZoom = CGPoint(x: offset.width, y: offset.height)

        let pointRelativeToCenter = CGPoint(
            x: zoomPoint.x - viewCenter.x,
            y: zoomPoint.y - viewCenter.y
        )

        let newOffsetX = offsetBeforeZoom.x * scaleChange + pointRelativeToCenter
            .x * (1 - scaleChange)
        let newOffsetY = offsetBeforeZoom.y * scaleChange + pointRelativeToCenter
            .y * (1 - scaleChange)

        scale = newScale
        offset = CGSize(width: newOffsetX, height: newOffsetY)
        lastOffset = offset
    }

    private func calculateImageRect(in geometry: GeometryProxy) -> CGRect {
        let imageSize = image.size
        let viewSize = geometry.size

        let widthRatio = viewSize.width / imageSize.width
        let heightRatio = viewSize.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * ratio * scale
        let scaledHeight = imageSize.height * ratio * scale

        let x = (viewSize.width - scaledWidth) / 2 + offset.width
        let y = (viewSize.height - scaledHeight) / 2 + offset.height

        return CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
    }
}

struct ZoomableImageRepresentable: NSViewRepresentable {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize
    let onScrollWheel: (CGFloat, CGPoint) -> Void

    func makeNSView(context _: Context) -> ZoomableNSImageView {
        let view = ZoomableNSImageView()
        view.imageView.image = image
        view.onScrollWheel = onScrollWheel
        view.onDragChanged = { translation in
            offset = CGSize(
                width: lastOffset.width + translation.width,
                height: lastOffset.height + translation.height
            )
        }
        view.onDragEnded = {
            lastOffset = offset
        }
        return view
    }

    func updateNSView(_ nsView: ZoomableNSImageView, context _: Context) {
        nsView.imageView.image = image
        nsView.onScrollWheel = onScrollWheel

        let transform = CGAffineTransform.identity
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: offset.width / scale, y: offset.height / scale)

        nsView.imageView.layer?.setAffineTransform(transform)
    }
}

class ZoomableNSImageView: NSView {
    let imageView = NSImageView()
    var onScrollWheel: ((CGFloat, CGPoint) -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var isDragging = false
    private var dragStartPoint: NSPoint = .zero

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
    }

    override func scrollWheel(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let flippedLocation = CGPoint(x: locationInView.x, y: bounds.height - locationInView.y)
        onScrollWheel?(event.deltaY, flippedLocation)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: currentPoint.x - dragStartPoint.x,
            height: currentPoint.y - dragStartPoint.y
        )

        onDragChanged?(translation)
    }

    override func mouseUp(with _: NSEvent) {
        if isDragging {
            isDragging = false
            onDragEnded?()
            dragStartPoint = .zero
        }
    }
}
