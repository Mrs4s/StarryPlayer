import AppKit
import MusicSources
import StarryCore
import SwiftUI

private struct LibraryCardRows<Item: Identifiable, Card: View>: View {
    var items: [Item]
    var columns: Int
    var loadMore: (() -> Void)?
    @ViewBuilder var card: (Item) -> Card
    @State private var shown = false

    static var spacing: CGFloat { 22 }

    static func columns(for width: CGFloat, minCardWidth: CGFloat = 150) -> Int {
        max(2, Int((width - 2 * Metrics.pagePadding + spacing) / (minCardWidth + spacing)))
    }

    var body: some View {
        let columns = max(columns, 1)
        ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
            let row = items[start..<min(start + columns, items.count)]
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(row) { item in
                    card(item).frame(maxWidth: .infinity)
                }
                ForEach(row.count..<columns, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            .padding(.bottom, 24)
            .staggeredReveal(shown, index: min(start / columns, 6))
            .onAppear {
                if !shown { shown = true }
                if start + columns >= items.count { loadMore?() }
            }
        }
    }
}

@MainActor @Observable
private final class LibraryTotal {
    var count: Int?
}

struct LibraryAlbumsPage: View {
    var genre: String?
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var feed = PagedFeed<Album>(pageSize: 60)
    @State private var total = LibraryTotal()
    @State private var columns = 5
    @AppStorage("library.albumSort") private var sortName = LibraryAlbumSort.title.rawValue

    private var source: SourceID { model.browsingSourceID }
    private var browsing: (any LibraryBrowsingSource)? { model.source(source, as: (any LibraryBrowsingSource).self) }
    private var sort: LibraryAlbumSort {
        let sorts = browsing?.albumSorts ?? []
        return LibraryAlbumSort(rawValue: sortName).flatMap { sorts.contains($0) ? $0 : nil } ?? sorts.first ?? .title
    }
    private var sortBinding: Binding<LibraryAlbumSort> { Binding { sort } set: { sortName = $0.rawValue } }
    private var loadKey: String? { model.signedInUser != nil ? "\(model.homeKey)|\(sort.rawValue)|\(genre ?? "")" : nil }

    var body: some View {
        PageScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(title: genre ?? "专辑", stat: total.count.map { "\($0) 张专辑" }, statIcon: genre == nil ? "opticaldisc" : "guitars")
                    Spacer(minLength: 12)
                    if let browsing, browsing.albumSorts.count > 1 {
                        SettingsMenu(selection: sortBinding, options: browsing.albumSorts.map { ($0, $0.title) })
                            .help("排序")
                    }
                }
                .padding(.bottom, 22)
                if browsing == nil {
                    SourceLacks(feature: "专辑", systemName: "opticaldisc")
                } else if !model.isLoggedIn {
                    LoginPrompt()
                } else {
                    LibraryFeedContent(feed: feed, emptyTitle: "还没有专辑", systemName: "opticaldisc") {
                        LibraryCardRows(items: feed.items, columns: columns, loadMore: { Task { await feed.loadMore(pages: fetch) } }) { album in
                            CoverCard(title: album.name, subtitle: album.artists.map(\.name).joined(separator: " / "), artwork: album.artwork) {
                                model.navigate(.album(album))
                            } onPlay: {
                                LibraryPlayback.play(album, model: model)
                            }
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: Int.self) { LibraryCardRows<Album, EmptyView>.columns(for: $0.size.width) } action: { columns = $0 }
        .task(id: loadKey) {
            feed = PagedFeed(pageSize: 60)
            total.count = nil
            guard loadKey != nil else { return }
            await feed.load(pages: fetch)
        }
    }

    private var fetch: PagedFeed<Album>.PageFetch {
        let browsing = browsing, sort = sort, genre = genre, total = total
        return { page in
            guard let browsing else { throw SourceError.capabilityMissing("专辑") }
            let result = try await browsing.libraryAlbums(sort: sort, genre: genre, page: page)
            if page.offset == 0 { total.count = result.total ?? (result.hasMore ? nil : result.items.count) }
            return (result.items, result.hasMore ? Page(offset: page.offset + result.items.count, limit: page.limit) : nil)
        }
    }
}

struct LibraryArtistsPage: View {
    @Environment(AppModel.self) private var model
    @State private var feed = PagedFeed<Artist>(pageSize: 80)
    @State private var total = LibraryTotal()
    @State private var columns = 6

