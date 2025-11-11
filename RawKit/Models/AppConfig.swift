import Foundation

struct AppConfig {
    // D65 标准白点，与 RAW 加载的基准白平衡一致
    static let defaultWhitePoint: Double = 6500.0

    static let whitePointTolerance: Double = 0.01
}
