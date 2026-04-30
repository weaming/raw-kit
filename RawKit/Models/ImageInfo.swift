import AppKit
import CoreImage
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
    let hdrHeadroom: Double?

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
        hdrHeadroom = Self.detectHDRHeadroom(for: url)
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
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  imageSource,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func generateThumbnail(for url: URL) -> NSImage? {
        let thumbnailURL: URL?

        if url.pathExtension.lowercased() == "x3f" {
            thumbnailURL = getSameNameJpeg(for: url)
            if thumbnailURL == nil {
                return nil
            }
        } else {
            thumbnailURL = url
        }

        guard let sourceURL = thumbnailURL else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
        ]

        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
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

    private static func getSameNameJpeg(for x3fURL: URL) -> URL? {
        let directory = x3fURL.deletingLastPathComponent()
        let baseName = x3fURL.deletingPathExtension().lastPathComponent

        let jpegExtensions = ["jpg", "jpeg", "JPG", "JPEG"]

        for ext in jpegExtensions {
            let jpegURL = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: jpegURL.path) {
                return jpegURL
            }
        }

        return nil
    }

    private static func getColorSpaceInfo(for url: URL) -> (space: String?, profile: String?) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  imageSource,
                  0,
                  nil
              ) as? [CFString: Any]
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
           let colorSpace = cgImage.colorSpace {
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

    private static func detectHDRHeadroom(for url: URL) -> Double? {
        if ImageFileType(from: url).isRaw {
            return nil
        }

        let ciImageOptions: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .toneMapHDRtoSDR: false,
            .expandToHDR: true,
        ]

        if let ciImage = CIImage(contentsOf: url, options: ciImageOptions) {
            let headroom = Double(ciImage.contentHeadroom)
            if headroom > 1.01 {
                return headroom
            }

            if let colorSpace = ciImage.colorSpace,
               colorSpace.isHDR() {
                return max(headroom, 2.0)
            }
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            imageSource,
            0,
            kCGImageAuxiliaryDataTypeHDRGainMap
        ) != nil {
            return 2.0
        }

        if #available(macOS 15.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(
               imageSource,
               0,
               kCGImageAuxiliaryDataTypeISOGainMap
           ) != nil {
            return 2.0
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceDecodeRequestOptions: [
                    kCGImageSourceGenerateImageSpecificLumaScaling: true,
                ],
            ] as CFDictionary
        ) else {
            return nil
        }

        let cgImageHeadroom = Double(cgImage.contentHeadroom)
        if cgImageHeadroom > 1.01 {
            return cgImageHeadroom
        }

        if let colorSpace = cgImage.colorSpace,
           colorSpace.isHDR() {
            return max(cgImageHeadroom, 2.0)
        }

        return nil
    }
}

enum ImageFileType: Equatable {
    case raw(RawType)
    case jpeg
    case png
    case tiff
    case heif
    case avif
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
            case "heic", "heif", "hif":
                self = .heif
            case "avif":
                self = .avif
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
        case .heif:
            "HEIF"
        case .avif:
            "AVIF"
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
