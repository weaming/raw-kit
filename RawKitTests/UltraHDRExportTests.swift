import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import RawKit

final class UltraHDRExportTests: XCTestCase {
    private let ISO_NAMESPACE = Data("urn:iso:std:iso:ts:21496:-1\0".utf8)

    func testXMPAdditionPreservesISOMetadataAndDecodedPixels() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = try encoder()
        let original = directory.appendingPathComponent("original.jpg")
        let hdr = directory.appendingPathComponent("hdr.raw")
        let sdr = directory.appendingPathComponent("sdr.raw")
        let levels: [Float16] = [2, 4, 8, 12]
        var pixels = [Float16]()
        for _ in 0..<32 {
            for level in levels {
                for _ in 0..<32 { pixels += [level, level, level, 1] }
            }
        }
        try pixels.withUnsafeBytes { try Data($0).write(to: hdr) }
        try Data((0..<128 * 32).flatMap { _ in [UInt8(128), 128, 128, 255] }).write(to: sdr)
        _ = try run(tool, ["-m", "0", "-p", hdr.path, "-y", sdr.path, "-w", "128", "-h", "32",
                           "-a", "4", "-b", "3", "-C", "0", "-c", "0", "-t", "0",
                           "-q", "100", "-Q", "100", "-s", "1", "-M", "0", "-G", "1.7",
                           "-D", "1", "-L", "3248", "-z", original.path], directory: directory)
        let before = try Data(contentsOf: original)
        let beforePixels = try decode(original, directory: directory)
        let patched = directory.appendingPathComponent("patched.jpg")
        try before.write(to: patched)
        try ImageExporter.ensureUltraHDRJPEGHasXMPMetadata(at: patched)
        let after = try Data(contentsOf: patched)
        XCTAssertEqual(try isoSegments(before), try isoSegments(after))
        XCTAssertEqual(beforePixels, try decode(patched, directory: directory))
        try checkMPF(after)
        try ImageExporter.ensureUltraHDRJPEGHasXMPMetadata(at: patched)
        XCTAssertEqual(after, try Data(contentsOf: patched), "重复执行后处理不应积累 XMP 或改变偏移")

