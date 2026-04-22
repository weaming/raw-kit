import Foundation

struct LUTSourceGroup: Codable, Hashable {
    let id: String
    let name: String

    static let saved = LUTSourceGroup(id: "__saved__", name: "已保存")
    static let ungrouped = LUTSourceGroup(id: "__ungrouped__", name: "未分组")
}

// LUT 文件数据模型
struct LUTFile: Identifiable {
    let id: UUID
    let name: String
    let url: URL
    let sourceGroup: LUTSourceGroup

    init(name: String, url: URL, sourceGroup: LUTSourceGroup = .ungrouped) {
        id = UUID()
        self.name = name
        self.url = url
        self.sourceGroup = sourceGroup
    }
}

struct LUTColorProfile: Codable, Equatable {
    var inputGamut: LUTGamut = .sRGB
    var inputTransfer: LUTTransferFunction = .sRGB
    var outputGamut: LUTGamut = .sRGB
    var outputTransfer: LUTTransferFunction = .sRGB

    static let `default` = LUTColorProfile()

    static func legacy(from rawValue: String) -> LUTColorProfile {
        switch LUTColorSpace(rawValue: rawValue) ?? .sRGB {
        case .sRGB:
            .default
        case .linear:
            LUTColorProfile(
                inputGamut: .sRGB,
                inputTransfer: .linear,
                outputGamut: .sRGB,
                outputTransfer: .linear
            )
        case .rec709:
            LUTColorProfile(
                inputGamut: .rec709,
                inputTransfer: .rec709,
                outputGamut: .rec709,
                outputTransfer: .rec709
            )
        case .rec2020:
            LUTColorProfile(
                inputGamut: .rec2020,
                inputTransfer: .rec709,
                outputGamut: .rec2020,
                outputTransfer: .rec709
            )
        }
    }

    var legacyCombinedColorSpace: LUTColorSpace {
        if inputGamut == .sRGB, inputTransfer == .linear,
           outputGamut == .sRGB, outputTransfer == .linear {
            return .linear
        }

        if inputGamut == .rec709, inputTransfer == .rec709,
           outputGamut == .rec709, outputTransfer == .rec709 {
            return .rec709
        }

        if inputGamut == .rec2020, inputTransfer == .rec709,
           outputGamut == .rec2020, outputTransfer == .rec709 {
            return .rec2020
        }

        return .sRGB
    }

    var summary: String {
        "In \(inputGamut.shortDisplayName) / \(inputTransfer.shortDisplayName) -> Out \(outputGamut.shortDisplayName) / \(outputTransfer.shortDisplayName)"
    }
}

enum LUTGamut: String, Codable, CaseIterable {
    case sRGB = "sRGB"
    case displayP3 = "Display P3"
    case rec709 = "Rec.709"
    case dciP3 = "DCI-P3"
    case rec2020 = "Rec.2020"
    case fGamut = "F-Gamut"
    case fGamutC = "F-Gamut C"

    var displayName: String {
        rawValue
    }

    var shortDisplayName: String {
        rawValue
    }
}

enum LUTTransferFunction: String, Codable, CaseIterable {
    case linear = "Linear"
    case sRGB = "sRGB"
    case gamma22 = "Gamma 2.2"
    case gamma24 = "Gamma 2.4"
    case gamma26 = "Gamma 2.6"
    case rec709 = "Rec.709"
    case hlg = "HLG"
    case pq = "PQ (ST 2084)"
    case fLog = "F-Log"
    case fLog2 = "F-Log2"
    case fLog2C = "F-Log2 C"

    var displayName: String {
        rawValue
    }

    var shortDisplayName: String {
        switch self {
        case .pq:
            "PQ"
        case .fLog2C:
            "F-Log2C"
        default:
            rawValue
        }
    }
}

// 旧版单一色彩空间枚举，仅用于迁移历史配置
enum LUTColorSpace: String, Codable, CaseIterable {
    case sRGB
    case linear = "Linear"
    case rec709 = "Rec.709"
    case rec2020 = "Rec.2020"

    var displayName: String {
        rawValue
    }
}
