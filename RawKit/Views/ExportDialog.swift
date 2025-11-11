import SwiftUI

struct ExportDialog: View {
    @StateObject private var configManager = ExportConfigManager()
    @State private var currentConfig: ExportConfig
    @State private var showingSavePresetDialog = false
    @State private var newPresetName = ""
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var isLoadingPreset = false
    @FocusState private var focusedField: Field?

    enum Field {
        case none  // 默认焦点，实际不显示
        case maxDimension
        case prefix
        case suffix
    }

    let imagesToExport: [ImageInfo]
    let adjustmentsCache: [UUID: ImageAdjustments]
    let onExport: (ExportConfig) -> Void
    let onCancel: () -> Void

    init(
        imagesToExport: [ImageInfo],
        adjustmentsCache: [UUID: ImageAdjustments],
        onExport: @escaping (ExportConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.imagesToExport = imagesToExport
        self.adjustmentsCache = adjustmentsCache
        self.onExport = onExport
        self.onCancel = onCancel
        _currentConfig = State(initialValue: ExportConfig())
    }

    var body: some View {
        VStack(spacing: 0) {
            // 隐藏的焦点接收器，防止输入框自动获得焦点
            TextField("", text: .constant(""))
                .frame(width: 0, height: 0)
                .opacity(0)
                .focused($focusedField, equals: Field.none)

            // 标题
            HStack {
                Text("导出图片")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(imagesToExport.count) 张图片")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // 预设选择
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("预设")
                        .font(.headline)

                    Spacer()

                    Button(action: {
                        showingSavePresetDialog = true
                    }) {
                        Image(systemName: "plus.circle")
                    }
                    .help("保存为预设")

                    if let matchedPreset = configManager.configs.first(where: { configsMatch(
                        currentConfig,
                        $0
                    ) }) {
                        Button(action: {
                            print("ExportDialog: 删除预设 - \(matchedPreset.name)")
                            configManager.deleteConfig(matchedPreset)
                        }) {
                            Image(systemName: "trash")
                        }
                        .help("删除预设")
                    }
                }

                // 预设列表框
                ScrollView {
                    VStack(spacing: 0) {
                        // 自定义选项
                        ExportPresetItemView(
                            name: "自定义",
                            isSelected: !configManager.configs.contains(where: { configsMatch(
                                currentConfig,
                                $0
                            ) }),
                            onSelect: {
                                configManager.selectPreset(nil)
                            }
                        )

                        // 预设列表
                        ForEach(configManager.configs) { config in
                            ExportPresetItemView(
                                name: config.name,
                                isSelected: configsMatch(currentConfig, config),
                                onSelect: {
                                    print("ExportDialog: 用户选择预设 - \(config.name)")
                                    isLoadingPreset = true
                                    currentConfig = config
                                    configManager.selectPreset(config.id)
                                    isLoadingPreset = false
                                }
                            )
                        }
                    }
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color(nsColor: .separatorColor), width: 1)
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()

            // 配置项区域
            VStack(alignment: .leading, spacing: 20) {
                // 格式
                VStack(alignment: .leading, spacing: 8) {
                    Text("格式")
                        .font(.headline)

                    Picker("", selection: $currentConfig.format) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // 色彩空间
                VStack(alignment: .leading, spacing: 8) {
                    Text("色彩空间")
                        .font(.headline)

                    Picker("", selection: $currentConfig.colorSpace) {
                        ForEach(ExportColorSpace.allCases, id: \.self) { space in
                            Text(space.rawValue).tag(space)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // 尺寸
                VStack(alignment: .leading, spacing: 8) {
                    Text("尺寸")
                        .font(.headline)

                    Toggle("限制长边", isOn: Binding(
                        get: { currentConfig.maxDimension != nil },
                        set: { enabled in
                            currentConfig.maxDimension = enabled ? 6000 : nil
                        }
                    ))

                    if currentConfig.maxDimension != nil {
                        HStack {
                            TextField("像素", value: Binding(
                                get: { currentConfig.maxDimension ?? 6000 },
                                set: { currentConfig.maxDimension = $0 }
                            ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .focused($focusedField, equals: .maxDimension)

                            Text("px")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // 质量（仅 JPG 和 HEIF）
                if currentConfig.format == .jpg || currentConfig.format == .heif {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("质量")
                                .font(.headline)

                            Spacer()

                            Text("\(Int(currentConfig.quality * 100))%")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $currentConfig.quality, in: 0.5 ... 1.0, step: 0.01)
                    }
                }

                // 文件名
                VStack(alignment: .leading, spacing: 8) {
                    Text("文件名")
                        .font(.headline)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("前缀")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("", text: $currentConfig.prefix)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .prefix)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("后缀")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("", text: $currentConfig.suffix)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .suffix)
                        }
                    }

                    Text("同名文件将被覆盖")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }

                // 输出目录
                VStack(alignment: .leading, spacing: 8) {
                    Text("输出目录")
                        .font(.headline)

                    HStack {
                        Text(currentConfig.outputDirectory?.path ?? "原始文件所在目录")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("选择...") {
                            selectOutputDirectory()
                        }

                        if currentConfig.outputDirectory != nil {
                            Button("清除") {
                                currentConfig.outputDirectory = nil
                            }
                        }
                    }
                }
            }
            .padding()

            Divider()

            // 按钮
            HStack {
                if isExporting {
                    ProgressView(value: exportProgress) {
                        Text("导出中... \(Int(exportProgress * 100))%")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Spacer()

                    Button("取消") {
                        onCancel()
                    }
                    .keyboardShortcut(.escape)
                    .help("取消导出 (Esc)")

                    Button("导出") {
                        print("ExportDialog: 点击导出按钮")

                        // 保存当前配置为上次使用的配置
                        configManager.updateLastUsed(currentConfig)

                        // 检查当前配置是否匹配某个预设，如果匹配就保存该预设的 ID
                        if let matchedPreset = configManager.configs.first(where: { configsMatch(
                            currentConfig,
                            $0
                        ) }) {
                            print("ExportDialog: 保存匹配的预设ID - \(matchedPreset.name)")
                            configManager.selectPreset(matchedPreset.id)
                        } else {
                            print("ExportDialog: 保存为自定义配置")
                            configManager.selectPreset(nil)
                        }

                        onExport(currentConfig)
                    }
                    .keyboardShortcut(.return)
                    .help("开始导出 (⏎)")
                }
            }
            .padding()
        }
        .frame(width: 500, height: 750)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedField = Field.none
                }
        )
        .onAppear {
            // 根据上次选择的预设加载配置
            if let selectedID = configManager.selectedPresetID,
               let preset = configManager.configs.first(where: { $0.id == selectedID }) {
                print("ExportDialog: onAppear - 加载预设: \(preset.name)")
                isLoadingPreset = true
                currentConfig = preset
                isLoadingPreset = false
            } else {
                print("ExportDialog: onAppear - 加载自定义配置")
                currentConfig = configManager.lastUsedConfig
            }

            // 默认焦点到隐藏的控件，防止输入框自动获得焦点
            focusedField = Field.none
        }
        .sheet(isPresented: $showingSavePresetDialog) {
            SaveExportPresetDialog(
                presetName: $newPresetName,
                onSave: {
                    // 创建新预设（使用新的 ID，避免覆盖现有预设）
                    let preset = ExportConfig(
                        name: newPresetName,
                        format: currentConfig.format,
                        colorSpace: currentConfig.colorSpace,
                        maxDimension: currentConfig.maxDimension,
                        quality: currentConfig.quality,
                        outputDirectory: currentConfig.outputDirectory,
                        prefix: currentConfig.prefix,
                        suffix: currentConfig.suffix
                    )
                    configManager.saveConfig(preset)

                    // 保存后切换到新预设
                    isLoadingPreset = true
                    currentConfig = preset
                    configManager.selectPreset(preset.id)
                    isLoadingPreset = false

                    showingSavePresetDialog = false
                    newPresetName = ""
                },
                onCancel: {
                    showingSavePresetDialog = false
                    newPresetName = ""
                }
            )
        }
    }

    private func configsMatch(_ config1: ExportConfig, _ config2: ExportConfig) -> Bool {
        config1.format == config2.format &&
            config1.colorSpace == config2.colorSpace &&
            config1.maxDimension == config2.maxDimension &&
            abs(config1.quality - config2.quality) < 0.001 &&
            config1.outputDirectory?.path == config2.outputDirectory?.path &&
            config1.prefix == config2.prefix &&
            config1.suffix == config2.suffix
    }

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            currentConfig.outputDirectory = url
        }
    }
}

struct ExportPresetItemView: View {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            Text(name)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

struct SaveExportPresetDialog: View {
    @Binding var presetName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            // 隐藏的焦点接收器
            TextField("", text: .constant(""))
                .frame(width: 0, height: 0)
                .opacity(0)
                .focused($isTextFieldFocused, equals: false)

            Text("保存导出预设")
                .font(.headline)

            TextField("预设名称", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .focused($isTextFieldFocused, equals: true)
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
                    .disabled(presetName.isEmpty)
                    .keyboardShortcut(.return)
                    .help("保存导出预设 (⏎)")
            }
        }
        .padding(24)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    isTextFieldFocused = false
                }
        )
        .onAppear {
            // 默认焦点到隐藏的控件
            isTextFieldFocused = false
        }
    }
}
