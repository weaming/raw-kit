import SwiftUI
import UniformTypeIdentifiers

// LUT list panel
struct LUTPanel: View, Equatable {
    let onLoadLUT: (URL?) -> Void
    @Binding var lutAlpha: Double
    @Binding var currentLUTURL: URL?
    @Binding var adjustments: ImageAdjustments

    @State private var lutFiles: [LUTFile] = []
    @State private var selectedLUT: UUID?
    @State private var showingSaveLUTDialog = false
    @State private var newLUTName = ""
    @State private var isSavingLUT = false
    @State private var lutProfiles: [String: LUTColorProfile] = [:]

    private let colorProfileStorageKey = "LUTColorProfiles"
    private let legacyColorSpaceStorageKey = "LUTColorSpaces"

    static func == (lhs: LUTPanel, rhs: LUTPanel) -> Bool {
        lhs.lutAlpha == rhs.lutAlpha &&
            lhs.currentLUTURL == rhs.currentLUTURL &&
            lhs.adjustments.lutColorProfile == rhs.adjustments.lutColorProfile &&
            lhs.adjustments.hasAdjustments == rhs.adjustments.hasAdjustments
    }

    private var selectedLUTFile: LUTFile? {
        lutFiles.first { $0.id == selectedLUT }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if let selectedLUTFile {
                SimpleSlider(
                    title: "强度",
                    value: $lutAlpha,
                    range: 0.0 ... 1.0,
                    step: 0.01,
                    valueFormatter: { "\(Int($0 * 100))%" }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                LUTProfileEditor(
                    profile: selectedLUTProfileBinding(for: selectedLUTFile)
                )
                .padding(.horizontal, 12)
            }

            Divider()
                .padding(.horizontal, 12)

            if lutFiles.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无 LUT")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("支持 .cube .3dl .lut 格式")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        LUTItemView(
                            name: "无 LUT",
                            summary: nil,
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
                                summary: lutProfile(for: lutFile).summary,
                                isSelected: selectedLUT == lutFile.id,
                                onSelect: {
                                    selectLUT(lutFile)
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
            loadLUTColorProfiles()
            loadLUTFiles()
            syncSelectedLUT()
        }
        .onChange(of: currentLUTURL) { _, _ in
            syncSelectedLUT()
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

    private func lutProfile(for lutFile: LUTFile) -> LUTColorProfile {
        if selectedLUT == lutFile.id {
            return adjustments.lutColorProfile
        }

        return lutProfiles[lutFile.url.path] ?? .default
    }

    private func selectedLUTProfileBinding(for lutFile: LUTFile) -> Binding<LUTColorProfile> {
        Binding(
            get: {
                lutProfile(for: lutFile)
            },
            set: { newProfile in
                setLUTProfile(newProfile, for: lutFile)
            }
        )
    }

    private func setLUTProfile(_ profile: LUTColorProfile, for lutFile: LUTFile) {
        lutProfiles[lutFile.url.path] = profile
        saveLUTColorProfiles()

        if selectedLUT == lutFile.id {
            adjustments.lutColorProfile = profile
        }
    }

    private func selectLUT(_ lutFile: LUTFile) {
        selectedLUT = lutFile.id
        lutAlpha = 1.0
        adjustments.lutColorProfile = lutProfiles[lutFile.url.path] ?? .default
        onLoadLUT(lutFile.url)
    }

    private func syncSelectedLUT() {
        if let currentURL = currentLUTURL {
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "选择 LUT 文件或文件夹（支持子目录扫描）"

        panel.begin { response in
            guard response == .OK else { return }

            Task {
                await importLUTFiles(from: panel.urls)
            }
        }
    }

    private func importLUTFiles(from urls: [URL]) async {
        let supportedExtensions = ["cube", "3dl", "lut"]
        var importedCount = 0
        let lutFolder = getLUTFolderURL()

        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            let lutURLs: [URL] = if isDirectory.boolValue {
                scanLUTFiles(in: url, supportedExtensions: supportedExtensions)
            } else {
                [url]
            }

            for lutURL in lutURLs {
                guard supportedExtensions.contains(lutURL.pathExtension.lowercased()) else {
                    continue
                }

                let fileName = lutURL.lastPathComponent
                let destURL = lutFolder.appendingPathComponent(fileName)

                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        let existingName = destURL.deletingPathExtension().lastPathComponent
                        let ext = destURL.pathExtension
                        var counter = 1
                        var newDestURL = destURL

                        while FileManager.default.fileExists(atPath: newDestURL.path) {
                            let newName = "\(existingName)_\(counter).\(ext)"
                            newDestURL = lutFolder.appendingPathComponent(newName)
                            counter += 1
                        }

                        try FileManager.default.copyItem(at: lutURL, to: newDestURL)
                    } else {
                        try FileManager.default.copyItem(at: lutURL, to: destURL)
                    }

                    importedCount += 1
                } catch {
                    print("导入 LUT 失败 [\(fileName)]: \(error)")
                }
            }
        }

        await MainActor.run {
            loadLUTFiles()
            print("成功导入 \(importedCount) 个 LUT 文件")
        }
    }

    private func scanLUTFiles(in directory: URL, supportedExtensions: [String]) -> [URL] {
        var lutFiles: [URL] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  let isRegularFile = resourceValues.isRegularFile,
                  isRegularFile
            else {
                continue
            }

            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                lutFiles.append(fileURL)
            }
        }

