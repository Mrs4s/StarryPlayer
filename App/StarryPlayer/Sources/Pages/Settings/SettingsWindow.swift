import AppKit
import SwiftUI

/// Settings in a window of its own, like the system's settings windows: its traffic lights (or ⌘W,
/// or esc) close it, it can sit beside the player, and music and shortcuts go on while it is up.
/// One at a time; each opening builds the page anew, so its rows and groups settle in again. It
/// opens over the middle of the player's window the first time, then where it was left.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let identifier = NSUserInterfaceItemIdentifier("starry.settings")
    static let defaultSize = CGSize(width: 900, height: 640)
    static let minSize = CGSize(width: 800, height: 540)

    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let host = NSHostingController(rootView: SettingsWindowRoot(model: model))
        // The window sets the size; asking the content would lay out every page's rows.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.identifier = Self.identifier
        window.title = "设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .documentWindow
        window.contentMinSize = Self.minSize
        window.delegate = self
        window.setContentSize(Self.defaultSize)
        let autosave = "starry.settings"
        if !window.setFrameUsingName(autosave) {
            if let parent {
                let frame = parent.frame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
            } else {
                window.center()
            }
        }
        window.setFrameAutosaveName(autosave)
        // Nothing focused at first: left to itself, AppKit focuses the first text field (the
        // search box) when the window becomes key, and it would take the space bar.
        window.initialFirstResponder = host.view
        self.window = window
        followAppearance()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    func yieldToMainWindow() {
        guard let window, window.isKeyWindow else { return }
        NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func followAppearance() {
        guard let window, let model else { return }
        withObservationTracking {
            window.appearance = switch model.preferredColorScheme {
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            default: nil
            }
        } onChange: {
            Task { @MainActor [weak self] in self?.followAppearance() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit keeps the last closed window around for a while; its pages go once it has
        // faded out.
        if let closing = window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { closing.contentViewController = nil }
        }
        window = nil
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
        model?.settingsDidClose()
    }
}

private struct SettingsWindowRoot: View {
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsView()
            .environment(model)
            .environment(\.theme, model.theme(for: colorScheme))
            .ignoresSafeArea()
    }
}
