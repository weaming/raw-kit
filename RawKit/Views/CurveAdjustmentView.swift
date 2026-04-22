import AppKit
import SwiftUI

struct CurvePickSamples: Equatable {
    var black: PixelInfo?
    var white: PixelInfo?
    var gray: PixelInfo?

    var hasSamples: Bool {
        black != nil || white != nil || gray != nil
    }

    mutating func reset() {
        black = nil
        white = nil
        gray = nil
    }
}

enum CurveCalibration {
    static func apply(samples: CurvePickSamples, to adjustments: inout ImageAdjustments) {
        guard let black = samples.black, let white = samples.white else {
            return
        }

        var redCurve = adjustments.redCurve
        var greenCurve = adjustments.greenCurve
        var blueCurve = adjustments.blueCurve

        applyThreePointCalibration(
            redCurve: &redCurve,
            greenCurve: &greenCurve,
            blueCurve: &blueCurve,
            blackRGB: black.linearRGB,
            grayRGB: samples.gray?.linearRGB,
            whiteRGB: white.linearRGB
        )

        adjustments.redCurve = redCurve
        adjustments.greenCurve = greenCurve
        adjustments.blueCurve = blueCurve
    }

    static func applyThreePointCalibration(
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

        let rangeR = safeWhite.r - safeBlack.r
        let rangeG = safeWhite.g - safeBlack.g
        let rangeB = safeWhite.b - safeBlack.b

        if rangeR < 0.02 || rangeG < 0.02 || rangeB < 0.02 {
            return
        }

        let clipBlack = 0.0
        let clipWhite = 1.0

        let result: (red: CurveAdjustment, green: CurveAdjustment, blue: CurveAdjustment)

        if let gray = grayRGB {
            let safeGray = (
                r: max(safeBlack.r + 0.02, min(safeWhite.r - 0.02, gray.r)),
                g: max(safeBlack.g + 0.02, min(safeWhite.g - 0.02, gray.g)),
                b: max(safeBlack.b + 0.02, min(safeWhite.b - 0.02, gray.b))
            )
            result = applyThreePointWithGray(
                redCurve: redCurve,
                greenCurve: greenCurve,
                blueCurve: blueCurve,
                blackRGB: safeBlack,
                grayRGB: safeGray,
                whiteRGB: safeWhite,
                clipBlack: clipBlack,
                clipWhite: clipWhite
            )
        } else {
            result = applyBlackWhiteOnly(
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

    private static func applyBlackWhiteOnly(
        redCurve: CurveAdjustment,
        greenCurve: CurveAdjustment,
        blueCurve: CurveAdjustment,
        blackRGB: (r: Double, g: Double, b: Double),
        whiteRGB: (r: Double, g: Double, b: Double),
        clipBlack: Double,
        clipWhite: Double
    ) -> (red: CurveAdjustment, green: CurveAdjustment, blue: CurveAdjustment) {
        var red = redCurve
        var green = greenCurve
        var blue = blueCurve

        applyCurveStretch(
            curve: &red,
            blackVal: blackRGB.r,
            whiteVal: whiteRGB.r,
            clipBlack: clipBlack,
            clipWhite: clipWhite
        )
        applyCurveStretch(
            curve: &green,
            blackVal: blackRGB.g,
            whiteVal: whiteRGB.g,
            clipBlack: clipBlack,
            clipWhite: clipWhite
        )
        applyCurveStretch(
            curve: &blue,
            blackVal: blackRGB.b,
            whiteVal: whiteRGB.b,
            clipBlack: clipBlack,
            clipWhite: clipWhite
        )

        return (red: red, green: green, blue: blue)
    }

    private static func applyCurveStretch(
        curve: inout CurveAdjustment,
        blackVal: Double,
        whiteVal: Double,
        clipBlack _: Double,
        clipWhite _: Double
    ) {
        _ = curve.addPoint(input: blackVal, output: 0.0)
        _ = curve.addPoint(input: whiteVal, output: 1.0)
    }

    private static func applyThreePointWithGray(
        redCurve: CurveAdjustment,
        greenCurve: CurveAdjustment,
        blueCurve: CurveAdjustment,
        blackRGB: (r: Double, g: Double, b: Double),
        grayRGB: (r: Double, g: Double, b: Double),
        whiteRGB: (r: Double, g: Double, b: Double),
        clipBlack: Double,
        clipWhite: Double
    ) -> (red: CurveAdjustment, green: CurveAdjustment, blue: CurveAdjustment) {
        let normalizedGray = (
            r: (grayRGB.r - blackRGB.r) / max(whiteRGB.r - blackRGB.r, 0.001),
            g: (grayRGB.g - blackRGB.g) / max(whiteRGB.g - blackRGB.g, 0.001),
            b: (grayRGB.b - blackRGB.b) / max(whiteRGB.b - blackRGB.b, 0.001)
        )
        let neutralGrayOutput = max(
            clipBlack + 0.02,
            min(
                clipWhite - 0.02,
                (normalizedGray.r + normalizedGray.g + normalizedGray.b) / 3.0
            )
        )

        var red = redCurve
        var green = greenCurve
        var blue = blueCurve

        applyCurveStretchWithGrayAnchor(
            curve: &red,
            blackVal: blackRGB.r,
            grayVal: grayRGB.r,
            whiteVal: whiteRGB.r,
            grayOutput: neutralGrayOutput
        )
        applyCurveStretchWithGrayAnchor(
            curve: &green,
            blackVal: blackRGB.g,
            grayVal: grayRGB.g,
            whiteVal: whiteRGB.g,
            grayOutput: neutralGrayOutput
        )
        applyCurveStretchWithGrayAnchor(
            curve: &blue,
            blackVal: blackRGB.b,
            grayVal: grayRGB.b,
            whiteVal: whiteRGB.b,
            grayOutput: neutralGrayOutput
        )

        return (red: red, green: green, blue: blue)
    }

    private static func applyCurveStretchWithGrayAnchor(
        curve: inout CurveAdjustment,
        blackVal: Double,
        grayVal: Double,
        whiteVal: Double,
        grayOutput: Double
    ) {
        _ = curve.addPoint(input: blackVal, output: 0.0)
        _ = curve.addPoint(input: grayVal, output: max(0, min(1, grayOutput)))
        _ = curve.addPoint(input: whiteVal, output: 1.0)
    }
}

// 曲线调整视图
// 包含通道选择、三点采样（黑/灰/白）和曲线编辑器
struct CurveAdjustmentView: View {
    @Binding var adjustments: ImageAdjustments
    let ciImage: CIImage?
    @Binding var pickMode: PickMode
    @Binding var curvePickSamples: CurvePickSamples
    @State private var selectedChannel: CurveAdjustment.Channel = .rgb
    @State private var autoLevelClipPercent: Double = 0.05
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
                            .fill(color(for: curvePickSamples.black) ?? .black)
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
                            .fill(color(for: curvePickSamples.gray) ?? .gray)
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
                            .fill(color(for: curvePickSamples.white) ?? .white)
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

        guard let pixelInfo = PixelSampler.samplePixelInfo(
            from: ciImage,
            point: point,
            imageSize: imageSize,
            sampleSize: 5
        ) else {
            return
        }

        switch pickMode {
        case .black:
            curvePickSamples.black = pixelInfo
            calculateCurve()
        case .white:
            curvePickSamples.white = pixelInfo
            calculateCurve()
        case .gray:
            curvePickSamples.gray = pixelInfo
            calculateCurve()
        case .whiteBalance:
            // 白平衡取色由 ImageDetailView 处理
            // 这里不应该处理，因为曲线调整不能直接修改色温色调
            break
        case .none:
            break
        }
    }

    // 检查是否有曲线调整
    private var hasCurveAdjustments: Bool {
        curvePickSamples.hasSamples ||
            adjustments.rgbCurve.hasPoints ||
            adjustments.redCurve.hasPoints ||
            adjustments.greenCurve.hasPoints ||
            adjustments.blueCurve.hasPoints ||
            adjustments.luminanceCurve.hasPoints
    }

    private func calculateCurve() {
        CurveCalibration.apply(samples: curvePickSamples, to: &adjustments)
    }

    // 自动色阶：基于直方图统计的 Photoshop 风格自动调整
    private func applyAutoLevels() {
        guard let ciImage else { return }

        // 限制裁剪百分比在合理范围内
        let clipPercent = max(0.0, min(5.0, autoLevelClipPercent)) / 100.0
        curvePickSamples.reset()

        switch selectedChannel {
        case .rgb:
            guard let histogram = calculateLuminanceHistogram(from: ciImage) else { return }
            var curve = CurveAdjustment()
            curve.channel = .rgb
            applyAutoStretch(to: &curve, histogram: histogram, clipPercent: clipPercent)
            adjustments.rgbCurve = curve

        case .luminance:
            guard let histogram = calculateLuminanceHistogram(from: ciImage) else { return }
            var curve = CurveAdjustment()
            curve.channel = .luminance
            applyAutoStretch(to: &curve, histogram: histogram, clipPercent: clipPercent)
            adjustments.luminanceCurve = curve

        case .red, .green, .blue:
            guard let histograms = calculateHistogram(from: ciImage) else { return }
            let histogram: [Int]
            var curve = CurveAdjustment()
            curve.channel = selectedChannel

            switch selectedChannel {
            case .red:
                histogram = histograms.red
                applyAutoStretch(to: &curve, histogram: histogram, clipPercent: clipPercent)
                adjustments.redCurve = curve
            case .green:
                histogram = histograms.green
                applyAutoStretch(to: &curve, histogram: histogram, clipPercent: clipPercent)
                adjustments.greenCurve = curve
            case .blue:
                histogram = histograms.blue
                applyAutoStretch(to: &curve, histogram: histogram, clipPercent: clipPercent)
                adjustments.blueCurve = curve
            default:
                return
            }
        }
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
            print("直方图计算：图像缩小到 \(String(format: "%.1f", scale * 100))%")
        } else {
            scaledImage = ciImage
        }

        let histogramImage = scaledImage.applyingFilter(
            "CIColorClamp",
            parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ]
        )
        let scaledExtent = histogramImage.extent

        // 创建直方图计算滤镜
        guard
            let filter = CIFilter(
                name: "CIAreaHistogram",
                parameters: [
                    kCIInputImageKey: histogramImage,
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
        Self.histogramContext.render(
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

    private static var histogramContext: CIContext {
        CIContextManager.shared.getHistogramContext()
    }

    private func calculateLuminanceHistogram(from ciImage: CIImage) -> [Int]? {
        guard let histogram = calculateHistogram(
            from: ciImage.applyingFilter(
                "CIColorControls",
                parameters: [kCIInputSaturationKey: 0.0]
            )
        ) else {
            return nil
        }

        return histogram.red
    }

    private func applyAutoStretch(
        to curve: inout CurveAdjustment,
        histogram: [Int],
        clipPercent: Double
    ) {
        let smoothedHistogram = smoothHistogram(histogram, radius: 2)
        guard let significantRange = findSignificantRange(histogram: smoothedHistogram) else { return }

        let percentileBlack = findBlackPoint(histogram: smoothedHistogram, clipPercent: clipPercent)
        let percentileWhite = findWhitePoint(histogram: smoothedHistogram, clipPercent: clipPercent)

        let blackPoint = max(significantRange.black, percentileBlack)
        let whitePoint = min(significantRange.white, percentileWhite)
        let range = whitePoint - blackPoint

        guard range >= 0.08 else { return }

        curve.reset()
        _ = curve.addPoint(input: blackPoint, output: 0.0)

        let shoulderWidth = min(0.12, max(0.04, range * 0.22))
        let shadowInput = min(blackPoint + shoulderWidth, whitePoint - 0.05)
        let highlightInput = max(whitePoint - shoulderWidth, shadowInput + 0.05)
        let midInput = (blackPoint + whitePoint) * 0.5

        _ = curve.addPoint(input: shadowInput, output: 0.18)
        _ = curve.addPoint(input: midInput, output: 0.5)
        _ = curve.addPoint(input: highlightInput, output: 0.82)
        _ = curve.addPoint(input: whitePoint, output: 1.0)

        print(
            "自动色阶 [\(curve.channel.rawValue)] (裁剪 \(String(format: "%.3f", clipPercent * 100))%): 有效范围 \(String(format: "%.3f", significantRange.black))-\(String(format: "%.3f", significantRange.white)), 黑点 \(String(format: "%.3f", blackPoint)), 白点 \(String(format: "%.3f", whitePoint))"
        )
    }

    private func smoothHistogram(_ histogram: [Int], radius: Int) -> [Int] {
        guard radius > 0, histogram.count > 2 else { return histogram }

        return histogram.indices.map { index in
            let start = max(0, index - radius)
            let end = min(histogram.count - 1, index + radius)
            let slice = histogram[start ... end]
            return slice.reduce(0, +) / slice.count
        }
    }

    private func findSignificantRange(histogram: [Int]) -> (black: Double, white: Double)? {
        let total = histogram.reduce(0, +)
        let peak = histogram.max() ?? 0
        guard total > 0, peak > 0 else { return nil }

        let noiseFloor = max(
            2,
            Int(Double(total) * 0.0001),
            Int(Double(peak) * 0.003)
        )

        guard let leftIndex = histogram.firstIndex(where: { $0 >= noiseFloor }),
              let rightIndex = histogram.lastIndex(where: { $0 >= noiseFloor }),
              rightIndex > leftIndex else {
            return nil
        }

        return (
            black: Double(leftIndex) / Double(histogram.count - 1),
            white: Double(rightIndex) / Double(histogram.count - 1)
        )
    }

    // 找到黑点：从暗部累计到达 clipPercent 的位置
    private func findBlackPoint(histogram: [Int], clipPercent: Double) -> Double {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0.0 }
        let threshold = max(1, Int(Double(total) * clipPercent))

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
        guard total > 0 else { return 1.0 }
        let threshold = max(1, Int(Double(total) * clipPercent))

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
        curvePickSamples.reset()

        // 重置所有曲线，而不只是当前选中的通道
        adjustments.rgbCurve.reset()
        adjustments.redCurve.reset()
        adjustments.greenCurve.reset()
        adjustments.blueCurve.reset()
        adjustments.luminanceCurve.reset()

        pickMode = .none
    }

    private func color(for sample: PixelInfo?) -> Color? {
        guard let sample else { return nil }
        return Color(
            red: sample.gammaRGB.r,
            green: sample.gammaRGB.g,
            blue: sample.gammaRGB.b
        )
    }
}
