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

struct LUTProfilePreset: Identifiable {
    static let customID = "__custom__"

    let id: String
    let displayName: String
    let profile: LUTColorProfile

    static let common: [LUTProfilePreset] = [
        LUTProfilePreset(
            id: "photo-srgb",
            displayName: "照片 sRGB LUT",
            profile: .default
        ),
        LUTProfilePreset(
            id: "photo-linear-srgb",
            displayName: "照片 Linear sRGB LUT",
            profile: LUTColorProfile(
                inputGamut: .sRGB,
                inputTransfer: .linear,
                outputGamut: .sRGB,
                outputTransfer: .linear
            )
        ),
        LUTProfilePreset(
            id: "video-rec709",
            displayName: "视频 Rec.709 LUT",
            profile: LUTColorProfile(
                inputGamut: .rec709,
                inputTransfer: .gamma24,
                outputGamut: .rec709,
                outputTransfer: .gamma24
            )
        ),
        LUTProfilePreset(
            id: "all-rec709",
            displayName: "All Rec.709",
            profile: LUTColorProfile(
                inputGamut: .rec709,
                inputTransfer: .rec709,
                outputGamut: .rec709,
                outputTransfer: .rec709
            )
        ),
        LUTProfilePreset(
            id: "hdr-hlg-to-sdr-rec709",
            displayName: "HDR HLG -> SDR Rec.709",
            profile: LUTColorProfile(
                inputGamut: .rec2020,
                inputTransfer: .hlg,
                outputGamut: .rec709,
                outputTransfer: .gamma24
            )
        ),
        LUTProfilePreset(
            id: "hdr-pq-to-sdr-rec709",
            displayName: "HDR PQ -> SDR Rec.709",
            profile: LUTColorProfile(
                inputGamut: .rec2020,
                inputTransfer: .pq,
                outputGamut: .rec709,
                outputTransfer: .gamma24
            )
        ),
        LUTProfilePreset(
            id: "fuji-flog-to-rec709",
            displayName: "Fuji F-Log -> Rec.709",
            profile: LUTColorProfile(
                inputGamut: .fGamut,
                inputTransfer: .fLog,
                outputGamut: .rec709,
                outputTransfer: .rec709
            )
        ),
        LUTProfilePreset(
            id: "fuji-flog2-to-rec709",
            displayName: "Fuji F-Log2 -> Rec.709",
            profile: LUTColorProfile(
                inputGamut: .fGamut,
                inputTransfer: .fLog2,
                outputGamut: .rec709,
                outputTransfer: .rec709
            )
        ),
        LUTProfilePreset(
            id: "sony-slog3-to-rec709",
            displayName: "Sony SL3 & SG3C -> Rec.709",
            profile: LUTColorProfile(
                inputGamut: .sonySGamut3Cine,
                inputTransfer: .sLog3,
                outputGamut: .rec709,
                outputTransfer: .rec709
            )
        ),
        LUTProfilePreset(
            id: "sony-slog2-to-rec709",
            displayName: "Sony SL2 & SG3  -> Rec.709",
            profile: LUTColorProfile(
                inputGamut: .sonySGamut,
                inputTransfer: .sLog2,
                outputGamut: .rec709,
                outputTransfer: .rec709
            )
        ),
        LUTProfilePreset(
            id: "dji-dlog-to-rec709",
            displayName: "DJI D-Log -> Rec.709",
            profile: LUTColorProfile(
                inputGamut: .djiDGamut,
                inputTransfer: .dLog,
                outputGamut: .rec709,
                outputTransfer: .gamma24
            )
        ),
        LUTProfilePreset(
            id: "canon-log3-to-rec709",
            displayName: "Canon Log 3 -> Rec.709",
            profile: LUTColorProfile(
                inputGamut: .canonCinemaGamut,
                inputTransfer: .canonLog3,
                outputGamut: .rec709,
                outputTransfer: .gamma24
            )
        ),
        LUTProfilePreset(
            id: "panasonic-vlog-to-rec709",
            displayName: "Panasonic V-Log -> Rec.709",
            profile: LUTColorProfile(
                inputGamut: .panasonicVGamut,
                inputTransfer: .vLog,
                outputGamut: .rec709,
                outputTransfer: .gamma24
            )
        ),
    ]

    static func matching(_ profile: LUTColorProfile) -> LUTProfilePreset? {
        common.first { $0.profile == profile }
    }

    static func preset(for id: String) -> LUTProfilePreset? {
        common.first { $0.id == id }
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
    case sonySGamut = "Sony S-Gamut"
    case sonySGamut3Cine = "Sony S-Gamut3.Cine"
    case djiDGamut = "DJI D-Gamut"
    case canonCinemaGamut = "Canon Cinema Gamut"
    case panasonicVGamut = "Panasonic V-Gamut"

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
    case sLog2 = "S-Log2"
    case sLog3 = "S-Log3"
    case dLog = "D-Log"
    case canonLog3 = "Canon Log 3"
    case vLog = "V-Log"

    var displayName: String {
        rawValue
    }

    var shortDisplayName: String {
        switch self {
        case .pq:
            "PQ"
        case .fLog2C:
            "F-Log2C"
        case .canonLog3:
            "C-Log3"
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
