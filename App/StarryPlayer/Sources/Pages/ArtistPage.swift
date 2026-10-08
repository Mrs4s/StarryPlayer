import AppKit
import MusicSources
import StarryCore
import SwiftUI

struct ArtistPage: View {
    enum Tab: Int {
        case hotSongs, newSongs, albums, about

        var section: Section {
            switch self {
            case .hotSongs, .newSongs: .songs
            case .albums: .albums
            case .about: .about
            }
        }
    }

    enum Section: Hashable {
        case songs, albums, about
    }

    var artist: Artist
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var state: Loadable<ArtistDetail> = .idle
    @State private var tab: Tab = .hotSongs
    @State private var songTab: Tab = .hotSongs
    @State private var hotSongs = PagedFeed<Track>(pageSize: 100)
    @State private var newSongs = PagedFeed<Track>(pageSize: 100)
    @State private var albums = PagedFeed<Album>(pageSize: 40)
    @State private var similar: Loadable<[Artist]> = .idle
    @State private var followed: Bool?
    @State private var columns = 5
    @State private var appeared = false
    @State private var backdrop = PageBackdrop()

    private static let portraitSize: CGFloat = 200
    static let portraitPixels = 400

    private var shown: Artist { state.value?.artist ?? artist }
    private var context: PlaybackContext { PlaybackContext(source: artist.source, originType: .artist, originID: artist.id, originName: artist.name) }

    private var songOrders: [ArtistSongOrder] {
        model.source(artist.source, as: (any CatalogSource).self)?.artistSongOrders ?? [.hot]
    }

    private var topTracks: [Track] {
        if let top = state.value?.topTracks, !top.isEmpty { return top }
        return Array(hotSongs.items.prefix(50))
    }

