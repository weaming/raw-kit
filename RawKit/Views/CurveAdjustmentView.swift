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
