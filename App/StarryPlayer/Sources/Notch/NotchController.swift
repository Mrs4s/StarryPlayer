import AppKit
import Library
import LyricsUI
import Observation
import StarryCore
import SwiftUI

/// What the island shows; `NotchController` changes it inside the animations that move it.
@MainActor
@Observable
final class NotchModel {
    var geometry = NotchGeometry(top: .zero, notch: CGSize(width: 0, height: NotchGeometry.fallbackHeight))
    var phase: NotchLayout.Phase = .hidden
    /// The closed island's line, cut to `NotchLayout.lyricsMaxWidth`, and its width; empty with
    /// the lyrics off.
    var lyric = ""
    var lyricWidth: CGFloat = 0

    var layout: NotchLayout {
        NotchLayout(phase: phase, geometry: geometry, lyricWidth: lyric.isEmpty ? nil : lyricWidth)
    }
}

/// What the island's views report back.
struct NotchActions {
    var hover: @MainActor (Bool) -> Void
    var tap: @MainActor () -> Void
    var scrub: @MainActor (Bool) -> Void
    var openNowPlaying: @MainActor () -> Void
}

/// The player in the notch (`AppSettings.Notch`): a panel over the menu bar, centred on the notch
/// (or the menu bar of a screen without one), holding an island that grows out of it. While a
/// song plays the cover and bars sit either side of the notch, with the line being sung after
/// them; resting the pointer on it drops the controls open. Paused for a while, it goes back
/// into the notch.
///
/// The panel is only as large as the island (and its shadow, open), so the rest of the menu bar
/// and the windows under it keep their clicks: it grows before the island does and shrinks once
/// the island has.
@MainActor
final class NotchController {
    private weak var model: AppModel?
    private let island = NotchModel()
    private var options = AppSettings.Notch()
    private var panel: NotchPanel?
    private var onScreen = false
    private var screenObserver: NSObjectProtocol?
    /// Bumped when the panel goes, so older observation loops and tasks stop.
    private var generation = 0
    private let lyricTitle = MenuBarLyricsTitle()

    private var expanded = false
    /// Nothing to play, or paused long enough that the island went back into the notch.
    private var idle = true
    private var hovering = false
    private var scrubbing = false
    private var idleTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    /// Counts island changes, so a shrink waiting for one to settle does not undo a newer one.
    private var revision = 0

    /// How long a paused song stays out beside the notch.
    static let pauseLinger: Duration = .seconds(20)
    static let lyricFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Keeps the island open whatever the pointer does (screenshots).
    var holdsOpen = false {
        didSet { setExpanded(holdsOpen) }
    }

    init(model: AppModel) {
        self.model = model
    }

    func apply(_ options: AppSettings.Notch) {
        guard options.enabled else { return remove() }
        guard options != self.options || panel == nil else { return }
        let lyricsChanged = options.showsLyrics != self.options.showsLyrics
        self.options = options
        if panel == nil {
            install()
        } else {
            placeOnScreen()
            if lyricsChanged { syncLyrics() }
        }
    }

