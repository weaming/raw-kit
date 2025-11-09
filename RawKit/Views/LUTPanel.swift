import SwiftUI
import UniformTypeIdentifiers

// LUT 列表面板
struct LUTPanel: View {
    let onLoadLUT: (URL?) -> Void
    @Binding var lutAlpha: Double
    @Binding var currentLUTURL: URL?
    @Binding var adjustments: ImageAdjustments

    @State private var lutFiles: [LUTFile] = []
    @State private var selectedLUT: UUID?
    @State private var tempAlpha: Double = 1.0
    @State private var isEditingAlpha = false
    @State private var showingSaveLUTDialog = false
    @State private var newLUTName = ""
    @State private var isSavingLUT = false
    @State private var lutColorSpaces: [String: LUTColorSpace] = [:]

    private let colorSpaceStorageKey = "LUTColorSpaces"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 导入 LUT 按钮
            Button(action: importLUT) {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入 LUT")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)

            // 保存为 LUT 按钮
            Button(action: {
                showingSaveLUTDialog = true
            }) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("保存为 LUT")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .disabled(!adjustments.hasAdjustments)

            // LUT 强度滑块
            if selectedLUT != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("强度")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("\(Int((isEditingAlpha ? tempAlpha : lutAlpha) * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 35, alignment: .trailing)
                            .monospacedDigit()
                    }

                    Slider(
                        value: Binding(
                            get: { isEditingAlpha ? tempAlpha : lutAlpha },
                            set: { tempAlpha = $0 }
                        ),
                        in: 0.0 ... 1.0,
                        step: 0.01,
                        onEditingChanged: { editing in
                            if editing {
                                isEditingAlpha = true
                                tempAlpha = lutAlpha
                            } else {
                                isEditingAlpha = false
                                lutAlpha = tempAlpha
                            }
                        }
                    )
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Divider()
                .padding(.horizontal, 12)

            // LUT 列表
            if lutFiles.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无 LUT")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("支持 .cube 格式")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        // 无 LUT 选项
                        LUTItemView(
                            name: "无 LUT",
                            isSelected: selectedLUT == nil,
                            colorSpace: .constant(.sRGB),
                            onSelect: {
                                selectedLUT = nil
                                onLoadLUT(nil)
                            },
                            onDelete: nil
                        )

                        ForEach(lutFiles) { lutFile in
                            LUTItemView(
                                name: lutFile.name,
                                isSelected: selectedLUT == lutFile.id,
                                colorSpace: Binding(
                                    get: {
                                        // 如果当前选中该LUT，从adjustments读取
                                        if selectedLUT == lutFile.id {
                                            return LUTColorSpace(rawValue: adjustments
                                                .lutColorSpace) ?? .sRGB
                                        }
                                        // 否则从保存的配置读取
                                        return lutColorSpaces[lutFile.url.path] ?? .sRGB
                                    },
                                    set: { newColorSpace in
                                        // 保存配置
                                        lutColorSpaces[lutFile.url.path] = newColorSpace
                                        saveLUTColorSpaces()

                                        // 如果当前选中该LUT，直接修改adjustments
                                        if selectedLUT == lutFile.id {
                                            adjustments.lutColorSpace = newColorSpace.rawValue
                                        }
                                    }
                                ),
                                onSelect: {
                                    selectedLUT = lutFile.id
                                    lutAlpha = 1.0
                                    tempAlpha = 1.0
                                    // 设置LUT的色彩空间
                                    adjustments
                                        .lutColorSpace = (lutColorSpaces[lutFile.url.path] ?? .sRGB)
                                        .rawValue
                                    onLoadLUT(lutFile.url)
                                },
                                onDelete: {
                                    deleteLUT(lutFile)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .onAppear {
            loadLUTColorSpaces()
            loadLUTFiles()
            syncSelectedLUT()
            tempAlpha = lutAlpha
        }
        .onChange(of: currentLUTURL) { _, _ in
            syncSelectedLUT()
        }
        .onChange(of: lutAlpha) { _, newValue in
            if !isEditingAlpha {
                tempAlpha = newValue
            }
        }
        .sheet(isPresented: $showingSaveLUTDialog) {
            SaveLUTDialog(
                lutName: $newLUTName,
                isSaving: $isSavingLUT,
                onSave: {
                    Task {
                        await saveLUTFromAdjustments()
                    }
                },
                onCancel: {
                    showingSaveLUTDialog = false
                    newLUTName = ""
                }
            )
        }
    }

    private func syncSelectedLUT() {
        if let currentURL = currentLUTURL {
            // 查找匹配的 LUT 文件
            if let matchedFile = lutFiles.first(where: { $0.url == currentURL }) {
                selectedLUT = matchedFile.id
            } else {
                selectedLUT = nil
            }
        } else {
            selectedLUT = nil
        }
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        let cubeType = UTType(filenameExtension: "cube")
        let dl3Type = UTType(filenameExtension: "3dl")
        let lutType = UTType(filenameExtension: "lut")
        panel.allowedContentTypes = [cubeType, dl3Type, lutType].compactMap(\.self)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            // 复制 LUT 文件到应用支持目录
            let destURL = getLUTFolderURL().appendingPathComponent(url.lastPathComponent)

            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: url, to: destURL)
                loadLUTFiles()
            } catch {
                print("导入 LUT 失败: \(error)")
            }
        }
    }

