import Foundation

// 导出格式
enum ExportFormat: String, Codable, CaseIterable {
    case dng = "DNG"
    case jpg = "JPEG"
    case heif = "HEIF"

    var fileExtension: String {
        switch self {
        case .dng: "dng"
        case .jpg: "jpg"
        case .heif: "heic"
        }
    }
}

// 色彩空间
enum ExportColorSpace: String, Codable, CaseIterable {
    case sRGB
    case displayP3 = "Display P3"
    case adobeRGB = "Adobe RGB"
    case proPhotoRGB = "ProPhoto RGB"
}

// 导出配置
struct ExportConfig: Codable, Identifiable {
    let id: UUID
    var name: String
    var format: ExportFormat
    var colorSpace: ExportColorSpace
    var maxDimension: Int? // nil 表示原始尺寸
    var quality: Double // 0.0-1.0，仅用于 JPG 和 HEIF
    var outputDirectory: URL?
    var prefix: String // 文件名前缀
    var suffix: String // 文件名后缀

    init(
        name: String = "默认",
        format: ExportFormat = .jpg,
        colorSpace: ExportColorSpace = .sRGB,
        maxDimension: Int? = nil,
        quality: Double = 0.98,
        outputDirectory: URL? = nil,
        prefix: String = "",
        suffix: String = ""
    ) {
        id = UUID()
        self.name = name
        self.format = format
        self.colorSpace = colorSpace
        self.maxDimension = maxDimension
        self.quality = quality
        self.outputDirectory = outputDirectory
        self.prefix = prefix
        self.suffix = suffix
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
