import AppKit
import Library
import LyricsUI
import Observation
import StarryCore
import SwiftUI

@MainActor
@Observable
final class DesktopLyricsChrome {
    var hovering = false
    var hint: String?
}

struct DesktopLyricsActions {
    var previous: @MainActor () -> Void
    var playPause: @MainActor () -> Void
    var next: @MainActor () -> Void
    var lock: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
    var close: @MainActor () -> Void
}

@MainActor
final class DesktopLyricsController {
    // Keep placement outside settings so dragging does not rewrite the settings store.
    static let anchorKey = "starry.desktopLyrics.anchor"
    static let toolbarHeight: CGFloat = 34
    static let toolbarWidth: CGFloat = 360
    // Avoid hiding during the pause between songs.
    static let pauseLinger: Duration = .milliseconds(1500)
    // Correct animation drift when playback stalls.
    static let driftCheckInterval: TimeInterval = 1

    private weak var model: AppModel?
    private var options = AppSettings.DesktopLyrics()
    private var panel: DesktopLyricsPanel?
    private var lyricsView: DesktopLyricsView?
    private var backdrop: NSView?
    private var toolbar: NSView?
    private let chrome = DesktopLyricsChrome()
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var driftTimer: Timer?
    private var pauseTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var hasTrack = false
    private var isPlaying = false
    private var hiddenForPause = false
    private var pressing = false
    /// The panel is being moved here, not by the user.
    private var placing = false
    // Requested size before clamping to the screen.
    private var size = CGSize.zero

    init(model: AppModel) {
        self.model = model
    }

    /// Keeps the controls up whatever the pointer does (screenshots).
    var holdsHover = false {
        didSet { setHovering(holdsHover) }
    }

    func apply(_ options: AppSettings.DesktopLyrics) {
        guard options.enabled else { return remove() }
        let old = self.options
        self.options = options
        if panel == nil {
            install()
        } else if options != old {
            update(from: old)
        }
    }

    // MARK: Panel

    private func install() {
        guard let model else { return }
        generation += 1
        let panel = DesktopLyricsPanel()
        let container = DesktopLyricsContainer()
        container.autoresizesSubviews = true

        let backdrop = DesktopLyricsBackdrop()
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)

        let view = DesktopLyricsView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        let player = model.player
        view.timeSource = { [weak player] in player?.preciseClock() ?? (0, 0) }
        container.addSubview(view)

        let actions = DesktopLyricsActions(
            previous: { [weak player] in player?.previous() },
            playPause: { [weak player] in player?.togglePlayPause() },
            next: { [weak player] in player?.next() },
            lock: { [weak model] in model?.desktopLyricsLocked = true },
            openSettings: { [weak model] in
                NSApp.activate()
                model?.openSettings(.lyrics)
            },
            close: { [weak model] in model?.showsDesktopLyrics = false }
        )
        let toolbar = NotchHostingView(rootView: DesktopLyricsToolbar(chrome: chrome, player: player, actions: actions))
        toolbar.sizingOptions = []
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(toolbar)

