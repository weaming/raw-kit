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
    let imageInfo: ImageInfo
    let savedAdjustments: ImageAdjustments?
    @Binding var sidebarWidth: CGFloat
    let onAdjustmentsChanged: (ImageAdjustments) -> Void
    @ObservedObject var history: AdjustmentHistory

    @State private var originalCIImage: CIImage?
    @State private var adjustedCIImage: CIImage?
    @State private var displayImage: NSImage?
    @State private var displayImageID = UUID() // 用于强制刷新视图
    @State private var isLoading = true
    @State private var loadingStage: LoadingStage = .thumbnail
    @State private var scale: CGFloat = 1.0
    @State private var adjustments = ImageAdjustments.default  // 面板 UI 使用（立即更新）
    @State private var showAdjustmentPanel = true
    @State private var whiteBalancePickMode: CurveAdjustmentView.PickMode = .none
    @State private var isUpdatingFromHistory = false
    @State private var currentPixelInfo: PixelInfo?
    @State private var viewportSize: CGSize = .zero

    // 渲染队列（延迟初始化）
    @State private var renderQueue: RenderQueue?

    enum LoadingStage {
        case thumbnail
        case mediumResolution
        case fullResolution
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
                    adjustments: $adjustments,
                    originalCIImage: originalCIImage,
                    adjustedCIImage: adjustedCIImage ?? originalCIImage,
                    width: $sidebarWidth,
                    whiteBalancePickMode: $whiteBalancePickMode
                )
                .equatable()
            }
        }
        .task {
            // 初始化渲染队列（maxFPS: 0 = 不限制，30 = 30fps，60 = 60fps）
            if renderQueue == nil {
                renderQueue = RenderQueue(maxFPS: 0) { adjustments in
                    await self.performRender(adjustments)
                }
            }

            if let saved = savedAdjustments {
                adjustments = saved
            } else {
                // RAW 文件在加载时已经应用了 As Shot 白平衡，
                // 所以初始调整应该是中性的（6500K/0 tint）
                // 不需要再从 EXIF 读取和设置白平衡
                print("ImageDetailView: 使用默认白平衡（RAW 已应用 As Shot）")
            }
            await loadImageProgressively()
        }
        .onChange(of: adjustments) { _, newValue in
            // 1. 立即更新历史记录和回调（不阻塞 UI）
            if !isUpdatingFromHistory {
                history.recordImmediate(newValue)
            }
            onAdjustmentsChanged(newValue)

            // 2. 将调整参数加入渲染队列
            Task {
                await renderQueue?.enqueue(newValue)
            }
        }
        .onChange(of: savedAdjustments) { _, newValue in
            if let newValue, newValue != adjustments {
                Task { @MainActor in
                    isUpdatingFromHistory = true
                    adjustments = newValue
                    isUpdatingFromHistory = false
                }
            }
        }
        .focusedSceneValue(\.undoAction, history.canUndo ? undo : nil)
        .focusedSceneValue(\.redoAction, history.canRedo ? redo : nil)
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
                // 等待视口尺寸可用，然后缩放到显示尺寸
                await waitForViewportSize()
                await displayScaledImage(fullImage)
                displayImageID = UUID()
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
            // 缩放到显示尺寸
            await displayScaledImage(fullImage)
            displayImageID = UUID()
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

    // 缩放并显示图像（初次加载时使用）
    private func displayScaledImage(_ image: CIImage) async {
        guard viewportSize != .zero else {
            // 如果视口尺寸还不可用，暂时显示原图
            await renderAndUpdateImage(image)
            return
        }

        // 计算渲染尺寸（预留放大空间）
        let renderSize = calculateRenderSize(
            imageSize: image.extent.size,
            viewportSize: viewportSize
        )

        // 缩放到渲染尺寸
        let scaledImage = scaleImageToDisplay(image, targetSize: renderSize)
        adjustedCIImage = scaledImage

        // 在后台线程渲染，不阻塞主线程
        await renderAndUpdateImage(scaledImage)
    }

    // 辅助函数：在后台渲染并更新 UI
    private func renderAndUpdateImage(_ image: CIImage) async {
        // 使用 CGImage 作为中间格式（Sendable）来避免跨线程传递 NSImage
        let cgImage = await Task.detached(priority: .userInitiated) {
            // 在后台线程渲染为 CGImage
            ImageProcessor.convertToCGImage(image)
        }.value

        // 在主线程从 CGImage 创建 NSImage
        if let cgImage = cgImage {
            displayImage = NSImage(cgImage: cgImage, size: image.extent.size)
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

    private func applyAdjustmentsSync(_ adj: ImageAdjustments, startTime: CFAbsoluteTime) {
        guard let original = originalCIImage else { return }
        guard viewportSize != .zero else { return }

        // 计算渲染尺寸（预留放大空间，但不超过原图）
        let renderSize = calculateRenderSize(
            imageSize: original.extent.size,
            viewportSize: viewportSize
        )

        // 先缩放到渲染尺寸
        let scaledImage = scaleImageToDisplay(original, targetSize: renderSize)

        // 在缩放后的图像上应用调整（Core Image 惰性计算，这里立即返回）
        let adjusted = ImageProcessor.applyAdjustments(to: scaledImage, adjustments: adj)
        adjustedCIImage = adjusted

        let filterTime = CFAbsoluteTimeGetCurrent()
        print("⏱️ 滤镜构建耗时: \(Int((filterTime - startTime) * 1000))ms")

        // 异步渲染，不阻塞主线程
        Task.detached(priority: .userInitiated) {
            let renderStartTime = CFAbsoluteTimeGetCurrent()
            // 渲染为 CGImage（可以安全地跨线程传递）
            let cgImage = ImageProcessor.convertToCGImage(adjusted)
            let renderTime = CFAbsoluteTimeGetCurrent()
            print("⏱️ 渲染耗时: \(Int((renderTime - renderStartTime) * 1000))ms")

            let beforeUpdate = CFAbsoluteTimeGetCurrent()

            // 在主线程从 CGImage 创建 NSImage 并更新
            await MainActor.run {
                let dispatchTime = CFAbsoluteTimeGetCurrent()
                print("⏱️ MainActor 调度延迟: \(Int((dispatchTime - beforeUpdate) * 1000))ms")

                if let cgImage = cgImage {
                    self.displayImage = NSImage(cgImage: cgImage, size: adjusted.extent.size)
                }

                let totalTime = CFAbsoluteTimeGetCurrent()
                print("⏱️ 总耗时: \(Int((totalTime - startTime) * 1000))ms\n")
            }
        }
    }

    private func applyAdjustments(_ adj: ImageAdjustments) async {
        let startTime = CFAbsoluteTimeGetCurrent()
        applyAdjustmentsSync(adj, startTime: startTime)
    }

    private func applyAdjustmentsAsync(_ adj: ImageAdjustments) async {
        // 在 MainActor 上获取必要的数据
        let (original, viewport) = await MainActor.run {
            (originalCIImage, viewportSize)
        }

        guard let original = original else { return }
        guard viewport != .zero else { return }

        // 计算渲染尺寸（预留放大空间，但不超过原图）
        let renderSize = calculateRenderSize(
            imageSize: original.extent.size,
            viewportSize: viewport
        )

        // 先缩放到渲染尺寸
        let scaledImage = scaleImageToDisplay(original, targetSize: renderSize)

        // 在缩放后的图像上应用调整（Core Image 惰性计算，这里立即返回）
        let adjusted = ImageProcessor.applyAdjustments(to: scaledImage, adjustments: adj)
        let imageSize = adjusted.extent.size

        // 在后台线程渲染为 CGImage（Sendable）
        let cgImage = await Task.detached(priority: .userInitiated) {
            ImageProcessor.convertToCGImage(adjusted)
        }.value

        // 在主线程更新状态
        await MainActor.run {
            adjustedCIImage = adjusted
            if let cgImage = cgImage {
                displayImage = NSImage(cgImage: cgImage, size: imageSize)
            }
        }
    }

    // 计算渲染尺寸：预留放大空间，让用户可以放大查看细节
    private nonisolated func calculateRenderSize(
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
    nonisolated func calculateMaxScale(
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
    private nonisolated func scaleImageToDisplay(_ image: CIImage, targetSize: CGSize) -> CIImage {
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

    private func handleColorPick(point: CGPoint, imageSize _: CGSize) {
        print("🔵 handleColorPick 被调用: point=\(point), mode=\(whiteBalancePickMode)")

        // 直接使用状态栏已经计算好的颜色信息
        guard whiteBalancePickMode != .none else {
            print("⚠️ whiteBalancePickMode 是 .none，取消操作")
            return
        }

        guard let pixelInfo = currentPixelInfo else {
            print("⚠️ currentPixelInfo 是 nil，取消操作")
            return
        }

        print(
            "✅ 使用 pixelInfo: gamma RGB=(\(pixelInfo.gammaRGB.r), \(pixelInfo.gammaRGB.g), \(pixelInfo.gammaRGB.b))"
        )

        // 白平衡取色
        if whiteBalancePickMode == .whiteBalance {
            adjustWhiteBalance(with: pixelInfo)
            // 保持激活状态，允许连续取色
            return
        }

        // 三点校色使用原始线性 RGB（从原始图片采样）
        let r = pixelInfo.linearRGB.r
        let g = pixelInfo.linearRGB.g
        let b = pixelInfo.linearRGB.b

        // 根据采样模式设置输出值
        let outputValue: Double
        switch whiteBalancePickMode {
        case .black:
            outputValue = 0.0
        case .gray:
            outputValue = 0.5
        case .white:
            outputValue = 1.0
        case .whiteBalance, .none:
            return
        }

        // 黑白灰采样只调整 R、G、B 三个独立通道
        _ = adjustments.redCurve.addPoint(input: r, output: outputValue)
        _ = adjustments.greenCurve.addPoint(input: g, output: outputValue)
        _ = adjustments.blueCurve.addPoint(input: b, output: outputValue)

        print(
            "✅ 采样\(whiteBalancePickMode == .black ? "黑点" : whiteBalancePickMode == .white ? "白点" : "中灰"): 线性RGB(\(String(format: "%.2f", r)), \(String(format: "%.2f", g)), \(String(format: "%.2f", b)))"
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
        adjustments.temperature = max(2000, min(10000, neutralTemp))
        adjustments.tint = max(-100, min(100, neutralTint))

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
            "  Neutral色温: \(Int(adjustments.temperature))K, Neutral色调: \(String(format: "%.1f", adjustments.tint))"
        )
    }

    private func undo() {
        guard let previousAdjustments = history.undo() else { return }
        isUpdatingFromHistory = true
        adjustments = previousAdjustments
        isUpdatingFromHistory = false
    }

    private func redo() {
        guard let nextAdjustments = history.redo() else { return }
        isUpdatingFromHistory = true
        adjustments = nextAdjustments
        isUpdatingFromHistory = false
    }

    /// 执行实际的渲染操作（由渲染队列调用）
    private func performRender(_ adj: ImageAdjustments) async {
        await applyAdjustmentsAsync(adj)
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
                    calculateMaxScale(
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
                    onColorPick: whiteBalancePickMode != .none ? handleColorPick : nil
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
                Task {
                    await renderQueue?.enqueue(adjustments)
                }
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
            adjustments: $adjustments,
            showAdjustmentPanel: $showAdjustmentPanel,
            pixelInfo: currentPixelInfo
        )
    }
}

struct ImageInfoBar: View {
    let imageInfo: ImageInfo
    let scale: CGFloat
    @Binding var adjustments: ImageAdjustments
    @Binding var showAdjustmentPanel: Bool
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

            // 重置按钮
            Button(action: {
                var newAdj = ImageAdjustments.default
                // 保留变换设置
                newAdj.rotation = adjustments.rotation
                newAdj.flipHorizontal = adjustments.flipHorizontal
                newAdj.flipVertical = adjustments.flipVertical
                adjustments = newAdj
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
