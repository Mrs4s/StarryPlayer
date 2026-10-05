import Backdrop
import MusicSources
import StarryCore
import SwiftUI

struct HomePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var state: Loadable<HomeContent>
    @State private var appeared = false
    @State private var backdrop: PageBackdrop
    @State private var loadedKey: AppModel.HomeKey?

    init(cached: HomeContent? = nil) {
        _state = State(initialValue: cached.map { .loaded($0) } ?? .idle)
        // A revisit starts with its wash in place: setting it later, from the tile, would flush
        // the whole graph once more while the page comes in.
        let backdrop = PageBackdrop()
        if let cached, let colors = TilePalette.cached(.artwork(HomeSections.firstTileTracks(cached).first?.artwork)) {
            backdrop.tint = colors[0]
        }
        _backdrop = State(initialValue: backdrop)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 26)
                // Its own container, so the skeleton → content swap stays inside it.
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
            }
            .padding(.bottom, 40)
            .frame(maxWidth: Metrics.pageMaxWidth)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: Double.self) { geo in
                let offset = -geo.frame(in: .scrollView).minY
                return (Double(min(max(offset / 360, 0), 1)) * 60).rounded() / 60
            } action: { fade in
                if backdrop.fade != fade { backdrop.fade = fade }
            }
        }
        .preference(key: PageBackdropKey.self, value: backdrop)
        .task(id: model.homeKey) { await load() }
        .onAppear { appeared = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.dateLine(Date()))
                .font(.system(size: 12.5, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(theme.onSurfaceVariant)
                .reveal(appeared, distance: 6)
            Text(model.profile.map { "\(greeting)，\($0.nickname)" } ?? greeting)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .padding(.top, 4)
                .reveal(appeared, delay: 0.05, distance: 8)
            subline
                .font(.system(size: 14))
                .padding(.top, 6)
                .reveal(appeared, delay: 0.1, distance: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .visualEffect { content, geo in
            let scrolled = max(-geo.frame(in: .scrollView).minY, 0)
            let t = min(scrolled / max(geo.size.height, 1), 1)
            return content
                .opacity(1 - t * 0.9)
                .offset(y: scrolled * 0.3)
        }
    }

    @ViewBuilder
    private var subline: some View {
        if model.isLoggedIn {
            let count = state.value?.daily.count ?? 0
            Text(count > 0 ? "今天为你准备了 \(count) 首歌" : "由此开启好心情 ~")
                .foregroundStyle(theme.onSurfaceVariant)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.3), value: count)
        } else if model.canLogIn(model.browsingSourceID) {
            HStack(spacing: 0) {
                TextLink(text: "登录", color: theme.accent, hoverColor: theme.accent) { model.requestLogin() }
                Text("\(model.currentSourceName)，\(model.loginBenefits(of: model.browsingSourceID))").foregroundStyle(theme.onSurfaceVariant)
            }
        } else {
            Text("由此开启好心情 ~").foregroundStyle(theme.onSurfaceVariant)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<9: "早上好"
        case 9..<12: "上午好"
        case 12..<14: "中午好"
        case 14..<18: "下午好"
        case 18..<23: "晚上好"
        default: "夜深了"
        }
    }

    static func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }

    static func artistLine(_ tracks: [Track]) -> String {
        var names: [String] = []
        for track in tracks {
            guard let name = track.artists.first?.name, !names.contains(name) else { continue }
            names.append(name)
            if names.count == 4 { break }
        }
        let line = names.prefix(3).joined(separator: "、")
        return names.count > 3 ? "\(line) 等" : line
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            // Leaves at once: fading out, it would stack above the incoming sections for a moment.
            HomeSkeleton()
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)), removal: .identity))
        case .failed(let message):
            VStack(spacing: 14) {
                StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message).frame(minHeight: 0)
                PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let content):
            HomeSections(content: content, backdrop: backdrop)
        }
    }

    /// Not animated: the page's height changes with it; the sections bring their own entrance.
    /// Recent content (another visit to Home a moment ago) is used as is. Another source or
    /// account starts from the skeleton.
    private func load() async {
        if let cached = model.cachedHome() {
            if state.value != cached { state = .loaded(cached) }
            return
        }
        if state.value == nil || loadedKey != model.homeKey { state = .loading }
        let key = model.homeKey
        let result = await Loadable.run { try await model.loadHome() }
        guard !Task.isCancelled else { return }
        loadedKey = key
        state = result
    }
}

