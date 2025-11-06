import CoreImage
import SwiftUI

struct ImageDetailView: View {
    let imageInfo: ImageInfo
    let savedAdjustments: ImageAdjustments?
    @Binding var sidebarWidth: CGFloat
    let onAdjustmentsChanged: (ImageAdjustments) -> Void

    @State private var originalCIImage: CIImage?
    @State private var displayImage: NSImage?
    @State private var isLoading = true
    @State private var loadingStage: LoadingStage = .thumbnail
    @State private var scale: CGFloat = 1.0
    @State private var adjustments = ImageAdjustments.default
    @State private var showAdjustmentPanel = true
    @State private var whiteBalancePickMode: CurveAdjustmentView.PickMode = .none

    enum LoadingStage {
        case thumbnail
        case mediumResolution
        case fullResolution
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("加载中...")
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = displayImage {
                    ClickableImageView(
                        image: image,
                        scale: $scale,
                        onColorPick: whiteBalancePickMode != .none ? handleColorPick : nil
                    )
                    .clipped()
                } else {
                    Text("无法加载图像")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ImageInfoBar(
                    imageInfo: imageInfo,
                    scale: scale,
                    adjustments: $adjustments,
                    showAdjustmentPanel: $showAdjustmentPanel
                )
            }
            .clipped()

