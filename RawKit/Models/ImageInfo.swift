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
    let colorSpace: String?
    let colorProfile: String?

    init(url: URL) {
        self.url = url
        filename = url.lastPathComponent
        fileType = ImageFileType(from: url)
        fileSize = Self.getFileSize(for: url)
        dimensions = Self.getImageDimensions(for: url)
        thumbnail = Self.generateThumbnail(for: url)

        let colorInfo = Self.getColorSpaceInfo(for: url)
        colorSpace = colorInfo.space
        colorProfile = colorInfo.profile
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

    private static func getColorSpaceInfo(for url: URL) -> (space: String?, profile: String?) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0,
                                                                  nil) as? [CFString: Any]
        else {
            return (nil, nil)
        }

        var spaceName: String?
        var profileName: String?

        if let colorModel = properties[kCGImagePropertyColorModel] as? String {
            spaceName = colorModel
        }

        if let profileNameValue = properties[kCGImagePropertyProfileName] as? String {
            profileName = profileNameValue
        }

        if let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
           let colorSpace = cgImage.colorSpace
        {
            if spaceName == nil {
                spaceName = getColorSpaceName(colorSpace)
            }

            if profileName == nil {
                profileName = colorSpace.name as String?
            }
        }

        return (spaceName, profileName)
    }

    private static func getColorSpaceName(_ colorSpace: CGColorSpace) -> String {
        if colorSpace.model == .rgb {
            if let name = colorSpace.name as String? {
                if name.contains("Display P3") || name.contains("P3") {
                    return "Display P3"
                } else if name.contains("Adobe RGB") || name.contains("AdobeRGB") {
                    return "Adobe RGB"
                } else if name.contains("ProPhoto") {
                    return "ProPhoto RGB"
                } else if name.contains("sRGB") {
                    return "sRGB"
                } else if name.contains("Generic RGB") {
                    return "Generic RGB"
                }
            }
            return "RGB"
        } else if colorSpace.model == .cmyk {
            return "CMYK"
        } else if colorSpace.model == .monochrome {
            return "灰度"
        } else if colorSpace.model == .lab {
            return "LAB"
        }

        return "未知"
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
