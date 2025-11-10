import Foundation

struct ImageAdjustments: Equatable, Codable {
    var brightness: Double = 0.0
    var contrast: Double = 1.0
    var saturation: Double = 1.0
    var exposure: Double = 0.0
    var linearExposure: Double = 0.0
    var highlights: Double = 1.0
    var shadows: Double = 0.0
    var whites: Double = 0.0
    var blacks: Double = 0.0
    var clarity: Double = 0.0
    var dehaze: Double = 0.0
    var temperature: Double = AppConfig.defaultWhitePoint
    var tint: Double = 0.0
    var vibrance: Double = 0.0
    var sharpness: Double = 0.0

    var rotation: Int = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    var rgbCurve = CurveAdjustment()
    var redCurve = CurveAdjustment()
    var greenCurve = CurveAdjustment()
    var blueCurve = CurveAdjustment()
    var luminanceCurve = CurveAdjustment()

    var lutURL: URL?
    var lutAlpha: Double = 1.0
    var lutColorSpace: String = "sRGB" // LUT输入色彩空间

    static let `default` = ImageAdjustments()

    var hasAdjustments: Bool {
        // 排除变换，只检查色彩调整
        var temp = self
        temp.rotation = 0
        temp.flipHorizontal = false
        temp.flipVertical = false
        return temp != .default
    }

    mutating func reset() {
        // 保留变换设置和 LUT 设置
        let savedRotation = rotation
        let savedFlipH = flipHorizontal
        let savedFlipV = flipVertical
        let savedLutURL = lutURL
        let savedLutAlpha = lutAlpha

        self = .default

        // 恢复变换设置和 LUT 设置
        rotation = savedRotation
        flipHorizontal = savedFlipH
        flipVertical = savedFlipV
        lutURL = savedLutURL
        lutAlpha = savedLutAlpha
    }

    // 检查基础调整组是否有变化
    var hasBasicAdjustments: Bool {
        exposure != 0.0 ||
            linearExposure != 0.0 ||
            brightness != 0.0 ||
            contrast != 1.0 ||
            whites != 0.0 ||
            highlights != 1.0 ||
            shadows != 0.0 ||
            blacks != 0.0
    }

    // 检查色彩调整组是否有变化
    var hasColorAdjustments: Bool {
        saturation != 1.0 ||
            vibrance != 0.0 ||
            abs(temperature - AppConfig.defaultWhitePoint) > AppConfig.whitePointTolerance ||
            tint != 0.0 ||
            rgbCurve.hasPoints ||
            redCurve.hasPoints ||
            greenCurve.hasPoints ||
            blueCurve.hasPoints ||
            luminanceCurve.hasPoints
    }

    // 检查细节调整组是否有变化
    var hasDetailAdjustments: Bool {
        sharpness != 0.0 ||
            clarity != 0.0 ||
            dehaze != 0.0
    }

    // 重置基础调整组
    mutating func resetBasic() {
        exposure = 0.0
        linearExposure = 0.0
        brightness = 0.0
        contrast = 1.0
        whites = 0.0
        highlights = 1.0
        shadows = 0.0
        blacks = 0.0
    }

    // 重置色彩调整组
    mutating func resetColor() {
        saturation = 1.0
        vibrance = 0.0
        temperature = AppConfig.defaultWhitePoint
        tint = 0.0
        rgbCurve.reset()
        redCurve.reset()
        greenCurve.reset()
        blueCurve.reset()
        luminanceCurve.reset()
    }

    // 重置细节调整组
    mutating func resetDetail() {
        sharpness = 0.0
        clarity = 0.0
        dehaze = 0.0
    }
}

extension ImageAdjustments {
    static let brightnessRange: ClosedRange<Double> = -1.0 ... 1.0
    static let contrastRange: ClosedRange<Double> = 0.0 ... 2.0
    static let saturationRange: ClosedRange<Double> = 0.0 ... 2.0
    static let exposureRange: ClosedRange<Double> = -2.0 ... 2.0
    static let linearExposureRange: ClosedRange<Double> = -5.0 ... 5.0
    static let highlightsRange: ClosedRange<Double> = 0.0 ... 2.0
    static let shadowsRange: ClosedRange<Double> = -1.0 ... 1.0
    static let whitesRange: ClosedRange<Double> = -1.0 ... 1.0
    static let blacksRange: ClosedRange<Double> = -1.0 ... 1.0
    static let clarityRange: ClosedRange<Double> = -1.0 ... 1.0
    static let dehazeRange: ClosedRange<Double> = -1.0 ... 1.0
    static let temperatureRange: ClosedRange<Double> = 2000.0 ... 10000.0
    static let tintRange: ClosedRange<Double> = -100.0 ... 100.0
    static let vibranceRange: ClosedRange<Double> = -1.0 ... 1.0
    static let sharpnessRange: ClosedRange<Double> = -1.0 ... 2.0
}