    private func install() {
        guard let model else { return }
        generation += 1
        let panel = NotchPanel()
        let actions = NotchActions(
            hover: { [weak self] in self?.hoverChanged($0) },
            tap: { [weak self] in self?.tapped() },
            scrub: { [weak self] in self?.scrubbingChanged($0) },
            openNowPlaying: { [weak self] in self?.openNowPlaying() }
        )
        // Inside a plain view, not the panel's content view itself: as that, the hosting view
        // sizes the window to the island on its own and fights the frames set here (an endless
        // update-constraints loop).
        let hosting = NotchHostingView(rootView: NotchRoot(island: island, actions: actions, app: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        let content = NSView()
        hosting.frame = content.bounds
        content.addSubview(hosting)
        panel.contentView = content
        self.panel = panel
        let player = model.player
        lyricTitle.font = Self.lyricFont
        lyricTitle.maxTextWidth = NotchLayout.lyricsMaxWidth
        lyricTitle.timeSource = { [weak player] in player?.preciseClock() ?? (0, 0) }
        lyricTitle.onChange = { [weak self] in self?.lyricChanged() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen() }
        }
        placeOnScreen()
        observePlayer()
    }

    private func remove() {
        guard let panel else { return }
        generation += 1
        idleTask?.cancel()
        idleTask = nil
        hoverTask?.cancel()
        lyricTitle.stop()
        lyricTitle.onChange = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        options.enabled = false
        expanded = false
        hovering = false
        scrubbing = false
        idle = true
        island.phase = .hidden
        island.lyric = ""
        island.lyricWidth = 0
    }

    // MARK: Screen

    private func placeOnScreen() {
        guard let panel else { return }
        let screen = NotchGeometry.screen(among: NSScreen.screens, notchedOnly: options.notchedScreensOnly) { NotchGeometry(screen: $0).hasNotch }
        onScreen = screen != nil
        if let screen { island.geometry = NotchGeometry(screen: screen) }
        revision += 1
        panel.setFrame(island.layout.windowFrame(on: island.geometry), display: false)
        updateVisibility(settled: true)
    }

    /// Shown while there is something to see; on a screen with a notch also while hidden, as
    /// the notch itself is where the pointer opens it. `settled`: no island change still
    /// running (one closing on a screen without a notch keeps the panel until it is done).
    private func updateVisibility(settled: Bool) {
        guard let panel else { return }
        let needed = onScreen && (island.phase != .hidden || island.geometry.hasNotch || !settled)
        if needed, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !needed, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: Player

    private func observePlayer() {
        guard let model, panel != nil else { return }
        let generation = generation
        let player = model.player
        let (hasTrack, playing) = withObservationTracking {
            // What `syncLyrics` reads, so a change to it comes back here.
            _ = (player.lyrics, player.duration, player.lyricOffset, player.seekSerial)
            return (player.current != nil, player.isPlaying)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.observePlayer()
            }
        }
        syncLyrics()
        updateIdle(hasTrack: hasTrack, playing: playing)
        update()
    }

    /// The closed island's line follows the song and its clock while the lyrics are on.
    private func syncLyrics() {
        guard let player = model?.player else { return }
        guard options.showsLyrics else {
            lyricTitle.stop()
            if !island.lyric.isEmpty {
                transition(Motion.notchResize, lyric: "", width: 0)
            }
            return
        }
        let track = player.current
        lyricTitle.timeOffset = -player.lyricOffset
        lyricTitle.content = MenuBarLyricsView.Content(document: player.lyrics, duration: player.duration, title: track?.title ?? "", artist: track?.artistText ?? "")
        lyricTitle.sync()
    }

    private func lyricChanged() {
        guard options.showsLyrics, panel != nil else { return }
        let text = lyricTitle.title
        let width = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: Self.lyricFont]).width)
        guard text != island.lyric || width != island.lyricWidth else { return }
        if island.phase == .compact {
            transition(Motion.notchResize, lyric: text, width: width)
        } else {
            // Only the closed island shows the line; it is laid out when the island closes.
            island.lyric = text
            island.lyricWidth = width
        }
    }

    private func updateIdle(hasTrack: Bool, playing: Bool) {
        guard hasTrack else {
            idleTask?.cancel()
            idleTask = nil
            idle = true
            return
        }
        if playing {
            idleTask?.cancel()
            idleTask = nil
            idle = false
            return
        }
        guard !idle, idleTask == nil else { return }
        let generation = generation
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pauseLinger)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.idleTask = nil
            self.idle = true
            self.update()
        }
    }

    // MARK: Phase

    private var targetPhase: NotchLayout.Phase {
        guard model?.player.current != nil else { return .hidden }
        if expanded { return .expanded }
        return idle ? .hidden : .compact
    }

    /// Moves the island to the phase the player and the pointer call for.
    private func update() {
        let phase = targetPhase
        guard phase != island.phase else { return }
        transition(phase == .expanded ? Motion.notchOpen : Motion.notchClose, phase: phase)
    }

    /// Moves the island to `phase` and the closed line to `lyric` inside `animation`. The panel
    /// grows to take the new island first and is laid out at once, outside the animation (in
    /// it, the island would rise from the old panel's bottom edge instead of dropping from the
    /// top); it shrinks to fit once the island has settled.
    private func transition(_ animation: Animation, phase: NotchLayout.Phase? = nil, lyric: String? = nil, width: CGFloat? = nil) {
        let phase = phase ?? island.phase
        let lyric = lyric ?? island.lyric
        let width = width ?? island.lyricWidth
        let apply = {
            self.island.phase = phase
            self.island.lyric = lyric
            self.island.lyricWidth = width
        }
        guard let panel, let content = panel.contentView else { return apply() }
        let target = NotchLayout(phase: phase, geometry: island.geometry, lyricWidth: lyric.isEmpty ? nil : width).windowFrame(on: island.geometry)
        let grown = panel.frame.union(target)
        if grown != panel.frame {
            panel.setFrame(grown, display: false)
            content.layoutSubtreeIfNeeded()
        }
        updateVisibility(settled: false)
        revision += 1
        let revision = revision
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : animation, completionCriteria: .logicallyComplete) {
            apply()
        } completion: { [weak self] in
            guard let self, self.revision == revision else { return }
            self.settle()
        }
    }

    private func settle() {
        guard let panel else { return }
        let target = island.layout.windowFrame(on: island.geometry)
        if panel.frame != target { panel.setFrame(target, display: true) }
        updateVisibility(settled: true)
    }

    // MARK: Pointer

    private var canExpand: Bool { onScreen && model?.player.current != nil }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        hoverTask?.cancel()
        if inside {
            guard options.expandsOnHover, !expanded, canExpand else { return }
            // A short rest, so a pointer passing over the menu bar does not open it.
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, self.hovering else { return }
                self.setExpanded(true, haptic: true)
            }
        } else {
            guard expanded, !scrubbing, !holdsOpen else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled, !self.hovering, !self.scrubbing, !self.holdsOpen else { return }
                self.setExpanded(false)
            }
        }
    }

    private func tapped() {
        guard !expanded, canExpand else { return }
        hoverTask?.cancel()
        setExpanded(true)
    }

    /// Dragging the progress keeps the island open though the pointer leaves it.
    private func scrubbingChanged(_ active: Bool) {
        scrubbing = active
        if !active, !hovering { hoverChanged(false) }
    }

    private func openNowPlaying() {
        setExpanded(false)
        MainWindow.show()
        model?.player.showNowPlaying = true
    }

    private func setExpanded(_ value: Bool, haptic: Bool = false) {
        guard expanded != value else { return }
        expanded = value
        if value, haptic { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        update()
    }
}

/// A borderless panel above the menu bar that never takes focus: a click on the island does not
/// bring the app forward. It is on every Space but full-screen ones (no `.fullScreenAuxiliary`),
/// so a full-screen video or game keeps the top of the screen.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Panels hide when their app goes to the background by default; this one stays.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click though the app is not active (the island's buttons work at once).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
