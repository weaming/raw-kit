import CoreImage
import ImageIO
import simd
import XCTest
@testable import RawKit

final class RawKitTests: XCTestCase {
    func testAdjustmentControlSpecKeepsStableMetadata() {
        XCTAssertEqual(AdjustmentControlSpec.exposure.id, "exposure")
        XCTAssertEqual(AdjustmentControlSpec.exposure.defaultValue, 0)
        XCTAssertEqual(AdjustmentControlSpec.exposure.format(1.26), "1.3")
        XCTAssertEqual(AdjustmentControlSpec.saturation.defaultValue, 1)
    }

    func testRenderKeyChangesWhenRenderingInputsChange() {
        let imageID = UUID()
        let adjustments = ImageAdjustments.default
        let baseKey = RenderKey(
            imageID: imageID,
            adjustments: adjustments,
            viewportSize: CGSize(width: 800, height: 600),
            isCropPreview: false
        )
        let sameKey = RenderKey(
            imageID: imageID,
            adjustments: adjustments,
            viewportSize: CGSize(width: 800, height: 600),
            isCropPreview: false
        )
        let comparisonKey = RenderKey(
            imageID: imageID,
            adjustments: adjustments,
            viewportSize: CGSize(width: 801, height: 600),
            isCropPreview: true
        )

        XCTAssertEqual(baseKey, sameKey)
        XCTAssertNotEqual(baseKey, comparisonKey)
    }

    func testRenderCoordinatorKeepsLatestPendingRequestForEachSlot() async {
        let recorder = RenderRecorder()
        let coordinator = RenderCoordinator<RenderTestRequest> { request in
            try? await Task.sleep(nanoseconds: 20_000_000)
            await recorder.append(request.value)
        }
        let renderKey = RenderKey(
            imageID: UUID(),
            adjustments: .default,
            viewportSize: CGSize(width: 100, height: 100),
            isCropPreview: false
        )

        let firstRequest = Task {
            await coordinator.enqueue(
                RenderTestRequest(value: 1),
                key: renderKey,
                slot: .main,
                priority: 10
            )
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
        await coordinator.enqueue(
            RenderTestRequest(value: 2),
            key: renderKey,
            slot: .main,
            priority: 10
        )
        await coordinator.enqueue(
            RenderTestRequest(value: 3),
            key: renderKey,
            slot: .main,
            priority: 10
        )
        await firstRequest.value
        try? await Task.sleep(nanoseconds: 30_000_000)

        let recordedValues = await recorder.values()
        XCTAssertEqual(recordedValues, [1, 3])
    }

    func testAppCommandsExposeAllGlobalActions() {
        XCTAssertEqual(AppCommand.allCases.count, 7)
        XCTAssertEqual(AppCommand.nextImage.title, "下一张图片")
    }

    func testHDRExportsDecodeThroughPublicExportPipeline() async throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("RawKitTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.png")
        let context = CIContext()
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let sourceImage = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        try context.writePNGRepresentation(
            of: sourceImage,
            to: sourceURL,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let imageInfo = ImageInfo(url: sourceURL)
        for format in [ExportFormat.heif, .avif] {
            let outputDirectory = temporaryDirectory.appendingPathComponent(format.fileExtension)
            let config = ExportConfig(
                format: format,
                outputPreset: .rec2020PQHDR,
                outputDirectory: outputDirectory,
                suffix: "-hdr"
            )
            let outputURL = try await ImageExporter.export(
                imageInfo: imageInfo,
                adjustments: .default,
                config: config,
                progress: { _ in }
            )

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 8)
            XCTAssertEqual(decoded.height, 8)
        }
    }

    func testDNGIsNotAdvertisedWithoutAWriter() {
        XCTAssertFalse(ExportOutputPreset.sdrSRGB.compatibleFormats.contains(.dng))

        let config = ExportConfig(
            format: .dng,
            outputPreset: .sdrSRGB
        )
        XCTAssertEqual(config.format, .jpg)
    }

    func testLUTAlphaBlendingDoesNotOverexpose() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKitLUTAlpha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 构造一个 2x2x2 Identity .cube LUT
        let lutURL = tempDir.appendingPathComponent("identity.cube")
        let cubeText = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        try cubeText.write(to: lutURL, atomically: true, encoding: .utf8)

