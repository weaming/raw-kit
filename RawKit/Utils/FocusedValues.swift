import SwiftUI

struct UndoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RedoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ResetZoomActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var undoAction: UndoActionKey.Value? {
        get { self[UndoActionKey.self] }
        set { self[UndoActionKey.self] = newValue }
    }

    var redoAction: RedoActionKey.Value? {
        get { self[RedoActionKey.self] }
        set { self[RedoActionKey.self] = newValue }
    }

    var resetZoomAction: ResetZoomActionKey.Value? {
        get { self[ResetZoomActionKey.self] }
        set { self[ResetZoomActionKey.self] = newValue }
    }
}
