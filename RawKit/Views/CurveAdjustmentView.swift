import AppKit
import SwiftUI

// 曲线调整视图
// 包含通道选择、三点采样（黑/灰/白）和曲线编辑器
struct CurveAdjustmentView: View {
    @Binding var adjustments: ImageAdjustments
    let ciImage: CIImage?
    @Binding var pickMode: PickMode

    @State private var blackPoint: NSColor?
    @State private var whitePoint: NSColor?
    @State private var grayPoint: NSColor?
    @State private var selectedChannel: CurveAdjustment.Channel = .rgb
    @State private var autoLevelClipPercent: Double = 0.001
    @State private var isEditingClipPercent: Bool = false
    @FocusState private var isClipPercentFocused: Bool

    enum PickMode: Equatable {
        case none
        case black
        case white
        case gray
        case whiteBalance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("曲线调整")
                .font(.headline)
                .padding(.horizontal, 16)

            Picker("通道", selection: $selectedChannel) {
                Text("RGB").tag(CurveAdjustment.Channel.rgb)
                Text("红色").tag(CurveAdjustment.Channel.red)
                Text("绿色").tag(CurveAdjustment.Channel.green)
                Text("蓝色").tag(CurveAdjustment.Channel.blue)
                Text("亮度").tag(CurveAdjustment.Channel.luminance)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: {
                        isEditingClipPercent = false
                        applyAutoLevels()
                    }) {
                        Text("自动色阶")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .help("基于直方图的自动色阶调整")

                    if isEditingClipPercent {
                        TextField("", value: $autoLevelClipPercent, format: .number)
                            .frame(width: 50)
                            .textFieldStyle(.roundedBorder)
                            .focused($isClipPercentFocused)
                            .onSubmit {
                                // 回车后切换回文本显示
                                isEditingClipPercent = false
                                isClipPercentFocused = false
                            }
                            .onChange(of: isClipPercentFocused) { _, isFocused in
                                // 失去焦点时切换回文本显示
                                if !isFocused {
                                    isEditingClipPercent = false
                                }
                            }
                            .onAppear {
                                // 切换到编辑模式时自动聚焦
                                isClipPercentFocused = true
                            }
                    } else {
                        Text(String(format: "%.3f", autoLevelClipPercent))
                            .font(.caption)
                            .frame(width: 50)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                            .onTapGesture {
                                isEditingClipPercent = true
                            }
                            .help("点击编辑色阶保护百分比")
                    }

                    Text("%")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: resetCurve) {
                        Text("重置")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasCurveAdjustments)
                }