        let source = makeLinearColorImage(r: 0.5, g: 0.5, b: 0.5)
        var adjustments = ImageAdjustments.default
        adjustments.lutURL = lutURL
        adjustments.lutAlpha = 0.5
        adjustments.lutColorProfile = LUTColorProfile(
            inputGamut: .sRGB,
            inputTransfer: .linear,
            outputGamut: .sRGB,
            outputTransfer: .linear
        )

        let output = ImageProcessor.applyAdjustments(to: source, adjustments: adjustments)
        let pixel = renderLinearPixel(output)
        XCTAssertEqual(pixel.r, 0.5, accuracy: 0.02)
        XCTAssertEqual(pixel.g, 0.5, accuracy: 0.02)
        XCTAssertEqual(pixel.b, 0.5, accuracy: 0.02)
    }

    func testWideGamutNegativeComponentsPreservedInAdjustments() {
        // extendedLinearSRGB 中 Display P3 纯红对应的 G、B 为负值
        let source = makeLinearColorImage(r: 0.8, g: -0.05, b: -0.03)
        var adjustments = ImageAdjustments.default
        adjustments.contrast = 0.2
        adjustments.saturation = 1.1

        let output = ImageProcessor.applyAdjustments(to: source, adjustments: adjustments)
        let pixel = renderLinearPixel(output)
        XCTAssertLessThan(pixel.g, 0.0)
        XCTAssertLessThan(pixel.b, 0.0)
    }

    func testCurveDuplicateEndpointsProduceFiniteValuesAndPreserveHDR() {
        var curve = CurveAdjustment()
        _ = curve.addPoint(input: 0.0, output: 0.1)
        _ = curve.addPoint(input: 1.0, output: 1.0)
        let values = curve.generateCurveValues()
        XCTAssertEqual(values.count, 256)
        XCTAssertTrue(values.allSatisfy { $0.isFinite })
        XCTAssertEqual(Double(values.first ?? 0), 0.1, accuracy: 1e-3)

        // HDR 像素 (> 1.0) 不应被截断到 1.0
        let hdrImage = makeLinearColorImage(r: 3.0, g: 2.0, b: 1.5)
        let adjusted = curve.applyToRGB(to: hdrImage)
        let pixel = renderLinearPixel(adjusted)
        XCTAssertGreaterThan(pixel.r, 2.5)
        XCTAssertGreaterThan(pixel.g, 1.5)

        // Luminance 曲线应能提亮纯黑像素
        let blackImage = makeLinearColorImage(r: 0.0, g: 0.0, b: 0.0)
        let lifted = curve.apply(to: blackImage, channel: .luminance)
        let liftedPixel = renderLinearPixel(lifted)
        XCTAssertGreaterThan(liftedPixel.r, 0.005)
    }

    func testDCIP3BradfordAdaptationPreservesNeutralGray() {
        let matrix = ImageProcessor.gamutTransformMatrix(from: .sRGB, to: .dciP3)
        let white = SIMD3<Double>(1.0, 1.0, 1.0)
        let mapped = matrix * white
        XCTAssertEqual(mapped.x, 1.0, accuracy: 1e-4)
        XCTAssertEqual(mapped.y, 1.0, accuracy: 1e-4)
        XCTAssertEqual(mapped.z, 1.0, accuracy: 1e-4)
    }

    func test3DLLUTAxisOrderAndBitDepthNormalization() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKit3DL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 2x2x2 .3dl，顺序为外层 R、中层 G、内层 B；最大值为 512 (10-bit 下应归一为 512/1023 ≈ 0.5)
        let lutURL = tempDir.appendingPathComponent("test.3dl")
        let content = """
        Mesh 2
        0 0 0
        0 0 512
        0 512 0
        0 512 512
        512 0 0
        512 0 512
        512 512 0
        512 512 512
        """
        try content.write(to: lutURL, atomically: true, encoding: .utf8)

        let parsed = try XCTUnwrap(ImageProcessor.parseLUTData(from: lutURL))
        XCTAssertEqual(parsed.size, 2)

        let floats = parsed.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // CIColorCube 中 (r=1, g=0, b=0) 位于 index = (0*4 + 0*2 + 1) = 1
        let rIndex = 1 * 4
        XCTAssertEqual(floats[rIndex + 0], 512.0 / 1023.0, accuracy: 1e-4)
        XCTAssertEqual(floats[rIndex + 1], 0.0, accuracy: 1e-4)
        XCTAssertEqual(floats[rIndex + 2], 0.0, accuracy: 1e-4)
    }

    func testWhiteBalancePreservesLuminanceAndSupportsHDRSamples() throws {
        let gains = ImageProcessor.calculateWhiteBalanceGains(temperature: 4000, tint: 20)
        let luma = 0.2126 * gains.r + 0.7152 * gains.g + 0.0722 * gains.b
        XCTAssertEqual(luma, 1.0, accuracy: 1e-5)

        let hdrSample = try XCTUnwrap(
            ImageProcessor.whiteBalanceFromNeutralSample(linearRGB: (r: 2.4, g: 2.0, b: 1.6))
        )
        XCTAssertTrue(hdrSample.temperature.isFinite)
        XCTAssertTrue(hdrSample.tint.isFinite)
    }

    func testHDRDisplayBoostPreservesHueAndPixelSamplerPreservesHDR() throws {
        let source = makeLinearColorImage(r: 4.0, g: 2.0, b: 1.0)
        var adjustments = ImageAdjustments.default
        adjustments.isHDREnabled = true
        adjustments.hdrHeadroom = 2.0
        adjustments.hdrBrightness = 0.5

        let boosted = ImageProcessor.applyAdjustments(to: source, adjustments: adjustments)
        let pixel = renderLinearPixel(boosted)
        // 等比肩部压缩应保持 R:G = 2:1, G:B = 2:1
        XCTAssertEqual(pixel.r / pixel.g, 2.0, accuracy: 1e-3)
        XCTAssertEqual(pixel.g / pixel.b, 2.0, accuracy: 1e-3)

        let sampled = try XCTUnwrap(
            PixelSampler.samplePixelInfo(
                from: source,
                point: CGPoint(x: 4, y: 4),
                imageSize: CGSize(width: 8, height: 8),
                sampleSize: 2
            )
        )
        XCTAssertEqual(sampled.linearRGB.r, 4.0, accuracy: 0.05)
    }

    func testLUTGeneratorUsesLinearWorkingColorSpace() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKitLUTGen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var adjustments = ImageAdjustments.default
        adjustments.exposure = 1.0 // 线性亮度翻倍

        let generatedLUT = await LUTGenerator.generateLUT(from: adjustments, sourceImage: nil, size: 9)
        let lutImage = try XCTUnwrap(generatedLUT)
        let cubeURL = tempDir.appendingPathComponent("ev1.cube")
        try LUTGenerator.saveLUTToCube(lutImage: lutImage, to: cubeURL, size: 9)

        let parsed = try XCTUnwrap(ImageProcessor.parseLUTData(from: cubeURL))
        let floats = parsed.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // 中点 sRGB 0.5 -> linear ~0.214 -> *2 = 0.428 -> sRGB ~0.687（若误用非线性工作空间会变成 1.0）
        let mid = 4
        let midOffset = (mid * 9 * 9 + mid * 9 + mid) * 4
        XCTAssertEqual(floats[midOffset], 0.687, accuracy: 0.03)
    }

    func testExportSanitizesFilenameAndPreservesExistingFileOnFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKitExportSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("photo.jpg")
        let info = ImageInfo(url: sourceURL)
        let config = ExportConfig(
            format: .tiff,
            outputPreset: .displayP3SDR,
            outputDirectory: tempDir,
            prefix: "../bad/",
            suffix: ":end"
        )
        let outputURL = ImageExporter.determineOutputURL(for: info, config: config)
        XCTAssertEqual(outputURL.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)
        XCTAssertEqual(outputURL.lastPathComponent, "..-bad-photo-end.tiff")

        // 16-bit TIFF 导出与原子覆盖验证
        let validImage = makeLinearColorImage(r: 0.6, g: 0.3, b: 0.2)
        try ImageExporter.exportImage(
            validImage,
            to: outputURL,
            format: .tiff,
            outputPreset: .displayP3SDR,
            quality: 1.0,
            ultraHDRGainMapCompression: .balanced,
            targetHDRHeadroom: nil
        )
        let savedData = try Data(contentsOf: outputURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.bitsPerComponent, 16)

        // 导出失败（无限 extent）不应损坏已有目标文件
        let infiniteImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        XCTAssertThrowsError(try ImageExporter.exportImage(
            infiniteImage,
            to: outputURL,
            format: .tiff,
            outputPreset: .displayP3SDR,
            quality: 1.0,
            ultraHDRGainMapCompression: .balanced,
            targetHDRHeadroom: nil
        ))
        XCTAssertEqual(try Data(contentsOf: outputURL), savedData)
    }

    func testLUTStackedWithSharpnessClarityHDRAndLUTGenerator() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawKitLUTStack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lutURL = tempDir.appendingPathComponent("boost.cube")
        let cubeText = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        try cubeText.write(to: lutURL, atomically: true, encoding: .utf8)

        let source = makeLinearColorImage(r: 0.5, g: 0.5, b: 0.5)
        var adjustments = ImageAdjustments.default
        adjustments.lutURL = lutURL
        adjustments.lutAlpha = 1.0
        adjustments.sharpness = -1.0
        adjustments.clarity = -0.8
        adjustments.isHDREnabled = true
        adjustments.hdrHeadroom = 2.0
        adjustments.hdrBrightness = 2.0

        let output = ImageProcessor.applyAdjustments(to: source, adjustments: adjustments)
        // 负锐化 + 负清晰度 + LUT 叠加后，extent 不应膨胀
        XCTAssertEqual(output.extent, source.extent)

        // HDR 增强在 LUT 之后执行，输出受 hdrHeadroom 上限保护
        let pixel = renderLinearPixel(output)
        XCTAssertLessThanOrEqual(pixel.r, 2.01)
        XCTAssertGreaterThan(pixel.r, 0.5)

        // 含旋转/裁切/锐化的调整生成 .cube LUT 不应破坏网格尺寸与色彩
        adjustments.rotation = 90
        adjustments.cropLeft = 0.2
        adjustments.exposure = 1.0
        adjustments.isHDREnabled = false
        adjustments.lutURL = nil
        let generated = await LUTGenerator.generateLUT(from: adjustments, sourceImage: nil, size: 9)
        let lutImage = try XCTUnwrap(generated)
        XCTAssertEqual(lutImage.extent, CGRect(x: 0, y: 0, width: 81, height: 9))
        let cubeURL = tempDir.appendingPathComponent("stacked.cube")
        try LUTGenerator.saveLUTToCube(lutImage: lutImage, to: cubeURL, size: 9)
        let parsed = try XCTUnwrap(ImageProcessor.parseLUTData(from: cubeURL))
        let floats = parsed.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let midOffset = (4 * 9 * 9 + 4 * 9 + 4) * 4
        XCTAssertEqual(floats[midOffset], 0.687, accuracy: 0.03)
    }

    private func makeLinearColorImage(r: Float, g: Float, b: Float) -> CIImage {
        let width = 8
        let height = 8
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for i in 0 ..< (width * height) {
            pixels[i * 4 + 0] = r
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = b
            pixels[i * 4 + 3] = 1.0
        }
        let data = Data(bytes: pixels, count: pixels.count * MemoryLayout<Float>.size)
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        )
    }

    private func renderLinearPixel(_ image: CIImage) -> (r: Float, g: Float, b: Float) {
        var pixel = [Float](repeating: 0, count: 4)
        CIContextManager.shared.getRenderContext().render(
            image,
            toBitmap: &pixel,
            rowBytes: 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        )
        return (pixel[0], pixel[1], pixel[2])
    }
}

private struct RenderTestRequest: Sendable {
    let value: Int
}

private actor RenderRecorder {
    private var recordedValues: [Int] = []

    func append(_ value: Int) {
        recordedValues.append(value)
    }

    func values() -> [Int] {
        recordedValues
    }
}
