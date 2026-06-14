import Foundation

enum CropAspectRatio: String, CaseIterable, Codable, Hashable, Identifiable {
    case free
    case original
    case square
    case ratio4x5
    case ratio5x4
    case ratio3x2
    case ratio2x3
    case ratio16x9
    case ratio9x16

    var id: Self { self }

    var title: String {
        switch self {
        case .free: "自由"
        case .original: "原始"
        case .square: "1:1"
        case .ratio4x5: "4:5"
        case .ratio5x4: "5:4"
        case .ratio3x2: "3:2"
        case .ratio2x3: "2:3"
        case .ratio16x9: "16:9"
        case .ratio9x16: "9:16"
        }
    }

    func resolvedValue(for imageSize: CGSize) -> Double? {
        switch self {
        case .free:
            return nil
        case .original:
            guard imageSize.width > 0, imageSize.height > 0 else { return nil }
            return Double(imageSize.width / imageSize.height)
        case .square:
            return 1.0
        case .ratio4x5:
            return 4.0 / 5.0
        case .ratio5x4:
            return 5.0 / 4.0
        case .ratio3x2:
            return 3.0 / 2.0
        case .ratio2x3:
            return 2.0 / 3.0
        case .ratio16x9:
            return 16.0 / 9.0
        case .ratio9x16:
            return 9.0 / 16.0
        }
    }
}

struct ImageAdjustments: Equatable, Codable {
    var contrast: Double = 0.0
    var saturation: Double = 1.0
    var exposure: Double = 0.0
    var perceptualExposure: Double = 0.0
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
    var isHDREnabled: Bool = false
    var hdrBrightness: Double = 0.0
    var hdrHighlights: Double = 0.0
    var hdrWhites: Double = 0.0
    var hdrHeadroom: Double = 2.0
    var isHDRAutoAdjustmentEnabled: Bool = true

    var rotation: Int = 0
    var straightenAngle: Double = 0.0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var cropLeft: Double = 0.0
    var cropTop: Double = 0.0
    var cropRight: Double = 0.0
    var cropBottom: Double = 0.0
    var cropAspectRatio: CropAspectRatio = .free

    var rgbCurve = CurveAdjustment()
    var redCurve = CurveAdjustment()
    var greenCurve = CurveAdjustment()
    var blueCurve = CurveAdjustment()
    var luminanceCurve = CurveAdjustment()

    var lutURL: URL?
    var lutAlpha: Double = 1.0
    var lutColorSpace: String = "sRGB" // legacy LUT color space for migration
    var lutProfile: LUTColorProfile?

    static let `default` = ImageAdjustments()

    enum CodingKeys: String, CodingKey {
        case contrast
        case saturation
        case exposure
        case perceptualExposure
        case highlights
        case shadows
        case whites
        case blacks
        case clarity
        case dehaze
        case temperature
        case tint
        case vibrance
        case sharpness
        case isHDREnabled
        case hdrBrightness
        case hdrHighlights
        case hdrWhites
        case hdrHeadroom
        case isHDRAutoAdjustmentEnabled
        case rotation
        case straightenAngle
        case flipHorizontal
        case flipVertical
        case cropLeft
        case cropTop
        case cropRight
        case cropBottom
        case cropAspectRatio
        case rgbCurve
        case redCurve
        case greenCurve
        case blueCurve
        case luminanceCurve
        case lutURL
        case lutAlpha
        case lutColorSpace
        case lutProfile
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        perceptualExposure = try container.decodeIfPresent(
            Double.self,
            forKey: .perceptualExposure
        ) ?? perceptualExposure
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? whites
        blacks = try container.decodeIfPresent(Double.self, forKey: .blacks) ?? blacks
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? clarity
        dehaze = try container.decodeIfPresent(Double.self, forKey: .dehaze) ?? dehaze
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? sharpness
        isHDREnabled = try container.decodeIfPresent(Bool.self, forKey: .isHDREnabled) ?? isHDREnabled
        hdrBrightness = try container.decodeIfPresent(Double.self, forKey: .hdrBrightness) ?? hdrBrightness
        hdrHighlights = try container.decodeIfPresent(Double.self, forKey: .hdrHighlights) ?? hdrHighlights
        hdrWhites = try container.decodeIfPresent(Double.self, forKey: .hdrWhites) ?? hdrWhites
        hdrHeadroom = try container.decodeIfPresent(Double.self, forKey: .hdrHeadroom) ?? hdrHeadroom
        isHDRAutoAdjustmentEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isHDRAutoAdjustmentEnabled
        ) ?? isHDRAutoAdjustmentEnabled

        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? rotation
        straightenAngle = try container.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? straightenAngle
        flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? flipHorizontal
        flipVertical = try container.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? flipVertical
        cropLeft = try container.decodeIfPresent(Double.self, forKey: .cropLeft) ?? cropLeft
        cropTop = try container.decodeIfPresent(Double.self, forKey: .cropTop) ?? cropTop
        cropRight = try container.decodeIfPresent(Double.self, forKey: .cropRight) ?? cropRight
        cropBottom = try container.decodeIfPresent(Double.self, forKey: .cropBottom) ?? cropBottom
        cropAspectRatio = try container.decodeIfPresent(CropAspectRatio.self, forKey: .cropAspectRatio) ?? cropAspectRatio