        container.onHover = { [weak self] in self?.hoverChanged($0) }
        container.onPress = { [weak self] in self?.press(with: $0) }
        container.onMenu = { [weak self] in self?.showMenu(for: $0) }
        panel.contentView = container
        self.panel = panel
        self.lyricsView = view
        self.backdrop = backdrop
        self.toolbar = toolbar

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelMoved() }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.occlusionChanged() }
            },
        ]

        applyStyle()
        layOut()
        panel.ignoresMouseEvents = options.locked
        panel.sharingType = options.hidesFromCapture ? .none : .readOnly
        observeSong()
        observeClock()
        if options.hidesWhenPaused, !isPlaying { hiddenForPause = true }
        updateVisibility()
    }

    private func remove() {
        guard let panel else { return }
        generation += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for task in [pauseTask, hintTask, hoverTask, saveTask] { task?.cancel() }
        driftTimer?.invalidate()
        driftTimer = nil
        lyricsView?.isSuspended = true
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        lyricsView = nil
        backdrop = nil
        toolbar = nil
        options.enabled = false
        chrome.hovering = false
        chrome.hint = nil
        hiddenForPause = false
        pressing = false
        hasTrack = false
        isPlaying = false
    }

    private func update(from old: AppSettings.DesktopLyrics) {
        guard let panel else { return }
        applyStyle()
        if options.fontSize != old.fontSize || options.width != old.width || options.showTranslation != old.showTranslation {
            layOut()
        }
        if options.locked != old.locked {
            panel.ignoresMouseEvents = options.locked
            if options.locked {
                hoverTask?.cancel()
                setHovering(false)
            }
            if panel.isVisible {
                showHint(options.locked ? "已锁定，可在程序坞图标的菜单中解锁" : "已解锁，拖动歌词可以移动位置")
            }
        }
        if options.hidesFromCapture != old.hidesFromCapture {
            panel.sharingType = options.hidesFromCapture ? .none : .readOnly
        }
        if options.hidesWhenPaused != old.hidesWhenPaused {
            pauseTask?.cancel()
            hiddenForPause = options.hidesWhenPaused && !isPlaying
            updateVisibility()
        }
    }

    private func layOut() {
        guard let panel, let container = panel.contentView, let lyricsView else { return }
        let metrics = DesktopLyricsView.Metrics(fontSize: CGFloat(options.fontSize))
        let lyricsHeight = metrics.height(showsTranslation: options.showTranslation)
        size = CGSize(width: CGFloat(min(max(options.width, 360), 2400)).rounded(), height: Self.toolbarHeight + lyricsHeight)
        place()
        let bounds = container.bounds
        lyricsView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.toolbarHeight)
        backdrop?.frame = bounds
        // Only as wide as the controls: a press beside them drags the panel.
        toolbar?.frame = CGRect(x: ((bounds.width - Self.toolbarWidth) / 2).rounded(), y: bounds.height - Self.toolbarHeight, width: Self.toolbarWidth, height: Self.toolbarHeight)
    }

    private func applyStyle() {
        guard let lyricsView else { return }
        var style = DesktopLyricsView.Style()
        style.fontSize = CGFloat(options.fontSize)
        style.perSyllable = options.perSyllable
        style.showsTranslation = options.showTranslation
        style.showsCard = options.background == .card
        (style.litColor, style.unlitColor) = Self.colors(options.palette, cover: model?.player.accentColor)
        style.translationColor = NSColor(white: 1, alpha: 0.85)
        lyricsView.style = style
    }

    static func colors(_ palette: AppSettings.DesktopLyrics.Palette, cover: Color?) -> (lit: NSColor, unlit: NSColor) {
        let whites = (NSColor.white, NSColor(white: 1, alpha: 0.5))
        let lit: NSColor
        switch palette {
        case .white: return whites
        case .cover:
            // The bright accent the dark theme takes from the cover; a grey cover has none.
            let accent = NSColor(Theme.make(seed: cover ?? Color(hex: "#FE7971"), dark: true, tintSurfaces: false).accent)
            guard let rgb = accent.usingColorSpace(.sRGB), rgb.saturationComponent > 0.15 else { return whites }
            lit = rgb
        case .blue: lit = NSColor(srgbRed: 0.31, green: 0.70, blue: 1, alpha: 1)
        case .green: lit = NSColor(srgbRed: 0.29, green: 0.87, blue: 0.50, alpha: 1)
        case .pink: lit = NSColor(srgbRed: 1, green: 0.44, blue: 0.66, alpha: 1)
        case .gold: lit = NSColor(srgbRed: 1, green: 0.78, blue: 0.24, alpha: 1)
        }
        return (lit, .white)
    }

    // MARK: Placement

    private var savedAnchor: DesktopLyricsPlacement.Anchor? {
        get {
            guard let values = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], values.count == 2 else { return nil }
            return .init(centerX: values[0], top: values[1])
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue.centerX, newValue.top], forKey: Self.anchorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.anchorKey)
            }
        }
    }

    private func place() {
        guard let panel else { return }
        let screens = NSScreen.screens.map { DesktopLyricsPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let frame = DesktopLyricsPlacement.frame(anchor: savedAnchor, size: size, screens: screens)
        guard frame != panel.frame else { return }
        placing = true
        panel.setFrame(frame, display: false)
        placing = false
    }

    /// Only moves made by dragging are kept: the system also moves the panel (a display going away).
    private func panelMoved() {
        guard !placing, pressing, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        saveWhenReleased()
    }

    private func saveWhenReleased() {
        saveTask?.cancel()
        let generation = generation
        saveTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled, self.generation == generation, let panel = self.panel else { return }
            self.pressing = false
            self.savedAnchor = DesktopLyricsPlacement.Anchor(frame: panel.frame)
            self.place()
        }
    }

    // MARK: Player

    // Update the view outside tracking so clock reads do not become song dependencies.
    private func observeSong() {
        guard let model, panel != nil else { return }
        let generation = generation
        let player = model.player
        let (content, offset, hasTrack) = withObservationTracking {
            let track = player.current
            // The cover's colour, for `.cover` (whenever the palette is switched to it).
            _ = player.accentColor
            let content = DesktopLyricsView.Content(document: player.lyrics, duration: player.duration,
                                                    title: track?.title ?? "Starry Player", artist: track?.artistText ?? "")
            return (content, -player.lyricOffset, track != nil)
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.observeSong()
            }
        }
        applyStyle()
        lyricsView?.timeOffset = offset
        lyricsView?.content = content
        if hasTrack != self.hasTrack {
            self.hasTrack = hasTrack
            pauseChanged()
        }
    }

    private func observeClock() {
        guard let model, panel != nil else { return }
        let generation = generation
        let player = model.player
        let playing = withObservationTracking {
            _ = player.isSeeking
            _ = player.seekSerial
            return player.isPlaying
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.observeClock()
            }
        }
        lyricsView?.sync()
        if playing != isPlaying {
            isPlaying = playing
            pauseChanged()
        }
        updateDriftTimer()
    }

    private func updateDriftTimer() {
        let needed = isPlaying && panel?.isVisible == true && lyricsView?.isSuspended == false
        if needed, driftTimer == nil {
            let timer = Timer(timeInterval: Self.driftCheckInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.lyricsView?.sync() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            driftTimer = timer
        } else if !needed, let timer = driftTimer {
            timer.invalidate()
            driftTimer = nil
        }
    }

    private func pauseChanged() {
        pauseTask?.cancel()
        let playing = isPlaying && hasTrack
        guard options.hidesWhenPaused, !playing else {
            if hiddenForPause {
                hiddenForPause = false
                updateVisibility()
            }
            return
        }
        guard !hiddenForPause else { return }
        let generation = generation
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pauseLinger)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.hiddenForPause = true
            self.updateVisibility()
        }
    }

    private func updateVisibility() {
        guard let panel else { return }
        let needed = !hiddenForPause
        if needed, !panel.isVisible {
            place()
            panel.orderFrontRegardless()
        } else if !needed, panel.isVisible {
            setHovering(false)
            panel.orderOut(nil)
        }
        updateDriftTimer()
    }

    private func occlusionChanged() {
        guard let panel, let lyricsView else { return }
        lyricsView.isSuspended = !panel.occlusionState.contains(.visible)
        updateDriftTimer()
    }

    // MARK: Pointer

    private func hoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        guard !options.locked else { return setHovering(false) }
        if inside {
            setHovering(true)
        } else {
            // A moment's grace, for a pointer passing over the edge on its way to a button.
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, !self.holdsHover else { return }
                self.setHovering(false)
            }
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard chrome.hovering != hovering else { return }
        chrome.hovering = hovering
        guard let backdrop else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hovering ? 0.15 : 0.25
            backdrop.animator().alphaValue = hovering ? 1 : 0
        }
    }

    private func press(with event: NSEvent) {
        guard let panel, !options.locked else { return }
        if event.clickCount == 2 {
            MainWindow.show()
            model?.player.showNowPlaying = true
            return
        }
        pressing = true
        let before = panel.frame
        // The window server moves the panel: smooth, and it keeps going while the app is busy.
        panel.performDrag(with: event)
        // Back once the drag is over; or at once, the moves then come while the button is held.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        if panel.frame != before {
            saveWhenReleased()
        } else {
            pressing = false
        }
    }

    private func showHint(_ text: String) {
        hintTask?.cancel()
        chrome.hint = text
        let generation = generation
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.chrome.hint = nil
        }
    }

    private func showMenu(for event: NSEvent) {
        guard let model, let view = panel?.contentView, !options.locked else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("锁定桌面歌词", symbol: "lock") { model.desktopLyricsLocked = true })
        menu.addItem(.separator())
        let translation = MenuAction.item("显示翻译", symbol: nil) { model.settings.settings.desktopLyrics.showTranslation.toggle() }
        translation.state = options.showTranslation ? .on : .off
        menu.addItem(translation)
        let syllables = MenuAction.item("逐字点亮", symbol: nil) { model.settings.settings.desktopLyrics.perSyllable.toggle() }
        syllables.state = options.perSyllable ? .on : .off
        menu.addItem(syllables)
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("桌面歌词设置…", symbol: "gearshape") {
            NSApp.activate()
            model.openSettings(.lyrics)
        })
        menu.addItem(MenuAction.item("关闭桌面歌词", symbol: "xmark") { model.showsDesktopLyrics = false })
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

