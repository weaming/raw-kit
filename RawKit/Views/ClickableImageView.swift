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
        let clamped = min(max(linear, 0.0), 1.0)

        if clamped <= 0.0031308 {
            return clamped * 12.92
        } else {
            return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
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

private struct ViewportImageGeometry {
    let imageSize: CGSize
    let viewportSize: CGSize

    var baseRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }

        let fitRatio = min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        let fitSize = CGSize(
            width: imageSize.width * fitRatio,
            height: imageSize.height * fitRatio
        )

        return CGRect(
            x: (viewportSize.width - fitSize.width) * 0.5,
            y: (viewportSize.height - fitSize.height) * 0.5,
            width: fitSize.width,
            height: fitSize.height
        )
    }

    func displayedRect(scale: CGFloat, offset: CGSize) -> CGRect {
        let rect = baseRect
        guard !rect.isEmpty else { return .zero }

        let scaledSize = CGSize(
            width: rect.width * scale,
            height: rect.height * scale
        )
        let center = CGPoint(
            x: rect.midX + offset.width,
            y: rect.midY + offset.height
        )

        return CGRect(
            x: center.x - scaledSize.width * 0.5,
            y: center.y - scaledSize.height * 0.5,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    func clampedOffset(_ candidate: CGSize, scale: CGFloat) -> CGSize {
        let rect = baseRect
        guard !rect.isEmpty else { return .zero }

        let scaledWidth = rect.width * scale
        let scaledHeight = rect.height * scale

        let horizontalOverflow = max(0, (scaledWidth - viewportSize.width) * 0.5)
        let verticalOverflow = max(0, (scaledHeight - viewportSize.height) * 0.5)

        let clampedX = horizontalOverflow > 0
            ? min(max(candidate.width, -horizontalOverflow), horizontalOverflow)
            : 0
        let clampedY = verticalOverflow > 0
            ? min(max(candidate.height, -verticalOverflow), verticalOverflow)
            : 0

        return CGSize(width: clampedX, height: clampedY)
    }

    func imagePixel(for viewPoint: CGPoint, scale: CGFloat, offset: CGSize) -> CGPoint? {
        let rect = displayedRect(scale: scale, offset: offset)
        guard rect.width > 0, rect.height > 0, rect.contains(viewPoint) else {
            return nil
        }

        let normalizedX = (viewPoint.x - rect.minX) / rect.width
        let normalizedY = (viewPoint.y - rect.minY) / rect.height

        return CGPoint(
            x: normalizedX * imageSize.width,
            y: (1.0 - normalizedY) * imageSize.height
        )
    }

    func zoomOffset(
        from oldScale: CGFloat,
        oldOffset: CGSize,
        to newScale: CGFloat,
        anchorViewPoint: CGPoint?
    ) -> CGSize {
        let oldRect = displayedRect(scale: oldScale, offset: oldOffset)

        let resolvedAnchorPoint: CGPoint
        let normalizedAnchor: CGPoint

        if let anchorViewPoint,
           oldRect.width > 0,
           oldRect.height > 0,
           oldRect.contains(anchorViewPoint) {
            resolvedAnchorPoint = anchorViewPoint
            normalizedAnchor = CGPoint(
                x: (anchorViewPoint.x - oldRect.minX) / oldRect.width,
                y: (anchorViewPoint.y - oldRect.minY) / oldRect.height
            )
        } else {
            resolvedAnchorPoint = CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5)
            normalizedAnchor = CGPoint(x: 0.5, y: 0.5)
        }

        let rect = baseRect
        let newSize = CGSize(
            width: rect.width * newScale,
            height: rect.height * newScale
        )
        let newOrigin = CGPoint(
            x: resolvedAnchorPoint.x - normalizedAnchor.x * newSize.width,
            y: resolvedAnchorPoint.y - normalizedAnchor.y * newSize.height
        )
        let newCenter = CGPoint(
            x: newOrigin.x + newSize.width * 0.5,
            y: newOrigin.y + newSize.height * 0.5
        )
        let rawOffset = CGSize(
            width: newCenter.x - rect.midX,
            height: newCenter.y - rect.midY
        )

        return clampedOffset(rawOffset, scale: newScale)
    }
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
    let displayedCIImage: CIImage?
    let isHDREnabled: Bool
    let pickMode: CurveAdjustmentView.PickMode
    let onColorPick: ((CGPoint, CGSize) -> Void)?
    let onCancelPickMode: (() -> Void)?
    let onFilesDrop: (([URL]) -> Void)?
    let isCropModeEnabled: Bool
    @Binding var cropLeft: Double
    @Binding var cropTop: Double
    @Binding var cropRight: Double
    @Binding var cropBottom: Double
    let cropAspectRatio: CropAspectRatio

    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var lastPixelSampleTime: TimeInterval = 0
    @State private var loupeState: LoupeOverlayState?
    @State private var viewportSize: CGSize = .zero
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ClickableImageRepresentable(
                image: image,
                scale: $scale,
                offset: $offset,
                onScrollWheel: { deltaY, location in
                    handleScrollWheel(deltaY: deltaY, location: location, viewportSize: geometry.size)
                },
                onDragChanged: { translation in
                    handleDragChanged(translation: translation, viewportSize: geometry.size)
                },
                onDragEnded: {
                    lastOffset = offset
                },
                isHDREnabled: isHDREnabled,
                pickMode: pickMode,
                onColorPick: onColorPick,
                onCancelPickMode: onCancelPickMode,
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
            .overlay {
                if isCropModeEnabled {
                    CropOverlayView(
                        imageSize: image.size,
                        viewportSize: geometry.size,
                        scale: scale,
                        offset: offset,
                        cropLeft: $cropLeft,
                        cropTop: $cropTop,
                        cropRight: $cropRight,
                        cropBottom: $cropBottom,
                        aspectRatio: cropAspectRatio
                    )
                    .transition(.opacity)
                }
            }
            .onAppear {
                updateViewportSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                updateViewportSize(newSize)
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

        let samplingImage = displayedCIImage ?? originalCIImage

        guard let ciImage = samplingImage else {
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
            outputSize: WhiteBalanceLoupeOverlay.loupeDisplaySize
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
        let panelSize = WhiteBalanceLoupeOverlay.overlaySize
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

        applyScaleChange(newScale, anchorInView: nil)
    }

    private func handleScrollWheel(
        deltaY: CGFloat,
        location: CGPoint,
        viewportSize: CGSize
    ) {
        let zoomFactor: CGFloat = 1.0 + (deltaY * 0.01)
        let oldScale = scale
        let newScale = max(0.1, min(oldScale * zoomFactor, maxScale))

        if oldScale == newScale {
            return
        }

        updateViewportSize(viewportSize)
        applyScaleChange(newScale, anchorInView: location)
    }

    private func handleDragChanged(translation: CGSize, viewportSize: CGSize) {
        updateViewportSize(viewportSize)
        let candidate = CGSize(
            width: lastOffset.width + translation.width,
            height: lastOffset.height + translation.height
        )
        offset = viewportGeometry(for: viewportSize).clampedOffset(candidate, scale: scale)
    }

    private func updateViewportSize(_ newViewportSize: CGSize) {
        guard newViewportSize != .zero else { return }
        viewportSize = newViewportSize

        let clamped = viewportGeometry(for: newViewportSize).clampedOffset(offset, scale: scale)
        if abs(clamped.width - offset.width) > 0.0001 || abs(clamped.height - offset.height) > 0.0001 {
            offset = clamped
            lastOffset = clamped
        }
    }

    private func applyScaleChange(_ newScale: CGFloat, anchorInView: CGPoint?) {
        guard viewportSize != .zero else {
            scale = newScale
            offset = .zero
            lastOffset = .zero
            return
        }

        let geometry = viewportGeometry(for: viewportSize)
        let currentDisplayedOffset = geometry.clampedOffset(offset, scale: scale)
        let newOffset = geometry.zoomOffset(
            from: scale,
            oldOffset: currentDisplayedOffset,
            to: newScale,
            anchorViewPoint: anchorInView
        )

        scale = newScale
        offset = newOffset
        lastOffset = newOffset
    }

    private func viewportGeometry(for viewportSize: CGSize) -> ViewportImageGeometry {
        ViewportImageGeometry(imageSize: image.size, viewportSize: viewportSize)
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            scale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }
}

private struct CropOverlayView: View {
    private enum Handle: CaseIterable {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
        case move
    }

    private struct DragStart {
        let cropRect: CGRect
    }

    let imageSize: CGSize
    let viewportSize: CGSize
    let scale: CGFloat
    let offset: CGSize
    @Binding var cropLeft: Double
    @Binding var cropTop: Double
    @Binding var cropRight: Double
    @Binding var cropBottom: Double
    let aspectRatio: CropAspectRatio

    @State private var activeHandle: Handle?
    @State private var dragStart: DragStart?

    private var displayedRect: CGRect {
        ViewportImageGeometry(imageSize: imageSize, viewportSize: viewportSize)
            .displayedRect(scale: scale, offset: offset)
    }

    private var cropRect: CGRect {
        normalizedCropRect(in: displayedRect)
    }

    var body: some View {
        ZStack {
            dimmingMask

            cropGrid

            ForEach(Handle.allCases.filter { $0 != .move }, id: \.self) { handle in
                handleView(for: handle)
            }
        }
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private var dimmingMask: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: viewportSize))
            path.addRect(cropRect)
        }
        .fill(Color.black.opacity(0.46), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var cropGrid: some View {
        ZStack {
            Rectangle()
                .stroke(Color.white, lineWidth: 1.4)

            Path { path in
                let thirdWidth = cropRect.width / 3
                let thirdHeight = cropRect.height / 3

                for index in 1 ... 2 {
                    let x = CGFloat(index) * thirdWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: cropRect.height))

                    let y = CGFloat(index) * thirdHeight
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: cropRect.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.58), lineWidth: 0.8)
        }
        .frame(width: cropRect.width, height: cropRect.height)
        .position(x: cropRect.midX, y: cropRect.midY)
        .gesture(dragGesture(for: .move))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard cropRect.contains(value.startLocation) else { return }
                updateCrop(handle: .move, translation: value.translation)
            }
            .onEnded { _ in
                activeHandle = nil
                dragStart = nil
            }
    }

    private func handleView(for handle: Handle) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
            .frame(width: handleSize(for: handle).width, height: handleSize(for: handle).height)
            .position(handlePosition(for: handle))
            .gesture(dragGesture(for: handle))
    }

    private func dragGesture(for handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                updateCrop(handle: handle, translation: value.translation)
            }
            .onEnded { _ in
                activeHandle = nil
                dragStart = nil
            }
    }

    private func updateCrop(handle: Handle, translation: CGSize) {
        if activeHandle != handle || dragStart == nil {
            activeHandle = handle
            dragStart = DragStart(cropRect: cropRect)
        }

        guard let dragStart else { return }

        let constrainedRect = constrainedCropRect(
            proposedRect(for: handle, startRect: dragStart.cropRect, translation: translation),
            fixedHandle: handle
        )
        writeCropRect(constrainedRect)
    }

    private func proposedRect(for handle: Handle, startRect: CGRect, translation: CGSize) -> CGRect {
        var rect = startRect

        switch handle {
        case .topLeft:
            rect.origin.x += translation.width
            rect.size.width -= translation.width
            rect.origin.y += translation.height
            rect.size.height -= translation.height
        case .top:
            rect.origin.y += translation.height
            rect.size.height -= translation.height
        case .topRight:
            rect.size.width += translation.width
            rect.origin.y += translation.height
            rect.size.height -= translation.height
        case .right:
            rect.size.width += translation.width
        case .bottomRight:
            rect.size.width += translation.width
            rect.size.height += translation.height
        case .bottom:
            rect.size.height += translation.height
        case .bottomLeft:
            rect.origin.x += translation.width
            rect.size.width -= translation.width
            rect.size.height += translation.height
        case .left:
            rect.origin.x += translation.width
            rect.size.width -= translation.width
        case .move:
            rect.origin.x += translation.width
            rect.origin.y += translation.height
        }

        return rect
    }

    private func constrainedCropRect(_ proposed: CGRect, fixedHandle: Handle) -> CGRect {
        let bounds = displayedRect
        let minLength: CGFloat = 48
        var rect = proposed.standardized

        if let ratio = aspectRatio.resolvedValue(for: imageSize), fixedHandle != .move {
            rect = applyAspectRatio(ratio, to: rect, fixedHandle: fixedHandle)
        }

        if rect.width < minLength {
            rect.size.width = minLength
        }

        if rect.height < minLength {
            rect.size.height = minLength
        }

        if rect.width > bounds.width {
            rect.size.width = bounds.width
        }

        if rect.height > bounds.height {
            rect.size.height = bounds.height
        }

        if rect.minX < bounds.minX {
            rect.origin.x = bounds.minX
        }

        if rect.minY < bounds.minY {
            rect.origin.y = bounds.minY
        }

        if rect.maxX > bounds.maxX {
            rect.origin.x -= rect.maxX - bounds.maxX
        }

        if rect.maxY > bounds.maxY {
            rect.origin.y -= rect.maxY - bounds.maxY
        }

        return rect.intersection(bounds)
    }

    private func applyAspectRatio(_ ratio: Double, to rect: CGRect, fixedHandle: Handle) -> CGRect {
        let aspect = CGFloat(ratio)
        guard aspect > 0 else { return rect }

        var result = rect
        let currentAspect = rect.width / max(rect.height, 1)

        if currentAspect > aspect {
            result.size.width = rect.height * aspect
        } else {
            result.size.height = rect.width / aspect
        }

        switch fixedHandle {
        case .topLeft:
            result.origin.x = rect.maxX - result.width
            result.origin.y = rect.maxY - result.height
        case .top, .topRight:
            result.origin.y = rect.maxY - result.height
        case .left, .bottomLeft:
            result.origin.x = rect.maxX - result.width
        case .move, .right, .bottomRight, .bottom:
            break
        }

        return result
    }

    private func normalizedCropRect(in rect: CGRect) -> CGRect {
        let left = CGFloat(min(max(cropLeft, 0.0), 0.95))
        let top = CGFloat(min(max(cropTop, 0.0), 0.95))
        let right = CGFloat(min(max(cropRight, 0.0), 0.95))
        let bottom = CGFloat(min(max(cropBottom, 0.0), 0.95))

        return CGRect(
            x: rect.minX + rect.width * left,
            y: rect.minY + rect.height * top,
            width: rect.width * max(0.02, 1.0 - left - right),
            height: rect.height * max(0.02, 1.0 - top - bottom)
        )
    }

    private func writeCropRect(_ rect: CGRect) {
        let bounds = displayedRect
        guard bounds.width > 0, bounds.height > 0 else { return }

        cropLeft = Double((rect.minX - bounds.minX) / bounds.width)
        cropTop = Double((rect.minY - bounds.minY) / bounds.height)
        cropRight = Double((bounds.maxX - rect.maxX) / bounds.width)
        cropBottom = Double((bounds.maxY - rect.maxY) / bounds.height)
    }

    private func handlePosition(for handle: Handle) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .top:
            return CGPoint(x: cropRect.midX, y: cropRect.minY)
        case .topRight:
            return CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .right:
            return CGPoint(x: cropRect.maxX, y: cropRect.midY)
        case .bottomRight:
            return CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        case .bottom:
            return CGPoint(x: cropRect.midX, y: cropRect.maxY)
        case .bottomLeft:
            return CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .left:
            return CGPoint(x: cropRect.minX, y: cropRect.midY)
        case .move:
            return CGPoint(x: cropRect.midX, y: cropRect.midY)
        }
    }

    private func handleSize(for handle: Handle) -> CGSize {
        switch handle {
        case .top, .bottom:
            return CGSize(width: 34, height: 7)
        case .left, .right:
            return CGSize(width: 7, height: 34)
        case .move:
            return .zero
        default:
            return CGSize(width: 12, height: 12)
        }
    }
}

