import Library
import LyricsCore
import LyricsProviders
import LyricsUI
import StarryCore
import SwiftUI

/// Compute Now Playing geometry from window size so the cover and lyric anchor
/// stay fixed during animations and metadata changes.
struct NowPlayingLayout {
    let size: CGSize
    let topBar: CGFloat = 52
    let bottomBar: CGFloat
    let scale: CGFloat
    let columnWidth: CGFloat
    let side: CGFloat
    let gap: CGFloat
    let infoHeight: CGFloat
    let groupTop: CGFloat

    init(size: CGSize) {
        self.size = size
        let k = min(max(min(size.height / 820, size.width / 1320), 0.82), 1.45)
        scale = k
        bottomBar = (92 * k).rounded()
        columnWidth = min(max(size.width * 0.42, 380), 860)
        gap = 24 * k
        infoHeight = NowPlayingInfoBlock.height * k
        let between = size.height - topBar - bottomBar
        let byWidth = columnWidth - 104 * k
        let byHeight = between - 32 * k - gap - infoHeight
        side = max(min(byWidth, byHeight).rounded(), 160)
        let free = between - (side + gap + infoHeight)
        groupTop = (topBar + max(8 * k, free * 0.45)).rounded()
    }

    var artworkFrame: CGRect {
        CGRect(x: ((columnWidth - side) / 2).rounded(), y: groupTop, width: side, height: side)
    }

    var artworkRadius: CGFloat { max(10, side * 0.032) }

    var panelGutter: CGFloat { 24 * scale }

    var panelContentWidth: CGFloat { min(size.width - columnWidth - 56 * scale, 720 * scale) }

    var transportWidth: CGFloat { min(max(size.width * 0.33, 340), 540) }

    static let equalizerButtonSize = CGSize(width: 30, height: 26)
    static let volumeWidth: CGFloat = 150
    static let equalizerSpacing: CGFloat = 14
    static let barInset: CGFloat = 28