    private func deleteLUT(_ lut: LUTFile) {
        do {
            try FileManager.default.removeItem(at: lut.url)
            loadLUTFiles()

            if selectedLUT == lut.id {
                selectedLUT = nil
            }
        } catch {
            print("删除 LUT 失败: \(error)")
        }
    }

    private func loadLUTFiles() {
        let lutFolder = getLUTFolderURL()
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: lutFolder.path) else {
            lutFiles = []
            return
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: lutFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            let supportedExtensions = ["cube", "3dl", "lut"]
            lutFiles = urls
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                .map { url in
                    LUTFile(
                        name: url.deletingPathExtension().lastPathComponent,
                        url: url
                    )
                }
                .sorted { $0.name < $1.name }

            // 加载完成后同步选择状态
            syncSelectedLUT()
        } catch {
            print("加载 LUT 列表失败: \(error)")
            lutFiles = []
        }
    }

    private func saveLUTFromAdjustments() async {
        guard !newLUTName.isEmpty else { return }

        isSavingLUT = true

        // 生成LUT（包含所有调整，包括当前应用的LUT）
        guard let lutImage = await LUTGenerator.generateLUT(
            from: adjustments,
            sourceImage: nil
        ) else {
            print("生成LUT失败")
            isSavingLUT = false
            return
        }

        // 保存LUT文件
        let lutFolder = getLUTFolderURL()
        let fileName = "\(newLUTName).cube"
        let fileURL = lutFolder.appendingPathComponent(fileName)

        do {
            try LUTGenerator.saveLUTToCube(
                lutImage: lutImage,
                to: fileURL
            )

            // 重新加载LUT列表
            loadLUTFiles()

            // 关闭对话框
            showingSaveLUTDialog = false
            newLUTName = ""

            print("LUT保存成功: \(fileURL.path)")
        } catch {
            print("保存LUT失败: \(error)")
        }

        isSavingLUT = false
    }

    private func getLUTFolderURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let appFolder = appSupport.appendingPathComponent("RawKit", isDirectory: true)
        let lutFolder = appFolder.appendingPathComponent("LUTs", isDirectory: true)

        if !FileManager.default.fileExists(atPath: lutFolder.path) {
            try? FileManager.default.createDirectory(
                at: lutFolder,
                withIntermediateDirectories: true
            )
        }

        return lutFolder
    }

    private func loadLUTColorSpaces() {
        if let data = UserDefaults.standard.data(forKey: colorSpaceStorageKey),
           let decoded = try? JSONDecoder().decode([String: LUTColorSpace].self, from: data) {
            lutColorSpaces = decoded
        }
    }

    private func saveLUTColorSpaces() {
        if let encoded = try? JSONEncoder().encode(lutColorSpaces) {
            UserDefaults.standard.set(encoded, forKey: colorSpaceStorageKey)
        }
    }
}

// LUT 项视图
struct LUTItemView: View {
    let name: String
    let isSelected: Bool
    @Binding var colorSpace: LUTColorSpace
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isSelected ? Color.blue : Color.clear)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    Text(name)
                        .font(.caption)
                        .foregroundColor(isSelected ? .primary : .secondary)
                }

                Spacer()

                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("删除 LUT")
                }
            }

            if onDelete != nil {
                HStack(spacing: 4) {
                    Text("色彩空间:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Picker("", selection: $colorSpace) {
                        ForEach(LUTColorSpace.allCases, id: \.self) { space in
                            Text(space.displayName).tag(space)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.caption2)
                    .frame(width: 100)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

// 保存LUT对话框
struct SaveLUTDialog: View {
    @Binding var lutName: String
    @Binding var isSaving: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("保存为 LUT")
                .font(.headline)

            TextField("LUT 名称", text: $lutName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit {
                    if !lutName.isEmpty {
                        onSave()
                    }
                }

            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.escape)
                    .disabled(isSaving)

                Button("保存", action: onSave)
                    .disabled(lutName.isEmpty || isSaving)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
    }
}
