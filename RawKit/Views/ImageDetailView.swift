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
    @State private var adjustments = ImageAdjustments.default
    @State private var showAdjustmentPanel = true
    @State private var whiteBalancePickMode: CurveAdjustmentView.PickMode = .none
    @State private var isUpdatingFromHistory = false
    @State private var currentPixelInfo: PixelInfo?

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
            }
        }
        .task {
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
            if !isUpdatingFromHistory {
                history.recordImmediate(newValue)
            }
            onAdjustmentsChanged(newValue)
            Task {
                await applyAdjustments(newValue)
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
        loadingStage = .thumbnail

        if let thumbnail = ImageProcessor.loadThumbnail(from: imageInfo.url) {
            displayImage = ImageProcessor.convertToNSImage(thumbnail)
            displayImageID = UUID()
            isLoading = false
        }

        loadingStage = .mediumResolution
        await Task.yield()

        if let mediumImage = ImageProcessor.loadMediumResolution(from: imageInfo.url) {
            originalCIImage = mediumImage
            displayImage = ImageProcessor.convertToNSImage(mediumImage)
            displayImageID = UUID()
        }

        loadingStage = .fullResolution
        await Task.yield()

        if let fullImage = await ImageProcessor.loadCIImage(from: imageInfo.url) {
            originalCIImage = fullImage
            displayImage = ImageProcessor.convertToNSImage(fullImage)
            displayImageID = UUID()
        }

        isLoading = false
    }

    private func applyAdjustments(_ adj: ImageAdjustments) async {
        guard let original = originalCIImage else { return }

        let adjusted = ImageProcessor.applyAdjustments(to: original, adjustments: adj)
        adjustedCIImage = adjusted

        let newDisplayImage = ImageProcessor.convertToNSImage(adjusted)
        displayImage = newDisplayImage
        // 不更新 displayImageID，避免重置视口缩放
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

    @ViewBuilder
    private func buildImageView() -> some View {
        if isLoading {
            ProgressView("加载中...")
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let image = displayImage {
            ClickableImageView(
                image: image,
                scale: $scale,
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
