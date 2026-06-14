import Combine
import Foundation

@MainActor
final class ImageEditingState: ObservableObject {
    @Published var adjustments: ImageAdjustments

    init(adjustments: ImageAdjustments) {
        self.adjustments = adjustments
    }
}

@MainActor
final class ImageEditingSession: Identifiable {
    private enum RecordMode {
        case debounced
        case immediate
        case skip
    }

    let id: UUID
    let imageInfo: ImageInfo
    let history: AdjustmentHistory
    let state: ImageEditingState

    var currentAdjustments: ImageAdjustments {
        state.adjustments
    }

    private(set) var committedAdjustments: ImageAdjustments

    private let thumbnailManager: ThumbnailManager
    private var stateObservation: AnyCancellable?
    private var commitTask: Task<Void, Never>?
    private var isSyncingState = false
    private let commitDelayNanoseconds: UInt64 = 120_000_000

    init(
        imageInfo: ImageInfo,
        initialAdjustments: ImageAdjustments = .default,
        thumbnailManager: ThumbnailManager
    ) {
        self.id = imageInfo.id
        self.imageInfo = imageInfo
        self.history = AdjustmentHistory()
        self.state = ImageEditingState(adjustments: initialAdjustments)
        self.committedAdjustments = initialAdjustments
        self.thumbnailManager = thumbnailManager

        history.recordImmediate(initialAdjustments)
        syncThumbnail(with: initialAdjustments)
        observeStateChanges()
    }

    func apply(_ adjustments: ImageAdjustments) {
        commitTask?.cancel()
        commitTask = nil
        commit(adjustments, recordMode: .immediate, syncState: true)
    }

    func applyLUT(_ url: URL?) {
        var updated = state.adjustments
        updated.lutURL = url
        apply(updated)
    }

    func flushPendingEdits() {
        commitTask?.cancel()
        commitTask = nil

        let adjustments = state.adjustments
        guard adjustments != committedAdjustments else { return }
        commit(adjustments, recordMode: .debounced, syncState: false)
    }

    func undo() {
        flushPendingEdits()
        history.flush()
        guard let previous = history.undo() else { return }
        applyHistory(previous)
    }

    func redo() {
        flushPendingEdits()
        history.flush()
        guard let next = history.redo() else { return }
        applyHistory(next)
    }

    private func applyHistory(_ adjustments: ImageAdjustments) {
        commitTask?.cancel()
        commitTask = nil
        commit(adjustments, recordMode: .skip, syncState: true)
    }

    private func observeStateChanges() {
        stateObservation = state.$adjustments
            .dropFirst()
            .sink { [weak self] adjustments in
                guard let self else { return }
                guard !self.isSyncingState else { return }
                self.scheduleCommit(for: adjustments)
            }
    }

    private func scheduleCommit(for adjustments: ImageAdjustments) {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.commitDelayNanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !self.isSyncingState else { return }
                guard self.state.adjustments == adjustments else { return }
                self.commit(adjustments, recordMode: .debounced, syncState: false)
                self.commitTask = nil
            }
        }
    }

    private func commit(
        _ adjustments: ImageAdjustments,
        recordMode: RecordMode,
        syncState: Bool
    ) {
        if syncState, state.adjustments != adjustments {
            isSyncingState = true
            state.adjustments = adjustments
            isSyncingState = false
        }

        guard committedAdjustments != adjustments else { return }
        committedAdjustments = adjustments

        switch recordMode {
        case .debounced:
            history.record(adjustments)
        case .immediate:
            history.recordImmediate(adjustments)
        case .skip:
            break
        }

        syncThumbnail(with: adjustments)
    }

    private func syncThumbnail(with adjustments: ImageAdjustments) {
        if adjustments.hasAdjustments || adjustments.hasTransformAdjustments || adjustments.lutURL != nil {
            thumbnailManager.generateAdjustedThumbnail(
                for: imageInfo,
                with: adjustments
            )
        } else {
            // 没有调整时，生成基础缩略图（显示原图）而不是清除所有缩略图
            // 修复：避免 clearThumbnail 同时清除 base 和 adjusted 导致缩略图消失
            thumbnailManager.generateBaseThumbnail(for: imageInfo)
        }
    }
}