private struct HomeSections: View {
    var content: HomeContent
    var backdrop: PageBackdrop
    @Environment(AppModel.self) private var model
    @State private var shown = false

    private var player: PlayerController { model.player }

    var body: some View {
        let history = Array(model.library.history.prefix(12))
        VStack(alignment: .leading, spacing: 34) {
            if model.browsingSourceID == .local, content.shelves.isEmpty {
                LocalLibraryWelcome()
                    .padding(.horizontal, Metrics.pagePadding)
                    .homeSection(shown, index: 0)
            }
            picks
            if !history.isEmpty {
                TrackShelf(title: "继续收听", tracks: history, rows: 2, context: PlaybackContext(source: nil, originType: .history, originName: "最近播放")) {
                    model.navigate(.history)
                }
                .homeSection(shown, index: 1)
            }
            if !content.recommended.isEmpty {
                Shelf(title: "推荐歌单", items: content.recommended) { playlist in
                    Color.clear.playlistCard(playlist, model: model)
                }
                .homeSection(shown, index: 2)
            }
            if !content.newSongs.isEmpty {
                TrackShelf(title: "新歌速递", tracks: Array(content.newSongs.prefix(18)), rows: 3)
                    .homeSection(shown, index: 3)
            }
            if !content.dailyPlaylists.isEmpty {
                Shelf(title: "每日歌单", items: content.dailyPlaylists) { playlist in
                    Color.clear.playlistCard(playlist, model: model)
                }
                .homeSection(shown, index: 4)
            }
            if !content.topArtists.isEmpty {
                Shelf(title: "热门歌手", items: content.topArtists, minCardWidth: 128, spacing: 22) { artist in
                    CoverCard(title: artist.name, artwork: artist.artwork, circle: true) {
                        model.navigate(.artist(artist))
                    }
                }
                .homeSection(shown, index: 5)
            }
            if !content.newAlbums.isEmpty {
                Shelf(title: "新碟上架", items: content.newAlbums) { album in
                    CoverCard(title: album.name, subtitle: album.artists.map(\.name).joined(separator: " / "), artwork: album.artwork) {
                        model.navigate(.album(album))
                    }
                }
                .homeSection(shown, index: 6)
            }
            ForEach(Array(content.shelves.enumerated()), id: \.element.id) { position, shelf in
                sourceShelf(shelf)
                    .homeSection(shown, index: 7 + position)
            }
        }
        .onAppear { if !shown { shown = true } }
    }

    @ViewBuilder
    private func sourceShelf(_ shelf: HomeShelf) -> some View {
        switch shelf.items {
        case .songs(let tracks):
            TrackShelf(title: shelf.title, tracks: Array(tracks.prefix(18)), rows: 3)
        case .albums(let albums):
            Shelf(title: shelf.title, items: albums) { album in
                CoverCard(title: album.name, subtitle: album.artists.map(\.name).joined(separator: " / "), artwork: album.artwork) {
                    model.navigate(.album(album))
                }
            }
        case .artists(let artists):
            Shelf(title: shelf.title, items: artists, minCardWidth: 128, spacing: 22) { artist in
                CoverCard(title: artist.name, artwork: artist.artwork, circle: true) {
                    model.navigate(.artist(artist))
                }
            }
        case .playlists(let playlists):
            Shelf(title: shelf.title, items: playlists) { playlist in
                Color.clear.playlistCard(playlist, model: model)
            }
        }
    }

