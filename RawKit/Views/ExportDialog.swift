import AppKit
import SwiftUI

struct ExportDialog: View {
    @StateObject private var configManager = ExportConfigManager()
    @State private var currentConfig: ExportConfig
    @State private var showingSavePresetDialog = false
    @State private var newPresetName = ""
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @FocusState private var focusedField: Field?

    enum Field {
        case none
        case maxDimension
        case prefix
        case suffix
    }

    let imagesToExport: [ImageInfo]
    let adjustmentsForImageID: (UUID) -> ImageAdjustments
    let onExport: (ExportConfig, @escaping @MainActor @Sendable (Double) -> Void) async -> Void
    let onCancel: () -> Void

    init(
        imagesToExport: [ImageInfo],
        adjustmentsForImageID: @escaping (UUID) -> ImageAdjustments,
        onExport: @escaping (ExportConfig, @escaping @MainActor @Sendable (Double) -> Void) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.imagesToExport = imagesToExport
        self.adjustmentsForImageID = adjustmentsForImageID
        self.onExport = onExport
        self.onCancel = onCancel
        _currentConfig = State(initialValue: ExportConfig())
    }

    private var matchedPreset: ExportConfig? {
        configManager.configs.first { configsMatch(currentConfig, $0) }
    }

    private var selectedPresetName: String {
        matchedPreset?.name ?? "自定义"
    }

    private var firstImage: ImageInfo? {
        imagesToExport.first
    }

    private var adjustedImageCount: Int {
        imagesToExport.filter { adjustmentsForImageID($0.id).hasAdjustments }.count
    }

    private var rawImageCount: Int {
        imagesToExport.filter { $0.fileType.isRaw }.count
    }

    private var totalSourceSize: Int64 {
        imagesToExport.reduce(0) { $0 + $1.fileSize }
    }

