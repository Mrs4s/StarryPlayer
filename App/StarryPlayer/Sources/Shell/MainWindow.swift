import AppKit

/// The library window, from places outside it (the menu bar lyrics' menu, the notch player).
@MainActor
enum MainWindow {
    /// Brings the app forward with its window: back from the Dock if minimised, opened again if
    /// it was closed.
    static func show() {
        NSApp.activate()
        let window = NSApp.windows.first { window in
            window.identifier != SettingsWindowController.identifier && window.canBecomeMain && !(window is NSPanel)
                && (window.isVisible || window.isMiniaturized)
        }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