struct ClickableImageRepresentable: NSViewRepresentable {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    let onScrollWheel: (CGFloat, CGPoint) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    let isHDREnabled: Bool
    let pickMode: CurveAdjustmentView.PickMode
    let onColorPick: ((CGPoint, CGSize) -> Void)?
    let onCancelPickMode: (() -> Void)?
    let onFilesDrop: (([URL]) -> Void)?
    let onMouseMove: ((ImageHoverSample?) -> Void)?

    func makeNSView(context _: Context) -> ClickableNSImageView {
        let view = ClickableNSImageView()
        view.imageView.image = image
        view.currentScale = scale
        view.isHDREnabled = isHDREnabled
        view.onScrollWheel = onScrollWheel
        view.pickMode = pickMode
        view.onColorPick = onColorPick
        view.onCancelPickMode = onCancelPickMode
        view.onFilesDrop = onFilesDrop
        view.onMouseMove = onMouseMove
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: ClickableNSImageView, context _: Context) {
        let imageChanged = nsView.imageView.image !== image

        // 更新图像
        nsView.imageView.image = image

        // 回调函数总是更新
        nsView.onScrollWheel = onScrollWheel
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.isHDREnabled = isHDREnabled
        nsView.pickMode = pickMode
        nsView.onColorPick = onColorPick
        nsView.onCancelPickMode = onCancelPickMode
        nsView.onFilesDrop = onFilesDrop
        nsView.onMouseMove = onMouseMove

        // 检查 scale 或 offset 是否变化
        let scaleChanged = abs(nsView.currentScale - scale) > 0.0001
        let offsetChanged = abs(nsView.currentOffset.width - offset.width) > 0.0001 ||
            abs(nsView.currentOffset.height - offset.height) > 0.0001

        nsView.currentScale = scale
        nsView.currentOffset = offset

        if imageChanged || scaleChanged || offsetChanged {
            nsView.updateImageLayout()
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
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    var onColorPick: ((CGPoint, CGSize) -> Void)?
    var onCancelPickMode: (() -> Void)?
    var onFilesDrop: (([URL]) -> Void)?
    var onMouseMove: ((ImageHoverSample?) -> Void)?
    var isHDREnabled: Bool = false {
        didSet {
            guard isHDREnabled != oldValue else { return }
            applyDynamicRangePreference()
        }
    }
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

    private func viewPointToImagePixel(_ viewPoint: CGPoint) -> CGPoint? {
        guard let geometry = viewportGeometry else { return nil }
        let displayedOffset = geometry.clampedOffset(currentOffset, scale: currentScale)
        return geometry.imagePixel(for: viewPoint, scale: currentScale, offset: displayedOffset)
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
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        applyDynamicRangePreference()

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
            if event.keyCode == 53, self?.pickMode == .whiteBalance {
                self?.onCancelPickMode?()
                return nil
            }
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

    private func applyDynamicRangePreference() {
        imageView.preferredImageDynamicRange = isHDREnabled ? .high : .standard

        if #available(macOS 26.0, *) {
            imageView.layer?.preferredDynamicRange = isHDREnabled ? .high : .standard
            layer?.preferredDynamicRange = isHDREnabled ? .high : .standard
        }
    }

    override func layout() {
        super.layout()
        updateImageLayout()
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
        onMouseMove?(nil)
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
        onScrollWheel?(event.deltaY, locationInView)
    }

    override func mouseDown(with event: NSEvent) {
        // 如果按住空格键，强制进入拖拽模式
        if isSpaceKeyPressed {
            isDragging = true
            dragStartPoint = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
            return
        }

        // 如果有取色回调，先尝试取色
        if let onColorPick, let image = imageView.image {
            let locationInView = convert(event.locationInWindow, from: nil)

            // 将视图坐标转换为图片像素坐标
            if let pixelPoint = viewPointToImagePixel(locationInView) {
                onColorPick(pixelPoint, image.size)
            }
            return
        }

        // 否则进入拖拽模式
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

        onDragChanged?(translation)
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

    private var viewportGeometry: ViewportImageGeometry? {
        guard let image = imageView.image else { return nil }
        return ViewportImageGeometry(imageSize: image.size, viewportSize: bounds.size)
    }

    func updateImageLayout() {
        guard let geometry = viewportGeometry else {
            imageView.frame = bounds
            return
        }

        let displayedOffset = geometry.clampedOffset(currentOffset, scale: currentScale)
        imageView.frame = geometry.displayedRect(
            scale: currentScale,
            offset: displayedOffset
        )
    }
}

private struct WhiteBalanceLoupeOverlay: View {
    let image: NSImage
    let pixelInfo: PixelInfo?
    static let loupeDisplaySize: CGFloat = 134
    private static let horizontalInset: CGFloat = 8
    private static let verticalInset: CGFloat = 6
    private static let contentSpacing: CGFloat = 4
    private static let infoHeight: CGFloat = 26
    static let overlaySize = CGSize(
        width: loupeDisplaySize + (horizontalInset * 2),
        height: loupeDisplaySize + infoHeight + contentSpacing + (verticalInset * 2)
    )

    private let panelWidth: CGFloat = WhiteBalanceLoupeOverlay.overlaySize.width
    private let panelHeight: CGFloat = WhiteBalanceLoupeOverlay.overlaySize.height
    private let loupeSize: CGFloat = WhiteBalanceLoupeOverlay.loupeDisplaySize
    private let infoHeight: CGFloat = WhiteBalanceLoupeOverlay.infoHeight
    private let focusBoxSize: CGFloat = 12
    private let focusBoxLineWidth: CGFloat = 1.25
    private let crosshairLineWidth: CGFloat = 1
    private let crosshairInnerGap: CGFloat = 9
    private let crosshairEdgeInset: CGFloat = 7

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: WhiteBalanceLoupeOverlay.contentSpacing) {
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
                .frame(width: loupeSize, height: loupeSize)

                HStack(alignment: .center, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(sampleColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("RGB \(pixelInfo.map { formatRGB($0.displayRGB) } ?? "---")")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.96))
                            .lineLimit(1)
                            .layoutPriority(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("HEX \(pixelInfo.map { formatHex($0.displayRGB) } ?? "---")")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, WhiteBalanceLoupeOverlay.horizontalInset)
                .frame(
                    width: panelWidth - (WhiteBalanceLoupeOverlay.horizontalInset * 2),
                    height: infoHeight,
                    alignment: .leading
                )
            }
            .padding(.top, WhiteBalanceLoupeOverlay.verticalInset)
            .padding(.bottom, WhiteBalanceLoupeOverlay.verticalInset)
            .frame(width: panelWidth, height: panelHeight)

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
        }
        .frame(width: panelWidth, height: panelHeight)
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

        let displayRGB = pixelInfo.displayRGB
        return Color(
            red: displayRGB.r,
            green: displayRGB.g,
            blue: displayRGB.b
        )
    }

    private func formatRGB(_ value: (r: Double, g: Double, b: Double)) -> String {
        let r = Int((value.r * 255).rounded())
        let g = Int((value.g * 255).rounded())
        let b = Int((value.b * 255).rounded())
        return "\(r),\(g),\(b)"
    }

    private func formatHex(_ value: (r: Double, g: Double, b: Double)) -> String {
        let r = Int((value.r * 255).rounded())
        let g = Int((value.g * 255).rounded())
        let b = Int((value.b * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