        var xmpOnly = after
        while let range = xmpOnly.range(of: ISO_NAMESPACE) {
            xmpOnly.replaceSubrange(range, with: Data(repeating: 0, count: range.count))
        }
        let xmpURL = directory.appendingPathComponent("xmp-only.jpg")
        try xmpOnly.write(to: xmpURL)
        XCTAssertEqual(beforePixels, try decode(xmpURL, directory: directory), "ISO 与 XMP 解码路径应还原相同像素")
    }

    func testAllHDRPresetsAndCompressionModesRoundTrip() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try encoder()
        let levels: [Float] = [0.4, 1, 4, 12]
        var pixels = [Float]()
        for _ in 0..<32 {
            for level in levels {
                for _ in 0..<32 { pixels += [level, level, level, 1] }
            }
        }
        let linearSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: 128 * 16,
                            size: CGSize(width: 128, height: 32), format: .RGBAf, colorSpace: linearSpace)
        for preset in ExportOutputPreset.allCases where preset.isHDR {
            for compression in UltraHDRGainMapCompression.allCases {
                let url = directory.appendingPathComponent("\(preset.rawValue)-\(compression.rawValue).jpg")
                try ImageExporter.exportImage(image, to: url, format: .ultraHDRJPEG, outputPreset: preset,
                                              quality: 0.95, ultraHDRGainMapCompression: compression, targetHDRHeadroom: 16)
                try checkMPF(Data(contentsOf: url))
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let sdr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(sdr.width, 128)
                XCTAssertEqual(sdr.height, 32)
                let decoded = try decode(url, directory: directory)
                XCTAssertEqual(decoded.count, 128 * 32 * 8)
                guard decoded.count == 128 * 32 * 8 else { continue }
                for patch in levels.indices {
                    let pixel = 16 * 128 + patch * 32 + 16
                    let bits = UInt16(decoded[pixel * 8]) | UInt16(decoded[pixel * 8 + 1]) << 8
                    let actual = Float(Float16(bitPattern: bits))
                    XCTAssertEqual(actual, levels[patch], accuracy: max(0.08, levels[patch] * 0.12),
                                   "\(preset) \(compression) patch \(patch)")
                }
                let metadata = try String(contentsOf: url.appendingPathExtension("cfg"), encoding: .utf8)
                let capacity = try XCTUnwrap(metadata.split(separator: "\n").first { $0.hasPrefix("--hdrCapacityMax ") })
                let value = try XCTUnwrap(Double(try XCTUnwrap(capacity.split(separator: " ").last)))
                XCTAssertEqual(value, 16, accuracy: 0.001)
            }
        }
    }

    func testMalformedJPEGLeavesDestinationUnchanged() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.jpg")
        let data = Data([0xff, 0xd8, 0xff, 0xe2, 0xff, 0xff])
        try data.write(to: url)
        XCTAssertThrowsError(try ImageExporter.ensureUltraHDRJPEGHasXMPMetadata(at: url))
        XCTAssertEqual(data, try Data(contentsOf: url))
    }

    func testOddDimensionsAndSDRHeadroom() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try encoder()
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: -9, y: 3, width: 65, height: 33))
        let url = directory.appendingPathComponent("odd.jpg")
        try ImageExporter.exportImage(image, to: url, format: .ultraHDRJPEG, outputPreset: .displayP3PQHDR,
                                      quality: 0.9, ultraHDRGainMapCompression: .compact, targetHDRHeadroom: 1)
        try checkMPF(Data(contentsOf: url))
        XCTAssertEqual(try decode(url, directory: directory).count, 65 * 33 * 8)

        let existing = try Data(contentsOf: url)
        XCTAssertThrowsError(try ImageExporter.exportImage(
            image, to: url, format: .ultraHDRJPEG, outputPreset: .displayP3PQHDR,
            quality: 0.9, ultraHDRGainMapCompression: .compact, targetHDRHeadroom: .nan
        ))
        XCTAssertEqual(existing, try Data(contentsOf: url), "导出失败不应覆盖已有文件")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UltraHDRTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func encoder() throws -> URL {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent("ultrahdr_app")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw XCTSkip("需要安装 libultrahdr")
    }

    private func run(_ tool: URL, _ arguments: [String], directory: URL) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail(String(decoding: output, as: UTF8.self))
            throw NSError(domain: "UltraHDRTests", code: Int(process.terminationStatus))
        }
        return output
    }

    private func decode(_ url: URL, directory: URL) throws -> Data {
        let tool = try encoder()
        _ = try run(tool, ["-m", "1", "-j", url.path, "-P"], directory: directory)
        let raw = url.appendingPathExtension("raw")
        _ = try run(tool, ["-m", "1", "-j", url.path, "-o", "0", "-O", "4",
                           "-z", raw.path, "-f", url.appendingPathExtension("cfg").path], directory: directory)
        return try Data(contentsOf: raw)
    }

    private func isoSegments(_ data: Data) throws -> [Data] {
        var result: [Data] = []
        var offset = 0
        while let range = data.range(of: ISO_NAMESPACE, in: offset..<data.count) {
            let length = Int(data[range.lowerBound - 2]) << 8 | Int(data[range.lowerBound - 1])
            let end = range.lowerBound + length - 2
            guard end <= data.count else { throw NSError(domain: "UltraHDRTests", code: 1) }
            result.append(Data(data[range.lowerBound..<end]))
            offset = end
        }
        XCTAssertEqual(result.count, 2)
        return result
    }

    private func checkMPF(_ data: Data) throws {
        let marker = try XCTUnwrap(data.range(of: Data("MPF\0".utf8)))
        let tiff = marker.upperBound
        let isLittleEndian = data[tiff] == 0x49
        func number(_ offset: Int, _ size: Int) -> Int {
            let bytes = Array(data[offset..<offset + size])
            return (isLittleEndian ? Array(bytes.reversed()) : bytes).reduce(0) { ($0 << 8) | Int($1) }
        }
        let ifd = tiff + number(tiff + 4, 4)
        let count = number(ifd, 2)
        let tag = try XCTUnwrap((0..<count).map { ifd + 2 + $0 * 12 }.first { number($0, 2) == 0xb002 })
        let entries = tiff + number(tag + 8, 4)
        let primaryLength = number(entries + 4, 4)
        let secondaryStart = tiff + number(entries + 24, 4)
        let secondaryLength = number(entries + 20, 4)
        XCTAssertEqual(primaryLength, secondaryStart)
        XCTAssertEqual(secondaryStart + secondaryLength, data.count)
        XCTAssertEqual(Array(data[secondaryStart..<secondaryStart + 2]), [0xff, 0xd8])
        XCTAssertEqual(Array(data[primaryLength - 2..<primaryLength]), [0xff, 0xd9])
        XCTAssertNotNil(data.range(of: Data("Item:Length=\"\(secondaryLength)\"".utf8)))
    }
}
