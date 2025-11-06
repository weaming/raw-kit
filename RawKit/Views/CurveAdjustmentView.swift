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

                Button(action: resetCurve) {
                    Text("重置")
                }
                .buttonStyle(.bordered)
                .disabled(!hasCurveAdjustments)
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
                InteractiveCurveView(curve: $adjustments.redCurve, channel: .red)
                    .padding(.top, 8)
            case .green:
                InteractiveCurveView(curve: $adjustments.greenCurve, channel: .green)
                    .padding(.top, 8)
            case .blue:
                InteractiveCurveView(curve: $adjustments.blueCurve, channel: .blue)
                    .padding(.top, 8)
            case .luminance:
                InteractiveCurveView(curve: $adjustments.luminanceCurve, channel: .luminance)
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

        var bitmap = [UInt8](repeating: 0, count: 4)

        // 创建 1x1 的采样图像
        if let averaged = ciImage.cropped(to: clampedRect)
            .applyingFilter(
                "CIAreaAverage",
                parameters: [kCIInputExtentKey: CIVector(cgRect: clampedRect)]
            ) as CIImage?,
            let cgImage = ImageProcessor.convertToCGImage(averaged)
        {
            // 使用 CGContext 读取像素，避免创建新的 CIContext
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

        return NSColor(
            red: CGFloat(bitmap[0]) / 255.0,
            green: CGFloat(bitmap[1]) / 255.0,
            blue: CGFloat(bitmap[2]) / 255.0,
            alpha: 1.0
        )
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

    // Photoshop 真正的三点采样算法
    // Photoshop 的三点采样基于 Levels（色阶）调整，而不是直接在曲线上添加点
    // 算法原理：
    // 1. 建立输入/输出映射关系
    // 2. 黑点/白点：线性映射输入范围到 [0, 1]
    // 3. 灰点：通过 gamma 校正调整中间调
    // 4. 将这个映射关系转换为曲线上的多个点
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

        switch selectedChannel {
        case .rgb:
            applyLevelsAdjustment(
                curve: &adjustments.rgbCurve,
                blackValue: blackRGB.map { ($0.r + $0.g + $0.b) / 3.0 },
                grayValue: grayRGB.map { ($0.r + $0.g + $0.b) / 3.0 },
                whiteValue: whiteRGB.map { ($0.r + $0.g + $0.b) / 3.0 }
            )

        case .red:
            applyLevelsAdjustment(
                curve: &adjustments.redCurve,
                blackValue: blackRGB?.r,
                grayValue: grayRGB?.r,
                whiteValue: whiteRGB?.r
            )

        case .green:
            applyLevelsAdjustment(
                curve: &adjustments.greenCurve,
                blackValue: blackRGB?.g,
                grayValue: grayRGB?.g,
                whiteValue: whiteRGB?.g
            )

        case .blue:
            applyLevelsAdjustment(
                curve: &adjustments.blueCurve,
                blackValue: blackRGB?.b,
                grayValue: grayRGB?.b,
                whiteValue: whiteRGB?.b
            )

        case .luminance:
            applyLevelsAdjustment(
                curve: &adjustments.luminanceCurve,
                blackValue: blackRGB.map { ($0.r + $0.g + $0.b) / 3.0 },
                grayValue: grayRGB.map { ($0.r + $0.g + $0.b) / 3.0 },
                whiteValue: whiteRGB.map { ($0.r + $0.g + $0.b) / 3.0 }
            )
        }
    }

    // Photoshop Levels 算法
    // 将色阶调整转换为曲线点
    private func applyLevelsAdjustment(
        curve: inout CurveAdjustment,
        blackValue: Double?,
        grayValue: Double?,
        whiteValue: Double?
    ) {
        // 如果没有任何采样点，不做任何操作
        if blackValue == nil, grayValue == nil, whiteValue == nil {
            return
        }

        // 重要：只有当黑点和白点都设置时才应用 Levels 调整
        // 如果只设置了其中一个，容易导致极端的映射
        guard let inputBlack = blackValue, let inputWhite = whiteValue else {
            // 如果只设置了黑点或白点，不应用调整
            return
        }

        // 确保黑点 < 白点，且有足够的范围
        let range = inputWhite - inputBlack
        if range < 0.1 {
            // 范围太小，不应用调整
            return
        }

        // 限制黑点和白点在合理范围内
        // 防止过度调整
        let clampedBlack = max(0.0, min(0.3, inputBlack))
        let clampedWhite = max(0.7, min(1.0, inputWhite))

        let gamma = calculateGamma(
            grayValue: grayValue,
            blackValue: clampedBlack,
            whiteValue: clampedWhite
        )

        // Photoshop Levels 公式：
        // output = ((input - inputBlack) / (inputWhite - inputBlack)) ^ (1/gamma)
        //
        // 为了生成平滑的曲线，我们在 [0, 1] 范围内采样多个点
        let sampleCount = 9
        for i in 0 ... sampleCount {
            let input = Double(i) / Double(sampleCount)

            // Levels 变换
            let normalized = (input - clampedBlack) / (clampedWhite - clampedBlack)
            let clamped = max(0, min(1, normalized))
            let output = pow(clamped, 1.0 / gamma)

            _ = curve.addPoint(input: input, output: output)
        }
    }

    // 计算 gamma 值
    private func calculateGamma(grayValue: Double?, blackValue: Double,
                                whiteValue: Double) -> Double
    {
        guard let grayValue else {
            return 1.0 // 无灰点时，gamma = 1（线性）
        }

        // 灰点在黑点和白点之间的归一化位置
        let range = whiteValue - blackValue
        if range <= 0.001 {
            return 1.0
        }

        let normalizedGray = (grayValue - blackValue) / range
        let clampedGray = max(0.001, min(0.999, normalizedGray))

        // Photoshop 的 gamma 计算：
        // 我们希望 normalizedGray 经过 gamma 校正后等于 0.5
        // 即：normalizedGray ^ (1/gamma) = 0.5
        // 所以：gamma = log(normalizedGray) / log(0.5)
        let gamma = log(clampedGray) / log(0.5)

        // 限制 gamma 在合理范围内 [0.1, 10]
        return max(0.1, min(10.0, gamma))
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
