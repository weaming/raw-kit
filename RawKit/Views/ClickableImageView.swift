import AppKit
import CoreImage
import SwiftUI

enum PixelSampler {
    private static var context: CIContext {
        CIContextManager.shared.getHistogramContext()
    }

    static func samplePixelInfo(
        from ciImage: CIImage,
        point: CGPoint,
        imageSize: CGSize,
        sampleSize: CGFloat
    ) -> PixelInfo? {
        guard point.x >= 0, point.y >= 0, imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let extent = ciImage.extent
        let normalizedX = point.x / imageSize.width
        let normalizedY = point.y / imageSize.height
        let x = extent.origin.x + normalizedX * extent.width
        let y = extent.origin.y + (1.0 - normalizedY) * extent.height

        let sampleRect = CGRect(
            x: x - sampleSize / 2,
            y: y - sampleSize / 2,
            width: sampleSize,
            height: sampleSize
        )

        let clampedRect = sampleRect.intersection(extent)
        guard !clampedRect.isEmpty else {
            return nil
        }

        guard let averaged = ciImage.cropped(to: clampedRect)
            .applyingFilter(
                "CIAreaAverage",
                parameters: [kCIInputExtentKey: CIVector(cgRect: clampedRect)]
            ) as CIImage?
        else {
            return nil
        }

        var bitmap = [UInt16](repeating: 0, count: 4)
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

        return PixelInfo(
            gammaRGB: (r: gammaR, g: gammaG, b: gammaB),
            linearRGB: (r: linearR, g: linearG, b: linearB),
            hsl: rgbToHSL(r: gammaR, g: gammaG, b: gammaB)
        )
    }

    static func sampleLoupeImage(
        from ciImage: CIImage,
        point: CGPoint,
        imageSize: CGSize,
        sampleSpan: CGFloat,
        outputSize: CGFloat
    ) -> NSImage? {
        guard point.x >= 0, point.y >= 0, imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let extent = ciImage.extent
        let normalizedX = point.x / imageSize.width
        let normalizedY = point.y / imageSize.height
        let x = extent.origin.x + normalizedX * extent.width
        let y = extent.origin.y + (1.0 - normalizedY) * extent.height

        let sampleRect = CGRect(
            x: x - sampleSpan / 2,
            y: y - sampleSpan / 2,
            width: sampleSpan,
            height: sampleSpan
        ).integral

        let sampleImage = ciImage
            .clampedToExtent()
            .cropped(to: sampleRect)

        guard let cgImage = context.createCGImage(sampleImage, from: sampleImage.extent) else {
            return nil
        }

        let size = NSSize(width: outputSize, height: outputSize)
        let loupeImage = NSImage(size: size)
        loupeImage.lockFocus()
        defer { loupeImage.unlockFocus() }

        if let graphicsContext = NSGraphicsContext.current {
            graphicsContext.imageInterpolation = .none
        }

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let drawRect = NSRect(origin: .zero, size: size)
        NSImage(cgImage: cgImage, size: drawRect.size).draw(in: drawRect)

        return loupeImage
    }

    private static func linearToGamma(_ linear: Double) -> Double {
        if linear <= 0.0031308 {
            linear * 12.92
        } else {
            1.055 * pow(linear, 1.0 / 2.2) - 0.055
        }
    }

    private static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
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

struct ImageHoverSample {
    let viewLocation: CGPoint
    let pixelPoint: CGPoint
    let imageSize: CGSize
}

struct ClickableImageView: View {
    private struct LoupeOverlayState {
        let viewLocation: CGPoint
        let image: NSImage
    }

