import Foundation

struct ImageAdjustments: Equatable {
    var brightness: Double = 0.0
    var contrast: Double = 1.0
    var saturation: Double = 1.0
    var exposure: Double = 0.0
    var highlights: Double = 1.0
    var shadows: Double = 0.0
    var temperature: Double = 6500.0
    var tint: Double = 0.0
    var vibrance: Double = 0.0
    var sharpness: Double = 0.0

    static let `default` = ImageAdjustments()

    var hasAdjustments: Bool {
        self != .default
    }

    mutating func reset() {
        self = .default
    }
}

extension ImageAdjustments {
    static let brightnessRange: ClosedRange<Double> = -1.0 ... 1.0
    static let contrastRange: ClosedRange<Double> = 0.0 ... 2.0
    static let saturationRange: ClosedRange<Double> = 0.0 ... 2.0
    static let exposureRange: ClosedRange<Double> = -2.0 ... 2.0
    static let highlightsRange: ClosedRange<Double> = 0.0 ... 1.0
    static let shadowsRange: ClosedRange<Double> = -1.0 ... 1.0
    static let temperatureRange: ClosedRange<Double> = 2000.0 ... 10000.0
    static let tintRange: ClosedRange<Double> = -100.0 ... 100.0
    static let vibranceRange: ClosedRange<Double> = -1.0 ... 1.0
    static let sharpnessRange: ClosedRange<Double> = 0.0 ... 2.0
}