    private var source: SourceID { model.browsingSourceID }
    private var browsing: (any LibraryBrowsingSource)? { model.source(source, as: (any LibraryBrowsingSource).self) }

    var body: some View {
        PageScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "歌手", stat: total.count.map { "\($0) 位歌手" }, statIcon: "music.mic")
                    .padding(.bottom, 22)
                if browsing == nil {
                    SourceLacks(feature: "歌手", systemName: "music.mic")
                } else if !model.isLoggedIn {
                    LoginPrompt()
                } else {
                    LibraryFeedContent(feed: feed, emptyTitle: "还没有歌手", systemName: "music.mic") {
                        LibraryCardRows(items: feed.items, columns: columns, loadMore: { Task { await feed.loadMore(pages: fetch) } }) { artist in
                            // A server that counts albums only (Subsonic) shows those.
                            CoverCard(title: artist.name, subtitle: artist.songCount > 0 ? "\(artist.songCount) 首" : artist.albumCount > 0 ? "\(artist.albumCount) 张专辑" : nil, artwork: artist.artwork, circle: true) {
                                model.navigate(.artist(artist))
                            }
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: Int.self) { LibraryCardRows<Artist, EmptyView>.columns(for: $0.size.width, minCardWidth: 128) } action: { columns = $0 }
        .task(id: model.signedInUser != nil ? model.homeKey : nil) {
            feed = PagedFeed(pageSize: 80)
            total.count = nil
            guard model.signedInUser != nil else { return }
            await feed.load(pages: fetch)
        }
    }

    private var fetch: PagedFeed<Artist>.PageFetch {
        let browsing = browsing, total = total
        return { page in
            guard let browsing else { throw SourceError.capabilityMissing("歌手") }
            let result = try await browsing.libraryArtists(page: page)
            if page.offset == 0 { total.count = result.total }
            return (result.items, result.hasMore ? Page(offset: page.offset + result.items.count, limit: page.limit) : nil)
        }
    }
}

struct LibraryGenresPage: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<[LibraryGenre]> = .idle
    @State private var columns = 5

    private var source: SourceID { model.browsingSourceID }

