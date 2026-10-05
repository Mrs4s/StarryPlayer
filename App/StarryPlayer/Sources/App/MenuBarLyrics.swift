import AppKit
import Library
import LyricsUI
import Observation
import StarryCore
import SwiftUI

@MainActor
final class MenuBarLyricsController: NSObject, NSMenuDelegate {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var lyricsView: MenuBarLyricsView?
    private var lyricsTitle: MenuBarLyricsTitle?
    private var visibility: NSKeyValueObservation?
    private var displayUpdateScheduled = false
    /// Bumped when the item or its display goes away, so older observation loops stop.
    private var generation = 0

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func apply(enabled: Bool, options: AppSettings.MenuBarLyrics) {
        guard enabled else { return remove() }
        if statusItem == nil { install() }
        let animated: Bool? = lyricsView != nil ? true : lyricsTitle != nil ? false : nil
        if animated != options.perSyllable { makeDisplay(animated: options.perSyllable) }
        let width = CGFloat(min(max(options.maxWidth, 120), 800))
        lyricsView?.maxTextWidth = width
        lyricsTitle?.maxTextWidth = width
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "starry.menuBarLyrics"
        item.behavior = .removalAllowed
        item.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        visibility = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            // KVO calls back on the thread that made the change; the status bar makes it on the main one.
            MainActor.assumeIsolated { self?.removedFromMenuBar() }
        }
    }

    private func makeDisplay(animated: Bool) {
        guard let model, let button = statusItem?.button else { return }
        generation += 1
        lyricsView?.removeFromSuperview()
        lyricsView = nil
        lyricsTitle?.stop()
        lyricsTitle = nil
        button.title = ""
        button.alphaValue = 1
        let clock: () -> (time: TimeInterval, rate: Double) = { [weak model] in model?.player.preciseClock() ?? (0, 0) }
        if animated {
            let view = MenuBarLyricsView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            view.timeSource = clock
            view.onPreferredWidthChange = { [weak self] _ in self?.scheduleDisplayUpdate() }
            view.onDisplayedTextChange = { [weak self] _ in self?.scheduleDisplayUpdate() }
            lyricsView = view
            button.addSubview(view)
        } else {
            let title = MenuBarLyricsTitle()
            title.timeSource = clock
            title.onChange = { [weak self] in self?.scheduleDisplayUpdate() }
            lyricsTitle = title
        }
        observeSong()
        observeClock()
    }

    private func remove() {
        guard let statusItem else { return }
        generation += 1
        visibility?.invalidate()
        visibility = nil
        lyricsTitle?.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        lyricsView = nil
        lyricsTitle = nil
    }

    private func removedFromMenuBar() {
        guard statusItem != nil else { return }
        model?.showsMenuBarLyrics = false
    }

    private func scheduleDisplayUpdate() {
        // Text, width and AppKit backing changes can all notify during the same layout.
        // Resizing the status item there reenters its window layout; apply the latest state
        // once that stack has unwound. A removed/replaced display is handled by updateLength.
        guard !displayUpdateScheduled else { return }
        displayUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayUpdateScheduled = false
            self.updateLength()
        }
    }

    private func updateLength() {
        guard let statusItem, let button = statusItem.button else { return }
        let text = lyricsView?.displayedText ?? lyricsTitle?.text ?? ""
        if model?.player.current == nil || text.isEmpty {
            lyricsView?.isHidden = true
            if !button.title.isEmpty { button.title = "" }
            if button.image == nil {
                button.image = AppMark.menuBarGlyph()
            }
            button.imagePosition = .imageOnly
            if statusItem.length != NSStatusItem.squareLength { statusItem.length = NSStatusItem.squareLength }
            button.setAccessibilityTitle("Starry Player")
            return
        }
        if button.image != nil { button.image = nil }
        button.setAccessibilityTitle(text)
        if let lyricsView {
            lyricsView.isHidden = false
            if statusItem.length != lyricsView.preferredWidth { statusItem.length = lyricsView.preferredWidth }
            // The autoresizing mask follows the button; don't set its frame inside AppKit layout.
        } else if let lyricsTitle {
            button.imagePosition = .noImage
            if button.title != lyricsTitle.title { button.title = lyricsTitle.title }
            if statusItem.length != NSStatusItem.variableLength { statusItem.length = NSStatusItem.variableLength }
        }
    }

    /// The song and its lyrics. Only reads the player inside the tracking closure; the display,
    /// which samples the clock, is updated outside it, so the clock is not a dependency here.
    private func observeSong() {
        guard let model, statusItem != nil else { return }
        let generation = generation
        let player = model.player
        let (content, offset) = withObservationTracking {
            let track = player.current
            let content = MenuBarLyricsView.Content(document: player.lyrics, duration: player.duration,
                                                    title: track?.title ?? "", artist: track?.artistText ?? "")
            return (content, -player.lyricOffset)
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.observeSong()
            }
        }
        lyricsView?.timeOffset = offset
        lyricsView?.content = content
        lyricsTitle?.timeOffset = offset
        lyricsTitle?.content = content
        scheduleDisplayUpdate()
    }

    private func observeClock() {
        guard let model, statusItem != nil else { return }
        let generation = generation
        let player = model.player
        let animated = lyricsView != nil
        let playing = withObservationTracking {
            if animated {
                _ = player.currentTime
                _ = player.isSeeking
            } else {
                _ = player.seekSerial
            }
            return player.isPlaying
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.observeClock()
            }
        }
        if let lyricsView {
            lyricsView.sync()
        } else if let lyricsTitle {
            lyricsTitle.sync()
            // As dim as the view goes while paused, at once. (`appearsDisabled` would take it
            // to a quarter, too faint to read.)
            statusItem?.button?.alphaValue = !playing && player.current != nil ? CGFloat(MenuBarLyricsView.pausedOpacity) : 1
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let player = model.player
        let track = player.current

        let header = NSMenuItem()
        let subtitle = track.map { track in [track.artistText, track.album?.name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ") } ?? ""
        let hosting = NSHostingView(rootView: MenuBarNowPlayingHeader(title: track?.title ?? "未在播放", subtitle: subtitle, cover: track == nil ? nil : player.coverImage))
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        header.view = hosting
        menu.addItem(header)
        menu.addItem(.separator())

        let hasTrack = track != nil
        menu.addItem(item(player.isPlaying ? "暂停" : "播放", symbol: player.isPlaying ? "pause.fill" : "play.fill", enabled: hasTrack, action: #selector(togglePlayPause)))
        menu.addItem(item("上一首", symbol: "backward.fill", enabled: hasTrack, action: #selector(previous)))
        menu.addItem(item("下一首", symbol: "forward.fill", enabled: hasTrack, action: #selector(next)))
        if let track, model.canLike(track), model.isLibraryOpen(track.id.source) {
            let liked = player.isLiked(track)
            menu.addItem(item(liked ? "取消喜欢" : "喜欢", symbol: liked ? "heart.fill" : "heart", enabled: true, action: #selector(toggleLike)))
        }
        menu.addItem(.separator())
        menu.addItem(item("打开播放页", symbol: "music.note.list", enabled: hasTrack, action: #selector(openNowPlaying)))
        menu.addItem(item("打开 Starry", symbol: "macwindow", enabled: true, action: #selector(openMainWindow)))
        menu.addItem(.separator())
        menu.addItem(item("菜单栏歌词设置…", symbol: "gearshape", enabled: true, action: #selector(openSettings)))
        menu.addItem(item("隐藏菜单栏歌词", symbol: "eye.slash", enabled: true, action: #selector(hideLyrics)))
        menu.addItem(.separator())
        let quit = item("退出 Starry", symbol: nil, enabled: true, action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, symbol: String?, enabled: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func togglePlayPause() { model?.player.togglePlayPause() }
    @objc private func previous() { model?.player.previous() }
    @objc private func next() { model?.player.next() }

    @objc private func toggleLike() {
        guard let model, let track = model.player.current else { return }
        model.toggleLike(track)
    }

    @objc private func openNowPlaying() {
        showMainWindow()
        model?.player.showNowPlaying = true
    }

    @objc private func openMainWindow() { showMainWindow() }

    @objc private func openSettings() {
        NSApp.activate()
        model?.openSettings(.lyrics)
    }

    @objc private func hideLyrics() { model?.showsMenuBarLyrics = false }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showMainWindow() {
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

private struct MenuBarNowPlayingHeader: View {
    let title: String
    let subtitle: String
    let cover: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 280, height: 56, alignment: .leading)
    }
}