        return lutFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func deleteLUT(_ lut: LUTFile) {
        do {
            try FileManager.default.removeItem(at: lut.url)
            lutProfiles.removeValue(forKey: lut.url.path)
            saveLUTColorProfiles()
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

            syncSelectedLUT()
        } catch {
            print("加载 LUT 列表失败: \(error)")
            lutFiles = []
        }
    }

    private func saveLUTFromAdjustments() async {
        guard !newLUTName.isEmpty else { return }

        isSavingLUT = true

        guard let lutImage = await LUTGenerator.generateLUT(
            from: adjustments,
            sourceImage: nil
        ) else {
            print("生成LUT失败")
            isSavingLUT = false
            return
        }

        let lutFolder = getLUTFolderURL()
        let fileName = "\(newLUTName).cube"
        let fileURL = lutFolder.appendingPathComponent(fileName)

        do {
            try LUTGenerator.saveLUTToCube(
                lutImage: lutImage,
                to: fileURL
            )

            loadLUTFiles()
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

    private func loadLUTColorProfiles() {
        if let data = UserDefaults.standard.data(forKey: colorProfileStorageKey),
           let decoded = try? JSONDecoder().decode([String: LUTColorProfile].self, from: data) {
            lutProfiles = decoded
            return
        }

        if let data = UserDefaults.standard.data(forKey: legacyColorSpaceStorageKey),
           let decoded = try? JSONDecoder().decode([String: LUTColorSpace].self, from: data) {
            lutProfiles = decoded.mapValues { LUTColorProfile.legacy(from: $0.rawValue) }
            saveLUTColorProfiles()
        }
    }

    private func saveLUTColorProfiles() {
        if let encoded = try? JSONEncoder().encode(lutProfiles) {
            UserDefaults.standard.set(encoded, forKey: colorProfileStorageKey)
        }
    }
}

struct LUTItemView: View {
    let name: String
    let summary: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isSelected ? Color.blue : Color.clear)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption)
                    .foregroundColor(isSelected ? .primary : .secondary)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
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

struct LUTProfileEditor: View {
    @Binding var profile: LUTColorProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LUT 变换")
                .font(.caption2)
                .foregroundColor(.secondary)

            LUTOptionRow(
                title: "输入色域",
                selection: $profile.inputGamut,
                label: \.displayName
            )
            LUTOptionRow(
                title: "输入曲线",
                selection: $profile.inputTransfer,
                label: \.displayName
            )
            LUTOptionRow(
                title: "输出色域",
                selection: $profile.outputGamut,
                label: \.displayName
            )
            LUTOptionRow(
                title: "输出曲线",
                selection: $profile.outputTransfer,
                label: \.displayName
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct LUTOptionRow<Option>: View where Option: Hashable & CaseIterable {
    let title: String
    @Binding var selection: Option
    let label: KeyPath<Option, String>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)

            Picker("", selection: $selection) {
                ForEach(Array(Option.allCases), id: \.self) { option in
                    Text(option[keyPath: label]).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

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
                    .help("取消 (Esc)")

                Button("保存", action: onSave)
                    .disabled(lutName.isEmpty || isSaving)
                    .keyboardShortcut(.return)
                    .help("保存 LUT (⏎)")
            }
        }
        .padding(24)
    }
}