        rgbCurve = try container.decodeIfPresent(CurveAdjustment.self, forKey: .rgbCurve) ?? rgbCurve
        redCurve = try container.decodeIfPresent(CurveAdjustment.self, forKey: .redCurve) ?? redCurve
        greenCurve = try container.decodeIfPresent(CurveAdjustment.self, forKey: .greenCurve) ?? greenCurve
        blueCurve = try container.decodeIfPresent(CurveAdjustment.self, forKey: .blueCurve) ?? blueCurve
        luminanceCurve = try container.decodeIfPresent(
            CurveAdjustment.self,
            forKey: .luminanceCurve
        ) ?? luminanceCurve

        lutURL = try container.decodeIfPresent(URL.self, forKey: .lutURL)
        lutAlpha = try container.decodeIfPresent(Double.self, forKey: .lutAlpha) ?? lutAlpha
        lutColorSpace = try container.decodeIfPresent(String.self, forKey: .lutColorSpace) ?? lutColorSpace
        lutProfile = try container.decodeIfPresent(LUTColorProfile.self, forKey: .lutProfile)
    }

    var lutColorProfile: LUTColorProfile {
        get {
            lutProfile ?? LUTColorProfile.legacy(from: lutColorSpace)
        }
        set {
            lutProfile = newValue
            lutColorSpace = newValue.legacyCombinedColorSpace.rawValue
        }
    }

    var hasAdjustments: Bool {
        // 排除变换，只检查色彩调整
        var temp = self
        temp.rotation = 0
        temp.straightenAngle = 0.0
        temp.flipHorizontal = false
        temp.flipVertical = false
        temp.cropLeft = 0.0
        temp.cropTop = 0.0
        temp.cropRight = 0.0
        temp.cropBottom = 0.0
        temp.cropAspectRatio = .free
        if temp.lutURL == nil {
            temp.lutAlpha = ImageAdjustments.default.lutAlpha
            temp.lutColorSpace = ImageAdjustments.default.lutColorSpace
            temp.lutProfile = ImageAdjustments.default.lutProfile
        }
        return temp != .default
    }

    mutating func reset() {
        // 保留变换设置和 LUT 设置
        let savedRotation = rotation
        let savedStraightenAngle = straightenAngle
        let savedFlipH = flipHorizontal
        let savedFlipV = flipVertical
        let savedCropLeft = cropLeft
        let savedCropTop = cropTop
        let savedCropRight = cropRight
        let savedCropBottom = cropBottom
        let savedCropAspectRatio = cropAspectRatio
        let savedLutURL = lutURL
        let savedLutAlpha = lutAlpha
        let savedLutColorSpace = lutColorSpace
        let savedLutProfile = lutProfile

        self = .default

        // 恢复变换设置和 LUT 设置
        rotation = savedRotation
        straightenAngle = savedStraightenAngle
        flipHorizontal = savedFlipH
        flipVertical = savedFlipV
        cropLeft = savedCropLeft
        cropTop = savedCropTop
        cropRight = savedCropRight
        cropBottom = savedCropBottom
        cropAspectRatio = savedCropAspectRatio
        lutURL = savedLutURL
        lutAlpha = savedLutAlpha
        lutColorSpace = savedLutColorSpace
        lutProfile = savedLutProfile
    }

    mutating func reset(to baseline: ImageAdjustments) {
        let savedRotation = rotation
        let savedStraightenAngle = straightenAngle
        let savedFlipH = flipHorizontal
        let savedFlipV = flipVertical
        let savedCropLeft = cropLeft
        let savedCropTop = cropTop
        let savedCropRight = cropRight
        let savedCropBottom = cropBottom
        let savedCropAspectRatio = cropAspectRatio
        let savedLutURL = lutURL
        let savedLutAlpha = lutAlpha
        let savedLutColorSpace = lutColorSpace
        let savedLutProfile = lutProfile

        self = baseline

        rotation = savedRotation
        straightenAngle = savedStraightenAngle
        flipHorizontal = savedFlipH
        flipVertical = savedFlipV
        cropLeft = savedCropLeft
        cropTop = savedCropTop
        cropRight = savedCropRight
        cropBottom = savedCropBottom
        cropAspectRatio = savedCropAspectRatio
        lutURL = savedLutURL
        lutAlpha = savedLutAlpha
        lutColorSpace = savedLutColorSpace
        lutProfile = savedLutProfile
    }

    // 检查基础调整组是否有变化
    var hasBasicAdjustments: Bool {
        exposure != 0.0 ||
            perceptualExposure != 0.0 ||
            contrast != 0.0 ||
            whites != 0.0 ||
            highlights != 1.0 ||
            shadows != 0.0 ||
            blacks != 0.0
    }

    var hasHDRAdjustments: Bool {
        isHDREnabled ||
            hdrBrightness != 0.0 ||
            hdrHighlights != 0.0 ||
            hdrWhites != 0.0 ||
            hdrHeadroom != 2.0 ||
            isHDRAutoAdjustmentEnabled != true
    }

    // 检查色彩调整组是否有变化
    var hasColorAdjustments: Bool {
        saturation != 1.0 ||
            vibrance != 0.0 ||
            abs(temperature - AppConfig.defaultWhitePoint) > AppConfig.whitePointTolerance ||
            tint != 0.0
    }

    // 检查细节调整组是否有变化
    var hasDetailAdjustments: Bool {
        sharpness != 0.0 ||
            clarity != 0.0 ||
            dehaze != 0.0
    }

    // 检查曲线调整组是否有变化
    var hasCurveAdjustments: Bool {
        rgbCurve.hasPoints ||
            redCurve.hasPoints ||
            greenCurve.hasPoints ||
            blueCurve.hasPoints ||
            luminanceCurve.hasPoints
    }

    var hasTransformAdjustments: Bool {
        rotation != 0 ||
            abs(straightenAngle) > 0.0001 ||
            flipHorizontal ||
            flipVertical ||
            cropLeft > 0.0001 ||
            cropTop > 0.0001 ||
            cropRight > 0.0001 ||
            cropBottom > 0.0001 ||
            cropAspectRatio != .free
    }

    // 重置基础调整组
    mutating func resetBasic() {
        exposure = 0.0
        perceptualExposure = 0.0
        contrast = 0.0
        whites = 0.0
        highlights = 1.0
        shadows = 0.0
        blacks = 0.0
    }

    mutating func resetHDR() {
        isHDREnabled = false
        hdrBrightness = 0.0
        hdrHighlights = 0.0
        hdrWhites = 0.0
        hdrHeadroom = 2.0
        isHDRAutoAdjustmentEnabled = true
    }

    // 重置色彩调整组
    mutating func resetColor() {
        saturation = 1.0
        vibrance = 0.0
        temperature = AppConfig.defaultWhitePoint
        tint = 0.0
    }

    // 重置细节调整组
    mutating func resetDetail() {
        sharpness = 0.0
        clarity = 0.0
        dehaze = 0.0
    }

    // 重置曲线调整组
    mutating func resetCurve() {
        rgbCurve.reset()
        redCurve.reset()
        greenCurve.reset()
        blueCurve.reset()
        luminanceCurve.reset()
    }

    mutating func resetTransform() {
        rotation = 0
        straightenAngle = 0.0
        flipHorizontal = false
        flipVertical = false
        resetCrop()
    }

    mutating func resetCrop() {
        cropLeft = 0.0
        cropTop = 0.0
        cropRight = 0.0
        cropBottom = 0.0
        cropAspectRatio = .free
    }

    func withoutCrop() -> ImageAdjustments {
        var result = self
        result.cropLeft = 0.0
        result.cropTop = 0.0
        result.cropRight = 0.0
        result.cropBottom = 0.0
        result.cropAspectRatio = .free
        return result
    }
}

