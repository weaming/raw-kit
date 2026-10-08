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
