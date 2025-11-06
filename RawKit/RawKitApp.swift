import SwiftUI

@main
struct RawKitApp: App {
    @FocusedValue(\.undoAction) private var undoAction
    @FocusedValue(\.redoAction) private var redoAction
    @FocusedValue(\.resetZoomAction) private var resetZoomAction

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    undoAction?()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoAction == nil)

                Button("重做") {
                    redoAction?()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redoAction == nil)
            }

            CommandMenu("视图") {
                Button("实际大小") {
                    resetZoomAction?()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(resetZoomAction == nil)
            }
        }
    }
}