    /// The first tile only with songs on it (a server signed out to has none), the row only with
    /// a tile.
    @ViewBuilder
    private var picks: some View {
        let hasFirst = !Self.firstTileTracks(content).isEmpty
        if hasFirst || model.hasPersonalFM || featured != nil {
            HStack(spacing: 16) {
                if hasFirst {
                    firstTile
                        .reveal(shown, delay: 0.06, distance: 14, scale: 0.97)
                }
                if model.hasPersonalFM {
                    fmTile
                        .reveal(shown, delay: 0.12, distance: 14, scale: 0.97)
                }
                if let featured {
                    featuredTile(featured)
                        .reveal(shown, delay: 0.18, distance: 14, scale: 0.97)
                }
            }
            .frame(height: PickTile<EmptyView>.height)
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    /// Daily recommendations when there is a daily list, otherwise new releases, otherwise the
    /// source's first shelf of songs (its title as the eyebrow).
    static func firstTileTracks(_ content: HomeContent) -> [Track] {
        if !content.daily.isEmpty { return content.daily }
        if !content.newSongs.isEmpty { return content.newSongs }
        return firstSongShelf(content)?.tracks ?? []
    }

    static func firstSongShelf(_ content: HomeContent) -> (title: String, tracks: [Track])? {
        for shelf in content.shelves {
            if case .songs(let tracks) = shelf.items { return (shelf.title, tracks) }
        }
        return nil
    }

    @ViewBuilder
    private var firstTile: some View {
        let daily = !content.daily.isEmpty
        let tracks = Self.firstTileTracks(content)
        let shelf = daily || !content.newSongs.isEmpty ? nil : Self.firstSongShelf(content)
        PickTile(
            eyebrow: daily ? "每日推荐" : shelf?.title ?? "新歌速递",
            title: HomePage.artistLine(tracks),
            detail: daily ? "\(tracks.count) 首 · 根据你的口味" : shelf != nil ? "\(tracks.count) 首" : "今日上新 · \(tracks.count) 首",
            tint: .artwork(tracks.first?.artwork),
            playing: daily ? player.playState(from: .dailyRecommendation, of: model.browsingSourceID) : nil,
            onTint: { if backdrop.tint != $0 { backdrop.tint = $0 } },
            onOpen: { daily ? model.navigate(.daily) : play(tracks, context: nil) },
            onPlay: { daily ? playDaily() : play(tracks, context: nil) }
        ) { hovering in
            CoverFan(artworks: tracks.prefix(3).map(\.artwork), size: 92, spread: hovering)
                .offset(x: 18, y: 2)
        }
    }

    @ViewBuilder
    private var fmTile: some View {
        let state = player.playState(from: .radio, of: model.browsingSourceID)
        let signedIn = model.isLoggedIn
        PickTile(
            eyebrow: "私人 FM",
            title: state != nil ? (player.current?.title ?? "私人 FM") : (signedIn ? "为你无限推荐" : "登录后收听"),
            detail: state != nil ? (player.current?.artistText ?? "") : (signedIn ? "根据你的口味 · 不喜欢就换一首" : "私人 FM 会根据你的口味推荐"),
            tint: .hue(Self.fmHue),
            playing: state,
            onOpen: {
                if state != nil {
                    player.showNowPlaying = true
                } else if signedIn {
                    model.playPersonalFM()
                } else {
                    model.requestLogin()
                }
            },
            onPlay: {
                if state != nil {
                    player.togglePlayPause()
                } else if signedIn {
                    model.playPersonalFM()
                } else {
                    model.requestLogin()
                }
            }
        ) { hovering in
            VinylDisc(artwork: state != nil ? player.current?.artwork : nil, spinning: state == true)
                .frame(width: 136, height: 136)
                .rotationEffect(.degrees(hovering ? 28 : 0))
                .offset(x: hovering ? 24 : 34, y: -22)
        }
    }

    private var featured: Playlist? { content.dailyPlaylists.first ?? content.recommended.first ?? firstPlaylistShelf?.playlists.first }

    private var firstPlaylistShelf: (title: String, playlists: [Playlist])? {
        for shelf in content.shelves {
            if case .playlists(let playlists) = shelf.items { return (shelf.title, playlists) }
        }
        return nil
    }

    private func featuredTile(_ playlist: Playlist) -> some View {
        let state = player.playState(from: .playlist, of: playlist.source, id: playlist.id)
        return PickTile(
            eyebrow: content.dailyPlaylists.first != nil ? "为你定制" : content.recommended.first != nil ? "推荐歌单" : firstPlaylistShelf?.title ?? "推荐歌单",
            title: playlist.name,
            detail: [playlist.trackCount > 0 ? "\(playlist.trackCount) 首" : nil, playlist.creatorName].compactMap { $0 }.joined(separator: " · "),
            tint: .artwork(playlist.artwork),
            playing: state,
            onOpen: { model.navigate(.collection(playlist)) },
            onPlay: { state != nil ? player.togglePlayPause() : playPlaylist(playlist) }
        ) { hovering in
            TiltedCover(artwork: playlist.artwork, size: 112, straight: hovering)
                .offset(x: 6, y: 4)
        }
    }

    private static let fmHue = 0.74

    private func play(_ tracks: [Track], context: PlaybackContext?) {
        guard !tracks.isEmpty else { return }
        player.play(tracks, context: context)
    }

    private func playDaily() {
        if player.playState(from: .dailyRecommendation, of: model.browsingSourceID) != nil {
            player.togglePlayPause()
        } else {
            play(content.daily, context: PlaybackContext(source: model.browsingSourceID, originType: .dailyRecommendation, originName: "每日推荐"))
        }
    }

    private func playPlaylist(_ playlist: Playlist) {
        Task {
            do {
                let detail = try await model.catalog(playlist.source).playlist(id: playlist.id)
                player.play(detail.tracks, context: PlaybackContext(source: playlist.source, originType: .playlist, originID: playlist.id, originName: playlist.name))
            } catch {
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}

private extension View {
    /// A home shelf's entrance: rises in after the tiles on first load; one that starts below
    /// the fold rises in when it scrolls into view instead.
    func homeSection(_ shown: Bool, index: Int) -> some View {
        modifier(HomeSectionEntrance(shown: shown, index: index))
    }
}

private struct HomeSectionEntrance: ViewModifier {
    var shown: Bool
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .reveal(shown, delay: 0.16 + Double(index) * 0.05, distance: 14)
            .scrollTransition(.animated(Motion.reveal).threshold(.visible(0.2)), axis: .vertical) { view, phase in
                let below = phase == .bottomTrailing
                return view
                    .opacity(below ? 0 : 1)
                    .offset(y: below && !reduceMotion ? 36 : 0)
            }
    }
}

private enum TileTint: Equatable {
    case artwork(Artwork?)
    case hue(Double)
}

/// A colour tile for the top of Home: a deep two-tone gradient from its cover (so white text
/// always reads), artwork in the top-right corner, eyebrow / title / detail on the left, a play
/// button bottom-right. On hover it lifts, the art moves (`art` gets the hover state), a sheen
/// crosses it once and the play button springs up; the button stays while its queue plays.
private struct PickTile<Art: View>: View {
    static var height: CGFloat { 196 }

    var eyebrow: String
    var title: String
    var detail: String
    var tint: TileTint
    var playing: Bool?
    var onTint: ((Color) -> Void)? = nil
    var onOpen: () -> Void
    var onPlay: () -> Void
    @ViewBuilder var art: (Bool) -> Art
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var colors: [Color]?
    @State private var sheens = 0

    private static var radius: CGFloat { 16 }

    var body: some View {
        let tones = colors ?? TilePalette.cached(tint) ?? TilePalette.placeholder(tint)
        ZStack(alignment: .bottomTrailing) {
            Button(action: onOpen) { face(tones) }
                .buttonStyle(PressScaleStyle(scale: 0.985))
            playButton.padding(16)
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(hovering ? 1.012 : 1)
        .shadow(color: tones[1].opacity(theme.isDark ? 0.6 : 0.35), radius: hovering ? 22 : 10, y: hovering ? 12 : 5)
        .onHover { inside in
            hovering = inside
            if inside { sheens += 1 }
        }
        .animation(Motion.lift, value: hovering)
        .animation(.easeOut(duration: 0.5), value: colors)
        .task(id: tint) {
            let resolved = await TilePalette.colors(tint)
            if (colors ?? TilePalette.cached(tint)) != resolved { colors = resolved }
            onTint?(resolved[0])
        }
    }

    private func face(_ tones: [Color]) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: tones, startPoint: .topTrailing, endPoint: .bottomLeading)
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 280)
            art(hovering)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 18)
                .padding(.trailing, 18)
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.3)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(.system(size: 11.5, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
                HStack(spacing: 7) {
                    if let playing {
                        PlayingBars(color: .white, animating: playing && pageActive && !reduceMotion)
                            .frame(width: 12, height: 11)
                            .transition(.opacity.combined(with: .scale(scale: 0.5)))
                    }
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .padding(.top, 5)
            }
            .padding(18)
            .padding(.trailing, 52)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            sheen
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .contentShape(shape)
        .animation(Motion.hover, value: playing)
        .animation(.easeOut(duration: 0.3), value: title)
    }

    private var sheen: some View {
        Color.clear
            .keyframeAnimator(initialValue: -0.7, trigger: sheens) { content, x in
                content.overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.45, height: geo.size.height * 1.8)
                            .rotationEffect(.degrees(20))
                            .position(x: x * geo.size.width, y: geo.size.height / 2)
                    }
                }
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(1.7, duration: reduceMotion ? 0 : 1.0)
                }
            }
            .allowsHitTesting(false)
    }

    private var playButton: some View {
        let isPlaying = playing == true
        let visible = hovering || playing != nil
        return Button(action: onPlay) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(PressScaleStyle())
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.7)
        .offset(y: visible ? 0 : 8)
        .allowsHitTesting(visible)
        .help(isPlaying ? "暂停" : "播放")
    }
}

