import AppKit
import SwiftUI

/// One row of a `PopMenu`: a command, a submenu (opened in place of the menu, with a way back),
/// an option with a checkmark, a section title, a line of information, or a divider.
struct PopMenuItem {
    enum Kind {
        case action(() -> Void)
        case submenu([PopMenuItem])
        case info(String)
        case header
        case divider
        /// Nothing: what a helper gives where its row does not apply.
        case empty
    }

    var title: String
    var systemImage: String?
    var kind: Kind
    var isDestructive = false
    var isDisabled = false
    var isChecked = false
    /// Small text before a submenu's chevron (the value picked in it).
    var detail: String?

    static func button(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, disabled: Bool = false, action: @escaping () -> Void) -> PopMenuItem {
        PopMenuItem(title: title, systemImage: systemImage, kind: .action(action), isDestructive: role == .destructive, isDisabled: disabled)
    }

    static func submenu(_ title: String, systemImage: String? = nil, detail: String? = nil, @PopMenuBuilder items: () -> [PopMenuItem]) -> PopMenuItem {
        let items = tidy(items())
        return PopMenuItem(title: title, systemImage: systemImage, kind: .submenu(items), isDisabled: items.isEmpty, detail: detail)
    }

    /// One of a set of choices, checked when it is the one picked.
    static func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> PopMenuItem {
        PopMenuItem(title: title, kind: .action(action), isChecked: selected)
    }

    static func header(_ title: String) -> PopMenuItem {
        PopMenuItem(title: title, kind: .header)
    }

    /// A label and its value on one line, not clickable.
    static func info(_ title: String, _ value: String) -> PopMenuItem {
        PopMenuItem(title: title, kind: .info(value))
    }

    static var divider: PopMenuItem { PopMenuItem(title: "", kind: .divider) }
    static var empty: PopMenuItem { PopMenuItem(title: "", kind: .empty) }

    var isSelectable: Bool {
        guard !isDisabled else { return false }
        switch kind {
        case .action, .submenu: return true
        case .info, .header, .divider, .empty: return false
        }
    }

    var isDivider: Bool {
        if case .divider = kind { true } else { false }
    }

    /// Without the empty rows, and with dividers only between rows (none leading, trailing or
    /// doubled), as menus built from conditions would otherwise have them.
    static func tidy(_ items: [PopMenuItem]) -> [PopMenuItem] {
        var result: [PopMenuItem] = []
        for item in items {
            if case .empty = item.kind { continue }
            if item.isDivider, result.last?.isDivider ?? true { continue }
            result.append(item)
        }
        if result.last?.isDivider == true { result.removeLast() }
        return result
    }
}

@resultBuilder
enum PopMenuBuilder {
    static func buildExpression(_ item: PopMenuItem) -> [PopMenuItem] { [item] }
    static func buildExpression(_ items: [PopMenuItem]) -> [PopMenuItem] { items }
    static func buildBlock(_ parts: [PopMenuItem]...) -> [PopMenuItem] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [PopMenuItem]?) -> [PopMenuItem] { part ?? [] }
    static func buildEither(first part: [PopMenuItem]) -> [PopMenuItem] { part }
    static func buildEither(second part: [PopMenuItem]) -> [PopMenuItem] { part }
    static func buildArray(_ parts: [[PopMenuItem]]) -> [PopMenuItem] { parts.flatMap { $0 } }
}

/// A button that opens the app's own menu in place of the system's (`Menu`): a card in the
/// page's colours that unfolds from the button, with a highlight that glides between rows,
/// submenus that slide in over the menu, and the arrow keys, Return and Esc.
///
/// The rows are built when it opens, as a system menu's are. Style the button as any other
/// (`buttonStyle`, `disabled`, `help`); the label can follow the menu being open.
struct PopMenu<Label: View>: View {
    private let items: () -> [PopMenuItem]
    private let label: (Bool) -> Label
    private let placement: PopMenuPlacement
    private let matchesWidth: Bool
    private let isPresented: Binding<Bool>?
    @Environment(\.theme) private var theme
    @State private var controller = PopMenuController()

    /// - Parameters:
    ///   - placement: where it opens by the button.
    ///   - matchesWidth: at least as wide as the button (a pop-up button's choices).
    ///   - isPresented: follows the menu being open, for a page that should not change under it.
    init(placement: PopMenuPlacement = .below, matchesWidth: Bool = false, isPresented: Binding<Bool>? = nil,
         @PopMenuBuilder items: @escaping () -> [PopMenuItem], @ViewBuilder label: @escaping (_ isOpen: Bool) -> Label) {
        self.items = items
        self.label = label
        self.placement = placement
        self.matchesWidth = matchesWidth
        self.isPresented = isPresented
    }