enum AdjustmentSyncGroup: String, CaseIterable, Hashable, Identifiable {
    case transform
    case lut
    case basic
    case hdr
    case color
    case detail
    case curve

    var id: Self { self }

    var title: String {
        switch self {
        case .transform: "构图"
        case .lut: "LUT"
        case .basic: "基础"
        case .hdr: "HDR"
        case .color: "色彩"
        case .detail: "细节"
        case .curve: "曲线"
        }
    }
}

extension ImageAdjustments {
    static func sourceHDRBaseline(headroom: Double?) -> ImageAdjustments {
        guard let headroom,
              headroom > 1.01 else {
            return .default
        }

        var adjustments = ImageAdjustments.default
        adjustments.isHDREnabled = true
        adjustments.hdrHeadroom = min(
            max(headroom, ImageAdjustments.hdrHeadroomRange.lowerBound),
            ImageAdjustments.hdrHeadroomRange.upperBound
        )
        adjustments.isHDRAutoAdjustmentEnabled = false
        return adjustments
    }

    static let contrastRange: ClosedRange<Double> = -1.0 ... 1.0
    static let saturationRange: ClosedRange<Double> = 0.0 ... 2.0
    static let exposureRange: ClosedRange<Double> = -5.0 ... 5.0
    static let perceptualExposureRange: ClosedRange<Double> = -2.0 ... 2.0
    static let highlightsRange: ClosedRange<Double> = 0.0 ... 2.0
    static let shadowsRange: ClosedRange<Double> = -1.0 ... 1.0
    static let whitesRange: ClosedRange<Double> = -1.0 ... 1.0
    static let blacksRange: ClosedRange<Double> = -1.0 ... 1.0
    static let clarityRange: ClosedRange<Double> = -1.0 ... 1.0
    static let dehazeRange: ClosedRange<Double> = -1.0 ... 1.0
    static let temperatureRange: ClosedRange<Double> = 2000.0 ... 25000.0
    static let tintRange: ClosedRange<Double> = -100.0 ... 100.0
    static let vibranceRange: ClosedRange<Double> = -1.0 ... 1.0
    static let sharpnessRange: ClosedRange<Double> = -1.0 ... 2.0
    static let straightenAngleRange: ClosedRange<Double> = -45.0 ... 45.0
    static let cropInsetRange: ClosedRange<Double> = 0.0 ... 0.95
    static let cropCoordinateRange: ClosedRange<Double> = 0.0 ... 1.0
    static let minimumCropVisibleFraction: Double = 0.05
    static let hdrBrightnessRange: ClosedRange<Double> = -2.0 ... 2.0
    static let hdrHighlightsRange: ClosedRange<Double> = -1.0 ... 1.0
    static let hdrWhitesRange: ClosedRange<Double> = -1.0 ... 1.0
    static let hdrHeadroomRange: ClosedRange<Double> = 1.0 ... 32.0