                HStack(spacing: 8) {
                    Button(action: {
                        pickMode = pickMode == .black ? .none : .black
                    }) {
                        Circle()
                            .fill(blackPoint != nil ? Color(blackPoint!) : Color.black)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(
                                        pickMode == .black ? Color.blue : Color.gray.opacity(0.3),
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("黑点")

                    Button(action: {
                        pickMode = pickMode == .gray ? .none : .gray
                    }) {
                        Circle()
                            .fill(grayPoint != nil ? Color(grayPoint!) : Color.gray)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(
                                        pickMode == .gray ? Color.blue : Color.gray.opacity(0.3),
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("中灰")

                    Button(action: {
                        pickMode = pickMode == .white ? .none : .white
                    }) {
                        Circle()
                            .fill(whitePoint != nil ? Color(whitePoint!) : Color.white)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(
                                        pickMode == .white ? Color.blue : Color.gray.opacity(0.3),
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("白点")

                    Spacer()
                }
            }
            .padding(.horizontal, 16)

            if pickMode == .black || pickMode == .white || pickMode == .gray {
                Text("点击图片选取\(pickMode == .black ? "黑" : pickMode == .white ? "白" : "中灰")点")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 16)
            }

            switch selectedChannel {
            case .rgb:
                InteractiveCurveView(
                    curve: $adjustments.rgbCurve,
                    channel: .rgb,
                    referenceCurves: [
                        .red: adjustments.redCurve,
                        .green: adjustments.greenCurve,
                        .blue: adjustments.blueCurve,
                    ]
                )
                .padding(.top, 8)
            case .red:
                InteractiveCurveView(
                    curve: $adjustments.redCurve,
                    channel: .red
                )
                .padding(.top, 8)
            case .green:
                InteractiveCurveView(
                    curve: $adjustments.greenCurve,
                    channel: .green
                )
                .padding(.top, 8)
            case .blue:
                InteractiveCurveView(
                    curve: $adjustments.blueCurve,
                    channel: .blue
                )
                .padding(.top, 8)
            case .luminance:
                InteractiveCurveView(
                    curve: $adjustments.luminanceCurve,
                    channel: .luminance
                )
                .padding(.top, 8)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    func handleColorPick(at point: CGPoint, in imageSize: CGSize) {
        guard pickMode != .none, let ciImage else { return }

        let color = getColor(at: point, from: ciImage, imageSize: imageSize)

        switch pickMode {
        case .black:
            blackPoint = color
            calculateCurve()
        case .white:
            whitePoint = color
            calculateCurve()
        case .gray:
            grayPoint = color
            calculateCurve()
        case .whiteBalance:
            // 白平衡取色由 ImageDetailView 处理
            // 这里不应该处理，因为曲线调整不能直接修改色温色调
            break
        case .none:
            break
        }
    }

    private func getColor(at point: CGPoint, from ciImage: CIImage, imageSize: CGSize) -> NSColor {
        // 将视图坐标转换为图片坐标
        let extent = ciImage.extent
        let x = extent.origin.x + (point.x / imageSize.width) * extent.width
        let y = extent.origin.y + (extent.height - (point.y / imageSize.height) * extent.height)

        // 采样 5x5 区域求平均
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

        var bitmap = [UInt16](repeating: 0, count: 4)

        // 创建 1x1 的采样图像，使用 16 位精度
        if let averaged = ciImage.cropped(to: clampedRect)
            .applyingFilter(
                "CIAreaAverage",
                parameters: [kCIInputExtentKey: CIVector(cgRect: clampedRect)]
            ) as CIImage? {
            let context = CIContext(options: [.workingColorSpace: NSNull()])
            context.render(
                averaged,
                toBitmap: &bitmap,
                rowBytes: 4 * MemoryLayout<UInt16>.size,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA16,
                colorSpace: nil
            )
        }

        // 将 16 位线性值转换为 gamma 空间（sRGB gamma 2.2）
        let linearR = Double(bitmap[0]) / 65535.0
        let linearG = Double(bitmap[1]) / 65535.0
        let linearB = Double(bitmap[2]) / 65535.0

        // 应用 gamma 2.2 转换
        let gammaR = linearToGamma(linearR)
        let gammaG = linearToGamma(linearG)
        let gammaB = linearToGamma(linearB)

        return NSColor(
            red: CGFloat(gammaR),
            green: CGFloat(gammaG),
            blue: CGFloat(gammaB),
            alpha: 1.0
        )
    }

    // 线性空间到 gamma 空间转换（sRGB gamma 2.2）
    private func linearToGamma(_ linear: Double) -> Double {
        if linear <= 0.0031308 {
            linear * 12.92
        } else {
            1.055 * pow(linear, 1.0 / 2.2) - 0.055
        }
    }

    // 检查是否有曲线调整
    private var hasCurveAdjustments: Bool {
        blackPoint != nil || whitePoint != nil || grayPoint != nil ||
            adjustments.rgbCurve.hasPoints ||
            adjustments.redCurve.hasPoints ||
            adjustments.greenCurve.hasPoints ||
            adjustments.blueCurve.hasPoints ||
            adjustments.luminanceCurve.hasPoints
    }

    // 三点定标法（Three-Point Calibration）
    // 专业图像校正的标准方法
    //
    // 原理：
    // 1. 黑场/白场：拉伸亮度范围，增强对比度
    //    新值 = (原值 - 黑场) × 255 / (白场 - 黑场)
    //
    // 2. 灰场：校正色偏
    //    - 找到应该是中性灰的点
    //    - 测量其 RGB 值，如果不相等说明有色偏
    //    - 调整各通道使其变为 R=G=B
    //
    // 3. 裁剪保护：黑场映射到 0.5%，白场映射到 99.5%
    //    避免极端值导致整体过暗/过亮
    private func calculateCurve() {
        let blackRGB = blackPoint.map {
            (r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent))
        }
        let grayRGB = grayPoint.map {
            (r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent))
        }
        let whiteRGB = whitePoint.map {
            (r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent))
        }

        // 三点定标只调整 R、G、B 三个独立通道
        var redCurve = adjustments.redCurve
        var greenCurve = adjustments.greenCurve
        var blueCurve = adjustments.blueCurve

        applyThreePointCalibration(
            redCurve: &redCurve,
            greenCurve: &greenCurve,
            blueCurve: &blueCurve,
            blackRGB: blackRGB,
            grayRGB: grayRGB,
            whiteRGB: whiteRGB
        )

        adjustments.redCurve = redCurve
        adjustments.greenCurve = greenCurve
        adjustments.blueCurve = blueCurve
    }

    // 三点定标法实现
    private func applyThreePointCalibration(
        redCurve: inout CurveAdjustment,
        greenCurve: inout CurveAdjustment,
        blueCurve: inout CurveAdjustment,
        blackRGB: (r: Double, g: Double, b: Double)?,
        grayRGB: (r: Double, g: Double, b: Double)?,
        whiteRGB: (r: Double, g: Double, b: Double)?
    ) {
        guard let black = blackRGB, let white = whiteRGB else {
            return
        }

        // 安全限制：防止极端采样值
        // 现在采样值已经在 gamma 空间中，白色应该接近 1.0
        // 允许黑点范围：0.1% - 70%（gamma 空间）
        // 允许白点范围：黑点+5% - 99%（确保有动态范围）
        let safeBlack = (
            r: max(0.001, min(0.7, black.r)),
            g: max(0.001, min(0.7, black.g)),
            b: max(0.001, min(0.7, black.b))
        )
        let safeWhite = (
            r: max(safeBlack.r + 0.05, min(0.99, white.r)),
            g: max(safeBlack.g + 0.05, min(0.99, white.g)),
            b: max(safeBlack.b + 0.05, min(0.99, white.b))
        )

        // 检查每个通道的动态范围
        let rangeR = safeWhite.r - safeBlack.r
        let rangeG = safeWhite.g - safeBlack.g
        let rangeB = safeWhite.b - safeBlack.b

        if rangeR < 0.02 || rangeG < 0.02 || rangeB < 0.02 {
            return
        }

        // 注意：0.5% 裁剪保护是基于直方图统计的
        // 但我们没有直方图，所以简化处理：
        // 用户采样的黑白点就是目标，直接映射到 0 和 1
        let clipBlack = 0.0
        let clipWhite = 1.0

        let result: (
            red: CurveAdjustment,
            green: CurveAdjustment,
            blue: CurveAdjustment
        ) = if let gray = grayRGB {
            applyThreePointWithGray(
                redCurve: redCurve,
                greenCurve: greenCurve,
                blueCurve: blueCurve,
                blackRGB: safeBlack,
                grayRGB: gray,
                whiteRGB: safeWhite,
                clipBlack: clipBlack,
                clipWhite: clipWhite
            )
        } else {
            applyBlackWhiteOnly(
                redCurve: redCurve,
                greenCurve: greenCurve,
                blueCurve: blueCurve,
                blackRGB: safeBlack,
                whiteRGB: safeWhite,
                clipBlack: clipBlack,
                clipWhite: clipWhite
            )
        }

        redCurve = result.red
        greenCurve = result.green
        blueCurve = result.blue
    }

    // 只有黑白场：统一拉伸对比度
    private func applyBlackWhiteOnly(
        redCurve: CurveAdjustment,
        greenCurve: CurveAdjustment,
        blueCurve: CurveAdjustment,
        blackRGB: (r: Double, g: Double, b: Double),
        whiteRGB: (r: Double, g: Double, b: Double),
        clipBlack: Double,
        clipWhite: Double
    ) -> (red: CurveAdjustment, green: CurveAdjustment, blue: CurveAdjustment) {
        let sampleCount = 9

        var red = redCurve
        var green = greenCurve
        var blue = blueCurve

        applyCurveStretch(
            curve: &red,
            blackVal: blackRGB.r,
            whiteVal: whiteRGB.r,
            clipBlack: clipBlack,
            clipWhite: clipWhite,
            sampleCount: sampleCount
        )
        applyCurveStretch(
            curve: &green,
            blackVal: blackRGB.g,
            whiteVal: whiteRGB.g,
            clipBlack: clipBlack,
            clipWhite: clipWhite,
            sampleCount: sampleCount
        )
        applyCurveStretch(
            curve: &blue,
            blackVal: blackRGB.b,
            whiteVal: whiteRGB.b,
            clipBlack: clipBlack,
            clipWhite: clipWhite,
            sampleCount: sampleCount
        )

        return (red: red, green: green, blue: blue)
    }

    private func applyCurveStretch(
        curve: inout CurveAdjustment,
        blackVal: Double,
        whiteVal: Double,
        clipBlack _: Double,
        clipWhite _: Double,
        sampleCount _: Int
    ) {
        // 只在 input 位置为黑点和白点时添加控制点
        // 黑点 → 0（映射到纯黑）
        _ = curve.addPoint(input: blackVal, output: 0.0)

        // 白点 → 1（映射到纯白）
        _ = curve.addPoint(input: whiteVal, output: 1.0)
    }

    // 有灰场：先拉伸对比度，再校正色偏
    private func applyThreePointWithGray(
        redCurve: CurveAdjustment,
        greenCurve: CurveAdjustment,
        blueCurve: CurveAdjustment,
        blackRGB: (r: Double, g: Double, b: Double),
        grayRGB: (r: Double, g: Double, b: Double),
        whiteRGB: (r: Double, g: Double, b: Double),
        clipBlack: Double,
        clipWhite: Double
    ) -> (red: CurveAdjustment, green: CurveAdjustment, blue: CurveAdjustment) {
        let grayLum = max(0.01, (grayRGB.r + grayRGB.g + grayRGB.b) / 3.0)

        // 防止除零：确保每个通道值至少为亮度的 10%
        let safeGrayR = max(grayLum * 0.1, grayRGB.r)
        let safeGrayG = max(grayLum * 0.1, grayRGB.g)
        let safeGrayB = max(grayLum * 0.1, grayRGB.b)

        let grayRatios = (
            r: safeGrayR / grayLum,
            g: safeGrayG / grayLum,
            b: safeGrayB / grayLum
        )

        let avgRatio = (grayRatios.r + grayRatios.g + grayRatios.b) / 3.0

        // 限制校正系数在合理范围内 [0.5, 2.0]
        let colorCorrection = (
            r: max(0.5, min(2.0, avgRatio / grayRatios.r)),
            g: max(0.5, min(2.0, avgRatio / grayRatios.g)),
            b: max(0.5, min(2.0, avgRatio / grayRatios.b))
        )

        let sampleCount = 9

        var red = redCurve
        var green = greenCurve
        var blue = blueCurve

        applyCurveStretchWithCorrection(
            curve: &red,
            blackVal: blackRGB.r,
            whiteVal: whiteRGB.r,
            correction: colorCorrection.r,
            clipBlack: clipBlack,
            clipWhite: clipWhite,
            sampleCount: sampleCount
        )
        applyCurveStretchWithCorrection(
            curve: &green,
            blackVal: blackRGB.g,
            whiteVal: whiteRGB.g,
            correction: colorCorrection.g,
            clipBlack: clipBlack,
            clipWhite: clipWhite,
            sampleCount: sampleCount
        )
        applyCurveStretchWithCorrection(
            curve: &blue,
            blackVal: blackRGB.b,
            whiteVal: whiteRGB.b,
            correction: colorCorrection.b,
            clipBlack: clipBlack,
            clipWhite: clipWhite,
            sampleCount: sampleCount
        )

        return (red: red, green: green, blue: blue)
    }

    private func applyCurveStretchWithCorrection(
        curve: inout CurveAdjustment,
        blackVal: Double,
        whiteVal: Double,
        correction: Double,
        clipBlack _: Double,
        clipWhite _: Double,
        sampleCount _: Int
    ) {
        // 黑点映射：应用色偏校正
        let blackOutput = 0.0 * correction
        _ = curve.addPoint(input: blackVal, output: max(0, min(1, blackOutput)))

        // 白点映射：应用色偏校正
        let whiteOutput = 1.0 * correction
        _ = curve.addPoint(input: whiteVal, output: max(0, min(1, whiteOutput)))
    }

    // 自动色阶：基于直方图统计的 Photoshop 风格自动调整
    private func applyAutoLevels() {
        guard let ciImage else { return }

        // 限制裁剪百分比在合理范围内
        let clipPercent = max(0.0, min(5.0, autoLevelClipPercent)) / 100.0

        // 计算每个通道的黑白点
        guard let histogram = calculateHistogram(from: ciImage) else { return }

        let blackPoints = findBlackWhitePoints(
            redHistogram: histogram.red,
            greenHistogram: histogram.green,
            blueHistogram: histogram.blue,
            clipPercent: clipPercent
        )

        // 应用三点定标法（不使用灰点）
        var redCurve = adjustments.redCurve
        var greenCurve = adjustments.greenCurve
        var blueCurve = adjustments.blueCurve

        applyThreePointCalibration(
            redCurve: &redCurve,
            greenCurve: &greenCurve,
            blueCurve: &blueCurve,
            blackRGB: blackPoints.black,
            grayRGB: nil,
            whiteRGB: blackPoints.white
        )

        adjustments.redCurve = redCurve
        adjustments.greenCurve = greenCurve
        adjustments.blueCurve = blueCurve

        print(
            "自动色阶 (裁剪 \(String(format: "%.2f", clipPercent * 100))%): 黑点 RGB(\(String(format: "%.3f", blackPoints.black.r)), \(String(format: "%.3f", blackPoints.black.g)), \(String(format: "%.3f", blackPoints.black.b))), 白点 RGB(\(String(format: "%.3f", blackPoints.white.r)), \(String(format: "%.3f", blackPoints.white.g)), \(String(format: "%.3f", blackPoints.white.b)))"
        )
    }

    // 计算 RGB 三通道直方图
    private func calculateHistogram(from ciImage: CIImage) -> (
        red: [Int], green: [Int], blue: [Int]
    )? {
        let extent = ciImage.extent
        let bins = 256

        // 为了避免内存问题，将大图像缩小到合理尺寸再计算直方图
        let maxDimension: CGFloat = 2048
        let scale = min(1.0, maxDimension / max(extent.width, extent.height))

        let scaledImage: CIImage
        if scale < 1.0 {
            scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            print("直方图计算：图像缩小到 \(scale * 100)%")
        } else {
            scaledImage = ciImage
        }

        let scaledExtent = scaledImage.extent

        // 创建直方图计算滤镜
        guard
            let filter = CIFilter(
                name: "CIAreaHistogram",
                parameters: [
                    kCIInputImageKey: scaledImage,
                    kCIInputExtentKey: CIVector(cgRect: scaledExtent),
                    "inputCount": bins,
                    "inputScale": 1.0,
                ]
            ),
            let outputImage = filter.outputImage
        else {
            print("直方图滤镜创建失败")
            return nil
        }

        // 渲染直方图数据 - CIAreaHistogram 输出的是 256x1 的图像，每个像素是 RGBA 格式
        var bitmap = [Float](repeating: 0, count: bins * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: bins * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        // 提取各通道数据并转换为整数
        var red = [Int](repeating: 0, count: bins)
        var green = [Int](repeating: 0, count: bins)
        var blue = [Int](repeating: 0, count: bins)

        for i in 0 ..< bins {
            red[i] = Int(bitmap[i * 4] * 1000) // 乘以系数以获得可见的数值
            green[i] = Int(bitmap[i * 4 + 1] * 1000)
            blue[i] = Int(bitmap[i * 4 + 2] * 1000)
        }

        print("直方图计算完成: R前5个值=\(Array(red.prefix(5))), max=\(red.max() ?? 0)")

        return (red: red, green: green, blue: blue)
    }

    // 根据直方图和裁剪百分比找到黑白点
    private func findBlackWhitePoints(
        redHistogram: [Int],
        greenHistogram: [Int],
        blueHistogram: [Int],
        clipPercent: Double
    ) -> (black: (r: Double, g: Double, b: Double), white: (r: Double, g: Double, b: Double)) {
        let blackR = findBlackPoint(histogram: redHistogram, clipPercent: clipPercent)
        let blackG = findBlackPoint(histogram: greenHistogram, clipPercent: clipPercent)
        let blackB = findBlackPoint(histogram: blueHistogram, clipPercent: clipPercent)

        let whiteR = findWhitePoint(histogram: redHistogram, clipPercent: clipPercent)
        let whiteG = findWhitePoint(histogram: greenHistogram, clipPercent: clipPercent)
        let whiteB = findWhitePoint(histogram: blueHistogram, clipPercent: clipPercent)

        return (
            black: (r: blackR, g: blackG, b: blackB),
            white: (r: whiteR, g: whiteG, b: whiteB)
        )
    }

    // 找到黑点：从暗部累计到达 clipPercent 的位置
    private func findBlackPoint(histogram: [Int], clipPercent: Double) -> Double {
        let total = histogram.reduce(0, +)
        let threshold = Int(Double(total) * clipPercent)

        var cumulative = 0
        for (i, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= threshold {
                // 转换到 [0, 1] 范围
                return Double(i) / Double(histogram.count - 1)
            }
        }

        return 0.0
    }

    // 找到白点：从高光累计到达 clipPercent 的位置
    private func findWhitePoint(histogram: [Int], clipPercent: Double) -> Double {
        let total = histogram.reduce(0, +)
        let threshold = Int(Double(total) * clipPercent)

        var cumulative = 0
        for (i, count) in histogram.enumerated().reversed() {
            cumulative += count
            if cumulative >= threshold {
                // 转换到 [0, 1] 范围
                return Double(i) / Double(histogram.count - 1)
            }
        }

        return 1.0
    }

    private func resetCurve() {
        blackPoint = nil
        whitePoint = nil
        grayPoint = nil

        // 重置所有曲线，而不只是当前选中的通道
        adjustments.rgbCurve.reset()
        adjustments.redCurve.reset()
        adjustments.greenCurve.reset()
        adjustments.blueCurve.reset()
        adjustments.luminanceCurve.reset()

        pickMode = .none
    }
}
