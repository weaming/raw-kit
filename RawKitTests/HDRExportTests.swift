import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import RawKit

final class HDRExportTests: XCTestCase {
    func testHEIFPresetsPreserveEncodedColorsAndStructure() throws {
        try checkPresets(format: .heif)
    }

    func testAVIFPresetsPreserveEncodedColorsAndStructure() throws {
        try checkPresets(format: .avif)
    }

    func testOddSizedHEIFAndAVIFDecodeWithValidItemLocations() throws {
        _ = try tool(named: "avifenc")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HDRExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.1))
            .cropped(to: CGRect(x: -11, y: 7, width: 1025, height: 769))
        for format in [ExportFormat.heif, .avif] {
            let output = directory.appendingPathComponent("odd.\(format.fileExtension)")
            try ImageExporter.exportImage(image, to: output, format: format, outputPreset: .rec2020PQHDR,
                                          quality: 0.9, ultraHDRGainMapCompression: .balanced, targetHDRHeadroom: 16)
            _ = try BMFFInspector(data: Data(contentsOf: output))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 1025)
            XCTAssertEqual(decoded.height, 769)
        }
    }

    private func checkPresets(format: ExportFormat) throws {
        let ffmpeg = try tool(named: "ffmpeg")
        let ffprobe = try tool(named: "ffprobe")
        if format == .avif { _ = try tool(named: "avifenc") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HDRExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let linearSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: linearSpace])
        let colors: [(Float, Float, Float)] = [
            (0, 0, 0), (0.18, 0.18, 0.18), (1, 1, 1), (4, 4, 4), (12, 12, 12),
            (0.8, 0.1, 0.02), (0.02, 0.8, 0.1), (0.1, 0.02, 0.8)
        ]
        let width = colors.count * 64
        let height = 64
        var pixels = [Float]()
        for _ in 0..<height {
            for color in colors {
                for _ in 0..<64 { pixels.append(contentsOf: [color.0, color.1, color.2, 1]) }
            }
        }
        let bitmap = pixels.withUnsafeBytes { Data($0) }
        var image = CIImage(bitmapData: bitmap, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linearSpace)
        if #available(macOS 16.0, *) { image = image.settingContentHeadroom(16) }

        for preset in ExportOutputPreset.allCases where format == .heif || preset.isHDR {
            let output = directory.appendingPathComponent("\(preset.rawValue).\(format.fileExtension)")
            try ImageExporter.exportImage(image, to: output, format: format, outputPreset: preset,
                                          quality: 1, ultraHDRGainMapCompression: .balanced,
                                          targetHDRHeadroom: preset.isHDR ? 16 : nil)
            let structure = try BMFFInspector(data: Data(contentsOf: output))
            let expected = signals(preset: preset, format: format)
            var matrix = expected.matrix
            if let color = structure.primaryProperties.first(where: { $0.type == "colr" && $0.payload.starts(with: Data("nclx".utf8)) }) {
                if format == .heif && preset.isHDR {
                    matrix = color.payload[9]
                    XCTAssertTrue([1, 9].contains(matrix), preset.rawValue)
                }
                XCTAssertEqual(Array(color.payload.suffix(7)), [0, expected.primaries, 0, expected.transfer, 0, matrix, 128], preset.rawValue)
            } else {
                XCTAssertEqual(preset, .displayP3SDR)
                let profile = try XCTUnwrap(structure.primaryProperties.first { $0.type == "colr" && $0.payload.starts(with: Data("prof".utf8)) })
                let space = try XCTUnwrap(CGColorSpace(iccData: Data(profile.payload.dropFirst(4)) as CFData))
                XCTAssertEqual(space.name, CGColorSpace.displayP3)
            }
            XCTAssertFalse(structure.primaryProperties.contains { $0.type == "mdcv" }, "没有母版数据时不应伪造 mdcv")
            if format == .avif {
                let profile = try XCTUnwrap(structure.primaryProperties.first {
                    $0.type == "colr" && $0.payload.starts(with: Data("prof".utf8))
                })
                let profileSpace = try XCTUnwrap(CGColorSpace(iccData: Data(profile.payload.dropFirst(4)) as CFData))
                XCTAssertEqual(profileSpace.name, expected.space)
            }
            let pixi = try XCTUnwrap(structure.primaryProperties.first { $0.type == "pixi" })
            XCTAssertEqual(Array(pixi.payload.suffix(3)), [10, 10, 10])

            let bitstream = output.appendingPathExtension(format == .heif ? "h265" : "obu")
            var extraction = ["-v", "error", "-i", output.path, "-map", "0:v:0", "-c:v", "copy"]
            if format == .heif { extraction += ["-bsf:v", "hevc_mp4toannexb"] }
            extraction += ["-f", format == .heif ? "hevc" : "obu", bitstream.path]
            _ = try run(ffmpeg, extraction)
            let probeData = try run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", bitstream.path])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: probeData) as? [String: Any])
            let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
            let stream = try XCTUnwrap(streams.first)
            XCTAssertEqual(stream["color_range"] as? String, "pc", preset.rawValue)
            XCTAssertEqual(stream["color_space"] as? String, matrix == 9 ? "bt2020nc" : matrix == 6 ? "smpte170m" : "bt709", preset.rawValue)
            XCTAssertEqual(stream["color_primaries"] as? String, expected.primaries == 9 ? "bt2020" : expected.primaries == 12 ? "smpte432" : "bt709", preset.rawValue)
            XCTAssertEqual(stream["color_transfer"] as? String, expected.transfer == 16 ? "smpte2084" : expected.transfer == 18 ? "arib-std-b67" : "iec61966-2-1", preset.rawValue)

            let decoded = try run(ffmpeg, ["-v", "error", "-i", output.path, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb48le", "pipe:1"])
            XCTAssertEqual(decoded.count, width * height * 6)
            guard decoded.count == width * height * 6 else { continue }
            var reference = [UInt16](repeating: 0, count: width * height * 4)
            let space = try XCTUnwrap(CGColorSpace(name: expected.space))
            reference.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 8,
                               bounds: image.extent, format: .RGBA16, colorSpace: space)
            }
            for patch in colors.indices {
                let pixel = (height / 2) * width + patch * 64 + 32
                for channel in 0..<3 {
                    let offset = pixel * 6 + channel * 2
                    let actual = Double(UInt16(decoded[offset]) | UInt16(decoded[offset + 1]) << 8) / 65535
                    let expectedValue = Double(reference[pixel * 4 + channel]) / 65535
                    XCTAssertEqual(actual, expectedValue, accuracy: 0.025,
                                   "\(format) \(preset) patch=\(patch) channel=\(channel)")
                }
            }
        }
    }

    private func signals(preset: ExportOutputPreset, format: ExportFormat) -> (primaries: UInt8, transfer: UInt8, matrix: UInt8, space: CFString) {
        switch preset {
        case .sdrSRGB: (1, 13, 6, CGColorSpace.sRGB)
        case .displayP3SDR: (12, 13, 6, CGColorSpace.displayP3)
        case .displayP3HLGHDR: (12, 18, format == .heif ? 9 : 1, CGColorSpace.displayP3_HLG)
        case .displayP3PQHDR: (12, 16, format == .heif ? 9 : 1, CGColorSpace.displayP3_PQ)
        case .rec2020HLGHDR: (9, 18, 9, CGColorSpace.itur_2100_HLG)
        case .rec2020PQHDR: (9, 16, 9, CGColorSpace.itur_2100_PQ)
        }
    }

    private func tool(named name: String) throws -> URL {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw XCTSkip("独立解码验证需要 \(name)")
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable.lastPathComponent): \(arguments)")
        return data
    }
}