    private var headerSubtitle: String {
        var parts = ["\(imagesToExport.count) 张照片"]

        if adjustedImageCount > 0 {
            parts.append("\(adjustedImageCount) 张含调整")
        }

        if rawImageCount > 0 {
            parts.append("\(rawImageCount) 张 RAW")
        }

        if totalSourceSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: totalSourceSize, countStyle: .file))
        }

        return parts.joined(separator: " · ")
    }

    private var sampleBaseName: String {
        firstImage?.url.deletingPathExtension().lastPathComponent ?? "IMG_0001"
    }

    private var fileNamePreview: String {
        "\(currentConfig.prefix)\(sampleBaseName)\(currentConfig.suffix).\(currentConfig.format.fileExtension)"
    }

    private var effectiveOutputDirectory: URL? {
        currentConfig.outputDirectory ?? firstImage?.url.deletingLastPathComponent()
    }

    private var outputDirectoryLabel: String {
        currentConfig.outputDirectory?.path ?? "原始文件所在目录"
    }

    private var outputPathPreview: String {
        guard let directory = effectiveOutputDirectory else {
            return fileNamePreview
        }

        return directory.appendingPathComponent(fileNamePreview).path
    }

    private var supportsQuality: Bool {
        currentConfig.format == .jpg ||
            currentConfig.format == .heif ||
            currentConfig.format == .jpegGainMap
    }

    private var availableFormats: [ExportFormat] {
        currentConfig.outputPreset.compatibleFormats
    }

    private var canExport: Bool {
        !imagesToExport.isEmpty && !isExporting
    }

    private var sizeLimitEnabled: Binding<Bool> {
        Binding(
            get: { currentConfig.maxDimension != nil },
            set: { enabled in
                currentConfig.maxDimension = enabled ? (currentConfig.maxDimension ?? 4096) : nil
            }
        )
    }

    private var maxDimensionBinding: Binding<Int> {
        Binding(
            get: { currentConfig.maxDimension ?? 4096 },
            set: { currentConfig.maxDimension = clampMaxDimension($0) }
        )
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { currentConfig.quality },
            set: { currentConfig.quality = min(max($0, 0.5), 1.0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            HStack(spacing: 0) {
                presetsSidebar

                Divider()

                mainConfigurationView
            }

            Divider()

            footerView
        }
        .frame(width: 780, height: 660)
        .overlay(alignment: .topLeading) {
            TextField("", text: .constant(""))
                .frame(width: 0, height: 0)
                .opacity(0)
                .focused($focusedField, equals: Field.none)
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedField = Field.none
                }
        )
        .onAppear {
            loadInitialConfig()
            focusedField = Field.none
        }
        .onSubmit {
            Task {
                await startExport()
            }
        }
        .sheet(isPresented: $showingSavePresetDialog) {
            SaveExportPresetDialog(
                presetName: $newPresetName,
                configSummary: configSummary(currentConfig),
                onSave: saveCurrentPreset,
                onCancel: {
                    showingSavePresetDialog = false
                    newPresetName = ""
                }
            )
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导出")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            ExportInfoBadge(
                icon: "slider.horizontal.3",
                label: "预设",
                value: selectedPresetName
            )

            ExportInfoBadge(
                icon: "square.and.arrow.up",
                label: "格式",
                value: currentConfig.format.rawValue
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var presetsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预设")
                    .font(.headline)

                Spacer()

                Button {
                    newPresetName = ""
                    showingSavePresetDialog = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("保存当前设置为预设")

                Button(role: .destructive) {
                    deleteMatchedPreset()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(matchedPreset == nil)
                .help("删除当前匹配的预设")
            }

            Text("当前：\(selectedPresetName)")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ExportPresetItemView(
                        name: "自定义",
                        summary: configSummary(currentConfig),
                        isSelected: matchedPreset == nil,
                        onSelect: {
                            configManager.selectPreset(nil)
                            focusedField = Field.none
                        }
                    )

                    ForEach(configManager.configs) { config in
                        ExportPresetItemView(
                            name: config.name,
                            summary: configSummary(config),
                            isSelected: matchedPreset?.id == config.id,
                            onSelect: {
                                applyPreset(config)
                            }
                        )
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(16)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .disabled(isExporting)
    }

    private var mainConfigurationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summarySection
                formatSection
                sizeSection
                namingSection
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(isExporting)
    }

    private var summarySection: some View {
        ExportSection(
            title: "导出内容",
            subtitle: "检查范围、命名结果和输出位置"
        ) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))

                    if let thumbnail = firstImage?.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 84)
                            .clipped()
                            .cornerRadius(8)
                    } else {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 84, height: 84)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(firstImage?.filename ?? "没有可导出的图片")
                            .font(.headline)
                            .lineLimit(1)

                        Text(firstImageDescription())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        ExportToken(text: "\(imagesToExport.count) 张")

                        if adjustedImageCount > 0 {
                            ExportToken(text: "\(adjustedImageCount) 张含调整")
                        }

                        if rawImageCount > 0 {
                            ExportToken(text: "\(rawImageCount) 张 RAW")
                        }
                    }

                    previewRow(title: "输出预览", value: outputPathPreview, monospaced: true)
                    previewRow(title: "覆盖策略", value: "同名文件将直接覆盖", monospaced: false)
                }
            }
        }
    }

    private var formatSection: some View {
        ExportSection(
            title: "格式与色彩",
            subtitle: currentConfig.format.description
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("格式", selection: $currentConfig.format) {
                    ForEach(availableFormats, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("输出预设")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Picker("", selection: $currentConfig.outputPreset) {
                            ForEach(ExportOutputPreset.allCases, id: \.self) { outputPreset in
                                Text(outputPreset.rawValue).tag(outputPreset)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(currentConfig.outputPreset.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if supportsQuality {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("质量")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Spacer()

                                Text("\(Int(currentConfig.quality * 100))%")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }

                            Slider(value: qualityBinding, in: 0.5 ... 1.0, step: 0.01)

                            HStack(spacing: 8) {
                                ForEach([0.8, 0.9, 0.98], id: \.self) { value in
                                    ExportQuickChoiceButton(
                                        title: "\(Int(value * 100))%",
                                        isSelected: abs(currentConfig.quality - value) < 0.005
                                    ) {
                                        currentConfig.quality = value
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onChange(of: currentConfig.outputPreset) { _, newOutputPreset in
            currentConfig.colorSpace = newOutputPreset.legacyColorSpace

            if !currentConfig.format.isCompatible(with: newOutputPreset) {
                currentConfig.format = newOutputPreset.preferredFormat
            }
        }
    }

    private var sizeSection: some View {
        ExportSection(
            title: "尺寸",
            subtitle: sizeLimitEnabled.wrappedValue ? "以长边为准，小图不会被放大" : "保持原始分辨率"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("限制长边", isOn: sizeLimitEnabled)
                    .toggleStyle(.switch)

                if currentConfig.maxDimension != nil {
                    HStack(spacing: 12) {
                        TextField("长边", value: maxDimensionBinding, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .focused($focusedField, equals: .maxDimension)

                        Text("px")
                            .foregroundColor(.secondary)

                        Stepper("", value: maxDimensionBinding, in: 256 ... 30000, step: 128)
                            .labelsHidden()

                        Spacer()
                    }

                    HStack(spacing: 8) {
                        ForEach([2048, 4096, 6000], id: \.self) { size in
                            ExportQuickChoiceButton(
                                title: "\(size)",
                                isSelected: currentConfig.maxDimension == size
                            ) {
                                currentConfig.maxDimension = size
                            }
                        }

                        ExportQuickChoiceButton(
                            title: "原始",
                            isSelected: currentConfig.maxDimension == nil
                        ) {
                            currentConfig.maxDimension = nil
                        }
                    }
                }
            }
        }
    }

    private var namingSection: some View {
        ExportSection(
            title: "命名与目录",
            subtitle: "可选前后缀，并实时预览最终文件名"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("前缀")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        TextField("可选", text: $currentConfig.prefix)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .prefix)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("后缀")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        TextField("可选", text: $currentConfig.suffix)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .suffix)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("文件名预览")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(verbatim: fileNamePreview)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("输出目录")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(outputDirectoryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button("选择目录...") {
                            selectOutputDirectory()
                        }

                        Button("显示") {
                            revealOutputDirectory()
                        }
                        .disabled(effectiveOutputDirectory == nil)

                        if currentConfig.outputDirectory != nil {
                            Button("使用原图目录") {
                                currentConfig.outputDirectory = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private var footerView: some View {
        HStack(spacing: 16) {
            if isExporting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("正在导出 \(Int(exportProgress * 100))%")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ProgressView(value: exportProgress)
                        .frame(width: 260)
                }

                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(configSummary(currentConfig))
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(outputDirectoryLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }

            Button("取消") {
                onCancel()
            }
            .keyboardShortcut(.escape)
            .disabled(isExporting)

            Button(isExporting ? "导出中..." : "导出 \(imagesToExport.count) 张") {
                Task {
                    await startExport()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func previewRow(title: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(verbatim: value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundColor(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func firstImageDescription() -> String {
        guard let firstImage else {
            return "没有可导出的图片"
        }

        var parts: [String] = []

        if let dimensions = firstImage.dimensions {
            parts.append("\(Int(dimensions.width))×\(Int(dimensions.height))")
        }

        parts.append(firstImage.fileType.displayName)

        if imagesToExport.count > 1 {
            parts.append("+\(imagesToExport.count - 1) 张")
        }

        return parts.joined(separator: " · ")
    }

    private func loadInitialConfig() {
        if let selectedID = configManager.selectedPresetID,
           let preset = configManager.configs.first(where: { $0.id == selectedID }) {
            currentConfig = preset
        } else {
            currentConfig = configManager.lastUsedConfig
        }
    }

    private func applyPreset(_ preset: ExportConfig) {
        currentConfig = preset
        configManager.selectPreset(preset.id)
        focusedField = Field.none
    }

    private func deleteMatchedPreset() {
        guard let matchedPreset else { return }
        configManager.deleteConfig(matchedPreset)
    }

    private func saveCurrentPreset() {
        let trimmedName = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let preset = ExportConfig(
            name: trimmedName,
            format: currentConfig.format,
            outputPreset: currentConfig.outputPreset,
            maxDimension: currentConfig.maxDimension,
            quality: currentConfig.quality,
            outputDirectory: currentConfig.outputDirectory,
            prefix: currentConfig.prefix,
            suffix: currentConfig.suffix
        )

        configManager.saveConfig(preset)
        currentConfig = preset
        configManager.selectPreset(preset.id)
        showingSavePresetDialog = false
        newPresetName = ""
    }

    private func startExport() async {
        guard canExport else { return }

        focusedField = Field.none
        isExporting = true
        exportProgress = 0.0

        configManager.updateLastUsed(currentConfig)

        if let matchedPreset {
            configManager.selectPreset(matchedPreset.id)
        } else {
            configManager.selectPreset(nil)
        }

        await onExport(currentConfig) { progress in
            exportProgress = progress
        }

        exportProgress = 1.0
        isExporting = false
        onCancel()
    }

    private func configsMatch(_ config1: ExportConfig, _ config2: ExportConfig) -> Bool {
        config1.format == config2.format &&
            config1.outputPreset == config2.outputPreset &&
            config1.maxDimension == config2.maxDimension &&
            abs(config1.quality - config2.quality) < 0.001 &&
            config1.outputDirectory?.path == config2.outputDirectory?.path &&
            config1.prefix == config2.prefix &&
            config1.suffix == config2.suffix
    }

    private func clampMaxDimension(_ value: Int) -> Int {
        min(max(value, 256), 30000)
    }

    private func configSummary(_ config: ExportConfig) -> String {
        let sizeLabel = config.maxDimension.map { "\($0) px" } ?? "原始尺寸"

        if config.format == .jpg ||
            config.format == .heif ||
            config.format == .jpegGainMap
        {
            return "\(config.format.rawValue) · \(config.outputPreset.rawValue) · \(sizeLabel) · \(Int(config.quality * 100))%"
        }

        return "\(config.format.rawValue) · \(config.outputPreset.rawValue) · \(sizeLabel)"
    }

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            currentConfig.outputDirectory = url
        }
    }

    private func revealOutputDirectory() {
        guard let directory = effectiveOutputDirectory else { return }
        NSWorkspace.shared.open(directory)
    }
}

struct ExportPresetItemView: View {
    let name: String
    let summary: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ExportSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ExportInfoBadge: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ExportToken: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(Capsule())
    }
}

struct ExportQuickChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }
}

struct SaveExportPresetDialog: View {
    @Binding var presetName: String
    let configSummary: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    private var trimmedPresetName: String {
        presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存导出预设")
                .font(.headline)

            Text("将当前导出设置保存为可复用的预设。")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("预设名称", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    if !trimmedPresetName.isEmpty {
                        presetName = trimmedPresetName
                        onSave()
                    }
                }

            Text(configSummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Spacer()

                Button("取消", action: onCancel)
                    .keyboardShortcut(.escape)

                Button("保存") {
                    presetName = trimmedPresetName
                    onSave()
                }
                .disabled(trimmedPresetName.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