    let image: NSImage
    @Binding var scale: CGFloat
    let maxScale: CGFloat
    @Binding var currentPixelInfo: PixelInfo?
    let originalCIImage: CIImage?
    let adjustedCIImage: CIImage?
    let pickMode: CurveAdjustmentView.PickMode
    let onColorPick: ((CGPoint, CGSize) -> Void)?
    let onFilesDrop: (([URL]) -> Void)?

    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var lastPixelSampleTime: TimeInterval = 0
    @State private var loupeState: LoupeOverlayState?
    @FocusState private var isFocused: Bool

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
                pickMode: pickMode,
                onColorPick: onColorPick,
                onFilesDrop: onFilesDrop,
                onMouseMove: { sample in
                    handleMouseMove(sample: sample, geometrySize: geometry.size)
                }
            )
            .overlay(alignment: .topLeading) {
                if pickMode == .whiteBalance,
                   let loupeState
                {
                    WhiteBalanceLoupeOverlay(
                        image: loupeState.image,
                        pixelInfo: currentPixelInfo
                    )
                    .position(loupePosition(for: loupeState.viewLocation, in: geometry.size))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .focusable(false)
        .focused($isFocused)
        .onAppear {
            isFocused = true
        }
        .onChange(of: pickMode) { _, newValue in
            if newValue != .whiteBalance {
                loupeState = nil
            }
        }
        .onKeyPress(keys: ["+", "=", "-", "_"]) { keyPress in
            handleKeyPress(keyPress)
            return .handled
        }
        .focusedSceneValue(\.resetZoomAction, resetZoom)
    }

    private func handleMouseMove(sample: ImageHoverSample?, geometrySize: CGSize) {
        guard let sample else {
            currentPixelInfo = nil
            loupeState = nil
            return
        }

        guard let ciImage = adjustedCIImage ?? originalCIImage else {
            currentPixelInfo = nil
            loupeState = nil
            return
        }

        if pickMode == .whiteBalance {
            loupeState = buildLoupeState(from: sample, using: ciImage, geometrySize: geometrySize)
        } else {
            loupeState = nil
        }

        let now = CACurrentMediaTime()
        guard now - lastPixelSampleTime >= 1.0 / 30.0 else {
            return
        }
        lastPixelSampleTime = now

        guard let newPixelInfo = PixelSampler.samplePixelInfo(
            from: ciImage,
            point: sample.pixelPoint,
            imageSize: sample.imageSize,
            sampleSize: 3
        ) else {
            currentPixelInfo = nil
            return
        }

        if currentPixelInfo != newPixelInfo {
            currentPixelInfo = newPixelInfo
        }
    }

    private func buildLoupeState(
        from sample: ImageHoverSample,
        using ciImage: CIImage,
        geometrySize: CGSize
    ) -> LoupeOverlayState? {
        guard let loupeImage = PixelSampler.sampleLoupeImage(
            from: ciImage,
            point: sample.pixelPoint,
            imageSize: sample.imageSize,
            sampleSpan: 17,
            outputSize: 104
        ) else {
            return nil
        }

        return LoupeOverlayState(
            viewLocation: CGPoint(
                x: sample.viewLocation.x,
                y: geometrySize.height - sample.viewLocation.y
            ),
            image: loupeImage
        )
    }

    private func loupePosition(for viewLocation: CGPoint, in geometrySize: CGSize) -> CGPoint {
        let panelSize = CGSize(width: 120, height: 120)
        let margin: CGFloat = 16
        let cursorOffset = CGSize(width: 22, height: 24)

        var x = viewLocation.x + cursorOffset.width + panelSize.width / 2
        var y = viewLocation.y + cursorOffset.height + panelSize.height / 2

        let maxX = geometrySize.width - margin - panelSize.width / 2
        let maxY = geometrySize.height - margin - panelSize.height / 2
        let minX = margin + panelSize.width / 2
        let minY = margin + panelSize.height / 2

        if x > maxX {
            x = viewLocation.x - cursorOffset.width - panelSize.width / 2
        }

        if y > maxY {
            y = viewLocation.y - cursorOffset.height - panelSize.height / 2
        }

        return CGPoint(
            x: min(max(x, minX), maxX),
            y: min(max(y, minY), maxY)
        )
    }

    private func handleKeyPress(_ keyPress: KeyPress) {
        let zoomFactor: CGFloat = 0.1
        let newScale: CGFloat

        if keyPress.characters == "+" || keyPress.characters == "=" {
            newScale = min(scale + zoomFactor, maxScale)
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
        let newScale = max(0.1, min(oldScale * zoomFactor, maxScale))

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
    let pickMode: CurveAdjustmentView.PickMode
    let onColorPick: ((CGPoint, CGSize) -> Void)?
    let onFilesDrop: (([URL]) -> Void)?
    let onMouseMove: ((ImageHoverSample?) -> Void)?

    func makeNSView(context _: Context) -> ClickableNSImageView {
        let view = ClickableNSImageView()
        view.imageView.image = image
        view.currentScale = scale
        view.onScrollWheel = onScrollWheel
        view.pickMode = pickMode
        view.onColorPick = onColorPick
        view.onFilesDrop = onFilesDrop
        view.onMouseMove = onMouseMove
        view.onDragChanged = { translation, currentScale in
            // 拖动距离是屏幕空间的，需要除以 scale 转换为 offset 空间
            offset = CGSize(
                width: lastOffset.width + translation.width / currentScale,
                height: lastOffset.height + translation.height / currentScale
            )
        }
        view.onDragEnded = {
            lastOffset = offset
        }
        return view
    }

    func updateNSView(_ nsView: ClickableNSImageView, context _: Context) {
        // 更新图像
        nsView.imageView.image = image

        // 回调函数总是更新
        nsView.onScrollWheel = onScrollWheel
        nsView.pickMode = pickMode
        nsView.onColorPick = onColorPick
        nsView.onFilesDrop = onFilesDrop
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
    private enum CursorFactory {
        static let whiteBalance = makeEyedropperCursor()

        static func pointPicker(for mode: CurveAdjustmentView.PickMode) -> NSCursor {
            switch mode {
            case .black:
                return makePointCursor(fillColor: .black, strokeColor: .white)
            case .gray:
                return makePointCursor(fillColor: NSColor(calibratedWhite: 0.65, alpha: 1), strokeColor: .white)
            case .white:
                return makePointCursor(fillColor: .white, strokeColor: NSColor(calibratedWhite: 0.2, alpha: 1))
            case .whiteBalance:
                return whiteBalance
            case .none:
                return .arrow
            }
        }

        private static func makeEyedropperCursor() -> NSCursor {
            let size = NSSize(width: 28, height: 28)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.clear.setFill()
                rect.fill()

                let badgeRect = NSRect(x: 3, y: 3, width: 22, height: 22)
                NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
                NSBezierPath(ovalIn: badgeRect).fill()

                if
                    let symbol = NSImage(
                        systemSymbolName: "eyedropper",
                        accessibilityDescription: "White balance picker"
                    )?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
                {
                    symbol.isTemplate = false
                    let symbolRect = NSRect(x: 6, y: 5, width: 16, height: 16)
                    NSColor.white.set()
                    symbol.draw(in: symbolRect)
                } else {
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: 9, y: 9))
                    path.line(to: CGPoint(x: 20, y: 20))
                    path.lineWidth = 2.4
                    NSColor.white.setStroke()
                    path.stroke()
                }

                let focusRect = NSRect(x: 18, y: 4, width: 6, height: 6)
                NSColor(calibratedRed: 0.38, green: 0.72, blue: 1.0, alpha: 1).setFill()
                NSBezierPath(ovalIn: focusRect).fill()

                return true
            }

            return NSCursor(image: image, hotSpot: NSPoint(x: 6, y: 22))
        }

        private static func makePointCursor(fillColor: NSColor, strokeColor: NSColor) -> NSCursor {
            let size = NSSize(width: 24, height: 24)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.clear.setFill()
                rect.fill()

                let center = CGPoint(x: rect.midX, y: rect.midY)
                let ringPath = NSBezierPath()
                ringPath.lineWidth = 1.25

                ringPath.move(to: CGPoint(x: center.x, y: 2))
                ringPath.line(to: CGPoint(x: center.x, y: 8))
                ringPath.move(to: CGPoint(x: center.x, y: rect.maxY - 2))
                ringPath.line(to: CGPoint(x: center.x, y: rect.maxY - 8))
                ringPath.move(to: CGPoint(x: 2, y: center.y))
                ringPath.line(to: CGPoint(x: 8, y: center.y))
                ringPath.move(to: CGPoint(x: rect.maxX - 2, y: center.y))
                ringPath.line(to: CGPoint(x: rect.maxX - 8, y: center.y))
                strokeColor.setStroke()
                ringPath.stroke()

                let outer = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 12, height: 12))
                outer.lineWidth = 1.5
                strokeColor.setStroke()
                outer.stroke()

                let inner = NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 6, height: 6))
                fillColor.setFill()
                inner.fill()

                return true
            }

            return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
        }
    }

    let imageView = NSImageView()
    var onScrollWheel: ((CGFloat, CGPoint) -> Void)?
    var onDragChanged: ((CGSize, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onColorPick: ((CGPoint, CGSize) -> Void)?
    var onFilesDrop: (([URL]) -> Void)?
    var onMouseMove: ((ImageHoverSample?) -> Void)?
    var pickMode: CurveAdjustmentView.PickMode = .none {
        didSet {
            guard pickMode != oldValue else { return }
            refreshCursor()
        }
    }

    var currentScale: CGFloat = 1.0
    var currentOffset: CGSize = .zero

    private var isDragging = false
    private var dragStartPoint: NSPoint = .zero
    private var isSpaceKeyPressed = false
    private var isMouseInside = false
    private var isHoveringImageContent = false
    private var trackingArea: NSTrackingArea?
    private var eventMonitors: [Any] = []

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

    deinit {
        MainActor.assumeIsolated {
            for monitor in eventMonitors {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    private func setupView() {
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        addSubview(imageView)

        // 监听全局键盘事件
        let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        if let flagsMonitor {
            eventMonitors.append(flagsMonitor)
        }

        let keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { // 空格键
                self?.isSpaceKeyPressed = true
                self?.refreshCursor()
            }
            return event
        }
        if let keyDownMonitor {
            eventMonitors.append(keyDownMonitor)
        }

        let keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.keyCode == 49 { // 空格键
                self?.isSpaceKeyPressed = false
                self?.refreshCursor()
            }
            return event
        }
        if let keyUpMonitor {
            eventMonitors.append(keyUpMonitor)
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
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .cursorUpdate,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        refreshCursor()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        isHoveringImageContent = false
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let image = imageView.image else { return }

        let locationInView = convert(event.locationInWindow, from: nil)

        if let pixelPoint = viewPointToImagePixel(locationInView) {
            if !isHoveringImageContent {
                isHoveringImageContent = true
                refreshCursor()
            }
            onMouseMove?(
                ImageHoverSample(
                    viewLocation: locationInView,
                    pixelPoint: pixelPoint,
                    imageSize: image.size
                )
            )
        } else {
            if isHoveringImageContent {
                isHoveringImageContent = false
                refreshCursor()
            }
            onMouseMove?(nil)
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
            NSCursor.closedHand.set()
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
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: currentPoint.x - dragStartPoint.x,
            height: currentPoint.y - dragStartPoint.y
        )

        onDragChanged?(translation, currentScale)
    }

    override func mouseUp(with _: NSEvent) {
        if isDragging {
            isDragging = false
            onDragEnded?()
            dragStartPoint = .zero

            refreshCursor()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        currentCursor().set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor())
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFilesDrop?(urls)
        return true
    }

    private func currentCursor() -> NSCursor {
        if isDragging {
            return .closedHand
        }

        if isSpaceKeyPressed {
            return .openHand
        }

        guard onColorPick != nil else {
            return .arrow
        }

        guard isHoveringImageContent else {
            return .arrow
        }

        return CursorFactory.pointPicker(for: pickMode)
    }

    private func refreshCursor() {
        guard window != nil else { return }
        window?.invalidateCursorRects(for: self)
        if isMouseInside {
            currentCursor().set()
        }
    }

    private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }
}

private struct WhiteBalanceLoupeOverlay: View {
    let image: NSImage
    let pixelInfo: PixelInfo?
    private let panelSize: CGFloat = 120
    private let loupeSize: CGFloat = 104
    private let focusBoxSize: CGFloat = 12
    private let focusBoxLineWidth: CGFloat = 1.25
    private let crosshairLineWidth: CGFloat = 1
    private let crosshairInnerGap: CGFloat = 9
    private let crosshairEdgeInset: CGFloat = 7

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: loupeSize, height: loupeSize)
                    .clipped()

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let boxRect = CGRect(
                        x: center.x - focusBoxSize / 2,
                        y: center.y - focusBoxSize / 2,
                        width: focusBoxSize,
                        height: focusBoxSize
                    )

                    var crosshairPath = Path()
                    crosshairPath.move(to: CGPoint(x: center.x, y: crosshairEdgeInset))
                    crosshairPath.addLine(
                        to: CGPoint(x: center.x, y: center.y - crosshairInnerGap)
                    )
                    crosshairPath.move(
                        to: CGPoint(x: center.x, y: center.y + crosshairInnerGap)
                    )
                    crosshairPath.addLine(
                        to: CGPoint(x: center.x, y: size.height - crosshairEdgeInset)
                    )
                    crosshairPath.move(to: CGPoint(x: crosshairEdgeInset, y: center.y))
                    crosshairPath.addLine(
                        to: CGPoint(x: center.x - crosshairInnerGap, y: center.y)
                    )
                    crosshairPath.move(
                        to: CGPoint(x: center.x + crosshairInnerGap, y: center.y)
                    )
                    crosshairPath.addLine(
                        to: CGPoint(x: size.width - crosshairEdgeInset, y: center.y)
                    )

                    context.stroke(
                        crosshairPath,
                        with: .color(Color.white.opacity(0.8)),
                        lineWidth: crosshairLineWidth
                    )
                    context.stroke(
                        Path(boxRect),
                        with: .color(Color.white.opacity(0.9)),
                        lineWidth: focusBoxLineWidth
                    )
                }
                .frame(width: loupeSize, height: loupeSize)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: panelSize, height: panelSize)

            HStack(spacing: 4) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)

                Text("WB")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.62))
            )
            .padding(.top, 8)
            .padding(.leading, 8)

            VStack {
                Spacer()

                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(sampleColor)
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )

                    Image(systemName: "eyedropper")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))

                    Text(pixelInfo.map { formatRGB($0.gammaRGB) } ?? "---")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.96))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(width: panelSize - 12, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.70))
                )
                .padding(.bottom, 6)
            }
            .frame(width: panelSize, height: panelSize)
        }
        .frame(width: panelSize, height: panelSize)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    private var sampleColor: Color {
        guard let pixelInfo else {
            return Color.clear
        }

        return Color(
            red: pixelInfo.gammaRGB.r,
            green: pixelInfo.gammaRGB.g,
            blue: pixelInfo.gammaRGB.b
        )
    }

    private func formatRGB(_ value: (r: Double, g: Double, b: Double)) -> String {
        let r = Int((value.r * 255).rounded())
        let g = Int((value.g * 255).rounded())
        let b = Int((value.b * 255).rounded())
        return "\(r),\(g),\(b)"
    }
}
