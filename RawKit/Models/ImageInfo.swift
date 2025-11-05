import AppKit
import Foundation

struct ImageInfo: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let fileType: ImageFileType
    let fileSize: Int64
    let dimensions: CGSize?
    let thumbnail: NSImage?

    init(url: URL) {
        self.url = url
        filename = url.lastPathComponent
        fileType = ImageFileType(from: url)
        fileSize = Self.getFileSize(for: url)
        dimensions = Self.getImageDimensions(for: url)
        thumbnail = Self.generateThumbnail(for: url)
    }

    private static func getFileSize(for url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64
        else {
            return 0
        }
        return size
    }

    private static func getImageDimensions(for url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0,
                                                                  nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func generateThumbnail(for url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
        ]

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  imageSource,
                  0,
                  options as CFDictionary
              )
        else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

enum ImageFileType: Equatable {
    case raw(RawType)
    case jpeg
    case png
    case tiff
    case unknown

    enum RawType: String {
        case arw
        case x3f
        case cr2
        case cr3
        case nef
        case dng
        case orf
        case raf
        case rw2
    }

    init(from url: URL) {
        let ext = url.pathExtension.lowercased()

        if let rawType = RawType(rawValue: ext) {
            self = .raw(rawType)
        } else {
            switch ext {
            case "jpg", "jpeg":
                self = .jpeg
            case "png":
                self = .png
            case "tif", "tiff":
                self = .tiff
            default:
                self = .unknown
            }
        }
    }

    var displayName: String {
        switch self {
        case let .raw(type):
            type.rawValue.uppercased()
        case .jpeg:
            "JPEG"
        case .png:
            "PNG"
        case .tiff:
            "TIFF"
        case .unknown:
            "未知"
        }
    }

    var isRaw: Bool {
        if case .raw = self {
            return true
        }
        return false
    }
}
