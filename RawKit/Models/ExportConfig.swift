import Foundation

// 导出格式
enum ExportFormat: String, Codable, CaseIterable {
    case tiff = "TIFF"
    case jpg = "JPEG"
    case heif = "HEIF"
    case avif = "AVIF"
    case ultraHDRJPEG = "Ultra HDR JPEG"
    case dng = "DNG"

    var fileExtension: String {
        switch self {
        case .tiff: "tiff"
        case .jpg: "jpg"
        case .heif: "heic"
        case .avif: "avif"
        case .ultraHDRJPEG: "jpg"
        case .dng: "dng"
        }
    }

    var description: String {
        switch self {
        case .tiff: "16-bit 无损，适合打印和后期处理"
        case .jpg: "8-bit 有损压缩，适合网络分享"
        case .heif: "10-bit 高效压缩，适合 Apple 生态"
        case .avif: "10-bit 高效压缩，适合支持 AVIF HDR 的平台"
        case .ultraHDRJPEG: "JPG 扩展名，写入 Ultra HDR gain map，适合支持 HDR 图片的平台"
        case .dng: "16-bit 数字底片格式"
        }
    }

    func isCompatible(with outputPreset: ExportOutputPreset) -> Bool {
        outputPreset.compatibleFormats.contains(self)
    }
}

// 输出预设
enum ExportOutputPreset: String, Codable, CaseIterable {
    case sdrSRGB = "SDR sRGB"
    case displayP3SDR = "Display P3 SDR"
    case rec2020HLGHDR = "Rec.2020 HLG HDR"
    case rec2020PQHDR = "Rec.2020 PQ HDR"

    var description: String {
        switch self {
        case .sdrSRGB:
            "标准 SDR 照片输出，兼容性最高"
        case .displayP3SDR:
            "宽色域 SDR，适合 Apple 设备和现代浏览器"
        case .rec2020HLGHDR:
            "照片 HDR 首选，使用 BT.2020 色域和 HLG 传递函数"
        case .rec2020PQHDR:
            "HDR 宽色域输出，适合 PQ HDR 工作流"
        }
    }

    var isHDR: Bool {
        switch self {
        case .sdrSRGB, .displayP3SDR:
            false
        case .rec2020HLGHDR, .rec2020PQHDR:
            true
        }
    }

    var compatibleFormats: [ExportFormat] {
        if isHDR {
            return [.heif, .avif, .ultraHDRJPEG]
        }

        return [.jpg, .heif, .tiff, .dng]
    }

    var preferredFormat: ExportFormat {
        isHDR ? .heif : .jpg
    }
}

enum UltraHDRGainMapCompression: String, Codable, CaseIterable {
    case highQuality = "高质量"
    case balanced = "均衡"
    case compact = "小体积"

    var description: String {
        switch self {
        case .highQuality:
            "完整分辨率 gain map，文件最大，保留最多局部 HDR 细节"
        case .balanced:
            "半分辨率 gain map，体积和 HDR 细节较均衡"
        case .compact:
            "低分辨率 gain map，文件更小，局部 HDR 细节略简化"
        }
    }

    var gainMapScaleFactor: Int {
        switch self {
        case .highQuality:
            1
        case .balanced:
            2
        case .compact:
            4
        }
    }

    var gainMapQualityMultiplier: Double {
        switch self {
        case .highQuality:
            1.0
        case .balanced:
            0.88
        case .compact:
            0.75
        }
    }

    var usesMultiChannelGainMap: Bool {
        false
    }
}

