import SwiftUI
import UniformTypeIdentifiers

// LUT 列表面板
struct LUTPanel: View {
    let onLoadLUT: (URL?) -> Void
    @Binding var lutAlpha: Double
    @Binding var currentLUTURL: URL?

    @State private var lutFiles: [LUTFile] = []
    @State private var selectedLUT: UUID?
    @State private var tempAlpha: Double = 1.0
    @State private var isEditingAlpha = false

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
                                onSelect: {
                                    selectedLUT = lutFile.id
                                    lutAlpha = 1.0 // 切换 LUT 时重置 alpha
                                    tempAlpha = 1.0
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
}

// LUT 项视图
struct LUTItemView: View {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
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

// LUT 文件数据模型
struct LUTFile: Identifiable {
    let id: UUID
    let name: String
    let url: URL

    init(name: String, url: URL) {
        id = UUID()
        self.name = name
        self.url = url
    }
}