@MainActor
final class MenuAction: NSObject {
    private let action: @MainActor () -> Void

    private init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    static func item(_ title: String, symbol: String?, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        // NSMenuItem.target is weak.
        item.representedObject = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func run() { action() }
}

final class DesktopLyricsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// The window server passes clicks on transparent pixels to the window underneath.
final class DesktopLyricsContainer: NSView {
    var onHover: ((Bool) -> Void)?
    var onPress: ((NSEvent) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onPress?(event) }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

// A visible backdrop keeps the pointer inside the panel between glyphs.
final class DesktopLyricsBackdrop: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 0.35)
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = CGColor(gray: 1, alpha: 0.12)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct DesktopLyricsToolbar: View {
    let chrome: DesktopLyricsChrome
    let player: PlayerController
    let actions: DesktopLyricsActions

    var body: some View {
        ZStack {
            if let hint = chrome.hint {
                Text(hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .transition(.opacity)
            } else if chrome.hovering {
                HStack(spacing: 2) {
                    DesktopLyricsButton(symbol: "backward.fill", action: actions.previous)
                    DesktopLyricsButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", action: actions.playPause)
                    DesktopLyricsButton(symbol: "forward.fill", action: actions.next)
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 14).padding(.horizontal, 6)
                    DesktopLyricsButton(symbol: "lock.fill", action: actions.lock)
                    DesktopLyricsButton(symbol: "gearshape.fill", action: actions.openSettings)
                    DesktopLyricsButton(symbol: "xmark", action: actions.close)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: chrome.hovering)
        .animation(.easeOut(duration: 0.2), value: chrome.hint)
    }
}

private struct DesktopLyricsButton: View {
    let symbol: String
    let action: @MainActor () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hovered ? 0.18 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
