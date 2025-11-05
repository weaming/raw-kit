import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
class ImageManager: ObservableObject {
    @Published var images: [ImageInfo] = []
    @Published var isScanning = false

    private let rawExtensions = [
        "arw", "x3f", "cr2", "cr3", "nef", "dng", "orf", "raf", "rw2",
    ]

    private let normalExtensions = [
        "jpg", "jpeg", "png", "tiff", "tif",
    ]

    private var supportedExtensions: [String] {
        rawExtensions + normalExtensions
    }

    func scanForImages(in directory: URL? = nil) {
        guard let directory else {
            print("ImageManager: 未指定目录，请通过「打开文件夹」选择目录")
            images = []
            return
        }

        Task {
            isScanning = true
            defer { isScanning = false }

            print("ImageManager: 扫描指定目录: \(directory.path)")
            let foundImages = await scanDirectory(directory)
            print("ImageManager: 找到 \(foundImages.count) 张图片")
            images = foundImages.sorted { $0.filename < $1.filename }
        }
    }

    func addImages(from urls: [URL]) {
        let newImages = urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .filter { url in !images.contains(where: { $0.url == url }) }
            .map { ImageInfo(url: $0) }

        images.append(contentsOf: newImages)
        images.sort { $0.filename < $1.filename }
    }

    func removeImage(at index: Int) {
        guard index < images.count else { return }
        images.remove(at: index)
    }

    private func scanDirectory(_ directory: URL) async -> [ImageInfo] {
        print("ImageManager: 开始扫描目录: \(directory.path)")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        )
        print("ImageManager: 目录是否存在: \(exists), 是否为目录: \(isDirectory.boolValue)")

        guard exists, isDirectory.boolValue else {
            print("ImageManager: 路径不存在或不是目录")
            return []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("ImageManager: 无法创建目录枚举器")
            return []
        }

        var foundURLs: [URL] = []
        var fileCount = 0
        var totalItems = 0

        for item in enumerator {
            totalItems += 1
            if let fileURL = item as? URL {
                fileCount += 1
                foundURLs.append(fileURL)
                if fileCount <= 5 {
                    print("ImageManager: 发现文件 \(fileCount): \(fileURL.lastPathComponent)")
                }
            } else {
                if totalItems <= 3 {
                    print("ImageManager: 跳过非URL项: \(type(of: item))")
                }
            }
        }

        print("ImageManager: 枚举器遍历了 \(totalItems) 个项目，其中 \(fileCount) 个是 URL")

        print("ImageManager: 扫描到 \(foundURLs.count) 个文件")
        if foundURLs.isEmpty {
            print("ImageManager: 警告：枚举器返回了0个文件，尝试直接读取目录内容")
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                print("ImageManager: contentsOfDirectory 找到 \(contents.count) 个项目")
                foundURLs = contents
                for (index, url) in contents.prefix(5).enumerated() {
                    print("ImageManager: 项目 \(index + 1): \(url.lastPathComponent)")
                }
            } catch {
                print("ImageManager: contentsOfDirectory 失败: \(error)")
            }
        }
        print("ImageManager: 支持的扩展名: \(supportedExtensions)")

        let filteredURLs = foundURLs.filter { url in
            let ext = url.pathExtension.lowercased()
            let isSupported = supportedExtensions.contains(ext)
            if foundURLs.count < 20, !isSupported, !ext.isEmpty {
                print("ImageManager: 跳过不支持的文件: \(url.lastPathComponent) (扩展名: \(ext))")
            }
            return isSupported
        }

        print("ImageManager: 过滤后剩余 \(filteredURLs.count) 个支持的图片文件")

        let deduplicated = deduplicateRawAndJpeg(urls: filteredURLs)
        print("ImageManager: 去重后剩余 \(deduplicated.count) 张图片")

        return deduplicated.map { ImageInfo(url: $0) }
    }

    private func deduplicateRawAndJpeg(urls: [URL]) -> [URL] {
        var filesByBaseName: [String: [URL]] = [:]

        for url in urls {
            let baseName = url.deletingPathExtension().lastPathComponent
            filesByBaseName[baseName, default: []].append(url)
        }

        var result: [URL] = []

        for (_, files) in filesByBaseName {
            if files.count == 1 {
                result.append(files[0])
            } else {
                let rawFile = files.first { rawExtensions.contains($0.pathExtension.lowercased()) }
                result.append(rawFile ?? files[0])
            }
        }

        return result.sorted { $0.path < $1.path }
    }

    private func defaultPicturesDirectory() -> URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedContentTypes()

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addImages(from: panel.urls)
        }
    }

    func openDirectoryDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.scanForImages(in: url)
        }
    }

    private func allowedContentTypes() -> [UTType] {
        var types: [UTType] = [.jpeg, .png, .tiff]

        let rawTypes = ["public.camera-raw-image", "com.sony.arw-raw-image"]
        types.append(contentsOf: rawTypes.compactMap { UTType($0) })

        return types
    }
}
