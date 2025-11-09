import Foundation
import CoreGraphics

// LUT 文件数据模型
struct LUTFile: Identifiable, Codable {
    let id: UUID
    let name: String
    let url: URL
    var colorSpace: LUTColorSpace

    init(name: String, url: URL, colorSpace: LUTColorSpace = .sRGB) {
        id = UUID()
        self.name = name
        self.url = url
        self.colorSpace = colorSpace
    }
}

// LUT 输入色彩空间
enum LUTColorSpace: String, Codable, CaseIterable {
    case sRGB
    case linear = "Linear"
    case rec709 = "Rec.709"
    case rec2020 = "Rec.2020"

    var displayName: String {
        rawValue
    }

    var cgColorSpace: CGColorSpace? {
        switch self {
        case .sRGB:
            CGColorSpace(name: CGColorSpace.sRGB)
        case .linear:
            CGColorSpace(name: CGColorSpace.linearSRGB)
        case .rec709:
            CGColorSpace(name: CGColorSpace.itur_709)
        case .rec2020:
            CGColorSpace(name: CGColorSpace.itur_2020)
        }
    }
}
