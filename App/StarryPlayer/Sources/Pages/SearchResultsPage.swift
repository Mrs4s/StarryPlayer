import MusicSources
import Observation
import StarryCore
import SwiftUI

struct SearchResultsPage: View {
    enum Tab: Int, CaseIterable {
        case top, songs, artists, albums, playlists, users

        var title: String {
            switch self {
            case .top: "综合"
            case .songs: "单曲"
            case .artists: "歌手"
            case .albums: "专辑"
            case .playlists: "歌单"
            case .users: "用户"
            }
        }

        var kind: SearchKind? {
            switch self {
            case .top: nil
            case .songs: .song
            case .artists: .artist
            case .albums: .album
            case .playlists: .playlist
            case .users: .user
            }
        }
    }

    var query: String
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var tab: Tab = .top
    @State private var overview: Loadable<SearchOverview> = .idle
    @State private var songs = PagedFeed<Track>(pageSize: 30)
    @State private var artists = PagedFeed<Artist>(pageSize: 30)
    @State private var albums = PagedFeed<Album>(pageSize: 30)
    @State private var playlists = PagedFeed<Playlist>(pageSize: 30)
    @State private var users = PagedFeed<UserProfile>(pageSize: 30)
    @State private var totals = SearchTotals()
    @State private var searched: SourceID?
    @State private var columns = 5
    @State private var appeared = false
    @State private var backdrop = PageBackdrop()

    static let artworkPixels = 240

    private var source: SourceID { model.browsingSourceID }
    private var context: PlaybackContext {
        PlaybackContext(source: source, originType: .search, originName: query)
    }
    private var kinds: [SearchKind] {
        model.source(source, as: (any SearchableSource).self)?.searchKinds ?? []
    }

    var body: some View {
        DetailPageScroll(tab: $tab, backdrop: backdrop) {
            hero
        } bar: { tab in
            DetailTabBar(tab: tab, items: tabItems) { EmptyView() }
                .reveal(appeared, delay: 0.12, distance: 6)
        } rows: { tab in
            tabRows(switchTab: tab)
        }
        .onGeometryChange(for: Int.self) { SearchGrid.columns(for: $0.size.width) } action: { columns = $0 }
        .task(id: source) { await load() }
        .task(id: topArtwork) { await backdrop.tint(from: topArtwork, pixels: Self.artworkPixels) }
        .onAppear { appeared = true }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("搜索")
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(theme.onSurfaceVariant)
                .reveal(appeared, delay: 0.02)
            Text(query)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .reveal(appeared, delay: 0.06)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }

    private var tabItems: [PageTabs<Tab>.Item] {
        Tab.allCases.filter { $0.kind.map(kinds.contains) ?? true }.map { tab in
            PageTabs<Tab>.Item(value: tab, title: tab.title, count: tab.kind.flatMap { totals.counts[$0] })
        }
    }

    private var topArtwork: Artwork? {
        switch overview.value?.topResult {
        case .song(let track): track.artwork
        case .artist(let artist): artist.artwork
        case .album(let album): album.artwork
        case .playlist(let playlist): playlist.artwork
        case nil: nil
        }
    }

    @ViewBuilder private func tabRows(switchTab: Binding<Tab>) -> some View {
        switch tab {
        case .top: topRows(switchTab: switchTab)
        case .songs: songRows
        case .artists:
            gridRows(artists, fetch: fetch(.artist) { $0.artists }, circle: true, empty: "歌手") { artist in
                CoverCard(title: artist.name, subtitle: SearchFormat.artistSubtitle(artist), artwork: artist.artwork, circle: true) {
                    model.navigate(.artist(artist))
                }
            }
        case .albums:
            gridRows(albums, fetch: fetch(.album) { $0.albums }, empty: "专辑") { album in
                CoverCard(title: album.name, subtitle: SearchFormat.albumSubtitle(album), artwork: album.artwork) {
                    model.navigate(.album(album))
                } onPlay: {
                    SearchPlayback.play(.album(album), model: model)
                }
            }
        case .playlists:
            gridRows(playlists, fetch: fetch(.playlist) { $0.playlists }, empty: "歌单") { playlist in
                CoverCard(title: playlist.name, subtitle: SearchFormat.playlistSubtitle(playlist), artwork: playlist.artwork) {
                    model.navigate(.collection(playlist))
                } onPlay: {
                    SearchPlayback.play(.playlist(playlist), model: model)
                }
            }
        case .users: userRows
        }
    }