    /// Where the equalizer button sits, for its dialog to grow out of (computed like everything
    /// else here: the bar rises into place as the page opens, so a measurement would move).
    var equalizerButtonFrame: CGRect {
        let k = scale
        let size = CGSize(width: Self.equalizerButtonSize.width * k, height: Self.equalizerButtonSize.height * k)
        let maxX = self.size.width - (Self.barInset + Self.volumeWidth + Self.equalizerSpacing) * k
        let midY = self.size.height - bottomBar + (bottomBar - 8 * k) / 2
        return CGRect(x: maxX - size.width, y: midY - size.height / 2, width: size.width, height: size.height)
    }

}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroIn = false
    @State private var backdropIn = false
    @State private var contentIn = false
    @State private var chromeVisible = true
    @State private var controlsLive = true
    @State private var idleTask: Task<Void, Never>?
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    @State private var isFullscreen = false
    static var forcesFullscreenLayout = false
    @State private var showLyricsSettings = false
    @State private var showAudioInfo = false
    @State private var showLyricsSource = false
    @State private var lyricsSourceSearches = false
    @State private var lyricsDropTargeted = false
    @State private var showVocals = false
    @State private var showEqualizer = false
    @State private var equalizerMounted = false
    @State private var editingLyricOffset = false
    /// The bar's cover in page coordinates when the page last opened or started closing.
    @State private var heroSource: CGRect?

    private var player: PlayerController { model.player }
    private var tint: Color { (player.accentColor ?? Color(hex: "#FE7971")).lightTint }

    var body: some View {
        GeometryReader { geo in
            let layout = NowPlayingLayout(size: geo.size)
            ZStack(alignment: .topLeading) {
                PlayerBackground(track: player.current, image: player.coverImage, accent: player.accentColor, settings: model.settings.settings.background, fullscreen: isFullscreen, behindLyrics: model.nowPlayingPanel == .lyrics && !(player.lyrics?.isEmpty ?? true), energyProvider: { [player] in player.energies() })
                    .opacity(backdropIn ? 1 : 0)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        leftColumn(layout)
                            .frame(width: layout.columnWidth, alignment: .topLeading)
                            .zIndex(1)
                        panel(layout)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, layout.topBar)
                            .opacity(contentIn ? 1 : 0)
                    }
                    .frame(height: geo.size.height - layout.bottomBar)
                    bottomBar(layout)
                }
                topBar(layout)
                if equalizerMounted {
                    EqualizerDialog(isPresented: showEqualizer, anchor: layout.equalizerButtonFrame, area: CGRect(x: 0, y: layout.topBar, width: geo.size.width, height: geo.size.height - layout.topBar - layout.bottomBar), tint: tint) {
                        showEqualizer = false
                    } onDismissed: {
                        if !showEqualizer { equalizerMounted = false }
                    }
                }
            }
            .onContinuousHover { phase in
                if case .active = phase { wake() }
            }
            .onAppear {
                isFullscreen = Self.forcesFullscreenLayout || (NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false)
                // Opened and closed again before the page first showed (⌘L twice at once): there
                // is nothing to animate, and no later change would close it.
                guard player.showNowPlaying else {
                    player.nowPlayingMounted = false
                    return
                }
                present(true)
                wake()
            }
            .onChange(of: player.showNowPlaying) { _, shown in present(shown) }
            .onDisappear {
                idleTask?.cancel()
                // A drag on the scrubber cut short by the page going away never ends on its own.
                if scrubbing { player.isSeeking = false }
            }
            .onChange(of: showLyricsSettings) { _, open in
                if !open { wake() }
            }
            .onChange(of: showLyricsSource) { _, open in
                if !open {
                    lyricsSourceSearches = false
                    wake()
                }
            }
            .onChange(of: showAudioInfo) { _, open in
                if !open { wake() }
            }
            .onChange(of: showVocals) { _, open in
                if !open { wake() }
            }
            .onChange(of: showEqualizer) { _, open in
                if !open { wake() }
            }
            .onChange(of: editingLyricOffset) { _, editing in
                if !editing { wake() }
            }
            .onChange(of: model.nowPlayingPanel) { _, _ in wake() }
            .onChange(of: player.vocalAttenuationEnabled) { _, on in
                if on { wake() }
                showVocals = on
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullscreen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullscreen = false }
            .task(id: player.current?.id) { await prefetchComments() }
        }
        .environment(\.theme, nowPlayingTheme)
        .onExitCommand {
            if showEqualizer {
                showEqualizer = false
            } else {
                player.showNowPlaying = false
            }
        }
    }

    private var nowPlayingTheme: Theme {
        var t = Theme.darkBase
        t.primary = tint
        t.onSurface = tint
        t.onSurfaceVariant = tint.opacity(0.7)
        t.surfacePanel = .black.opacity(0.55)
        t.surfaceAlt = .black.opacity(0.55)
        return t
    }

    private func present(_ shown: Bool) {
        heroSource = model.playerBarCoverFrame
        if shown {
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.56, dampingFraction: 0.84)) { heroIn = true }
            withAnimation(.easeOut(duration: 0.42)) { backdropIn = true }
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.5, dampingFraction: 0.9).delay(0.1)) { contentIn = true }
        } else {
            showEqualizer = false
            withAnimation(.easeIn(duration: 0.16)) { contentIn = false }
            withAnimation(.easeInOut(duration: 0.38).delay(0.05)) { backdropIn = false }
            withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .spring(response: 0.44, dampingFraction: 0.92)) {
                heroIn = false
            } completion: {
                if !player.showNowPlaying { player.nowPlayingMounted = false }
            }
        }
    }

    private var idleHides: Bool { model.nowPlayingPanel == .lyrics }

    private func wake() {
        controlsLive = true
        if !chromeVisible { withAnimation(.easeOut(duration: 0.3)) { chromeVisible = true } }
        idleTask?.cancel()
        guard idleHides else { return }
        idleTask = Task {
            try? await Task.sleep(for: .seconds(3))
            // The settings popover is its own window, so hovering it sends no events here; hiding
            // the chrome would remove its anchor button and close it.
            guard !Task.isCancelled, idleHides, !scrubbing, !showLyricsSettings, !showLyricsSource, !showAudioInfo, !showVocals, !editingLyricOffset, !showEqualizer, player.showNowPlaying else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                chromeVisible = false
            } completion: {
                if !chromeVisible { controlsLive = false }
            }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func topBar(_ layout: NowPlayingLayout) -> some View {
        let k = layout.scale
        return HStack(spacing: 8) {
            Button { player.showNowPlaying = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 28))
            .help("收起播放页（Esc）")
            Spacer()
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 28))
            .help(isFullscreen ? "退出全屏" : "全屏")
        }
        // After the traffic lights (they end at x 69 on macOS 26); in full screen they are gone.
        .padding(.leading, isFullscreen ? 20 : 84)
        .padding(.trailing, 20 * k)
        .frame(height: layout.topBar)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            NowPlayingPanelSwitch(selection: model.nowPlayingPanel, panels: panels, commentCount: commentCount, tint: tint, k: k, select: select)
                .fixedSize()
                .frame(width: layout.panelContentWidth)
                .offset(x: layout.columnWidth)
        }
        .opacity(contentIn && chromeVisible ? 1 : 0)
        .background {
            Color.clear.contentShape(Rectangle()).modifier(WindowDrag())
        }
    }

    private func leftColumn(_ layout: NowPlayingLayout) -> some View {
        let k = layout.scale
        return VStack(spacing: 0) {
            Color.clear.frame(height: layout.groupTop)
            artwork(layout)
            Color.clear.frame(height: layout.gap)
            if let track = player.current {
                NowPlayingInfoBlock(track: track, tint: tint, k: k, showAudioInfo: $showAudioInfo, showLyricsSource: $showLyricsSource, lyricsSourceSearches: lyricsSourceSearches)
                    .frame(width: layout.side, height: layout.infoHeight, alignment: .topLeading)
                    .opacity(contentIn ? 1 : 0)
                    .offset(y: contentIn || reduceMotion ? 0 : 20 * k)
            }
            Spacer(minLength: 0)
        }
        .frame(width: layout.columnWidth)
    }

    private func bottomBar(_ layout: NowPlayingLayout) -> some View {
        let k = layout.scale
        return HStack(spacing: 16 * k) {
            HStack(spacing: 8 * k) {
                if let track = player.current {
                    if model.canLike(track) {
                        NowPlayingLikeButton(track: track, tint: tint, k: k)
                    }
                    NowPlayingMoreMenu(track: track, tint: tint, k: k) {
                        model.openSettings(.nowPlaying)
                    } onSearchLyrics: {
                        searchLyricsByHand()
                    } onEqualizer: {
                        openEqualizer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2 * k) {
                NowPlayingTransport(tint: tint, k: k)
                    .frame(height: 46 * k)
                HStack(spacing: 10 * k) {
                    NowPlayingClock(kind: .elapsed, scrubbing: scrubbing, scrubValue: scrubValue, tint: tint, k: k, live: controlsLive)
                        .frame(width: 42 * k, alignment: .trailing)
                    NowPlayingScrubber(scrubbing: $scrubbing, scrubValue: $scrubValue, tint: tint, k: k, live: controlsLive)
                    NowPlayingClock(kind: .remaining, scrubbing: scrubbing, scrubValue: scrubValue, tint: tint, k: k, live: controlsLive)
                        .frame(width: 42 * k, alignment: .leading)
                }
                .frame(height: 22 * k)
            }
            .frame(width: layout.transportWidth)
            HStack(spacing: NowPlayingLayout.equalizerSpacing * k) {
                NowPlayingEqualizerButton(tint: tint, k: k, isOpen: showEqualizer) {
                    if showEqualizer { showEqualizer = false } else { openEqualizer() }
                }
                NowPlayingVolume(tint: tint, k: k)
                    .frame(width: NowPlayingLayout.volumeWidth * k)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, NowPlayingLayout.barInset * k)
        .padding(.bottom, 8 * k)
        .frame(height: layout.bottomBar)
        .opacity(contentIn && chromeVisible ? 1 : 0)
        .offset(y: contentIn || reduceMotion ? 0 : 24 * k)
    }

    /// The cover, flying between the bar's cover and its place. Its frame is the layout's; the
    /// flight is a scale and an offset drawn on top of it, and the corner radius follows the
    /// scale so the cover lands with the bar's corners.
    private func artwork(_ layout: NowPlayingLayout) -> some View {
        let target = layout.artworkFrame
        let source = heroSource.flatMap { $0.width > 1 ? $0 : nil }
        let barRadius: CGFloat = model.playerBarUsesGlass ? 12 : 8
        let barScale = source.map { $0.width * (player.isPlaying ? 1 : 0.88) / target.width } ?? 0.86
        let away = CGSize(width: source.map { $0.midX - target.midX } ?? 0, height: source.map { $0.midY - target.midY } ?? 60)
        let flying = !heroIn && !reduceMotion
        let scale = flying ? barScale : (player.isPlaying || reduceMotion ? 1 : 0.9)
        let radius = flying ? barRadius / barScale : layout.artworkRadius
        return ArtworkView(artwork: player.current?.artwork, radius: 0, pixelSize: 800, fallback: player.coverImage)
            .frame(width: layout.side, height: layout.side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(heroIn ? (player.isPlaying ? 0.42 : 0.28) : 0), radius: 34 * layout.scale, y: 16 * layout.scale)
            .scaleEffect(scale)
            .offset(flying ? away : .zero)
            .opacity(heroIn || source != nil ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.68), value: player.isPlaying)
    }

    private var panels: [NowPlayingPanel] {
        player.current.flatMap { model.commentSource($0.id.source) } == nil ? [.lyrics, .queue] : NowPlayingPanel.allCases
    }

    private var commentCount: Int? {
        player.current.flatMap { model.commentThread(for: $0) }?.total
    }

    private func select(_ panel: NowPlayingPanel) {
        model.selectNowPlayingPanel(panel)
    }

    @ViewBuilder
    private func panel(_ layout: NowPlayingLayout) -> some View {
        let k = layout.scale
        let insertion = AnyTransition.opacity.combined(with: .offset(x: 36 * k * CGFloat(model.nowPlayingPanelDirection)))
        // The old panel leaves quickly, so the two do not read over each other.
        let transition = AnyTransition.asymmetric(insertion: insertion, removal: .opacity.combined(with: .scale(scale: 0.97)).animation(.easeOut(duration: 0.18)))
        ZStack {
            switch model.nowPlayingPanel {
            case .lyrics:
                lyricsPanel(layout).transition(transition)
            case .comments:
                if let track = player.current, let thread = model.commentThread(for: track) {
                    // A new song brings its own thread (scrolled to the top), crossfading in.
                    CommentsPanel(thread: thread, tint: tint, k: k, leading: layout.panelGutter) { select(.lyrics) }
                        .id(track.id)
                        .padding(.top, 10 * k)
                        .frame(width: layout.panelContentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(transition)
                } else {
                    lyricsPanel(layout).transition(transition)
                }
            case .queue:
                QueuePanel(tint: tint, k: k, leading: layout.panelGutter)
                    .padding(.top, 10 * k)
                    .frame(width: layout.panelContentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(transition)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: player.current?.id)
    }

    /// Fetches the song's first page of comments while the page is open, so the comments tab shows
    /// its count and opens filled. Waits a moment first: skipping through songs fetches nothing.
    private func prefetchComments() async {
        guard let track = player.current, let source = model.commentSource(track.id.source), let thread = model.commentThread(for: track) else { return }
        try? await Task.sleep(for: .seconds(model.nowPlayingPanel == .comments ? 0 : 0.8))
        guard !Task.isCancelled else { return }
        await thread.loadIfNeeded(thread.sort, from: source)
    }

    private func lyricsPanel(_ layout: NowPlayingLayout) -> some View {
        let height = layout.size.height - layout.topBar - layout.bottomBar
        // The current line is centred on the cover. The centre comes from the layout, not from a
        // measurement (see `NowPlayingLayout`).
        let artworkRect = CGRect(x: 0, y: (layout.artworkFrame.midY - layout.topBar).rounded(), width: 0, height: 0)
        var specs = LyricsSpecs.make(from: model.settings.settings.lyrics, fullscreen: isFullscreen, viewHeight: height, artworkRect: artworkRect)
        // The gutter lives inside the lyrics view (it clips to its bounds), so the hover
        // highlight and glow around a line have room.
        specs.horizontalInset = layout.panelGutter
        return ZStack(alignment: .trailing) {
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                LyricsHost(document: lyrics, specs: specs, rate: player.rate, color: tint, timeOffset: -player.lyricOffset, scrubTime: scrubbing ? scrubValue : nil, alignment: model.settings.settings.lyrics.alignment == .center ? .center : .left, clock: { [player] in player.preciseClock() }) { time in
                    player.seek(to: time)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .padding(.trailing, 72 * layout.scale)
            } else {
                noLyrics
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -layout.topBar / 2)
            }
            lyricsTools(layout)
                .padding(.trailing, 18 * layout.scale)
                .opacity(contentIn && chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let track = player.current, let url = urls.first(where: { LyricsFile.extensions.contains($0.pathExtension.lowercased()) }) else { return false }
            return model.loadLyricsFile(at: url, for: track)
        } isTargeted: { lyricsDropTargeted = $0 }
        .overlay {
            if lyricsDropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(tint.opacity(0.06))
                    .strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay {
                        Label("松开以载入歌词文件", systemImage: "doc.text")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tint.opacity(0.9))
                    }
                    .padding(.leading, layout.panelGutter)
                    .padding(.trailing, 72 * layout.scale)
                    .padding(.vertical, 24)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Motion.hover, value: lyricsDropTargeted)
    }

    private var noLyrics: some View {
        VStack(spacing: 10) {
            Image(systemName: "quote.bubble").font(.system(size: 30, weight: .light))
            Text(player.lyricsLoading ? "正在查找歌词…" : "暂无歌词").font(.system(size: 18, weight: .semibold))
            if !player.lyricsLoading, let track = player.current {
                HStack(spacing: 8) {
                    noLyricsAction("搜索歌词", systemImage: "magnifyingglass") { searchLyricsByHand() }
                    noLyricsAction("打开歌词文件…", systemImage: "doc.text") { model.openLyricsFile(for: track) }
                }
                .padding(.top, 8)
                Text("也可以把歌词文件拖到这里")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(tint.opacity(0.4))
    }

    private func noLyricsAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(tint.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(NowPlayingPressStyle())
    }

    private func openEqualizer() {
        showEqualizer = true
        equalizerMounted = true
        wake()
    }

    private func searchLyricsByHand() {
        lyricsSourceSearches = true
        showLyricsSource = true
    }

    private func lyricsTools(_ layout: NowPlayingLayout) -> some View {
        VStack(spacing: 4) {
            VocalControl(isExpanded: $showVocals, size: 32, tint: tint)
            Capsule().fill(tint.opacity(0.14)).frame(width: 16, height: 1).padding(.vertical, 3)
            IconButton(systemName: "plus", size: 30, iconSize: 12, tint: tint, help: "歌词延后 0.1 s") { player.setLyricOffset(player.lyricOffset + 0.1) }
            LyricOffsetField(isEditing: $editingLyricOffset, tint: tint)
            IconButton(systemName: "minus", size: 30, iconSize: 12, tint: tint, help: "歌词提前 0.1 s") { player.setLyricOffset(player.lyricOffset - 0.1) }
            LyricCalibrationButton(size: 30, tint: tint)
            Capsule().fill(tint.opacity(0.14)).frame(width: 16, height: 1).padding(.vertical, 3)
            IconButton(systemName: "gearshape", size: 30, iconSize: 13, tint: tint, isActive: showLyricsSettings, help: "歌词与背景设置") { showLyricsSettings.toggle() }
                .popover(isPresented: $showLyricsSettings, arrowEdge: .leading) {
                    LyricsSettingsPanel {
                        showLyricsSettings = false
                        model.openSettings(.nowPlaying)
                    }
                    .environment(model)
                    .environment(\.theme, Theme.darkBase)
                }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Capsule().fill(tint.opacity(0.07)))
    }
}

/// The lyric offset between + and −. Clicked, it turns into a field for seconds (or `ms`):
/// Return or a click elsewhere applies it, Esc leaves it as it was.
struct LyricOffsetField: View {
    @Binding var isEditing: Bool
    var tint: Color
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var hovering = false
    @State private var clickMonitor: Any?

    var body: some View {
        let player = model.player
        let offset = player.lyricOffset
        ZStack {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(tint)
                    .textContentType(.lyricOffset)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .padding(.horizontal, 2)
                    .frame(width: 32, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
            } else {
                Button(action: begin) {
                    Text(LyricOffsetText.label(offset))
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint.opacity(offset == 0 ? 0.45 : 0.9))
                        .contentTransition(.numericText(value: offset))
                        .animation(Motion.hover, value: offset)
                        .fixedSize()
                        .padding(.horizontal, 3)
                        .frame(minWidth: 32, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(hovering ? 0.1 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点按输入歌词偏移（秒）")
                .accessibilityLabel("歌词偏移 \(LyricOffsetText.label(offset))")
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .onChange(of: offset) { _, value in
            if isEditing { draft = LyricOffsetText.draft(value) }
        }
        .onChange(of: player.current?.id) { _, _ in isEditing = false }
        .onChange(of: isEditing) { _, editing in watchClicks(editing) }
        .onDisappear {
            watchClicks(false)
            isEditing = false
        }
    }

    private func begin() {
        draft = LyricOffsetText.draft(model.player.lyricOffset)
        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        if let seconds = LyricOffsetText.seconds(from: draft) { model.player.setLyricOffset(seconds) }
    }

    private func watchClicks(_ on: Bool) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard on else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if !hovering { commit() }
            return event
        }
    }
}

enum LyricOffsetText {
    static func label(_ offset: TimeInterval) -> String {
        String(format: hasTenths(offset) ? "%+.1fs" : "%+.2fs", offset)
    }

    static func draft(_ offset: TimeInterval) -> String {
        offset == 0 ? "0" : String(format: hasTenths(offset) ? "%.1f" : "%.2f", offset)
    }

    /// Seconds from what was typed: a signed number, optionally followed by `s` / `秒`, or `ms` /
    /// `毫秒` for milliseconds. Full-width characters from a Chinese input method count as well.
    static func seconds(from text: String) -> TimeInterval? {
        // `。` first: the transform turns it into a half-width `｡`, not a full stop.
        let text = text.replacingOccurrences(of: "。", with: ".")
        var number = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        var scale = 1.0
        for (unit, unitScale) in [("ms", 0.001), ("毫秒", 0.001), ("s", 1), ("秒", 1)] where number.hasSuffix(unit) {
            number.removeLast(unit.count)
            scale = unitScale
            break
        }
        guard let value = Double(number), value.isFinite else { return nil }
        return value * scale
    }

    private static func hasTenths(_ offset: TimeInterval) -> Bool {
        abs(offset * 10 - (offset * 10).rounded()) < 0.05
    }
}

struct LyricCalibrationButton: View {
    var size: CGFloat = 32
    var tint: Color
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let running = player.lyricCalibration.isRunning
        let available = player.lyrics.map { !$0.isEmpty } ?? false
        Button { player.calibrateLyrics() } label: {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .symbolEffect(.pulse, isActive: running)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isCircle: true, isActive: running))
        .disabled(!available && !running)
        .opacity(available || running ? 1 : 0.4)
        .help(running ? "正在分析人声以校准歌词，点按停止" : "自动校准：分析人声，把歌词对准演唱")
        .accessibilityLabel("校准歌词时间")
    }
}
