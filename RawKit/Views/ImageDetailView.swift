import CoreImage
import SwiftUI

struct PixelInfo: Equatable {
    var gammaRGB: (r: Double, g: Double, b: Double)
    var linearRGB: (r: Double, g: Double, b: Double)
    var hsl: (h: Double, s: Double, l: Double)

    static func == (lhs: PixelInfo, rhs: PixelInfo) -> Bool {
        lhs.gammaRGB == rhs.gammaRGB &&
            lhs.linearRGB == rhs.linearRGB &&
            lhs.hsl == rhs.hsl
    }
}

struct ImageDetailView: View {
    private struct RenderRequest: Sendable {
        let id: Int
        let adjustments: ImageAdjustments
    }

    private struct RenderSnapshot: @unchecked Sendable {
        let requestID: Int
        let originalImage: CIImage
        let viewportSize: CGSize
        let adjustments: ImageAdjustments
        let showOriginal: Bool
    }

    private struct RenderOutput: @unchecked Sendable {
        let requestID: Int
        let image: CIImage
        let cgImage: CGImage?
        let adjustments: ImageAdjustments
        let showOriginal: Bool
    }

    let imageInfo: ImageInfo
    let session: ImageEditingSession
    @ObservedObject var editingState: ImageEditingState
    @ObservedObject private var history: AdjustmentHistory
    @Binding var sidebarWidth: CGFloat
    let onFilesDrop: (([URL]) -> Void)?

    @State private var originalCIImage: CIImage?
    @State private var adjustedCIImage: CIImage?
    @State private var previewCIImage: CIImage?
    @State private var previewRevision = 0
    @State private var displayImage: NSImage?
    @State private var displayImageID = UUID() // 用于强制刷新视图
    @State private var isLoading = true
    @State private var loadingStage: LoadingStage = .thumbnail
    @State private var scale: CGFloat = 1.0
    @State private var showAdjustmentPanel = true
    @State private var whiteBalancePickMode: CurveAdjustmentView.PickMode = .none
    @State private var currentPixelInfo: PixelInfo?
    @State private var viewportSize: CGSize = .zero
    @State private var showOriginal = false  // 是否显示原图（Before/After 切换）
    @State private var curvePickSamples = CurvePickSamples()

    // Before/After 缓存
    @State private var cachedAdjustedImage: NSImage?  // 缓存的调整后图像
    @State private var cachedAdjustments: ImageAdjustments?  // 缓存对应的调整参数

    // 渲染队列（延迟初始化）
    @State private var renderQueue: RenderQueue<RenderRequest>?
    @State private var nextRenderRequestID = 0
    @State private var latestRenderRequestID = 0

    enum LoadingStage {
        case thumbnail
        case mediumResolution
        case fullResolution
    }

    init(
        imageInfo: ImageInfo,
        session: ImageEditingSession,
        editingState: ImageEditingState,
        sidebarWidth: Binding<CGFloat>,
        onFilesDrop: (([URL]) -> Void)?
    ) {
        self.imageInfo = imageInfo
        self.session = session
        self._editingState = ObservedObject(wrappedValue: editingState)
        self._history = ObservedObject(wrappedValue: session.history)
        self._sidebarWidth = sidebarWidth
        self.onFilesDrop = onFilesDrop
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                buildImageView()
                buildImageInfoBar()
            }
            .clipped()