    init(placement: PopMenuPlacement = .below, matchesWidth: Bool = false, isPresented: Binding<Bool>? = nil,
         @PopMenuBuilder items: @escaping () -> [PopMenuItem], @ViewBuilder label: @escaping () -> Label) {
        self.init(placement: placement, matchesWidth: matchesWidth, isPresented: isPresented, items: items) { _ in label() }
    }

    var body: some View {
        Button {
            controller.toggle(items: items(), theme: theme, placement: placement, matchesWidth: matchesWidth)
        } label: {
            label(controller.isOpen)
        }
        .background(PopMenuAnchor(controller: controller))
        .onChange(of: controller.isOpen) { _, open in
            if let isPresented, isPresented.wrappedValue != open { isPresented.wrappedValue = open }
        }
        .onDisappear { controller.close() }
    }
}

/// The "…" of a more menu, standing up while its menu is open.
struct PopMenuEllipsis: View {
    var isOpen: Bool
    var size: CGFloat = 15
    var weight: Font.Weight = .semibold

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: size, weight: weight))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: isOpen)
    }
}

/// Where the button is in AppKit, to place the menu by it, and the button going away.
private struct PopMenuAnchor: NSViewRepresentable {
    let controller: PopMenuController

    func makeNSView(context: Context) -> PopMenuAnchorView {
        let view = PopMenuAnchorView()
        view.controller = controller
        controller.anchor = view
        return view
    }

    func updateNSView(_ view: PopMenuAnchorView, context: Context) {
        view.controller = controller
        controller.anchor = view
    }
}

final class PopMenuAnchorView: NSView {
    weak var controller: PopMenuController?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.close() }
    }
}

/// Opens and closes one button's menu: places its panel, keeps it the only menu open, and
/// closes it on a click elsewhere, Esc, the window changing or the app going to the background.
@MainActor
@Observable
final class PopMenuController {
    private(set) var isOpen = false
    @ObservationIgnored weak var anchor: NSView?
    @ObservationIgnored private var panel: PopMenuPanel?
    @ObservationIgnored private var session: PopMenuSession?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static weak var active: PopMenuController?

    /// A menu is open: other click and Esc watchers (the account switcher's) leave it the events.
    static var isAnyOpen: Bool { active?.isOpen == true }

    func toggle(items: [PopMenuItem], theme: Theme, placement: PopMenuPlacement, matchesWidth: Bool) {
        if isOpen {
            close()
        } else {
            open(items: items, theme: theme, placement: placement, matchesWidth: matchesWidth)
        }
    }

