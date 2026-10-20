import SwiftUI

@main
struct CodeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var l10n = L10n.shared

    var body: some Scene {
        // Keep SwiftUI's application lifecycle without registering an empty
        // Settings window. The menu is always available, even if the island is
        // hidden, and all settings actions use the existing window controller.
        MenuBarExtra {
            Button(l10n["settings_ellipsis"]) {
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button(l10n["quit"]) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(nsImage: StatusItemController.menuBarIcon())
        }
        .menuBarExtraStyle(.menu)
    }
}