    @ViewBuilder private func topRows(switchTab: Binding<Tab>) -> some View {
        switch overview {
        case .idle, .loading:
            TopResultsSkeleton()
        case .failed(let message):
            failure(message) { Task { await loadOverview() } }
        case .loaded(let overview):
            if overview.isEmpty {
                StateView(systemName: "magnifyingglass", title: "没有找到与“\(query)”相关的结果", detail: "换个关键词试试")
            } else {
                SearchOverviewRows(overview: overview, context: context, tint: backdrop.tint) { switchTab.wrappedValue = $0 }
            }
        }
    }

    @ViewBuilder private var userRows: some View {
        let fetch = fetch(.user) { $0.users }
        switch users.phase {
        case .idle, .loading:
            UserSkeleton(count: 8)
                .task { await users.loadIfNeeded(pages: fetch) }
        case .failed(let message):
            failure(message) { Task { await users.load(pages: fetch) } }
        case .loaded:
            Color.clear.frame(height: 8)
            if users.items.isEmpty {
                StateView(systemName: "person.2", title: "没有找到与“\(query)”相关的用户")
            } else {
                UserRows(users: users.items, list: "search")
            }
            if users.hasMore {
                moreRows(users, fetch: fetch) { UserSkeleton(count: 3) }
            }
        }
    }

    @ViewBuilder private var songRows: some View {
        let fetch = fetch(.song) { $0.songs }
        switch songs.phase {
        case .idle, .loading:
            TrackSkeleton(count: 10, artwork: true)
                .task { await songs.loadIfNeeded(pages: fetch) }
        case .failed(let message):
            failure(message) { Task { await songs.load(pages: fetch) } }
        case .loaded:
            Color.clear.frame(height: 8)
            if songs.items.isEmpty {
                StateView(systemName: "music.note", title: "没有找到与“\(query)”相关的单曲")
            } else {
                RevealedTrackRows(tracks: songs.items, context: context)
            }
            if songs.hasMore {
                moreRows(songs, fetch: fetch) { TrackSkeleton(count: 3, artwork: true) }
            }
        }
    }

    @ViewBuilder private func gridRows<Item: Identifiable, Card: View>(_ feed: PagedFeed<Item>, fetch: @escaping PagedFeed<Item>.PageFetch, circle: Bool = false, empty: String, @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        switch feed.phase {
        case .idle, .loading:
            CardGridSkeleton(columns: columns, rows: 2, circle: circle)
                .task { await feed.loadIfNeeded(pages: fetch) }
        case .failed(let message):
            failure(message) { Task { await feed.load(pages: fetch) } }
        case .loaded:
            if feed.items.isEmpty {
                StateView(systemName: "magnifyingglass", title: "没有找到与“\(query)”相关的\(empty)")
            } else {
                SearchCardRows(items: feed.items, columns: columns, card: card)
            }
            if feed.hasMore {
                moreRows(feed, fetch: fetch) { CardGridSkeleton(columns: columns, rows: 1, circle: circle) }
            }
        }
    }

