import AppKit

@MainActor
enum MainWindow {
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
