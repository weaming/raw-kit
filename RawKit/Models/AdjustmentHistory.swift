import Foundation

class AdjustmentHistory: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var history: [ImageAdjustments] = []
    private var currentIndex = -1
    private let maxHistorySize = 50

    private var pendingAdjustments: ImageAdjustments?
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.3

    func record(_ adjustments: ImageAdjustments) {
        // 如果与当前状态相同，不记录
        if currentIndex >= 0, currentIndex < history.count {
            let current = history[currentIndex]
            if current == adjustments {
                return
            }
        }

        // 取消之前的防抖定时器
        debounceTimer?.invalidate()

        // 保存待记录的调整
        pendingAdjustments = adjustments

        // 设置新的防抖定时器
        debounceTimer = Timer
            .scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
                self?.commitPendingRecord()
            }
    }

    // 立即记录（用于非连续操作，如点击按钮、加载预设等）
    func recordImmediate(_ adjustments: ImageAdjustments) {
        debounceTimer?.invalidate()
        pendingAdjustments = nil
        commitRecord(adjustments)
    }

    // 强制提交待处理的记录（在视图消失等时机调用）
    func flush() {
        debounceTimer?.invalidate()
        commitPendingRecord()
    }

    private func commitPendingRecord() {
        guard let adjustments = pendingAdjustments else { return }
        commitRecord(adjustments)
        pendingAdjustments = nil
    }

    private func commitRecord(_ adjustments: ImageAdjustments) {
        if currentIndex >= 0, currentIndex < history.count {
            let current = history[currentIndex]
            if current == adjustments {
                return
            }
        }

        if currentIndex < history.count - 1 {
            history.removeSubrange((currentIndex + 1)...)
        }

        history.append(adjustments)

        if history.count > maxHistorySize {
            history.removeFirst()
        } else {
            currentIndex += 1
        }

        updateState()
    }

    func undo() -> ImageAdjustments? {
        guard canUndo else { return nil }
        currentIndex -= 1
        updateState()
        return history[currentIndex]
    }

    func redo() -> ImageAdjustments? {
        guard canRedo else { return nil }
        currentIndex += 1
        updateState()
        return history[currentIndex]
    }

    func clear() {
        history.removeAll()
        currentIndex = -1
        updateState()
    }

    func jumpTo(index: Int) {
        guard index >= 0, index < history.count else { return }
        currentIndex = index
        updateState()
    }

    func current() -> ImageAdjustments? {
        guard currentIndex >= 0, currentIndex < history.count else { return nil }
        return history[currentIndex]
    }

    var states: [ImageAdjustments] {
        history
    }

    var currentStateIndex: Int {
        currentIndex
    }

    private func updateState() {
        canUndo = currentIndex > 0
        canRedo = currentIndex < history.count - 1
    }
}