            if showAdjustmentPanel {
                Divider()
                ResizableAdjustmentPanel(
                    adjustments: $adjustments,
                    ciImage: originalCIImage,
                    width: $sidebarWidth,
                    whiteBalancePickMode: $whiteBalancePickMode
                )
            }
        }
        .task {
            if let saved = savedAdjustments {
                adjustments = saved
            }
            await loadImageProgressively()
        }
        .onChange(of: adjustments) { _, newValue in
            onAdjustmentsChanged(newValue)
            Task {
                await applyAdjustments(newValue)
            }
        }
    }

    private func loadImageProgressively() async {
        loadingStage = .thumbnail

        if let thumbnail = ImageProcessor.loadThumbnail(from: imageInfo.url) {
            displayImage = ImageProcessor.convertToNSImage(thumbnail)
            isLoading = false
        }

        loadingStage = .mediumResolution
        await Task.yield()

        if let mediumImage = ImageProcessor.loadMediumResolution(from: imageInfo.url) {
            originalCIImage = mediumImage
            displayImage = ImageProcessor.convertToNSImage(mediumImage)
        }

        loadingStage = .fullResolution
        await Task.yield()

        if let fullImage = await ImageProcessor.loadCIImage(from: imageInfo.url) {
            originalCIImage = fullImage
            displayImage = ImageProcessor.convertToNSImage(fullImage)
        }

        isLoading = false
    }

    private func applyAdjustments(_ adj: ImageAdjustments) async {
        guard let original = originalCIImage else { return }

        let adjusted = ImageProcessor.applyAdjustments(to: original, adjustments: adj)
        displayImage = ImageProcessor.convertToNSImage(adjusted)
    }

    private func handleColorPick(point: CGPoint, imageSize: CGSize) {
        guard whiteBalancePickMode != .none, let ciImage = originalCIImage else { return }

        // 白平衡取色：为了实现幂等操作，始终从原始图片采样
        // 曲线采样：也使用原始图片
        let color = getColor(at: point, from: ciImage, displaySize: imageSize)

        // 白平衡取色
        if whiteBalancePickMode == .whiteBalance {
            adjustWhiteBalance(with: color)
            // 保持激活状态，允许连续取色
            return
        }

        // 将颜色转换为 RGB 值
        let r = Double(color.redComponent)
        let g = Double(color.greenComponent)
        let b = Double(color.blueComponent)
        let avg = (r + g + b) / 3.0

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

        // 添加曲线点（这里暂时只添加到 RGB 曲线，实际应该根据当前选择的通道）
        _ = adjustments.rgbCurve.addPoint(input: avg, output: outputValue)
        _ = adjustments.redCurve.addPoint(input: r, output: outputValue)
        _ = adjustments.greenCurve.addPoint(input: g, output: outputValue)
        _ = adjustments.blueCurve.addPoint(input: b, output: outputValue)
        _ = adjustments.luminanceCurve.addPoint(input: avg, output: outputValue)

        print(
            "采样\(whiteBalancePickMode == .black ? "黑点" : whiteBalancePickMode == .white ? "白点" : "中灰"): RGB(\(String(format: "%.2f", r)), \(String(format: "%.2f", g)), \(String(format: "%.2f", b)))"
        )
    }

    // 白平衡算法（幂等实现）
    // CITemperatureAndTint 正确理解：
    // neutral: "在这个色温/色调下，图片看起来是中性的"
    // targetNeutral: "希望在这个色温/色调下，图片看起来是中性的"
    //
    // 白平衡逻辑（反向思维）：
    // 1. 点击偏黄的区域（应该是中性灰）
    // 2. 说："在更高的色温下，图片才看起来中性"
    // 3. 滤镜会降低色温来补偿
    // 4. 结果：偏黄的区域变成中性灰
    private func adjustWhiteBalance(with color: NSColor) {
        let r = Double(color.redComponent)
        let g = Double(color.greenComponent)
        let b = Double(color.blueComponent)

        // 计算亮度（使用感知亮度公式）
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        // 如果采样点太暗或太亮，不适合做白平衡
        if luminance < 0.05 || luminance > 0.95 {
            return
        }

        // 计算采样点的色温特征（基于 R/B 比例）
        let rbRatio = r / max(b, 0.001)

        // 将 R/B 比例映射到 neutral 色温（反向逻辑）
        // rbRatio > 1.0（偏红/偏黄）-> 需要设置更高的 neutral 色温 -> 滤镜会降温加蓝
        // rbRatio < 1.0（偏蓝）-> 需要设置更低的 neutral 色温 -> 滤镜会升温加红
        let baseTemp = 6500.0
        let tempSensitivity = 2000.0

        let logRatio = log(rbRatio)
        // 反向：采样点偏红时，设置更高的 neutral
        let neutralTemp = baseTemp + (logRatio * tempSensitivity)

        // 计算采样点的色调特征（基于绿色偏差）
        let expectedGreen = (r + b) / 2.0
        let greenDiff = g - expectedGreen

        // 将绿色偏差映射到 neutral 色调（反向逻辑）
        // greenDiff > 0（偏绿）-> 需要设置更高的 neutral 色调 -> 滤镜会加品红
        // greenDiff < 0（偏品红）-> 需要设置更低的 neutral 色调 -> 滤镜会加绿
        let tintSensitivity = 150.0
        // 反向：采样点偏绿时，设置更高的 neutral
        let neutralTint = (greenDiff / max(luminance, 0.001)) * tintSensitivity

        // 设置绝对值（幂等操作）
        adjustments.temperature = max(2000, min(10000, neutralTemp))
        adjustments.tint = max(-100, min(100, neutralTint))

        print(
            "白平衡取色: RGB(\(String(format: "%.3f", r)), \(String(format: "%.3f", g)), \(String(format: "%.3f", b))) 亮度: \(String(format: "%.3f", luminance))"
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

    private func getColor(at point: CGPoint, from ciImage: CIImage,
                          displaySize: CGSize) -> NSColor
    {
        // 将显示坐标转换为图片坐标
        let extent = ciImage.extent
        let x = extent.origin.x + (point.x / displaySize.width) * extent.width
        let y = extent.origin.y + (extent.height - (point.y / displaySize.height) * extent.height)

        // 采样 5x5 区域求平均（更大的区域更稳定）
        let sampleSize: CGFloat = 5
        let sampleRect = CGRect(
            x: x - sampleSize / 2,
            y: y - sampleSize / 2,
            width: sampleSize,
            height: sampleSize
        )

        // 确保采样区域在图片范围内
        let clampedRect = sampleRect.intersection(extent)
        guard !clampedRect.isEmpty else {
            return NSColor.gray
        }

        var bitmap = [UInt8](repeating: 0, count: 4)

        // 创建 1x1 的采样图像
        if let averaged = ciImage.cropped(to: clampedRect)
            .applyingFilter(
                "CIAreaAverage",
                parameters: [kCIInputExtentKey: CIVector(cgRect: clampedRect)]
            ) as CIImage?
        {
            // 使用共享的 CIContext 进行渲染，避免 Metal 锁冲突
            let cgImage = ImageProcessor.convertToCGImage(averaged)
            if let cgImage {
                let bitmapContext = CGContext(
                    data: &bitmap,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                bitmapContext?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }

        return NSColor(
            red: CGFloat(bitmap[0]) / 255.0,
            green: CGFloat(bitmap[1]) / 255.0,
            blue: CGFloat(bitmap[2]) / 255.0,
            alpha: 1.0
        )
    }
}

struct ImageInfoBar: View {
    let imageInfo: ImageInfo
    let scale: CGFloat
    @Binding var adjustments: ImageAdjustments
    @Binding var showAdjustmentPanel: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(imageInfo.filename)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

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
}