    private func open(items: [PopMenuItem], theme: Theme, placement: PopMenuPlacement, matchesWidth: Bool) {
        let items = PopMenuItem.tidy(items)
        guard !items.isEmpty, let anchor, let window = anchor.window, let screen = window.screen ?? NSScreen.main else { return }
        Self.active?.close()
        Self.active = self

        // Laid out top-left (as SwiftUI lays the card out), in the screen's points.
        let top = screen.frame.maxY
        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height) }
        let anchorFrame = flipped(window.convertToScreen(anchor.convert(anchor.bounds, to: nil)))
        let measurer = PopMenuMeasurer(theme: theme)
        let root = PopMenuPage(title: nil, items: items, measurer: measurer)
        let layout = PopMenuLayout(anchor: anchorFrame, bounds: flipped(screen.visibleFrame), window: flipped(window.frame),
                                   root: root.size, largest: CGSize(width: root.widest, height: root.tallest), placement: placement,
                                   minWidth: matchesWidth ? anchorFrame.width : PopMenuMetrics.minWidth)
        let session = PopMenuSession(root: root, theme: theme, layout: layout)
        session.onPick = { [weak self] action in self?.close(then: action) }
        session.onDismiss = { [weak self] in self?.close() }

        let panel = PopMenuPanel(session: session)
        panel.setFrame(flipped(layout.frame.insetBy(dx: -PopMenuMetrics.margin, dy: -PopMenuMetrics.margin)), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()

        self.panel = panel
        self.session = session
        isOpen = true
        watch(window)
        // The first frame shows the folded card, so it unfolds from there.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.present() }
        }
    }

    /// Closes the menu, the card folding back; `then` runs as it starts to.
    func close(then action: (() -> Void)? = nil) {
        guard isOpen, let panel, let session else { return }
        isOpen = false
        unwatch()
        self.panel = nil
        self.session = nil
        if Self.active === self { Self.active = nil }
        panel.ignoresMouseEvents = true
        session.dismiss {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        action?()
    }

    // MARK: Events

    private func watch(_ window: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
        let center = NotificationCenter.default
        let closing: [(NSNotification.Name, AnyObject?)] = [
            (NSApplication.didResignActiveNotification, nil),
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.willCloseNotification, window),
            (NSWindow.didMoveNotification, window),
            (NSWindow.didResizeNotification, window),
            (NSWindow.willEnterFullScreenNotification, window),
            (NSWindow.willExitFullScreenNotification, window),
        ]
        observers = closing.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    private func unwatch() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// True when the event is the menu's: a click in it or a key it takes.
    private func handle(_ event: NSEvent) -> Bool {
        guard let panel, let session else { return false }
        let onCard = event.window === panel && panel.cardContains(event.locationInWindow)
        switch event.type {
        case .keyDown:
            return handleKey(event, session: session)
        case .scrollWheel:
            if !onCard { close() }
            return false
        default:
            if onCard { return false }
            // A click elsewhere only closes the menu, as a system menu's does (clicking its
            // button again closes it rather than opening it once more).
            close()
            return true
        }
    }

    private func handleKey(_ event: NSEvent, session: PopMenuSession) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            close()
            return false
        }
        switch event.keyCode {
        case 53: session.back()                          // Esc
        case 125: session.moveHighlight(by: 1)            // ↓
        case 126: session.moveHighlight(by: -1)           // ↑
        case 124: session.enterHighlighted()              // →
        case 123: session.back(closing: false)            // ←
        case 36, 76, 49: session.activateHighlighted()    // Return, Enter, Space
        case 48: session.moveHighlight(by: modifiers.contains(.shift) ? -1 : 1)  // Tab
        default: break
        }
        return true
    }
}

/// A borderless panel over its window, holding the card, that never takes focus: the window
/// stays key (and its title bar active), and its key events reach the menu through
/// `PopMenuController`'s monitor. A window of its own, so the rows under the card (tracked by
/// their window's pointer areas) do not light up as the pointer moves over the menu, and the
/// card can reach past the window's edge.
final class PopMenuPanel: NSPanel {
    private let session: PopMenuSession
    private let host: PopMenuHostingView<PopMenuCanvas>

    init(session: PopMenuSession) {
        self.session = session
        host = PopMenuHostingView(rootView: PopMenuCanvas(session: session))
        host.sizingOptions = []
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        appearance = NSAppearance(named: session.theme.isDark ? .darkAqua : .aqua)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A point in the panel (window coordinates) on the card.
    func cardContains(_ point: NSPoint) -> Bool {
        session.cardFrame.contains(host.convert(point, from: nil))
    }
}

/// Takes the click that picks a row, though the panel is never key.
final class PopMenuHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum PopMenuMetrics {
    static let minWidth: CGFloat = 188
    static let maxWidth: CGFloat = 320
    static let maxHeight: CGFloat = 540
    static let radius: CGFloat = 13
    static let inset: CGFloat = 5
    static let rowHeight: CGFloat = 30
    /// Room around the card in its panel for the shadow and the spring's overshoot.
    static let margin: CGFloat = 40
    /// Between the button and the card.
    static let gap: CGFloat = 6
    /// Kept clear at the screen's edges.
    static let edgeInset: CGFloat = 8
}

/// Where a menu opens by its button.
enum PopMenuPlacement {
    /// Under it, or above when it fits only there.
    case below
    /// Above it, or under when it fits only there.
    case above
    /// Beside it, its first row level with the button, on the trailing side or the leading one
    /// when it fits only there (a row that leads on to more, like a submenu's).
    case beside
}

/// Where a menu goes, lined up with the button's leading edge (its trailing one for a button on
/// the right of its window), on the side `PopMenuPlacement` asks for when it fits there. It keeps
/// to the window when it fits in it on either side, and to the screen past that. Top-left
/// coordinates.
struct PopMenuLayout {
    /// Room for the largest page; the card sits in the corner by the button.
    var frame: CGRect
    var opensUpward: Bool
    var leading: Bool
    var minWidth: CGFloat
    var maxHeight: CGFloat
    /// The point the card unfolds from (the button's centre on the card's near edge).
    var unfoldAnchor: UnitPoint
    /// Where the folded card sits: a little towards the button.
    var foldOffset: CGSize

