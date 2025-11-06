import Foundation

class AdjustmentHistory: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var history: [ImageAdjustments] = []
    private var currentIndex = -1
    private let maxHistorySize = 50

    func record(_ adjustments: ImageAdjustments) {
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

    private func updateState() {
        canUndo = currentIndex > 0
        canRedo = currentIndex < history.count - 1
    }
}