    var body: some View {
        PageScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "流派", stat: state.value.map { "\($0.count) 种" }, statIcon: "guitars")
                    .padding(.bottom, 22)
                if !model.isLoggedIn {
                    LoginPrompt()
                } else {
                    genreGrid
                }
            }
        }
        .onGeometryChange(for: Int.self) { LibraryCardRows<LibraryGenre, EmptyView>.columns(for: $0.size.width) } action: { columns = $0 }
        .task(id: model.signedInUser != nil ? model.homeKey : nil) {
            if model.signedInUser != nil { await load() }
        }
    }

    private var genreGrid: some View {
        AsyncContent(state: state, retry: { Task { await load() } }) { genres in
            if genres.isEmpty {
                StateView(systemName: "guitars", title: "还没有流派", detail: "歌曲标签里写有流派时，会按流派列在这里")
            } else {
                LibraryCardRows(items: genres, columns: columns, loadMore: nil) { genre in
                    // No count from servers whose counts cannot be trusted (Ampache).
                    CoverCard(title: genre.name, subtitle: genre.albumCount > 0 ? "\(genre.albumCount) 张专辑" : nil, artwork: genre.artwork ?? Artwork(seed: genre.name)) {
                        model.navigate(.libraryAlbums(genre: genre.name))
                    }
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        state = await Loadable.run { try await model.require(source, as: (any LibraryBrowsingSource).self, "流派").libraryGenres() }
    }
}

struct LibraryFolderView: View {
    var path: String?
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var state: Loadable<LibraryFolderPage> = .idle

    private var source: SourceID { model.browsingSourceID }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                header
                AsyncContent(state: state, retry: { Task { await load() } }) { page in
                    content(page)
                }
            }
        }
        .task(id: "\(model.homeKey)|\(path ?? "")") { await load() }
    }

    private var page: LibraryFolderPage? { state.value }

    private var context: PlaybackContext {
        PlaybackContext(source: source, originType: .local, originID: path, originName: page?.title ?? "文件夹")
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trail = page?.trail, !trail.isEmpty {
                HStack(spacing: 4) {
                    Button("文件夹") { model.navigate(.libraryFolder(nil)) }
                        .buttonStyle(.plain)
                    ForEach(trail) { entry in
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        Button(entry.name) { model.navigate(.libraryFolder(entry.path)) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
            }
            PageTitle(title: page?.title ?? (path == nil ? "文件夹" : ""), stat: page.map { "\($0.songCount) 首歌曲" }, statIcon: "folder")
            HStack(spacing: 10) {
                PillButton(title: "播放全部", systemName: "play.fill") { playAll() }
                    .disabled((page?.songCount ?? 0) == 0)
                if let location = page?.location {
                    PillButton(title: "在访达中显示", systemName: "folder", variant: .tertiary) {
                        NSWorkspace.shared.activateFileViewerSelecting([location])
                    }
                }
                if path == nil, model.localSource != nil {
                    PillButton(title: "添加文件夹…", systemName: "plus", variant: .tertiary) { model.chooseLocalFolders() }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func content(_ page: LibraryFolderPage) -> some View {
        if page.folders.isEmpty, page.tracks.isEmpty {
            StateView(systemName: "folder", title: path == nil ? "还没有添加文件夹" : "这个文件夹里没有歌曲")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(page.folders) { entry in
                    FolderRow(entry: entry) { model.navigate(.libraryFolder(entry.path)) }
                }
            }
            if !page.tracks.isEmpty {
                SongList(tracks: page.tracks, context: context)
                    .padding(.top, page.folders.isEmpty ? 0 : 12)
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        state = await Loadable.run { try await model.require(source, as: (any LibraryBrowsingSource).self, "文件夹").libraryFolder(path) }
    }

    private func playAll() {
        guard let browsing = model.source(source, as: (any LibraryBrowsingSource).self), let page else { return }
        Task {
            var tracks = page.tracks
            if let path {
                tracks = (try? await browsing.libraryFolderSongs(path)) ?? tracks
            } else {
                for folder in page.folders { tracks += (try? await browsing.libraryFolderSongs(folder.path)) ?? [] }
            }
            guard !tracks.isEmpty else { return }
            model.player.play(tracks, context: context)
        }
    }
}

private struct FolderRow: View {
    var entry: LibraryFolderPage.Entry
    var open: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: entry.isOffline ? "externaldrive.badge.xmark" : "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(entry.isOffline ? theme.onSurfaceVariant : theme.accent.opacity(0.85))
                    .frame(width: 26)
                Text(entry.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(entry.isOffline ? "磁盘未连接" : "\(entry.songCount) 首")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(theme.onSurface.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

private struct LibraryFeedContent<Item: Identifiable, Content: View>: View {
    var feed: PagedFeed<Item>
    var emptyTitle: String
    var systemName: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch feed.phase {
        case .idle, .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message)
        case .loaded:
            if feed.items.isEmpty {
                StateView(systemName: systemName, title: emptyTitle)
            } else {
                content()
            }
        }
    }
}

enum LibraryPlayback {
    @MainActor
    static func play(_ album: Album, model: AppModel) {
        Task {
            do {
                let detail = try await model.catalog(album.source).album(id: album.id)
                model.player.play(detail.tracks, context: PlaybackContext(source: album.source, originType: .album, originID: album.id, originName: album.name))
            } catch {
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}