    @ViewBuilder private func moreRows<Item: Identifiable, Placeholder: View>(_ feed: PagedFeed<Item>, fetch: @escaping PagedFeed<Item>.PageFetch, @ViewBuilder placeholder: () -> Placeholder) -> some View {
        if feed.moreFailed {
            PillButton(title: "加载失败，重试", systemName: "arrow.clockwise", variant: .tertiary) { feed.retryMore() }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            placeholder()
                .task(id: feed.items.count) { await feed.loadMore(pages: fetch) }
        }
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message).frame(minHeight: 0)
            PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary, action: retry)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func load() async {
        if searched != source {
            if searched != nil { reset() }
            searched = source
        }
        let kinds = kinds
        if let kind = tab.kind, !kinds.contains(kind) { tab = .top }
        async let top: Void = loadOverview()
        async let songPage: Void = songs.loadIfNeeded(pages: fetch(.song) { $0.songs })
        async let artistPage: Void = kinds.contains(.artist) ? artists.loadIfNeeded(pages: fetch(.artist) { $0.artists }) : ()
        async let albumPage: Void = kinds.contains(.album) ? albums.loadIfNeeded(pages: fetch(.album) { $0.albums }) : ()
        async let playlistPage: Void = kinds.contains(.playlist) ? playlists.loadIfNeeded(pages: fetch(.playlist) { $0.playlists }) : ()
        async let userPage: Void = kinds.contains(.user) ? users.loadIfNeeded(pages: fetch(.user) { $0.users }) : ()
        _ = await (top, songPage, artistPage, albumPage, playlistPage, userPage)
    }

    private func reset() {
        overview = .idle
        songs = PagedFeed(pageSize: 30)
        artists = PagedFeed(pageSize: 30)
        albums = PagedFeed(pageSize: 30)
        playlists = PagedFeed(pageSize: 30)
        users = PagedFeed(pageSize: 30)
        totals = SearchTotals()
    }

    private func loadOverview() async {
        if overview.value == nil { overview = .loading }
        let source = source
        // Not animated: the page's height changes with it (see `DetailPageScroll`).
        overview = await Loadable.run { try await model.require(source, as: (any SearchableSource).self, "搜索").searchOverview(query) }
    }

    private func fetch<Item>(_ kind: SearchKind, _ pick: @escaping @Sendable (SearchPage) -> [Item]) -> PagedFeed<Item>.PageFetch {
        let model = model, query = query, totals = totals, source = source
        return { page in
            let result = try await model.require(source, as: (any SearchableSource).self, "搜索").search(query, kind: kind, page: page)
            if page.offset == 0, let total = result.total { totals.counts[kind] = total }
            return (pick(result), result.nextPage)
        }
    }
}

@MainActor @Observable
final class SearchTotals {
    var counts: [SearchKind: Int] = [:]
}

private struct SearchOverviewRows: View {
    var overview: SearchOverview
    var context: PlaybackContext
    var tint: Color?
    var open: (SearchResultsPage.Tab) -> Void
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        TopResultsRow(overview: overview, context: context, tint: tint, shown: shown) { open(.songs) }
            .padding(.top, 18)
            .onAppear { if !shown { shown = true } }
        if !overview.artists.isEmpty {
            Shelf(title: "歌手", items: overview.artists, minCardWidth: 128, moreAction: { open(.artists) }) { artist in
                CoverCard(title: artist.name, subtitle: SearchFormat.artistSubtitle(artist), artwork: artist.artwork, circle: true) {
                    model.navigate(.artist(artist))
                }
            }
            .padding(.horizontal, -Metrics.pagePadding)
            .padding(.top, 34)
            .reveal(shown, delay: 0.16, distance: 14)
        }
        if !overview.albums.isEmpty {
            Shelf(title: "专辑", items: overview.albums, moreAction: { open(.albums) }) { album in
                CoverCard(title: album.name, subtitle: SearchFormat.albumSubtitle(album), artwork: album.artwork) {
                    model.navigate(.album(album))
                } onPlay: {
                    SearchPlayback.play(.album(album), model: model)
                }
            }
            .padding(.horizontal, -Metrics.pagePadding)
            .padding(.top, 30)
            .reveal(shown, delay: 0.22, distance: 14)
        }
        if !overview.playlists.isEmpty {
            Shelf(title: "歌单", items: overview.playlists, moreAction: { open(.playlists) }) { playlist in
                CoverCard(title: playlist.name, subtitle: SearchFormat.playlistSubtitle(playlist), artwork: playlist.artwork) {
                    model.navigate(.collection(playlist))
                } onPlay: {
                    SearchPlayback.play(.playlist(playlist), model: model)
                }
            }
            .padding(.horizontal, -Metrics.pagePadding)
            .padding(.top, 30)
            .reveal(shown, delay: 0.28, distance: 14)
        }
    }
}

