import SwiftUI

// 调整预设面板
struct PresetsPanel: View {
    let currentAdjustments: ImageAdjustments
    let onLoadPreset: (ImageAdjustments) -> Void

    @State private var presets: [AdjustmentPreset] = []
    @State private var showingSaveDialog = false
    @State private var newPresetName = ""

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

        // 检查重名
        if presets.contains(where: { $0.name == name }) {
            // 已存在同名预设，更新而不是添加
            if let index = presets.firstIndex(where: { $0.name == name }) {
                presets[index] = AdjustmentPreset(
                    name: name,
                    adjustments: currentAdjustments,
                    createdAt: Date()
                )
            }
        } else {
            // 新预设
            let preset = AdjustmentPreset(
                name: name,
                adjustments: currentAdjustments,
                createdAt: Date()
            )
            presets.append(preset)
        }

        savePresetsToFile()
    }

    private func deletePreset(_ preset: AdjustmentPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresetsToFile()
    }

    private func loadPresets() {
        let fileManager = FileManager.default
        let presetsURL = getPresetsFileURL()

        guard fileManager.fileExists(atPath: presetsURL.path) else { return }

        do {
            let data = try Data(contentsOf: presetsURL)
            presets = try JSONDecoder().decode([AdjustmentPreset].self, from: data)
        } catch {
            print("加载预设失败: \(error)")
        }
    }

    private func savePresetsToFile() {
        let presetsURL = getPresetsFileURL()

        do {
            let data = try JSONEncoder().encode(presets)
            try data.write(to: presetsURL)
        } catch {
            print("保存预设失败: \(error)")
        }
    }

    private func getPresetsFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let appFolder = appSupport.appendingPathComponent("RawKit", isDirectory: true)

        if !FileManager.default.fileExists(atPath: appFolder.path) {
            try? FileManager.default.createDirectory(
                at: appFolder,
                withIntermediateDirectories: true
            )
        }

        return appFolder.appendingPathComponent("presets.json")
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

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.escape)

                Button("保存", action: onSave)
                    .keyboardShortcut(.return)
                    .disabled(presetName.isEmpty)
            }
        }
        .padding(24)
    }
}

// 调整预设数据模型
struct AdjustmentPreset: Identifiable, Codable {
    let id: UUID
    let name: String
    let adjustments: ImageAdjustments
    let createdAt: Date

    init(name: String, adjustments: ImageAdjustments, createdAt: Date) {
        id = UUID()
        self.name = name
        self.adjustments = adjustments
        self.createdAt = createdAt
    }
}