@MainActor
private enum TilePalette {
    private static var cache: [URL: [Color]] = [:]
    /// The tiles' covers are drawn at this size too, so the palette reuses their bitmap.
    static let pixels = 300

    static func placeholder(_ tint: TileTint) -> [Color] {
        switch tint {
        case .artwork(let artwork): tones(hue: PlaceholderArt.hue(for: artwork?.seed ?? "starry"), saturation: 0.5)
        case .hue(let hue): tones(hue: hue, saturation: 0.5)
        }
    }

    static func cached(_ tint: TileTint) -> [Color]? {
        guard case .artwork(let artwork) = tint, let url = artwork?.sized(pixels) else { return placeholder(tint) }
        return cache[url]
    }

    static func colors(_ tint: TileTint) async -> [Color] {
        if let known = cached(tint) { return known }
        guard case .artwork(let artwork) = tint, let url = artwork?.sized(pixels) else { return placeholder(tint) }
        guard let image = await ImageStore.shared.load(url, maxPixelSize: pixels),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return placeholder(tint) }
        let palette = CoverPalette.extract(from: cgImage)
        let result = [tone(palette.accents.first ?? palette.dominant, brightness: 0.5), tone(palette.dominant, brightness: 0.26)]
        cache[url] = result
        return result
    }

    private static func tones(hue: Double, saturation: Double) -> [Color] {
        [.hsb(hue, saturation, 0.52), .hsb(hue + 0.05, saturation + 0.08, 0.27)]
    }

    private static func tone(_ rgb: CoverPalette.RGB, brightness: Double) -> Color {
        let color = Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
        guard let hsb = color.hsb else { return color }
        return .hsb(hsb.hue, min(hsb.saturation, 0.62), brightness)
    }
}