private struct TopResultsRow: View {
    var overview: SearchOverview
    var context: PlaybackContext
    var tint: Color?
    var shown: Bool
    var openSongs: () -> Void

    private static let songCount = 4
    static let height = CGFloat(songCount) * 62

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                best.frame(minWidth: 300, maxWidth: 420)
                songs.frame(minWidth: 360, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 26) {
                best
                songs
            }
        }
    }

    @ViewBuilder private var best: some View {
        if let top = overview.topResult {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: "最佳匹配")
                    .reveal(shown, delay: 0.02)
                TopResultCard(result: top, songs: overview.songs, context: context, tint: tint)
                    .frame(height: Self.height)
                    .reveal(shown, delay: 0.05, distance: 12, scale: 0.97)
            }
        }
    }

    @ViewBuilder private var songs: some View {
        let tracks = Array(overview.songs.prefix(Self.songCount))
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: "单曲", moreAction: openSongs)
                    .reveal(shown, delay: 0.04)
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackTileRow(track: track, separator: index < tracks.count - 1, tracks: overview.songs, index: index, context: context)
                            .staggeredReveal(shown, index: index, base: 0.08)
                    }
                }
            }
        }
    }
}

private struct TrackTileRow: View {
    var track: Track
    var separator: Bool
    var tracks: [Track]
    var index: Int
    var context: PlaybackContext
    @Environment(AppModel.self) private var model

    var body: some View {
        TrackTile(track: track, separator: separator) {
            model.player.play(tracks, startAt: index, context: context)
        }
    }
}

private struct TopResultCard: View {
    var result: SearchOverview.TopResult
    var songs: [Track]
    var context: PlaybackContext
    var tint: Color?
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var isArtist: Bool {
        if case .artist = result { return true }
        return false
    }

