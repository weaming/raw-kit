import Foundation

struct AdjustmentControlSpec: Equatable, Sendable {
  let id: String
  let title: String
  let range: ClosedRange<Double>
  let defaultValue: Double
  let step: Double
  let decimals: Int

  init(
    id: String,
    title: String,
    range: ClosedRange<Double>,
    defaultValue: Double,
    step: Double,
    decimals: Int? = nil
  ) {
    self.id = id
    self.title = title
    self.range = range
    self.defaultValue = defaultValue
    self.step = step
    self.decimals = decimals ?? (step >= 1 ? 0 : 2)
  }

  func format(_ value: Double) -> String {
    String(format: "%.*f", decimals, value)
  }
}

extension AdjustmentControlSpec {
  static let exposure = Self(
    id: "exposure",
    title: "曝光",
    range: ImageAdjustments.exposureRange,
    defaultValue: 0,
    step: 0.1,
    decimals: 1
  )

  static let perceptualExposure = Self(
    id: "perceptualExposure",
    title: "感知曝光",
    range: ImageAdjustments.perceptualExposureRange,
    defaultValue: 0,
    step: 0.01
  )

  static let contrast = Self(
    id: "contrast",
    title: "对比度",
    range: ImageAdjustments.contrastRange,
    defaultValue: 0,
    step: 0.01
  )

  static let whites = Self(
    id: "whites",
    title: "白色",
    range: ImageAdjustments.whitesRange,
    defaultValue: 0,
    step: 0.01
  )

  static let highlights = Self(
    id: "highlights",
    title: "高光",
    range: ImageAdjustments.highlightsRange,
    defaultValue: 1,
    step: 0.01
  )

  static let shadows = Self(
    id: "shadows",
    title: "阴影",
    range: ImageAdjustments.shadowsRange,
    defaultValue: 0,
    step: 0.01
  )

  static let blacks = Self(
    id: "blacks",
    title: "黑色",
    range: ImageAdjustments.blacksRange,
    defaultValue: 0,
    step: 0.01
  )

  static let hdrBrightness = Self(
    id: "hdrBrightness",
    title: "HDR 亮度",
    range: ImageAdjustments.hdrBrightnessRange,
    defaultValue: 0,
    step: 0.01
  )

  static let hdrHighlights = Self(
    id: "hdrHighlights",
    title: "高光亮度",
    range: ImageAdjustments.hdrHighlightsRange,
    defaultValue: 0,
    step: 0.01
  )

  static let hdrWhites = Self(
    id: "hdrWhites",
    title: "白色亮度",
    range: ImageAdjustments.hdrWhitesRange,
    defaultValue: 0,
    step: 0.01
  )

  static func hdrHeadroom(range: ClosedRange<Double>) -> Self {
    Self(
      id: "hdrHeadroom",
      title: "HDR 峰值",
      range: range,
      defaultValue: 2,
      step: 0.1,
      decimals: 1
    )
  }

  static let temperature = Self(
    id: "temperature",
    title: "色温",
    range: ImageAdjustments.temperatureRange,
    defaultValue: AppConfig.defaultWhitePoint,
    step: 1,
    decimals: 0
  )

  static let tint = Self(
    id: "tint",
    title: "色调",
    range: ImageAdjustments.tintRange,
    defaultValue: 0,
    step: 1,
    decimals: 0
  )

  static let saturation = Self(
    id: "saturation",
    title: "饱和度",
    range: ImageAdjustments.saturationRange,
    defaultValue: 1,
    step: 0.01
  )

  static let vibrance = Self(
    id: "vibrance",
    title: "自然饱和度",
    range: ImageAdjustments.vibranceRange,
    defaultValue: 0,
    step: 0.01
  )

  static let clarity = Self(
    id: "clarity",
    title: "清晰度",
    range: ImageAdjustments.clarityRange,
    defaultValue: 0,
    step: 0.01
  )

  static let dehaze = Self(
    id: "dehaze",
    title: "去雾",
    range: ImageAdjustments.dehazeRange,
    defaultValue: 0,
    step: 0.01
  )

  static let sharpness = Self(
    id: "sharpness",
    title: "锐化",
    range: ImageAdjustments.sharpnessRange,
    defaultValue: 0,
    step: 0.01
  )
}
