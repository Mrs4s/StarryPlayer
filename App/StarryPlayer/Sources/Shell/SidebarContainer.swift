import AppKit
import SwiftUI

struct SidebarContainer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var window = WindowRef()

    static let edgeWidth: CGFloat = 8
    static let outsideReach: CGFloat = 200
    static let keepAfterLeaving: Duration = .milliseconds(150)
    static var holdsPeek = false

    var body: some View {
        let mode = model.sidebarMode
        let floating = mode != .docked
        let peeking = mode == .autoHide && model.sidebarPeeking
        let shown = mode != .autoHide || peeking
        let inset = floating ? Metrics.floatingSidebarInset : 0
        let width = mode == .docked && model.sidebarCollapsed ? Metrics.sidebarCollapsedWidth : Metrics.sidebarWidth
        let shape = RoundedRectangle(cornerRadius: floating ? Metrics.floatingSidebarRadius : 0, style: .continuous)
        ZStack(alignment: .topLeading) {
            Sidebar()
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .clipShape(shape)
                .background { SidebarSurface(shape: shape, floating: floating, overPages: mode == .autoHide) }
                .padding(inset)
                // Out of sight, the hidden sidebar waits just past the window's edge, shadow and
                // all; with Reduce Motion it fades instead.
                .offset(x: shown || reduceMotion ? 0 : -(inset + width + 32))
                .opacity(shown || !reduceMotion ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
                .environment(\.isPageActive, shown)
            if mode == .autoHide && !peeking {
                edgeTrigger
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background { WindowButtonsSync(window: window) }
        .task(id: peeking) {
            if peeking { await sendBackOnceLeft() }
        }
    }

    /// The strip along the window's left edge: the pointer touching it brings the sidebar out at
    /// once. Not while a button is held — resizing the window from its left edge passes here.
    private var edgeTrigger: some View {
        Color.clear
            .frame(width: Self.edgeWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside, NSEvent.pressedMouseButtons == 0, !model.player.showNowPlaying else { return }
                withAnimation(Motion.sidebarPeek) { model.sidebarPeeking = true }
            }
    }

    /// Poll only while the auto-hide sidebar is open: hover events stop at window edges.
    /// Keep it open during drags and menu tracking.
    private func sendBackOnceLeft() async {
        var awaySince: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            if Self.holdsPeek || pointerIsNearPanel() {
                awaySince = nil
            } else if let since = awaySince {
                if ContinuousClock.now - since >= Self.keepAfterLeaving {
                    withAnimation(Motion.sidebarUnpeek) { model.sidebarPeeking = false }
                    return
                }
            } else {
                awaySince = ContinuousClock.now
            }
        }
    }

    private func pointerIsNearPanel() -> Bool {
        if NSEvent.pressedMouseButtons != 0 || RunLoop.current.currentMode == .eventTracking { return true }
        guard let window = window.window, window.isVisible, !window.isMiniaturized else { return false }
        // Window coordinates: origin at the bottom left, x < 0 left of the window.
        let point = window.mouseLocationOutsideOfEventStream
        let right = Metrics.floatingSidebarInset * 2 + Metrics.sidebarWidth
        return point.x >= -Self.outsideReach && point.x <= right && point.y >= -7 && point.y <= window.frame.height + 7
    }
}

/// The sidebar's surface. Docked: a faint tone over the window surface with a hairline down its
/// right edge. Floating: Liquid Glass (macOS 26+), or before that a frosted panel like the classic
/// player bar, its shadow deeper when it lies over the pages. The two cross-fade as the mode
/// changes.
private struct SidebarSurface: View {
    var shape: RoundedRectangle
    var floating: Bool
    var overPages: Bool
    @Environment(\.theme) private var theme

    private static var glass: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    var body: some View {
        let dark = theme.isDark
        ZStack {
            shape.fill(theme.onSurface.opacity(dark ? 0.025 : 0.03))
                .background(shape.fill(theme.surface))
                .overlay(alignment: .trailing) {
                    LinearGradient(stops: [
                        .init(color: theme.outlineVariant.opacity(0), location: 0),
                        .init(color: theme.outlineVariant.opacity(0.7), location: 0.12),
                        .init(color: theme.outlineVariant.opacity(0.7), location: 0.88),
                        .init(color: theme.outlineVariant.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(width: 1)
                }
                .opacity(floating ? 0 : 1)
            if Self.glass {
                // Out over the pages, clear glass lets their text show through the rows'; a layer
                // of the panel colour over it (not in it, where the glass would recolour it) calms
                // it.
                shape.fill(theme.surfacePanel.opacity(overPages ? (dark ? 0.32 : 0.42) : 0))
                    .background { Color.clear.barGlass(floating, in: shape) }
                    .opacity(floating ? 1 : 0)
            } else {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(theme.surfacePanel.opacity(dark ? 0.62 : 0.7))
                    shape.strokeBorder(theme.onSurface.opacity(dark ? 0.09 : 0.07), lineWidth: 1)
                }
                .background(
                    shape.fill(theme.surfacePanel.opacity(0.4))
                        .shadow(color: .black.opacity(dark ? (overPages ? 0.45 : 0.28) : (overPages ? 0.24 : 0.08)), radius: overPages ? 28 : 14, y: overPages ? 10 : 3)
                )
                .opacity(floating ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
    }
}

@MainActor
final class WindowRef {
    weak var window: NSWindow?
}

/// Keeps the traffic lights where the sidebar wants them: in the floating panel's top row, and
/// out of sight with the hidden panel (back while Now Playing covers the shell). A leaf of its own,
/// so only it follows Now Playing.
private struct WindowButtonsSync: View {
    var window: WindowRef
    @Environment(AppModel.self) private var model

    var body: some View {
        let mode = model.sidebarMode
        WindowButtonsPlacement(
            moved: mode != .docked,
            hidden: mode == .autoHide && !model.sidebarPeeking && !model.player.showNowPlaying,
            window: window
        )
    }
}

private struct WindowButtonsPlacement: NSViewRepresentable {
    var moved: Bool
    var hidden: Bool
    var window: WindowRef

    func makeNSView(context: Context) -> WindowButtonsView {
        let view = WindowButtonsView()
        view.windowRef = window
        return view
    }

    func updateNSView(_ view: WindowButtonsView, context: Context) {
        view.update(moved: moved, hidden: hidden)
    }
}

/// Reposition traffic lights after AppKit finishes tiling, never inside frame notifications.
/// Animate layers instead of `alphaValue`, which triggers retiling; leave full-screen controls
/// alone.
final class WindowButtonsView: NSView {
    weak var windowRef: WindowRef?

    static let floatingOrigin = CGPoint(x: Metrics.floatingSidebarInset + 10, y: Metrics.floatingSidebarInset + 10)
    static let floatingCenterY: CGFloat = floatingOrigin.y + 7

    private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private static let fadeKey = "starry.fade"

    private var moved = false
    private var hidesButtons = false
    private var fullScreen = false
    /// Where AppKit put each button, and where this view last put it.
    private var system: [NSWindow.ButtonType: NSPoint] = [:]
    private var placed: [NSWindow.ButtonType: NSPoint] = [:]
    /// Setting the sidebar's place again is queued (and how many times in a row it did not stick).
    private var placeQueued = false
    private var placeRetries = 0
    /// Bumped by every change, so the end of a superseded fade does nothing.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(moved: Bool, hidden: Bool) {
        guard moved != self.moved || hidden != hidesButtons else { return }
        self.moved = moved
        hidesButtons = hidden
        apply(animated: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        windowRef?.window = window
        guard let window else { return }
        fullScreen = window.styleMask.contains(.fullScreen)
        for (type, button) in buttons(in: window) {
            if system[type] == nil { system[type] = button.frame.origin }
            button.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.buttonMoved(type, button) }
            })
        }
        // A resize tiles the title bar before this; setting the place here, not later, keeps a
        // live resize from drawing the buttons in AppKit's place first.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeNow() }
        })
        for (name, entering) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fullScreen = entering
                    self?.apply(animated: false)
                }
            })
        }
        apply(animated: false)
    }

    private func buttons(in window: NSWindow) -> [(NSWindow.ButtonType, NSButton)] {
        Self.types.compactMap { type in window.standardWindowButton(type).map { (type, $0) } }
    }

    /// A button moved: by this view (where it last put it: nothing to do), or by AppKit.
    private func buttonMoved(_ type: NSWindow.ButtonType, _ button: NSButton) {
        guard button.frame.origin != placed[type] else { return }
        system[type] = button.frame.origin
        placed[type] = nil
        queuePlace()
    }

    /// Sets the sidebar's place again, where AppKit is not tiling (it has returned).
    private func placeNow() {
        guard moved, !fullScreen, let window else { return }
        let buttons = buttons(in: window)
        if buttons.contains(where: { $0.1.frame.origin != target($0.0, $0.1) }) { place(buttons) }
    }

    /// Sets the sidebar's place again after the current AppKit call (a tiling) has returned.
    private func queuePlace() {
        guard moved, !fullScreen, !placeQueued else { return }
        placeQueued = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.placeQueued = false
                self.placeNow()
            }
        }
    }

    private func target(_ type: NSWindow.ButtonType, _ button: NSButton) -> NSPoint {
        guard let origin = system[type] else { return button.frame.origin }
        guard moved, !fullScreen, let window, let superview = button.superview, let close = system[.closeButton] else { return origin }
        let size = button.frame.size
        // From the window's top-left to the title bar view's coordinates, kept inside that view.
        var rect = NSRect(x: Self.floatingOrigin.x + origin.x - close.x, y: window.frame.height - Self.floatingOrigin.y - size.height, width: size.width, height: size.height)
        rect = superview.convert(rect, from: nil)
        rect.origin.y = min(max(rect.origin.y, 0), superview.bounds.height - size.height)
        return rect.origin
    }

    private func place(_ buttons: [(NSWindow.ButtonType, NSButton)]) {
        for (type, button) in buttons {
            let origin = target(type, button)
            placed[type] = origin
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        // A move AppKit ignored (it was tiling after all): try again, a few times at most.
        if buttons.contains(where: { $0.1.frame.origin != placed[$0.0] }), placeRetries < 3 {
            placeRetries += 1
            for (type, button) in buttons where button.frame.origin != placed[type] { placed[type] = nil }
            queuePlace()
        } else {
            placeRetries = 0
        }
        buttons.first?.1.superview?.updateTrackingAreas()
        window?.contentView?.superview?.updateTrackingAreas()
    }

    private func apply(animated: Bool) {
        guard let window else { return }
        generation += 1
        let generation = generation
        let buttons = buttons(in: window)
        let visible = !hidesButtons || fullScreen
        let needsMove = buttons.contains { $0.1.frame.origin != target($0.0, $0.1) }
        let onScreen = buttons.contains { !$0.1.isHidden && ($0.1.layer?.opacity ?? 1) > 0 }
        if needsMove && onScreen && animated {
            fade(buttons, to: 0, duration: 0.1) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.place(buttons)
                self.show(buttons, visible, animated: true, generation: generation)
            }
        } else {
            if needsMove { place(buttons) }
            show(buttons, visible, animated: animated, generation: generation)
        }
    }

    private func show(_ buttons: [(NSWindow.ButtonType, NSButton)], _ visible: Bool, animated: Bool, generation: Int) {
        if visible {
            for (_, button) in buttons where button.isHidden {
                button.layer?.opacity = 0
                button.isHidden = false
            }
            placeNow()
            fade(buttons, to: 1, duration: animated ? 0.14 : 0)
        } else {
            // Hidden, not just transparent: a transparent button still takes clicks.
            fade(buttons, to: 0, duration: animated ? 0.1 : 0) { [weak self] in
                guard let self, self.generation == generation else { return }
                for (_, button) in buttons { button.isHidden = true }
                self.placeNow()
            }
        }
    }

    private func fade(_ buttons: [(NSWindow.ButtonType, NSButton)], to opacity: Float, duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion {
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        }
        for (_, button) in buttons {
            guard let layer = button.layer else { continue }
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = opacity
            if duration > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from
                fade.toValue = opacity
                fade.duration = duration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(fade, forKey: Self.fadeKey)
            } else {
                layer.removeAnimation(forKey: Self.fadeKey)
            }
        }
        CATransaction.commit()
    }
}