private struct BMFFInspector {
    struct Box {
        let type: String
        let payload: Data
        let start: Int
    }
    let primaryProperties: [Box]

    init(data: Data) throws {
        let top = try Self.boxes(data)
        let meta = try XCTUnwrap(top.first { $0.type == "meta" })
        let children = try Self.boxes(meta.payload, start: 4)
        let pitm = try XCTUnwrap(children.first { $0.type == "pitm" })
        let primary = try Self.number(pitm.payload, 4, pitm.payload[0] == 0 ? 2 : 4)
        let iprp = try XCTUnwrap(children.first { $0.type == "iprp" })
        let properties = try Self.boxes(iprp.payload)
        let ipco = try XCTUnwrap(properties.first { $0.type == "ipco" })
        let values = try Self.boxes(ipco.payload)
        let ipma = try XCTUnwrap(properties.first { $0.type == "ipma" }).payload
        let entryCount = try Self.number(ipma, 4, 4)
        var cursor = 8
        var primaryValues: [Box] = []
        for _ in 0..<entryCount {
            let idSize = ipma[0] == 0 ? 2 : 4
            let item = try Self.number(ipma, cursor, idSize)
            cursor += idSize
            let count = try Self.number(ipma, cursor, 1)
            cursor += 1
            let size = ipma[3] & 1 == 0 ? 1 : 2
            for _ in 0..<count {
                let association = try Self.number(ipma, cursor, size)
                cursor += size
                let index = association & (size == 1 ? 127 : 32767)
                XCTAssertLessThanOrEqual(index, values.count)
                if item == primary && index > 0 && index <= values.count { primaryValues.append(values[index - 1]) }
            }
        }
        XCTAssertEqual(cursor, ipma.count)
        primaryProperties = primaryValues

        let iloc = try XCTUnwrap(children.first { $0.type == "iloc" }).payload
        let version = iloc[0]
        let offsetSize = Int(iloc[4] >> 4)
        let lengthSize = Int(iloc[4] & 15)
        let baseSize = Int(iloc[5] >> 4)
        let indexSize = version == 0 ? 0 : Int(iloc[5] & 15)
        let countSize = version < 2 ? 2 : 4
        let itemCount = try Self.number(iloc, 6, countSize)
        cursor = 6 + countSize
        let mdat = top.filter { $0.type == "mdat" }
        for _ in 0..<itemCount {
            cursor += version < 2 ? 2 : 4
            let method = version == 0 ? 0 : try Self.number(iloc, cursor, 2) & 15
            if version > 0 { cursor += 2 }
            XCTAssertEqual(try Self.number(iloc, cursor, 2), 0)
            cursor += 2
            let base = try Self.number(iloc, cursor, baseSize)
            cursor += baseSize
            let extents = try Self.number(iloc, cursor, 2)
            cursor += 2
            for _ in 0..<extents {
                cursor += indexSize
                let offset = try Self.number(iloc, cursor, offsetSize)
                cursor += offsetSize
                let length = try Self.number(iloc, cursor, lengthSize)
                cursor += lengthSize
                if method == 0 {
                    XCTAssertTrue(mdat.contains { base + offset >= $0.start && base + offset + length <= $0.start + $0.payload.count })
                } else {
                    XCTAssertEqual(method, 1)
                    let idat = try XCTUnwrap(children.first { $0.type == "idat" })
                    XCTAssertLessThanOrEqual(base + offset + length, idat.payload.count)
                }
            }
        }
        XCTAssertEqual(cursor, iloc.count)
    }

    private static func number(_ data: Data, _ offset: Int, _ size: Int) throws -> Int {
        guard offset >= 0, size <= 8, offset + size <= data.count else {
            throw NSError(domain: "BMFFTests", code: 1)
        }
        return data[offset..<offset + size].reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func boxes(_ data: Data, start: Int = 0) throws -> [Box] {
        var cursor = start
        var result: [Box] = []
        while cursor < data.count {
            let size32 = try number(data, cursor, 4)
            let header = size32 == 1 ? 16 : 8
            let size = size32 == 0 ? data.count - cursor : size32 == 1 ? try number(data, cursor + 8, 8) : size32
            guard size >= header, cursor + size <= data.count else { throw NSError(domain: "BMFFTests", code: 2) }
            let type = String(decoding: data[cursor + 4..<cursor + 8], as: UTF8.self)
            result.append(Box(type: type, payload: Data(data[cursor + header..<cursor + size]), start: cursor + header))
            cursor += size
        }
        return result
    }
}