            if showAdjustmentPanel {
                Divider()
                ResizableAdjustmentPanel(
                    adjustments: $editingState.adjustments,
                    curvePickSamples: $curvePickSamples,
                    originalCIImage: originalCIImage,
                    adjustedCIImage: adjustedCIImage ?? originalCIImage,
                    previewCIImage: previewCIImage,
                    previewRevision: previewRevision,
                    width: $sidebarWidth,
                    whiteBalancePickMode: $whiteBalancePickMode
                )
                .equatable()
            }
        }
        .task(id: imageInfo.id) {
            // 初始化渲染队列（maxFPS: 0 = 不限制，30 = 30fps，60 = 60fps）
            if renderQueue == nil {
                renderQueue = RenderQueue(maxFPS: 30) { request in
                    await self.performRender(request)
                }
            }

            await loadImageProgressively()
        }
        .onChange(of: editingState.adjustments) { _, newValue in
            if showOriginal {
                cachedAdjustedImage = nil
                cachedAdjustments = nil
                print("Before/After: 在原图模式下修改参数，清空缓存")
            }

            enqueueRender(newValue)
        }
        .onChange(of: showOriginal) { _, newValue in
            if newValue {
                // 切换到原图：保存当前调整图到缓存，然后渲染原图
                if editingState.adjustments == cachedAdjustments {
                    // 参数没变，保存当前显示的图像
                    cachedAdjustedImage = displayImage
                }
                enqueueRender(editingState.adjustments)
            } else {
                // 切换回调整效果：检查缓存是否有效
                if let cached = cachedAdjustedImage, editingState.adjustments == cachedAdjustments {
                    // 缓存有效，直接使用缓存图像（无需重新渲染）
                    displayImage = cached
                    if let adjustedCIImage {
                        commitPreviewImage(adjustedCIImage)
                    }
                    print("Before/After: 使用缓存的调整图像")
                } else {
                    // 缓存失效或不存在，重新渲染
                    print("Before/After: 缓存失效，重新渲染调整图像")
                    enqueueRender(editingState.adjustments)
                }
            }
        }
        .focusedSceneValue(\.undoAction, history.canUndo ? undo : nil)
        .focusedSceneValue(\.redoAction, history.canRedo ? redo : nil)
        .background(
            Button("") {
                cancelWhiteBalancePickMode()
            }
            .keyboardShortcut(.escape)
            .disabled(whiteBalancePickMode != .whiteBalance)
            .hidden()
        )
        .onDisappear {
            session.flushPendingEdits()
        }
    }

    private func loadImageProgressively() async {
        // 检查图像尺寸，决定加载策略
        let imageSize = getImageDimensions(from: imageInfo.url)
        let maxDimension = max(imageSize.width, imageSize.height)

        // 小图直接加载完整分辨率，跳过渐进式加载
        if maxDimension > 0 && maxDimension < 6000 {
            print("ImageDetailView: 小图片（\(Int(maxDimension))px），直接加载完整分辨率")

            loadingStage = .fullResolution
            if let fullImage = await ImageProcessor.loadCIImage(from: imageInfo.url) {
                originalCIImage = fullImage
                print("ImageDetailView: ✓ originalCIImage 已加载（小图）")
                await waitForViewportSize()
                await renderCurrentStateImmediately()
                displayImageID = UUID()
            } else {
                print("ImageDetailView: ✗ 加载 CIImage 失败（小图）")
            }

            isLoading = false
            return
        }

        // 大图：缩略图 → 完整分辨率（跳过中等分辨率）
        print("ImageDetailView: 大图片（\(Int(maxDimension))px），缩略图 → 完整分辨率")

        loadingStage = .thumbnail
        if let thumbnail = ImageProcessor.loadThumbnail(from: imageInfo.url) {
            displayImage = ImageProcessor.convertToNSImage(thumbnail)
            displayImageID = UUID()
            isLoading = false
        }

        loadingStage = .fullResolution
        await Task.yield()

        if let fullImage = await ImageProcessor.loadCIImage(from: imageInfo.url) {
            originalCIImage = fullImage
            print("ImageDetailView: ✓ originalCIImage 已加载（大图）")
            await waitForViewportSize()
            await renderCurrentStateImmediately()
            displayImageID = UUID()
        } else {
            print("ImageDetailView: ✗ 加载 CIImage 失败（大图）")
        }

        isLoading = false
    }

    // 等待视口尺寸可用
    private func waitForViewportSize() async {
        var retries = 0
        while viewportSize == .zero && retries < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            retries += 1
        }
    }

    private func getImageDimensions(from url: URL) -> CGSize {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return .zero
        }

        let width = properties[kCGImagePropertyPixelWidth as String] as? CGFloat ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? CGFloat ?? 0

        return CGSize(width: width, height: height)
    }

    private func renderCurrentStateImmediately() async {
        guard let request = await MainActor.run(body: { () -> RenderRequest? in
            guard originalCIImage != nil, viewportSize != .zero else {
                return nil
            }

            nextRenderRequestID += 1
            let request = RenderRequest(id: nextRenderRequestID, adjustments: editingState.adjustments)
            latestRenderRequestID = request.id
            return request
        }) else {
            return
        }

        await applyAdjustmentsAsync(request)
    }

    private func applyAdjustmentsAsync(_ request: RenderRequest) async {
        guard let snapshot = await MainActor.run(body: { () -> RenderSnapshot? in
            guard let originalImage = originalCIImage,
                  viewportSize != .zero,
                  latestRenderRequestID == request.id else {
                return nil
            }

            return RenderSnapshot(
                requestID: request.id,
                originalImage: originalImage,
                viewportSize: viewportSize,
                adjustments: request.adjustments,
                showOriginal: showOriginal
            )
        }) else {
            return
        }

        let outputTask = Task.detached(priority: .userInitiated) {
            Self.renderPreview(from: snapshot)
        }
        let output = await outputTask.value

        await MainActor.run {
            guard latestRenderRequestID == output.requestID else {
                return
            }

            let displayImage = output.cgImage.map {
                NSImage(cgImage: $0, size: output.image.extent.size)
            }

            if !output.showOriginal {
                adjustedCIImage = output.image

                if let displayImage {
                    cachedAdjustedImage = displayImage
                    cachedAdjustments = output.adjustments
                    self.displayImage = displayImage
                }
            } else if let displayImage {
                self.displayImage = displayImage
            }

            commitPreviewImage(output.image)
        }
    }

    // 计算渲染尺寸：预留放大空间，让用户可以放大查看细节
    private nonisolated static func calculateRenderSize(
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        // 计算 aspect-fit 尺寸
        let fitRatio = min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )

        let fitWidth = imageSize.width * fitRatio
        let fitHeight = imageSize.height * fitRatio

        // 预留 3 倍放大空间（用户可以放大到 3x 查看细节）
        // 但不超过原图尺寸
        let renderWidth = min(fitWidth * 3.0, imageSize.width)
        let renderHeight = min(fitHeight * 3.0, imageSize.height)

        return CGSize(width: renderWidth, height: renderHeight)
    }

    // 计算最大允许的缩放倍数（基于 PPI）
    private nonisolated static func calculateMaxScale(
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> CGFloat {
        // 计算 aspect-fit 尺寸
        let fitRatio = min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )

        let fitWidth = imageSize.width * fitRatio

        // 最大放大到图像像素和屏幕像素 1:1
        // 这样保证视网膜屏 PPI 不会低于标准
        let maxScale = imageSize.width / fitWidth

        // 限制在合理范围内（至少 1.0，最多 10.0）
        return max(1.0, min(maxScale, 10.0))
    }

    // 缩放图像到目标显示尺寸
    private nonisolated static func scaleImageToDisplay(_ image: CIImage, targetSize: CGSize) -> CIImage {
        let extent = image.extent
        let scaleX = targetSize.width / extent.width
        let scaleY = targetSize.height / extent.height

        // 如果目标尺寸与原图尺寸非常接近，不缩放
        if abs(scaleX - 1.0) < 0.01 && abs(scaleY - 1.0) < 0.01 {
            return image
        }

        // 使用 Lanczos 缩放算法获得最佳质量
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        return image.transformed(by: transform, highQualityDownsample: true)
    }

    private nonisolated static func renderPreview(from snapshot: RenderSnapshot) -> RenderOutput {
        let renderSize = calculateRenderSize(
            imageSize: snapshot.originalImage.extent.size,
            viewportSize: snapshot.viewportSize
        )
        let scaledImage = scaleImageToDisplay(snapshot.originalImage, targetSize: renderSize)
        let outputImage = snapshot.showOriginal
            ? scaledImage
            : ImageProcessor.applyAdjustments(to: scaledImage, adjustments: snapshot.adjustments)

        return RenderOutput(
            requestID: snapshot.requestID,
            image: outputImage,
            cgImage: ImageProcessor.convertToCGImage(outputImage),
            adjustments: snapshot.adjustments,
            showOriginal: snapshot.showOriginal
        )
    }

    @MainActor
    private func commitPreviewImage(_ image: CIImage) {
        previewCIImage = image
        previewRevision &+= 1
    }

    private func handleColorPick(point: CGPoint, imageSize: CGSize) {
        print("🔵 handleColorPick 被调用: point=\(point), mode=\(whiteBalancePickMode)")

        guard whiteBalancePickMode != .none else {
            print("⚠️ whiteBalancePickMode 是 .none，取消操作")
            return
        }

        guard let originalCIImage else {
            print("⚠️ originalCIImage 是 nil，取消操作")
            return
        }

        guard let pixelInfo = PixelSampler.samplePixelInfo(
            from: originalCIImage,
            point: point,
            imageSize: imageSize,
            sampleSize: 5
        ) else {
            print("⚠️ 原图采样失败，取消操作")
            return
        }

        print(
            "✅ 使用原图采样 pixelInfo: gamma RGB=(\(pixelInfo.gammaRGB.r), \(pixelInfo.gammaRGB.g), \(pixelInfo.gammaRGB.b))"
        )

        // 白平衡取色
        if whiteBalancePickMode == .whiteBalance {
            adjustWhiteBalance(with: pixelInfo)
            // 保持激活状态，允许连续取色
            return
        }

        switch whiteBalancePickMode {
        case .black:
            curvePickSamples.black = pixelInfo
            var updatedAdjustments = editingState.adjustments
            if curvePickSamples.white != nil {
                CurveCalibration.apply(samples: curvePickSamples, to: &updatedAdjustments)
            } else {
                _ = updatedAdjustments.redCurve.addPoint(input: pixelInfo.linearRGB.r, output: 0.0)
                _ = updatedAdjustments.greenCurve.addPoint(input: pixelInfo.linearRGB.g, output: 0.0)
                _ = updatedAdjustments.blueCurve.addPoint(input: pixelInfo.linearRGB.b, output: 0.0)
            }
            editingState.adjustments = updatedAdjustments
        case .gray:
            curvePickSamples.gray = pixelInfo
            var updatedAdjustments = editingState.adjustments
            if curvePickSamples.black != nil, curvePickSamples.white != nil {
                CurveCalibration.apply(samples: curvePickSamples, to: &updatedAdjustments)
            } else {
                _ = updatedAdjustments.redCurve.addPoint(input: pixelInfo.linearRGB.r, output: 0.5)
                _ = updatedAdjustments.greenCurve.addPoint(input: pixelInfo.linearRGB.g, output: 0.5)
                _ = updatedAdjustments.blueCurve.addPoint(input: pixelInfo.linearRGB.b, output: 0.5)
            }
            editingState.adjustments = updatedAdjustments
        case .white:
            curvePickSamples.white = pixelInfo
            var updatedAdjustments = editingState.adjustments
            if curvePickSamples.black != nil {
                CurveCalibration.apply(samples: curvePickSamples, to: &updatedAdjustments)
            } else {
                _ = updatedAdjustments.redCurve.addPoint(input: pixelInfo.linearRGB.r, output: 1.0)
                _ = updatedAdjustments.greenCurve.addPoint(input: pixelInfo.linearRGB.g, output: 1.0)
                _ = updatedAdjustments.blueCurve.addPoint(input: pixelInfo.linearRGB.b, output: 1.0)
            }
            editingState.adjustments = updatedAdjustments
        case .whiteBalance, .none:
            return
        }

        print(
            "✅ 采样\(whiteBalancePickMode == .black ? "黑点" : whiteBalancePickMode == .white ? "白点" : "中灰"): 线性RGB(\(String(format: "%.2f", pixelInfo.linearRGB.r)), \(String(format: "%.2f", pixelInfo.linearRGB.g)), \(String(format: "%.2f", pixelInfo.linearRGB.b)))"
        )
    }

    // 白平衡算法（幂等实现）
    // 使用 gamma RGB 进行白平衡计算
    private func adjustWhiteBalance(with pixelInfo: PixelInfo) {
        let r = pixelInfo.gammaRGB.r
        let g = pixelInfo.gammaRGB.g
        let b = pixelInfo.gammaRGB.b

        // 计算亮度（使用感知亮度公式）
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        // 如果采样点太暗或太亮，不适合做白平衡
        if luminance < 0.05 || luminance > 0.95 {
            print("⚠️ 采样点太暗或太亮，亮度: \(String(format: "%.3f", luminance))")
            return
        }

        // 计算采样点的色温特征（基于 R/B 比例）
        let rbRatio = r / max(b, 0.001)

        // 将 R/B 比例映射到色温（反向校正）
        // rbRatio > 1.0（偏红/偏黄）-> 降低色温让画面变冷
        // rbRatio < 1.0（偏蓝）-> 升高色温让画面变暖
        let baseTemp = AppConfig.defaultWhitePoint
        let tempSensitivity = 2000.0

        let logRatio = log(rbRatio)
        let neutralTemp = baseTemp - (logRatio * tempSensitivity)

        // 计算采样点的色调特征（基于绿色偏差）
        let expectedGreen = (r + b) / 2.0
        let greenDiff = g - expectedGreen

        // 将绿色偏差映射到色调（反向校正）
        // greenDiff > 0（偏绿）-> 添加品红中和（正tint值）
        // greenDiff < 0（偏品红）-> 添加绿色中和（负tint值）
        let tintSensitivity = 150.0
        let neutralTint = (greenDiff / max(luminance, 0.001)) * tintSensitivity

        // 设置绝对值（幂等操作）
        var updatedAdjustments = editingState.adjustments
        updatedAdjustments.temperature = max(2000, min(10000, neutralTemp))
        updatedAdjustments.tint = max(-100, min(100, neutralTint))
        editingState.adjustments = updatedAdjustments

        print(
            "✅ 白平衡取色: GammaRGB(\(String(format: "%.3f", r)), \(String(format: "%.3f", g)), \(String(format: "%.3f", b))) 亮度: \(String(format: "%.3f", luminance))"
        )
        print(
            "  R/B比例: \(String(format: "%.3f", rbRatio)), 对数比例: \(String(format: "%.3f", logRatio))"
        )
        print(
            "  绿色偏差: \(String(format: "%.3f", greenDiff)), 期望绿色: \(String(format: "%.3f", expectedGreen))"
        )
        print(
            "  Neutral色温: \(Int(updatedAdjustments.temperature))K, Neutral色调: \(String(format: "%.1f", updatedAdjustments.tint))"
        )
    }

    private func undo() {
        session.undo()
    }

    private func redo() {
        session.redo()
    }

    /// 执行实际的渲染操作（由渲染队列调用）
    private func performRender(_ request: RenderRequest) async {
        await applyAdjustmentsAsync(request)
    }

    @MainActor
    private func enqueueRender(_ adjustments: ImageAdjustments) {
        nextRenderRequestID += 1
        let request = RenderRequest(id: nextRenderRequestID, adjustments: adjustments)
        latestRenderRequestID = request.id

        Task {
            await renderQueue?.enqueue(request)
        }
    }

    @ViewBuilder
    private func buildImageView() -> some View {
        GeometryReader { geometry in
            if isLoading {
                ProgressView("加载中...")
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = displayImage {
                let maxScale = originalCIImage.map { original in
                    Self.calculateMaxScale(
                        imageSize: original.extent.size,
                        viewportSize: geometry.size
                    )
                } ?? 10.0

                ClickableImageView(
                    image: image,
                    scale: $scale,
                    maxScale: maxScale,
                    currentPixelInfo: $currentPixelInfo,
                    originalCIImage: originalCIImage,
                    adjustedCIImage: adjustedCIImage,
                    pickMode: whiteBalancePickMode,
                    onColorPick: whiteBalancePickMode != .none ? handleColorPick : nil,
                    onFilesDrop: onFilesDrop
                )
                .clipped()
                .id(displayImageID) // 使用 displayImageID 强制刷新
            } else {
                Text("无法加载图像")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: viewportSize) { _, newSize in
            // 视口尺寸变化时，重新渲染（使用当前调整）
            if newSize != .zero {
                enqueueRender(editingState.adjustments)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewportSize = geo.size
                    }
                    .onChange(of: geo.size) { _, newSize in
                        viewportSize = newSize
                    }
            }
        )
    }

    @ViewBuilder
    private func buildImageInfoBar() -> some View {
        ImageInfoBar(
            imageInfo: imageInfo,
            scale: scale,
            adjustments: $editingState.adjustments,
            curvePickSamples: $curvePickSamples,
            showAdjustmentPanel: $showAdjustmentPanel,
            showOriginal: $showOriginal,
            pixelInfo: currentPixelInfo
        )
    }

    private func cancelWhiteBalancePickMode() {
        guard whiteBalancePickMode == .whiteBalance else { return }
        whiteBalancePickMode = .none
        currentPixelInfo = nil
    }
}

