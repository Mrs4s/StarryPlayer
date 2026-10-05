import AppKit
import SwiftUI

@MainActor
final class AuxiliaryWindowController: NSObject, NSWindowDelegate {

    let identifier: NSUserInterfaceItemIdentifier
    private(set) var window: NSWindow?
    private weak var model: AppModel?
    private var onClose: (() -> Void)?

    init(identifier: String) {
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
    }

    var isOpen: Bool { window != nil }

    func show<Content: View>(title: String, model: AppModel, onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        if window != nil { closeNow() }
        self.model = model
        self.onClose = onClose
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let host = NSHostingController(rootView: AuxiliaryWindowRoot(model: model, content: content()))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.identifier = identifier
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior.insert([.fullScreenNone, .fullScreenAuxiliary])
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .documentWindow
        window.delegate = self
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        // Nothing focused at first, so a text field does not take the keyboard on its own.
        window.initialFirstResponder = host.view
        self.window = window
        followAppearance()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window as its close button would.
    func close() {
        window?.performClose(nil)
    }

    private func closeNow() {
        window?.close()
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
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // AppKit keeps a closed window around for a while; its content goes once it has faded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { closing.contentViewController = nil }
        window = nil
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}

/// The window's content in the app's theme for the window's appearance. The content sits below
/// the title bar (its safe area), so the window fits it exactly; its background should reach
/// under the title bar (`.ignoresSafeArea()` on the background).
private struct AuxiliaryWindowRoot<Content: View>: View {
    let model: AppModel
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .environment(model)
            .environment(\.theme, model.theme(for: colorScheme))
    }
}

/// Esc closes the window whatever has the focus (a key equivalent, not `onExitCommand`).
struct WindowCancelShortcut: ViewModifier {
    var action: () -> Void

    func body(content: Content) -> some View {
        content.background {
            Button("", action: action)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