    var body: some View {
        DetailPageScroll(tab: $tab, backdrop: backdrop) {
            hero
        } bar: { tab in
            DetailTabBar(tab: sectionBinding(tab), items: tabItems) {
                if tab.wrappedValue.section == .songs, songOrders.count > 1 {
                    SegmentSwitch(selection: orderBinding(tab), options: [(.hot, "热门"), (.time, "最新")])
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                }
            }
            .reveal(appeared, delay: 0.26, distance: 6)
        } rows: {
            tabRows
        }
        .onGeometryChange(for: Int.self) { DiscographyRows.columns(for: $0.size.width) } action: { columns = $0 }
        .onChange(of: tab) { if tab.section == .songs { songTab = tab } }
        .task(id: artist.id) { await load() }
        .task(id: shown.artwork?.sized(Self.portraitPixels)) { await backdrop.tint(from: shown.artwork, pixels: Self.portraitPixels) }
        .onAppear { appeared = true }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 34) {
            ArtistPortrait(artwork: shown.artwork, artist: artist, size: Self.portraitSize, glow: backdrop.tint, appeared: appeared, onPlay: playTop)
            VStack(alignment: .leading, spacing: 0) {
                Text("歌手")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .reveal(appeared, delay: 0.06)
                Text(shown.name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .reveal(appeared, delay: 0.1)
                if let alias = shown.alias {
                    Text(alias)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                        .reveal(appeared, delay: 0.12)
                } else if isLoading {
                    // Holds the lines the details usually bring, so the header keeps its height (it
                    // is bottom-aligned: a taller text column would move the name and the
                    // portrait).
                    SkeletonBar(width: 96, height: 11)
                        .frame(height: 18)
                        .padding(.top, 4)
                        .reveal(appeared, delay: 0.12)
                }
                Text(metaText.isEmpty ? " " : metaText)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: metaText)
                    .padding(.top, 12)
                    .reveal(appeared, delay: 0.14)
                if let description = shown.description {
                    DescriptionPeek(title: "歌手简介", text: description)
                        .padding(.top, 10)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                        .reveal(appeared, delay: 0.17)
                } else if isLoading {
                    VStack(alignment: .leading, spacing: 9) {
                        SkeletonBar(width: 360, height: 9)
                        SkeletonBar(width: 260, height: 9)
                    }
                    .frame(height: 34)
                    .padding(.top, 10)
                    .reveal(appeared, delay: 0.17)
                }
                actions
                    .padding(.top, 22)
                    .reveal(appeared, delay: 0.2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 34)
        .padding(.bottom, 28)
    }

    /// The details have not come yet.
    private var isLoading: Bool {
        switch state {
        case .idle, .loading: true
        case .loaded, .failed: false
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if shown.songCount > 0 { parts.append("\(shown.songCount) 首歌曲") }
        if shown.albumCount > 0 { parts.append("\(shown.albumCount) 张专辑") }
        if let videos = state.value?.videoCount, videos > 0 { parts.append("\(videos) 个 MV") }
        if let followers = shown.followerCount, followers > 0 { parts.append("\(TimeFormatting.compactCount(followers)) 粉丝") }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            ArtistPlayButton(artist: artist, action: playTop)
                .disabled(topTracks.isEmpty)
            if model.collecting(.artist, in: artist.source) != nil { followButton }
            moreMenu
        }
    }

    private var followButton: some View {
        let isFollowed = followed ?? state.value?.isFollowed ?? false
        return Button(action: toggleFollow) {
            HStack(spacing: 6) {
                Image(systemName: isFollowed ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(isFollowed ? "已关注" : "关注")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .disabled(state.value == nil)
    }

    private var moreMenu: some View {
        PopMenu {
            PopMenuItem.button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(next: true) }
            PopMenuItem.button("添加到播放队列", systemImage: "text.line.last.and.arrowtriangle.forward") { enqueue(next: false) }
            if let url = webURL {
                PopMenuItem.divider
                PopMenuItem.button("复制链接", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    model.showToast("已复制歌手链接")
                }
                PopMenuItem.button("在浏览器中打开", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
        } label: { open in
            PopMenuEllipsis(isOpen: open)
                .foregroundStyle(theme.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isCircle: true))
        .fixedSize()
        .disabled(topTracks.isEmpty)
    }

    private var webURL: URL? {
        model.webURL(.artist(artist.id), in: artist.source)
    }

    private var tabItems: [PageTabs<Section>.Item] {
        [
            .init(value: .songs, title: "歌曲", count: shown.songCount > 0 ? shown.songCount : nil),
            .init(value: .albums, title: "专辑", count: shown.albumCount > 0 ? shown.albumCount : nil),
            .init(value: .about, title: "歌手详情"),
        ]
    }

    private func sectionBinding(_ tab: Binding<Tab>) -> Binding<Section> {
        Binding {
            tab.wrappedValue.section
        } set: { section in
            switch section {
            case .songs: tab.wrappedValue = songTab
            case .albums: tab.wrappedValue = .albums
            case .about: tab.wrappedValue = .about
            }
        }
    }

    /// Hot / newest are tabs of their own, so switching them scrolls and slides like a tab.
    private func orderBinding(_ tab: Binding<Tab>) -> Binding<ArtistSongOrder> {
        Binding {
            tab.wrappedValue == .newSongs ? .time : .hot
        } set: { order in
            tab.wrappedValue = order == .time ? .newSongs : .hotSongs
        }
    }

    /// The selected tab as rows of the page's lazy stack (several views, not one container).
    @ViewBuilder private var tabRows: some View {
        switch tab {
        case .hotSongs: songRows(hotSongs, order: songOrders.contains(.hot) ? .hot : songOrders.first ?? .hot)
        case .newSongs: songRows(newSongs, order: .time)
        case .albums: albumRows
        case .about: aboutRows
        }
    }

    @ViewBuilder private func songRows(_ feed: PagedFeed<Track>, order: ArtistSongOrder) -> some View {
        let fetch = songFetcher(order)
        switch feed.phase {
        case .idle, .loading:
            TrackSkeleton(count: 10, artwork: true)
                .task { await feed.loadIfNeeded(fetch) }
        case .failed(let message):
            failure(message) { Task { await feed.load(fetch) } }
        case .loaded:
            Color.clear.frame(height: 8)
            if feed.items.isEmpty {
                StateView(systemName: "music.note", title: "暂无歌曲")
            } else {
                RevealedTrackRows(tracks: feed.items, context: context)
            }
            if feed.hasMore {
                moreRows(feed, fetch: fetch) { TrackSkeleton(count: 3, artwork: true) }
            } else if !feed.items.isEmpty {
                Text("共 \(feed.items.count) 首歌曲")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.top, 22)
                    .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder private var albumRows: some View {
        let fetch = albumFetcher
        switch albums.phase {
        case .idle, .loading:
            AlbumGridSkeleton(columns: columns, rows: 2, heading: true)
                .task { await albums.loadIfNeeded(fetch) }
        case .failed(let message):
            failure(message) { Task { await albums.load(fetch) } }
        case .loaded:
            if albums.items.isEmpty {
                StateView(systemName: "opticaldisc", title: "暂无专辑")
            } else {
                DiscographyRows(albums: albums.items, columns: columns)
            }
            if albums.hasMore {
                moreRows(albums, fetch: fetch) { AlbumGridSkeleton(columns: columns, rows: 1, heading: false) }
            }
        }
    }

    @ViewBuilder private var aboutRows: some View {
        switch state {
        case .idle, .loading:
            AboutSkeleton()
        case .failed(let message):
            failure(message) { Task { await load() } }
        case .loaded(let detail):
            ArtistAboutRows(detail: detail, similar: similar) { await loadSimilar() }
        }
    }

    @ViewBuilder private func moreRows<Item: Identifiable, Placeholder: View>(_ feed: PagedFeed<Item>, fetch: @escaping PagedFeed<Item>.Fetch, @ViewBuilder placeholder: () -> Placeholder) -> some View {
        if feed.moreFailed {
            PillButton(title: "加载失败，重试", systemName: "arrow.clockwise", variant: .tertiary) { feed.retryMore() }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            placeholder()
                .task(id: feed.items.count) { await feed.loadMore(fetch) }
        }
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message).frame(minHeight: 0)
            PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary, action: retry)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func songFetcher(_ order: ArtistSongOrder) -> PagedFeed<Track>.Fetch {
        let model = model, id = artist.id, source = artist.source
        return { page in try await model.catalog(source).artistSongs(id: id, order: order, page: page) }
    }

    private var albumFetcher: PagedFeed<Album>.Fetch {
        let model = model, id = artist.id, source = artist.source
        return { page in try await model.catalog(source).artistAlbums(id: id, page: page) }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        // Not animated: the page's height changes with it (see `DetailPageScroll`); the pieces
        // that appear bring their own transitions.
        state = await Loadable.run { try await model.catalog(artist.source).artist(id: artist.id) }
        followed = nil
    }

    private func loadSimilar() async {
        guard similar.value == nil, !similar.isLoading else { return }
        similar = .loading
        let loaded = await Loadable.run { try await model.catalog(artist.source).similarArtists(id: artist.id) }
        similar = Task.isCancelled ? .idle : loaded
    }

    private func playTop() {
        if model.player.playState(from: .artist, of: artist.source, id: artist.id) != nil {
            model.player.togglePlayPause()
        } else if !topTracks.isEmpty {
            model.player.play(topTracks, context: context)
        }
    }

    private func enqueue(next: Bool) {
        let tracks = topTracks
        guard !tracks.isEmpty else { return }
        if next {
            model.player.playNext(tracks)
            model.showToast("已添加 \(tracks.count) 首到下一首播放")
        } else {
            model.player.addToQueue(tracks)
            model.showToast("已添加 \(tracks.count) 首到播放队列")
        }
    }

    private func toggleFollow() {
        guard let detail = state.value, let collecting = model.collecting(.artist, in: artist.source) else { return }
        guard model.accounts.isLoggedIn(artist.source) else {
            model.requestLogin(artist.source)
            return
        }
        let was = followed ?? detail.isFollowed ?? false
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { followed = !was }
        Task {
            do {
                try await collecting.setCollected(.artist(artist.id), collected: !was)
                model.showToast(was ? "已取消关注" : "已关注 \(shown.name)")
            } catch {
                withAnimation { followed = was }
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}

private struct ArtistPortrait: View {
    var artwork: Artwork?
    var artist: Artist
    var size: CGFloat
    var glow: Color?
    var appeared: Bool
    var onPlay: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let playing = model.player.playState(from: .artist, of: artist.source, id: artist.id) == true
        ZStack {
            RippleRings(color: ringColor, diameter: size, rippling: playing && pageActive && !reduceMotion, pulse: appeared && pageActive && !reduceMotion)
                .frame(width: size * RippleRings.extent, height: size * RippleRings.extent)
            portrait(isPlaying: playing)
        }
        .frame(width: size, height: size)
    }

    private func portrait(isPlaying: Bool) -> some View {
        let rim = size / 2 * 0.7071
        return ArtworkView(artwork: artwork, circle: true, zoom: hovering ? 1.05 : 1, pixelSize: ArtistPage.portraitPixels, neutralPlaceholder: "person.fill")
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay {
                CoverPlayButton(isPlaying: isPlaying, visible: hovering, action: onPlay)
                    .padding(-12)
                    .offset(x: rim, y: rim)
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .shadow(color: theme.coverShadow(glow), radius: hovering ? 26 : 18, y: hovering ? 14 : 9)
            .onHover { hovering = $0 }
            .animation(Motion.lift, value: hovering)
            .reveal(appeared, distance: 0, scale: 0.92)
    }

    private var ringColor: Color {
        guard let glow, let hsb = glow.hsb else { return theme.onSurface }
        return theme.isDark
            ? .hsb(hsb.hue, min(hsb.saturation, 0.45), 0.92)
            : .hsb(hsb.hue, min(hsb.saturation, 0.6), 0.5)
    }
}

private struct ArtistPlayButton: View {
    var artist: Artist
    var action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let state = model.player.playState(from: .artist, of: artist.source, id: artist.id)
        let playing = state == true
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(playing ? "暂停" : (state != nil ? "继续播放" : "播放热门"))
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(theme.onPrimary)
            .padding(.horizontal, 20)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .filled, isPill: true))
        .animation(Motion.hover, value: state)
    }
}

/// Songs with covers, numbered by rank (an artist's songs, search results). Rows rise in with a
/// stagger when the list first shows. Its body is the rows themselves, so they become rows of the
/// page's lazy stack.
struct RevealedTrackRows: View {
    var tracks: [Track]
    var context: PlaybackContext
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            SongRow(track: track, index: index + 1) {
                model.player.play(tracks, startAt: index, context: context)
            }
            .staggeredReveal(shown, index: index)
            .onAppear { if !shown { shown = true } }
        }
    }
}

/// Discography: the albums by release year, newest first. Each year's albums fill rows of
/// `columns` cards, with the year and its count in a gutter beside the first row. Its body is
/// the rows themselves, so they become rows of the page's lazy stack; they rise in with a
/// stagger when the grid first shows.
struct DiscographyRows: View {
    struct Row: Identifiable {
        var id: String
        var albums: [Album]
        var year: (title: String, count: Int)?
    }

    var albums: [Album]
    var columns: Int
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var shown = false

    static let spacing: CGFloat = 22
    static let minCardWidth: CGFloat = 150
    static let gutter: CGFloat = 84

    nonisolated static func columns(for width: CGFloat) -> Int {
        max(2, Int((width - 2 * Metrics.pagePadding - gutter + spacing) / (minCardWidth + spacing)))
    }

    var body: some View {
        ForEach(Array(Self.rows(albums, columns: columns).enumerated()), id: \.element.id) { index, row in
            HStack(alignment: .top, spacing: 0) {
                yearLabel(row.year)
                    .frame(width: Self.gutter, alignment: .topLeading)
                cardRow(row.albums)
            }
            .padding(.top, row.year == nil ? 0 : (index == 0 ? 22 : 12))
            .staggeredReveal(shown, index: index)
            .onAppear { if !shown { shown = true } }
        }
    }

    @ViewBuilder private func yearLabel(_ year: (title: String, count: Int)?) -> some View {
        if let year {
            VStack(alignment: .leading, spacing: 4) {
                Text(year.title)
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurface)
                Text("\(year.count) 张")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.numericText(value: Double(year.count)))
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func cardRow(_ albums: [Album]) -> some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(albums) { album in
                CoverCard(title: album.name, subtitle: Self.subtitle(album), artwork: album.artwork) {
                    model.navigate(.album(album))
                } onPlay: {
                    play(album)
                }
                .frame(maxWidth: .infinity)
            }
            ForEach(albums.count..<max(columns, albums.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
        .padding(.bottom, 24)
    }

    private func play(_ album: Album) {
        Task {
            do {
                let detail = try await model.catalog(album.source).album(id: album.id)
                model.player.play(detail.tracks, context: PlaybackContext(source: album.source, originType: .album, originID: album.id, originName: album.name))
            } catch {
                model.showToast(ErrorText.describe(error))
            }
        }
    }

    nonisolated static func rows(_ albums: [Album], columns: Int, calendar: Calendar = Calendar(identifier: .gregorian)) -> [Row] {
        var groups: [(title: String, albums: [Album])] = []
        var undated: [Album] = []
        for album in albums {
            guard let date = album.releaseDate else { undated.append(album); continue }
            let title = String(calendar.component(.year, from: date))
            if groups.last?.title == title { groups[groups.count - 1].albums.append(album) } else { groups.append((title, [album])) }
        }
        if !undated.isEmpty { groups.append(("其他", undated)) }
        let columns = max(columns, 1)
        return groups.flatMap { group in
            stride(from: 0, to: group.albums.count, by: columns).map { start in
                Row(
                    id: "\(group.title)-\(start / columns)",
                    albums: Array(group.albums[start..<min(start + columns, group.albums.count)]),
                    year: start == 0 ? (group.title, group.albums.count) : nil
                )
            }
        }
    }

    nonisolated static func subtitle(_ album: Album, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        var parts: [String] = []
        if let date = album.releaseDate {
            let c = calendar.dateComponents([.month, .day], from: date)
            parts.append("\(c.month ?? 0)月\(c.day ?? 0)日")
        }
        if let kind = kind(album) { parts.append(kind) }
        return parts.joined(separator: " · ")
    }

    /// The edition when it is not the studio one (`现场版`, `翻唱版`…), else the release type.
    nonisolated static func kind(_ album: Album) -> String? {
        if let edition = album.edition, !edition.isEmpty, edition != "录音室版" { return edition }
        switch album.releaseType {
        case "Single": return "单曲"
        case "EP/Single", "EP": return "EP"
        case let type?: return type.isEmpty ? nil : type
        case nil: return nil
        }
    }
}

private struct AlbumGridSkeleton: View {
    var columns: Int
    var rows: Int
    var heading: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 0) {
                    Group {
                        if heading && row == 0 { SkeletonBar(width: 52, height: 16).padding(.top, 3) } else { Color.clear.frame(height: 1) }
                    }
                    .frame(width: DiscographyRows.gutter, alignment: .topLeading)
                    cardRow
                }
            }
        }
        .padding(.top, 22)
        .shimmer()
    }

    private var cardRow: some View {
        HStack(alignment: .top, spacing: DiscographyRows.spacing) {
            ForEach(0..<columns, id: \.self) { index in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08))
                        .aspectRatio(1, contentMode: .fit)
                    SkeletonBar(width: [112, 84, 128, 96][index % 4], height: 11)
                    SkeletonBar(width: 64, height: 9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ArtistAboutRows: View {
    var detail: ArtistDetail
    var similar: Loadable<[Artist]>
    var loadSimilar: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var shown = false

    static let sideWidth: CGFloat = 220

    private var isEmpty: Bool {
        detail.artist.description == nil && detail.introduction.isEmpty && detail.photo == nil
    }

    var body: some View {
        lead
            // On the first row, not the shelf's: the lazy stack creates the last row only once
            // it scrolls near, and the shelf would then come in below where the page had ended.
            .task { await loadSimilar() }
        if !isEmpty {
            ForEach(Array(detail.introduction.enumerated()), id: \.offset) { index, section in
                BioSection(title: section.title, text: section.text, artistName: detail.artist.name)
                    .staggeredReveal(shown, index: index + 1)
            }
        }
        similarShelf
    }

    @ViewBuilder private var lead: some View {
        if isEmpty {
            StateView(systemName: "person.text.rectangle", title: "暂无歌手介绍")
        } else {
            overview
                .staggeredReveal(shown, index: 0)
                .onAppear { if !shown { shown = true } }
        }
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 28) {
            Group {
                if let photo = detail.photo {
                    // 5 : 4, the usual shape of these photos, so none of it is cropped away.
                    ArtworkView(artwork: photo, radius: 14, pixelSize: 440, pixelHeight: 352, neutralPlaceholder: "person.fill")
                        .frame(width: Self.sideWidth, height: Self.sideWidth * 0.8)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.onSurface.opacity(0.07), lineWidth: 1))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Self.sideWidth, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 12) {
                Text("简介")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                Text(detail.artist.description ?? "暂无简介")
                    .font(.system(size: 14))
                    .lineSpacing(7)
                    .foregroundStyle(theme.onSurface.opacity(0.88))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var similarShelf: some View {
        switch similar {
        case .loaded(let artists) where !artists.isEmpty:
            Shelf(title: "相似歌手", items: artists, minCardWidth: 128, spacing: 22) { artist in
                CoverCard(title: artist.name, subtitle: artist.followerCount.map { "\(TimeFormatting.compactCount($0)) 粉丝" }, artwork: artist.artwork, circle: true) {
                    model.navigate(.artist(artist))
                }
            }
            .padding(.horizontal, -Metrics.pagePadding)
            .padding(.top, 40)
            .transition(.opacity.combined(with: .offset(y: 10)).animation(Motion.reveal))
        default:
            Color.clear.frame(height: 1)
        }
    }
}

private struct BioSection: View {
    var title: String
    var text: String
    var artistName: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onSurface)
                .frame(width: ArtistAboutRows.sideWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ArtistBio.blocks(text).enumerated()), id: \.offset) { index, block in
                    view(for: block, first: index == 0)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .padding(.top, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: ArtistBio.Block, first: Bool) -> some View {
        switch block {
        case .works(let works):
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(Array(works.enumerated()), id: \.offset) { _, work in
                    WorkChip(title: work, query: "\(artistName) \(work)")
                }
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(theme.onSurfaceVariant)
                        Text(item).foregroundStyle(theme.onSurface.opacity(0.88))
                    }
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                }
            }
        case .heading(let heading):
            Text(heading)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.onSurface)
                .padding(.top, first ? 0 : 8)
        case .paragraph(let paragraph):
            Text(paragraph)
                .font(.system(size: 14))
                .lineSpacing(7)
                .foregroundStyle(theme.onSurface.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WorkChip: View {
    var title: String
    var query: String
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { model.navigate(.search(query)) } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.onSurface.opacity(hovering ? 1 : 0.85))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(theme.onSurface.opacity(hovering ? 0.11 : 0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("搜索“\(title)”")
    }
}

private struct AboutSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08))
                .frame(width: ArtistAboutRows.sideWidth, height: ArtistAboutRows.sideWidth * 0.8)
            VStack(alignment: .leading, spacing: 14) {
                SkeletonBar(width: 40, height: 13)
                ForEach([520, 560, 480, 540, 300] as [CGFloat], id: \.self) { SkeletonBar(width: $0, height: 10) }
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmer()
    }
}

enum ArtistBio {
    enum Block: Hashable {
        case works([String])
        case list([String])
        case heading(String)
        case paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        if lines.count == 1 {
            let works = lines[0].split(separator: "、").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if works.count >= 3, works.allSatisfy({ $0.count <= 24 && !endsSentence($0) }) { return [.works(works)] }
            return [.paragraph(lines[0])]
        }
        if lines.allSatisfy({ $0.count <= 40 && !endsSentence($0) }) { return [.list(lines)] }
        return lines.enumerated().map { index, line in
            index < lines.count - 1 && line.count <= 14 && !endsSentence(line) && !line.contains("，") ? .heading(line) : .paragraph(line)
        }
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return "。！？；.!?;：:".contains(last)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