private struct CoverFan: View {
    var artworks: [Artwork?]
    var size: CGFloat
    var spread: Bool

    private static let slots: [CGFloat] = [0, -1, 1]

    var body: some View {
        let count = min(artworks.count, 3)
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let slot = Self.slots[i]
                ArtworkView(artwork: artworks[i], radius: 8, pixelSize: TilePalette.pixels)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .scaleEffect(i == 0 ? 1 : 0.88)
                    .rotationEffect(.degrees(slot * (spread ? 14 : 8)))
                    .offset(x: slot * size * (spread ? 0.46 : 0.32), y: i == 0 ? (spread ? -5 : 0) : 8)
                    .zIndex(Double(count - i))
            }
        }
        .frame(width: size * 1.9, height: size + 18)
    }
}

private struct TiltedCover: View {
    var artwork: Artwork?
    var size: CGFloat
    var straight: Bool

    var body: some View {
        ArtworkView(artwork: artwork, radius: 10, pixelSize: TilePalette.pixels)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: straight ? 16 : 10, y: straight ? 10 : 5)
            .rotationEffect(.degrees(straight ? 0 : 7))
            .scaleEffect(straight ? 1.05 : 1)
    }
}

private struct HomeSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let fill = theme.onSurface.opacity(theme.isDark ? 0.06 : 0.07)
        VStack(alignment: .leading, spacing: 34) {
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill).frame(height: PickTile<EmptyView>.height)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                SkeletonBar(width: 96, height: 14)
                HStack(alignment: .top, spacing: 18) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(fill).aspectRatio(1, contentMode: .fit)
                            SkeletonBar(width: 92, height: 10)
                            SkeletonBar(width: 56, height: 8)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        .shimmer()
    }
}