    var body: some View {
        let playing = SearchPlayback.state(of: result, player: model.player)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(artwork: SearchFormat.artwork(result), radius: 10, circle: isArtist, zoom: hovering ? 1.05 : 1, pixelSize: SearchResultsPage.artworkPixels, neutralPlaceholder: isArtist ? "music.mic" : nil)
                .frame(width: 104, height: 104)
                .overlay {
                    (isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
                        .stroke(theme.onSurface.opacity(0.07), lineWidth: 1)
                }
                .shadow(color: theme.coverShadow(tint), radius: hovering ? 16 : 10, y: hovering ? 8 : 5)
            Spacer(minLength: 12)
            Text(SearchFormat.kind(result))
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(theme.onSurfaceVariant)
            Text(SearchFormat.title(result))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
                .padding(.top, 4)
            Text(SearchFormat.subtitle(result))
                .font(.system(size: 13))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
                .padding(.top, 4)
                .padding(.trailing, 60)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            playButton(playing: playing)
                .padding(18)
        }
        .background {
            shape.fill(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035))
            if let tint {
                shape.fill(LinearGradient(colors: [theme.wash(tint).opacity(theme.isDark ? 0.5 : 0.55), theme.wash(tint).opacity(theme.isDark ? 0.14 : 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
        .contentShape(shape)
        .scaleEffect(hovering ? 1.012 : 1)
        .shadow(color: .black.opacity(hovering ? (theme.isDark ? 0.35 : 0.12) : 0), radius: hovering ? 18 : 0, y: hovering ? 10 : 0)
        .onTapGesture(perform: activate)
        .onHover { hovering = $0 }
        .animation(Motion.lift, value: hovering)
    }

    /// `nil` unless the queue is this result's; then whether it plays.
    private func playButton(playing: Bool?) -> some View {
        let visible = hovering || playing != nil
        return Button {
            if playing != nil { model.player.togglePlayPause() } else { SearchPlayback.play(result, songs: songs, context: context, model: model) }
        } label: {
            Image(systemName: playing == true ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.surface)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(theme.onSurface, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .buttonStyle(PressScaleStyle())
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.7)
        .offset(y: visible ? 0 : 8)
        .allowsHitTesting(visible)
        .help(playing == true ? "暂停" : "播放")
    }

    private func activate() {
        switch result {
        case .song:
            if SearchPlayback.state(of: result, player: model.player) != nil {
                model.player.togglePlayPause()
            } else {
                SearchPlayback.play(result, songs: songs, context: context, model: model)
            }
        case .artist(let artist): model.navigate(.artist(artist))
        case .album(let album): model.navigate(.album(album))
        case .playlist(let playlist): model.navigate(.collection(playlist))
        }
    }
}

enum SearchGrid {
    static let spacing: CGFloat = 22
    static let minCardWidth: CGFloat = 150

    static func columns(for width: CGFloat) -> Int {
        max(2, Int((width - 2 * Metrics.pagePadding + spacing) / (minCardWidth + spacing)))
    }
}

private struct SearchCardRows<Item: Identifiable, Card: View>: View {
    var items: [Item]
    var columns: Int
    @ViewBuilder var card: (Item) -> Card
    @State private var shown = false

    var body: some View {
        let columns = max(columns, 1)
        // Keyed by the kind as well: the lazy stack would take the artists' first rows for the
        // albums' (same offsets) and keep showing the artists after a tab switch.
        ForEach(Array(stride(from: 0, to: items.count, by: columns)).map { RowID(kind: "\(Item.self)", start: $0) }) { rowID in
            let start = rowID.start
            let row = items[start..<min(start + columns, items.count)]
            HStack(alignment: .top, spacing: SearchGrid.spacing) {
                ForEach(row) { item in
                    card(item).frame(maxWidth: .infinity)
                }
                ForEach(row.count..<columns, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            .padding(.top, start == 0 ? 22 : 0)
            .padding(.bottom, 24)
            .staggeredReveal(shown, index: start / columns)
            .onAppear { if !shown { shown = true } }
        }
    }

    private struct RowID: Hashable, Identifiable {
        var kind: String
        var start: Int
        var id: Self { self }
    }
}

private struct CardGridSkeleton: View {
    var columns: Int
    var rows: Int
    var circle = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(alignment: .top, spacing: SearchGrid.spacing) {
                    ForEach(0..<columns, id: \.self) { index in
                        VStack(alignment: circle ? .center : .leading, spacing: 10) {
                            (circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)))
                                .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08))
                                .aspectRatio(1, contentMode: .fit)
                            SkeletonBar(width: [112, 84, 128, 96][index % 4], height: 11)
                            SkeletonBar(width: 64, height: 9)
                        }
                        .frame(maxWidth: .infinity, alignment: circle ? .center : .leading)
                    }
                }
            }
        }
        .padding(.top, 22)
        .shimmer()
    }
}

private struct TopResultsSkeleton: View {
    @Environment(\.theme) private var theme
    private static let widths: [CGFloat] = [150, 110, 180, 128]

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(width: 72, height: 14).frame(height: 28)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.04))
                    .frame(height: TopResultsRow.height)
            }
            .frame(minWidth: 300, maxWidth: 420)
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(width: 44, height: 14).frame(height: 28)
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08))
                                .frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 8) {
                                SkeletonBar(width: Self.widths[index], height: 11)
                                SkeletonBar(width: 72, height: 9)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 62)
                    }
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity)
        }
        .padding(.top, 18)
        .shimmer()
    }
}

enum SearchFormat {
    static func kind(_ result: SearchOverview.TopResult) -> String {
        switch result {
        case .song: "单曲"
        case .artist: "歌手"
        case .album: "专辑"
        case .playlist: "歌单"
        }
    }

