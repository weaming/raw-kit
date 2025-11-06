import AppKit
import CoreImage
import SwiftUI

struct ClickableImageView: View, Equatable {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var currentPixelInfo: PixelInfo?
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    let onColorPick: ((CGPoint, CGSize) -> Void)?

    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @FocusState private var isFocused: Bool

    // Equatable 实现:只比较影响渲染的属性
    static func == (lhs: ClickableImageView, rhs: ClickableImageView) -> Bool {
        // 只比较 image 和 scale,忽略 currentPixelInfo 的变化
        // 但要比较 onColorPick 是否变化（从 nil 到非 nil，或反之）
        let sameImage = lhs.image === rhs.image &&
            abs(lhs.scale - rhs.scale) < 0.0001 &&
            lhs.originalCIImage === rhs.originalCIImage &&
            lhs.adjustedCIImage === rhs.adjustedCIImage

        let sameCallback = (lhs.onColorPick == nil) == (rhs.onColorPick == nil)

        return sameImage && sameCallback
    }

    var body: some View {
        GeometryReader { geometry in
            ClickableImageRepresentable(
                image: image,
                scale: $scale,
                offset: $offset,
                lastOffset: $lastOffset,
                onScrollWheel: { deltaY, location in
                    handleScrollWheel(deltaY: deltaY, location: location, geometry: geometry)
                },
                onColorPick: onColorPick,
                onMouseMove: handleMouseMove
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
        .focusedSceneValue(\.resetZoomAction, resetZoom)
    }

    private func handleMouseMove(point: CGPoint, imageSize: CGSize) {
        // 检查是否在图片范围外
        guard point.x >= 0, point.y >= 0 else {
            currentPixelInfo = nil
            return
        }

        guard let ciImage = adjustedCIImage ?? originalCIImage else {
            currentPixelInfo = nil
            return
        }

        // 从 CIImage 采样颜色
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
        guard !clampedRect.isEmpty else {
            currentPixelInfo = nil
            return
        }

        guard let averaged = ciImage.cropped(to: clampedRect)
            .applyingFilter(
                "CIAreaAverage",
                parameters: [kCIInputExtentKey: CIVector(cgRect: clampedRect)]
            ) as CIImage?
        else {
            currentPixelInfo = nil
            return
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

        let newPixelInfo = PixelInfo(
            gammaRGB: (r: gammaR, g: gammaG, b: gammaB),
            linearRGB: (r: linearR, g: linearG, b: linearB),
            hsl: hsl
        )

        if currentPixelInfo != newPixelInfo {
            currentPixelInfo = newPixelInfo
        }
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

    // Photoshop 风格的缩放算法
    // 变换模型: Transform = Scale(scale) × Translate(offset)
    // 即: 先对图片应用 offset 平移，再整体缩放
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

        // 视图中心点
        let viewCenterX = geometry.size.width / 2
        let viewCenterY = geometry.size.height / 2

        // 鼠标相对于视图中心的位置
        let mouseX = location.x - viewCenterX
        let mouseY = location.y - viewCenterY

        // 找到鼠标当前指向的画布坐标（变换前的坐标）
        // 逆变换: P_canvas = P_view / oldScale - offset
        let canvasX = mouseX / oldScale - offset.width
        let canvasY = mouseY / oldScale - offset.height

        // 缩放后，让这个画布点仍然对应鼠标位置
        // 正变换: P_view = (P_canvas + offset) × scale
        // 求 offset: P_view = (P_canvas + offset) × newScale
        //           mouseX = (canvasX + newOffsetX) × newScale
        //           newOffsetX = mouseX / newScale - canvasX
        let newOffsetX = mouseX / newScale - canvasX
        let newOffsetY = mouseY / newScale - canvasY

        scale = newScale
        offset = CGSize(width: newOffsetX, height: newOffsetY)
        lastOffset = offset
    }

    private func calculateImageRect(in geometry: GeometryProxy) -> CGRect {
        // 使用与 ImageGeometry 相同的计算逻辑
        let fitRatio = min(
            geometry.size.width / image.size.width,
            geometry.size.height / image.size.height
        )
        let fitWidth = image.size.width * fitRatio
        let fitHeight = image.size.height * fitRatio

        let scaledWidth = fitWidth * scale
        let scaledHeight = fitHeight * scale

        let x = (geometry.size.width - scaledWidth) / 2 + offset.width
        let y = (geometry.size.height - scaledHeight) / 2 + offset.height

        return CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            scale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }
}

struct ClickableImageRepresentable: NSViewRepresentable {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize
    let onScrollWheel: (CGFloat, CGPoint) -> Void
    let onColorPick: ((CGPoint, CGSize) -> Void)?
    let onMouseMove: ((CGPoint, CGSize) -> Void)?

    func makeNSView(context _: Context) -> ClickableNSImageView {
        let view = ClickableNSImageView()
        view.imageView.image = image
        view.onScrollWheel = onScrollWheel
        view.onColorPick = onColorPick
        view.onMouseMove = onMouseMove
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

    func updateNSView(_ nsView: ClickableNSImageView, context _: Context) {
        // 只在图片实例变化时更新
        if nsView.imageView.image !== image {
            nsView.imageView.image = image
        }

        // 回调函数总是更新
        nsView.onScrollWheel = onScrollWheel
        nsView.onColorPick = onColorPick
        nsView.onMouseMove = onMouseMove

        // 检查 scale 或 offset 是否变化
        let scaleChanged = abs(nsView.currentScale - scale) > 0.0001
        let offsetChanged = abs(nsView.currentOffset.width - offset.width) > 0.0001 ||
            abs(nsView.currentOffset.height - offset.height) > 0.0001

        // ⚠️ 关键:总是更新这两个值,确保几何计算使用最新值
        nsView.currentScale = scale
        nsView.currentOffset = offset

        // scale/offset 变化时应用 transform
        if scaleChanged || offsetChanged {
            // 应用 GPU transform
            // 变换模型: Scale(scale) × Translate(offset)
            // 先平移 offset，再缩放 scale
            let transform = CGAffineTransform.identity
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: offset.width, y: offset.height)

            nsView.imageView.layer?.setAffineTransform(transform)
        }
    }
}

class ClickableNSImageView: NSView {
    let imageView = NSImageView()
    var onScrollWheel: ((CGFloat, CGPoint) -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    var onColorPick: ((CGPoint, CGSize) -> Void)?
    var onMouseMove: ((CGPoint, CGSize) -> Void)?

    var currentScale: CGFloat = 1.0
    var currentOffset: CGSize = .zero

    private var isDragging = false
    private var dragStartPoint: NSPoint = .zero
    private var isSpaceKeyPressed = false
    private var trackingArea: NSTrackingArea?

    // 将视图坐标转换为图片像素坐标
    // 新方法：直接使用逆 transform
    private func viewPointToImagePixel(_ viewPoint: CGPoint) -> CGPoint? {
        guard let image = imageView.image,
              let layer = imageView.layer else { return nil }

        // 步骤 1: 将父 view 坐标转换到 imageView 坐标系
        let pointInImageView = convert(viewPoint, to: imageView)

        // 步骤 2: 应用逆 transform
        // layer.affineTransform() 返回当前的 transform
        let transform = layer.affineTransform()
        let invertedTransform = transform.inverted()

        // 应用逆变换，得到变换前的坐标
        let untransformedPoint = pointInImageView.applying(invertedTransform)

        // 步骤 3: 现在 untransformedPoint 是在未变换的 imageView 坐标系中
        // 计算图片在 imageView 中的 aspect-fit 位置
        let viewBounds = imageView.bounds
        let imageSize = image.size

        let widthRatio = viewBounds.width / imageSize.width
        let heightRatio = viewBounds.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)

        let displayWidth = imageSize.width * ratio
        let displayHeight = imageSize.height * ratio

        let imageX = (viewBounds.width - displayWidth) / 2
        let imageY = (viewBounds.height - displayHeight) / 2

        let imageRect = CGRect(x: imageX, y: imageY, width: displayWidth, height: displayHeight)

        // 步骤 4: 检查是否在图片范围内
        guard imageRect.contains(untransformedPoint) else {
            return nil
        }

        // 步骤 5: 转换为图片像素坐标
        let normalizedX = (untransformedPoint.x - imageRect.minX) / imageRect.width
        let normalizedY = (untransformedPoint.y - imageRect.minY) / imageRect.height

        let pixelX = normalizedX * imageSize.width
        let pixelY = (1.0 - normalizedY) * imageSize.height

        return CGPoint(x: pixelX, y: pixelY)
    }

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

        // 监听全局键盘事件
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { // 空格键
                self?.isSpaceKeyPressed = true
            }
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.keyCode == 49 { // 空格键
                self?.isSpaceKeyPressed = false
            }
            return event
        }
    }

    private func handleFlagsChanged(_: NSEvent) {
        // 空格键通过 keyDown/keyUp 处理，这里处理其他修饰键（如果需要）
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

        if let pixelPoint = viewPointToImagePixel(locationInView) {
            onMouseMove?(pixelPoint, image.size)
        } else {
            onMouseMove?(CGPoint(x: -1, y: -1), image.size)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let flippedLocation = CGPoint(x: locationInView.x, y: bounds.height - locationInView.y)
        onScrollWheel?(event.deltaY, flippedLocation)
    }

    override func mouseDown(with event: NSEvent) {
        print("🖱️ mouseDown 被调用")

        // 如果按住空格键，强制进入拖拽模式
        if isSpaceKeyPressed {
            print("  空格键被按住，进入拖拽模式")
            isDragging = true
            dragStartPoint = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.push()
            return
        }

        // 如果有取色回调，先尝试取色
        if let onColorPick, let image = imageView.image {
            print("  有 onColorPick 回调")
            let locationInView = convert(event.locationInWindow, from: nil)

            // 将视图坐标转换为图片像素坐标
            if let pixelPoint = viewPointToImagePixel(locationInView) {
                print("  转换成功，像素坐标: \(pixelPoint)")
                onColorPick(pixelPoint, image.size)
            } else {
                print("  ⚠️ 坐标转换失败（点击在图片外）")
            }
            return
        }

        // 否则进入拖拽模式
        print("  没有 onColorPick，进入拖拽模式")
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

            // 恢复光标
            if isSpaceKeyPressed {
                NSCursor.pop()
            }
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isSpaceKeyPressed {
            NSCursor.openHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isSpaceKeyPressed ? .openHand : .arrow)
    }
}