// 导出配置
struct ExportConfig: Codable, Identifiable {
    let id: UUID
    var name: String
    var format: ExportFormat
    var outputPreset: ExportOutputPreset
    var maxDimension: Int? // nil 表示原始尺寸
    var quality: Double // 0.0-1.0，仅用于 JPG 和 HEIF
    var ultraHDRGainMapCompression: UltraHDRGainMapCompression
    var outputDirectory: URL?
    var prefix: String // 文件名前缀
    var suffix: String // 文件名后缀

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case format
        case outputPreset
        case maxDimension
        case quality
        case ultraHDRGainMapCompression
        case outputDirectory
        case prefix
        case suffix
    }

    init(
        name: String = "默认",
        format: ExportFormat = .jpg,
        outputPreset: ExportOutputPreset = .sdrSRGB,
        maxDimension: Int? = nil,
        quality: Double = 0.98,
        ultraHDRGainMapCompression: UltraHDRGainMapCompression = .balanced,
        outputDirectory: URL? = nil,
        prefix: String = "",
        suffix: String = ""
    ) {
        id = UUID()
        self.name = name
        self.format = format
        self.outputPreset = outputPreset
        self.maxDimension = maxDimension
        self.quality = quality
        self.ultraHDRGainMapCompression = ultraHDRGainMapCompression
        self.outputDirectory = outputDirectory
        self.prefix = prefix
        self.suffix = suffix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "默认"
        format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .jpg
        outputPreset = try container.decodeIfPresent(
            ExportOutputPreset.self,
            forKey: .outputPreset
        ) ?? .sdrSRGB

        maxDimension = try container.decodeIfPresent(Int.self, forKey: .maxDimension)
        quality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? 0.98
        ultraHDRGainMapCompression = try container.decodeIfPresent(
            UltraHDRGainMapCompression.self,
            forKey: .ultraHDRGainMapCompression
        ) ?? .balanced
        outputDirectory = try container.decodeIfPresent(URL.self, forKey: .outputDirectory)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? ""

        if !format.isCompatible(with: outputPreset) {
            format = outputPreset.preferredFormat
        }
    }

    static let `default` = ExportConfig()
}

// 导出配置管理器
class ExportConfigManager: ObservableObject {
    @Published var configs: [ExportConfig] = []
    @Published var lastUsedConfig: ExportConfig = .default
    @Published var selectedPresetID: UUID?

    private let configsKey = "ExportConfigs"
    private let lastUsedKey = "LastUsedExportConfig"
    private let selectedPresetKey = "SelectedExportPresetID"

    init() {
        loadConfigs()
        loadLastUsed()
        loadSelectedPreset()
        print("ExportConfigManager: 初始化完成")
        print("ExportConfigManager: 加载了 \(configs.count) 个预设")
        print("ExportConfigManager: selectedPresetID = \(selectedPresetID?.uuidString ?? "nil")")
    }

    func saveConfig(_ config: ExportConfig) {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        saveConfigs()
    }

    func deleteConfig(_ config: ExportConfig) {
        configs.removeAll { $0.id == config.id }
        if selectedPresetID == config.id {
            selectedPresetID = nil
            saveSelectedPreset()
        }
        saveConfigs()
    }

    func updateLastUsed(_ config: ExportConfig) {
        lastUsedConfig = config
        saveLastUsed()
    }

    func selectPreset(_ id: UUID?) {
        selectedPresetID = id
        saveSelectedPreset()
        print("ExportConfigManager: selectPreset(\(id?.uuidString ?? "nil"))")
    }

    private func loadConfigs() {
        if let data = UserDefaults.standard.data(forKey: configsKey),
           let decoded = try? JSONDecoder().decode([ExportConfig].self, from: data) {
            configs = decoded
        }
    }

    private func saveConfigs() {
        if let encoded = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(encoded, forKey: configsKey)
        }
    }

    private func loadLastUsed() {
        if let data = UserDefaults.standard.data(forKey: lastUsedKey),
           let decoded = try? JSONDecoder().decode(ExportConfig.self, from: data) {
            lastUsedConfig = decoded
        }
    }

    private func saveLastUsed() {
        if let encoded = try? JSONEncoder().encode(lastUsedConfig) {
            UserDefaults.standard.set(encoded, forKey: lastUsedKey)
        }
    }

    private func loadSelectedPreset() {
        if let uuidString = UserDefaults.standard.string(forKey: selectedPresetKey),
           let uuid = UUID(uuidString: uuidString) {
            selectedPresetID = uuid
            print("ExportConfigManager: loadSelectedPreset - 加载: \(uuidString)")
        } else {
            print("ExportConfigManager: loadSelectedPreset - 未找到保存的预设ID")
        }
    }

    private func saveSelectedPreset() {
        if let id = selectedPresetID {
            UserDefaults.standard.set(id.uuidString, forKey: selectedPresetKey)
            print("ExportConfigManager: saveSelectedPreset - 保存: \(id.uuidString)")
        } else {
            UserDefaults.standard.removeObject(forKey: selectedPresetKey)
            print("ExportConfigManager: saveSelectedPreset - 清除")
        }
    }
}