    /// - Parameters:
    ///   - anchor, bounds, window: the button, the screen's usable area and the button's window.
    ///   - root: the menu's size; `largest`, the widest and the tallest of it and its submenus.
    init(anchor: CGRect, bounds: CGRect, window: CGRect, root: CGSize, largest: CGSize, placement: PopMenuPlacement, minWidth: CGFloat) {
        let gap = PopMenuMetrics.gap
        let inset = PopMenuMetrics.edgeInset
        self.minWidth = min(max(minWidth, 120), PopMenuMetrics.maxWidth)
        let widest = min(max(largest.width, self.minWidth), PopMenuMetrics.maxWidth, bounds.width - 2 * inset)
        let rootWidth = min(max(root.width, self.minWidth), widest)
        let rootHeight = root.height

        if placement == .beside {
            // Wider: the button is usually a row inset in a panel, and the card goes outside it.
            let gap = gap * 2
            opensUpward = false
            maxHeight = max(min(bounds.height - 2 * inset, PopMenuMetrics.maxHeight), PopMenuMetrics.rowHeight * 3)
            let tallest = min(largest.height, maxHeight)
            let after = Room(window: window.maxX - inset - (anchor.maxX + gap), screen: bounds.maxX - inset - (anchor.maxX + gap))
            let before = Room(window: anchor.minX - gap - (window.minX + inset), screen: anchor.minX - gap - (bounds.minX + inset))
            // `leading` is the card's edge by the button: its leading edge when it is after it.
            leading = Room.prefers(after, over: before, for: widest)
            let x = leading ? anchor.maxX + gap : anchor.minX - gap - widest
            let y = min(max(anchor.minY - PopMenuMetrics.inset, bounds.minY + inset), bounds.maxY - inset - tallest)
            frame = CGRect(x: x, y: y, width: widest, height: tallest)
            let unitY = (anchor.midY - y) / max(min(rootHeight, maxHeight), 1)
            unfoldAnchor = UnitPoint(x: leading ? 0 : 1, y: min(max(unitY, 0), 1))
            foldOffset = CGSize(width: leading ? -8 : 8, height: 0)
            return
        }

        let below = Room(window: window.maxY - inset - (anchor.maxY + gap), screen: bounds.maxY - inset - (anchor.maxY + gap))
        let above = Room(window: anchor.minY - gap - (window.minY + inset), screen: anchor.minY - gap - (bounds.minY + inset))
        opensUpward = placement == .above ? Room.prefers(above, over: below, for: rootHeight) : !Room.prefers(below, over: above, for: rootHeight)
        maxHeight = max(min((opensUpward ? above : below).screen, PopMenuMetrics.maxHeight), PopMenuMetrics.rowHeight * 3)
        let tallest = min(largest.height, maxHeight)

        var leading = anchor.midX < window.minX + window.width * 0.62
        if leading, anchor.minX + widest > bounds.maxX - inset { leading = false }
        if !leading, anchor.maxX - widest < bounds.minX + inset { leading = true }
        self.leading = leading

        var x = leading ? anchor.minX : anchor.maxX - widest
        x = min(max(x, bounds.minX + inset), bounds.maxX - inset - widest)
        let y = opensUpward ? anchor.minY - gap - tallest : anchor.maxY + gap
        frame = CGRect(x: x, y: y, width: widest, height: tallest)

        let cardMinX = leading ? frame.minX : frame.maxX - rootWidth
        let unitX = (anchor.midX - cardMinX) / max(rootWidth, 1)
        unfoldAnchor = UnitPoint(x: min(max(unitX, 0), 1), y: opensUpward ? 1 : 0)
        foldOffset = CGSize(width: 0, height: opensUpward ? 6 : -6)
    }

    /// The space on one side of the button, in its window and on the screen.
    private struct Room {
        var window: CGFloat
        var screen: CGFloat

        /// The side asked for when the card fits there in the window, the other when only it
        /// does; past the window, the same on the screen; else the roomier.
        static func prefers(_ first: Room, over second: Room, for need: CGFloat) -> Bool {
            if first.window >= need { return true }
            if second.window >= need { return false }
            if first.screen >= need { return true }
            if second.screen >= need { return false }
            return first.screen >= second.screen
        }
    }

    var cardAlignment: Alignment {
        switch (opensUpward, leading) {
        case (false, true): .topLeading
        case (false, false): .topTrailing
        case (true, true): .bottomLeading
        case (true, false): .bottomTrailing
        }
    }
}
