import SwiftUI

// 调整预设面板
struct PresetsPanel: View, Equatable {
    let currentAdjustments: ImageAdjustments
    let onLoadPreset: (ImageAdjustments) -> Void

    @State private var presets: [AdjustmentPreset] = []
    @State private var showingSaveDialog = false
    @State private var newPresetName = ""

    static func == (lhs: PresetsPanel, rhs: PresetsPanel) -> Bool {
        // 比较完整的 adjustments，确保保存预设时使用最新的值
        lhs.currentAdjustments == rhs.currentAdjustments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 保存当前调整为预设
            Button(action: {
                showingSaveDialog = true
            }) {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("保存当前调整")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)

            Divider()
                .padding(.horizontal, 12)

            // 预设列表
            if presets.isEmpty {
                Text("暂无预设")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(presets) { preset in
                            PresetItemView(
                                preset: preset,
                                onLoad: {
                                    onLoadPreset(preset.adjustments)
                                },
                                onDelete: {
                                    deletePreset(preset)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .sheet(isPresented: $showingSaveDialog) {
            SavePresetDialog(
                presetName: $newPresetName,
                onSave: {
                    savePreset(name: newPresetName)
                    showingSaveDialog = false
                    newPresetName = ""
                },
                onCancel: {
                    showingSaveDialog = false
                    newPresetName = ""
                }
            )
        }
        .onAppear {
            loadPresets()
        }
    }

    private func savePreset(name: String) {
        guard !name.isEmpty else { return }

        // 保存为单独的文件
        let fileURL = getPresetFileURL(for: name)

        // 检查是否存在同名预设（用于覆盖）
        let existingPreset = presets.first { $0.name == name }

        let preset: AdjustmentPreset
        if let existing = existingPreset {
            // 覆盖：保留原有的 id 和 createdAt，只更新 adjustments
            preset = AdjustmentPreset(
                id: existing.id,
                name: name,
                adjustments: currentAdjustments,
                createdAt: existing.createdAt
            )
            print("预设已覆盖: \(name)")
        } else {
            // 新建：创建新的预设
            preset = AdjustmentPreset(
                name: name,
                adjustments: currentAdjustments,
                createdAt: Date()
            )
            print("预设已创建: \(name)")
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(preset)
            try data.write(to: fileURL)
            print("预设已保存: \(fileURL.path)")

            // 重新加载预设列表
            loadPresets()
        } catch {
            print("保存预设失败: \(error)")
        }
    }

    private func deletePreset(_ preset: AdjustmentPreset) {
        let fileURL = getPresetFileURL(for: preset.name)
        do {
            try FileManager.default.removeItem(at: fileURL)
            print("预设已删除: \(fileURL.path)")

            // 重新加载预设列表
            loadPresets()
        } catch {
            print("删除预设失败: \(error)")
        }
    }

    private func loadPresets() {
        let presetsFolder = getPresetsFolderURL()
        let fileManager = FileManager.default

        // 迁移旧的 presets.json 文件（如果存在）
        migrateOldPresetsFile()

        guard fileManager.fileExists(atPath: presetsFolder.path) else {
            presets = []
            return
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: presetsFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            var loadedPresets: [AdjustmentPreset] = []
            for url in urls where url.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    let preset = try JSONDecoder().decode(AdjustmentPreset.self, from: data)
                    loadedPresets.append(preset)
                } catch {
                    print("加载预设文件失败 \(url.lastPathComponent): \(error)")
                }
            }

            presets = loadedPresets.sorted { $0.createdAt > $1.createdAt }
        } catch {
            print("加载预设列表失败: \(error)")
            presets = []
        }
    }

    private func migrateOldPresetsFile() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let appFolder = appSupport.appendingPathComponent("RawKit", isDirectory: true)
        let oldFileURL = appFolder.appendingPathComponent("presets.json")

        guard FileManager.default.fileExists(atPath: oldFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: oldFileURL)
            let oldPresets = try JSONDecoder().decode([AdjustmentPreset].self, from: data)

            // 将每个预设保存为单独的文件
            for preset in oldPresets {
                let fileURL = getPresetFileURL(for: preset.name)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let presetData = try encoder.encode(preset)
                try presetData.write(to: fileURL)
            }

            // 删除旧文件
            try FileManager.default.removeItem(at: oldFileURL)
            print("已迁移 \(oldPresets.count) 个预设到新格式")
        } catch {
            print("迁移旧预设失败: \(error)")
        }
    }

    private func getPresetsFolderURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let appFolder = appSupport.appendingPathComponent("RawKit", isDirectory: true)
        let presetsFolder = appFolder.appendingPathComponent("Presets", isDirectory: true)

        if !FileManager.default.fileExists(atPath: presetsFolder.path) {
            try? FileManager.default.createDirectory(
                at: presetsFolder,
                withIntermediateDirectories: true
            )
        }

        return presetsFolder
    }

    private func getPresetFileURL(for name: String) -> URL {
        let presetsFolder = getPresetsFolderURL()
        // 清理文件名中的非法字符
        let safeName = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return presetsFolder.appendingPathComponent("\(safeName).json")
    }
}

// 预设项视图
struct PresetItemView: View {
    let preset: AdjustmentPreset
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onLoad) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.caption)
                            .foregroundColor(.primary)

                        Text(formatDate(preset.createdAt))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
            }
            .buttonStyle(.borderless)
            .help("删除预设")
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(4)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// 保存预设对话框
struct SavePresetDialog: View {
    @Binding var presetName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("保存调整预设")
                .font(.headline)

            TextField("预设名称", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit {
                    if !presetName.isEmpty {
                        onSave()
                    }
                }

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.escape)
                    .help("取消 (Esc)")

                Button("保存", action: onSave)
                    .keyboardShortcut(.return)
                    .disabled(presetName.isEmpty)
                    .help("保存预设 (⏎)")
            }
        }
        .padding(24)
    }
}