    func synced(with source: ImageAdjustments, groups: Set<AdjustmentSyncGroup>) -> ImageAdjustments {
        var result = self
        result.applySyncGroups(groups, from: source)
        return result
    }

    mutating func applySyncGroups(_ groups: Set<AdjustmentSyncGroup>, from source: ImageAdjustments) {
        for group in AdjustmentSyncGroup.allCases where groups.contains(group) {
            applySyncGroup(group, from: source)
        }
    }

    private mutating func applySyncGroup(_ group: AdjustmentSyncGroup, from source: ImageAdjustments) {
        switch group {
        case .transform:
            rotation = source.rotation
            straightenAngle = source.straightenAngle
            flipHorizontal = source.flipHorizontal
            flipVertical = source.flipVertical
            cropLeft = source.cropLeft
            cropTop = source.cropTop
            cropRight = source.cropRight
            cropBottom = source.cropBottom
            cropAspectRatio = source.cropAspectRatio

        case .lut:
            lutURL = source.lutURL
            lutAlpha = source.lutAlpha
            lutColorSpace = source.lutColorSpace
            lutProfile = source.lutProfile

        case .basic:
            exposure = source.exposure
            perceptualExposure = source.perceptualExposure
            contrast = source.contrast
            whites = source.whites
            highlights = source.highlights
            shadows = source.shadows
            blacks = source.blacks

        case .hdr:
            isHDREnabled = source.isHDREnabled
            isHDRAutoAdjustmentEnabled = true
            // 不直接复制 HDR 数值，启用自动计算模式让目标图片按自身内容计算

        case .color:
            saturation = source.saturation
            vibrance = source.vibrance
            temperature = source.temperature
            tint = source.tint

        case .detail:
            sharpness = source.sharpness
            clarity = source.clarity
            dehaze = source.dehaze

        case .curve:
            rgbCurve = source.rgbCurve
            redCurve = source.redCurve
            greenCurve = source.greenCurve
            blueCurve = source.blueCurve
            luminanceCurve = source.luminanceCurve
        }
    }
}