    static func title(_ result: SearchOverview.TopResult) -> String {
        switch result {
        case .song(let track): track.title
        case .artist(let artist): artist.name
        case .album(let album): album.name
        case .playlist(let playlist): playlist.name
        }
    }

    static func subtitle(_ result: SearchOverview.TopResult) -> String {
        switch result {
        case .song(let track): [track.artistText, track.album?.name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .artist(let artist): artistDetail(artist)
        case .album(let album): albumSubtitle(album)
        case .playlist(let playlist): playlistSubtitle(playlist)
        }
    }

    static func artwork(_ result: SearchOverview.TopResult) -> Artwork? {
        switch result {
        case .song(let track): track.artwork
        case .artist(let artist): artist.artwork
        case .album(let album): album.artwork
        case .playlist(let playlist): playlist.artwork
        }
    }

    static func artistDetail(_ artist: Artist) -> String {
        var parts: [String] = []
        if artist.songCount > 0 { parts.append("\(artist.songCount) 首歌曲") }
        if artist.albumCount > 0 { parts.append("\(artist.albumCount) 张专辑") }
        if let fans = artist.followerCount, fans > 0 { parts.append("\(TimeFormatting.compactCount(fans)) 粉丝") }
        return parts.isEmpty ? (artist.alias ?? "") : parts.joined(separator: " · ")
    }

    static func artistSubtitle(_ artist: Artist) -> String {
        if let alias = artist.alias { return alias }
        if let fans = artist.followerCount, fans > 0 { return "\(TimeFormatting.compactCount(fans)) 粉丝" }
        return artist.songCount > 0 ? "\(artist.songCount) 首歌曲" : ""
    }

    static func albumSubtitle(_ album: Album, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let year = album.releaseDate.map { String(calendar.component(.year, from: $0)) }
        return [album.artists.map(\.name).joined(separator: " / "), year].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    static func playlistSubtitle(_ playlist: Playlist) -> String {
        [playlist.trackCount > 0 ? "\(playlist.trackCount) 首" : nil, playlist.creatorName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

@MainActor
enum SearchPlayback {
    /// nil unless the queue is `result`'s (the song is current); then whether it plays.
    static func state(of result: SearchOverview.TopResult, player: PlayerController) -> Bool? {
        switch result {
        case .song(let track): player.current?.id == track.id ? player.isPlaying : nil
        case .artist(let artist): player.playState(from: .artist, of: artist.source, id: artist.id)
        case .album(let album): player.playState(from: .album, of: album.source, id: album.id)
        case .playlist(let playlist): player.playState(from: .playlist, of: playlist.source, id: playlist.id)
        }
    }

    static func play(_ result: SearchOverview.TopResult, songs: [Track] = [], context: PlaybackContext? = nil, model: AppModel) {
        switch result {
        case .song(let track):
            if let index = songs.firstIndex(where: { $0.id == track.id }) {
                model.player.play(songs, startAt: index, context: context)
            } else {
                model.player.play([track], context: context)
            }
        case .artist(let artist):
            Task {
                do {
                    let detail = try await model.catalog(artist.source).artist(id: artist.id)
                    model.player.play(detail.topTracks, context: PlaybackContext(source: artist.source, originType: .artist, originID: artist.id, originName: artist.name))
                } catch {
                    model.showToast(ErrorText.describe(error))
                }
            }
        case .album(let album):
            Task {
                do {
                    let detail = try await model.catalog(album.source).album(id: album.id)
                    model.player.play(detail.tracks, context: PlaybackContext(source: album.source, originType: .album, originID: album.id, originName: album.name))
                } catch {
                    model.showToast(ErrorText.describe(error))
                }
            }
        case .playlist(let playlist):
            Task {
                do {
                    let detail = try await model.catalog(playlist.source).playlist(id: playlist.id)
                    model.player.play(detail.tracks, context: PlaybackContext(source: playlist.source, originType: .playlist, originID: playlist.id, originName: playlist.name))
                } catch {
                    model.showToast(ErrorText.describe(error))
                }
            }
        }
    }
}