struct ImageInfoBar: View {
    let imageInfo: ImageInfo
    let scale: CGFloat
    @Binding var adjustments: ImageAdjustments
    @Binding var curvePickSamples: CurvePickSamples
    @Binding var showAdjustmentPanel: Bool
    @Binding var showOriginal: Bool
    let pixelInfo: PixelInfo?

    var body: some View {
        HStack(spacing: 12) {
            Text(imageInfo.filename)
                .font(.caption)
                .foregroundColor(.secondary)

            // 固定占位,避免高度变化
            Divider()
                .frame(height: 16)

            HStack(spacing: 6) {
                // 颜色预览方格 - 始终占位
                Rectangle()
                    .fill(pixelInfo.map { info in
                        Color(
                            red: info.gammaRGB.r,
                            green: info.gammaRGB.g,
                            blue: info.gammaRGB.b
                        )
                    } ?? Color.clear)
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .opacity(pixelInfo == nil ? 0.3 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pixelInfo.map { "RGB: \(formatRGB($0.gammaRGB))" } ?? "RGB: ---")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .opacity(pixelInfo == nil ? 0.5 : 1.0)
                    Text(pixelInfo.map { "原始: \(formatRGB($0.linearRGB))" } ?? "原始: ---")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .opacity(pixelInfo == nil ? 0.5 : 1.0)
                }
                .frame(minWidth: 120, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pixelInfo.map { "H:\(formatValue($0.hsl.h, decimals: 0))°" } ?? "H:---°")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .opacity(pixelInfo == nil ? 0.5 : 1.0)
                    Text(pixelInfo
                        .map {
                            "S:\(formatValue($0.hsl.s, decimals: 0))% L:\(formatValue($0.hsl.l, decimals: 0))%"
                        } ?? "S:---% L:---%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .opacity(pixelInfo == nil ? 0.5 : 1.0)
                }
                .frame(minWidth: 100, alignment: .leading)
            }

            Spacer()

            // Before/After 切换按钮
            Button(action: {
                showOriginal.toggle()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: showOriginal ? "eye.slash" : "eye")
                        .font(.caption)
                    Text(showOriginal ? "调整" : "原图")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .help(showOriginal ? "显示调整效果 (\\\\)" : "显示原图 (\\\\)")
            .keyboardShortcut("\\", modifiers: [])

            Spacer()
                .frame(width: 8)

            // 重置按钮
            Button(action: {
                var newAdj = ImageAdjustments.default
                // 保留变换设置
                newAdj.rotation = adjustments.rotation
                newAdj.flipHorizontal = adjustments.flipHorizontal
                newAdj.flipVertical = adjustments.flipVertical
                adjustments = newAdj
                curvePickSamples.reset()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                    Text("重置")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .help("重置所有调整")
            .disabled(!adjustments.hasAdjustments)

            Spacer()
                .frame(width: 16)

            // 变换按钮组
            HStack(spacing: 4) {
                Button(action: {
                    adjustments.rotation = (adjustments.rotation + 90) % 360
                }) {
                    Image(systemName: "rotate.left")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("向左旋转90° (⌘[)")
                .keyboardShortcut("[", modifiers: .command)

                Spacer()
                    .frame(width: 8)

                Button(action: {
                    adjustments.rotation = (adjustments.rotation - 90 + 360) % 360
                }) {
                    Image(systemName: "rotate.right")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("向右旋转90° (⌘])")
                .keyboardShortcut("]", modifiers: .command)

                Spacer()
                    .frame(width: 16)

                Button(action: {
                    adjustments.flipHorizontal.toggle()
                }) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.body)
                        .foregroundColor(adjustments.flipHorizontal ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .help("水平镜像")

                Spacer()
                    .frame(width: 8)

                Button(action: {
                    adjustments.flipVertical.toggle()
                }) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.body)
                        .foregroundColor(adjustments.flipVertical ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .help("垂直镜像")
            }

            Divider()
                .frame(height: 16)

            if let size = imageInfo.dimensions {
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let colorSpace = imageInfo.colorSpace {
                Text(colorSpace)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
            }

            if let profile = imageInfo.colorProfile {
                Text(profile)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
            }

            Text(String(format: "%.0f%%", scale * 100))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(minWidth: 50, alignment: .trailing)

            Button(action: { showAdjustmentPanel.toggle() }) {
                Image(systemName: showAdjustmentPanel ? "sidebar.right" : "sidebar.left")
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .help(showAdjustmentPanel ? "隐藏调整面板" : "显示调整面板")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func formatRGB(_ rgb: (r: Double, g: Double, b: Double)) -> String {
        let r = Int(rgb.r * 255)
        let g = Int(rgb.g * 255)
        let b = Int(rgb.b * 255)
        return "\(r), \(g), \(b)"
    }

    private func formatValue(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
