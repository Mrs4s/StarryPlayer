import Foundation
import MusicSources
import StarryCore

enum Route: Hashable {
    case home
    case liked
    case history
    case daily
    case allMedia
    case collection(Playlist)
    case album(Album)
    case artist(Artist)
    case search(String)
    case user(UserProfile)
    /// The library (`LibraryBrowsingSource`): the browsing source's albums (of a genre), artists,
    /// genres, and its folders (a folder's path; nil for the top).
    case libraryAlbums(genre: String?)
    case libraryArtists
    case libraryGenres
    case libraryFolder(String?)

    var title: String {
        switch self {
        case .home: "首页"
        case .liked: "我喜欢的音乐"
        case .history: "最近播放"
        case .daily: "每日推荐"
        case .allMedia: "所有媒体"
        case .collection(let playlist): playlist.name
        case .album(let album): album.name
        case .artist(let artist): artist.name
        case .search(let query): "搜索：\(query)"
        case .user(let user): user.nickname
        case .libraryAlbums(let genre): genre ?? "专辑"
        case .libraryArtists: "歌手"
        case .libraryGenres: "流派"
        case .libraryFolder: "文件夹"
        }
    }

    func isSamePage(as other: Route) -> Bool {
        switch (self, other) {
        case let (.collection(a), .collection(b)): a.source == b.source && a.id == b.id
        case let (.album(a), .album(b)): a.source == b.source && a.id == b.id
        case let (.artist(a), .artist(b)): a.source == b.source && a.id == b.id
        case let (.user(a), .user(b)): a.source == b.source && a.id == b.id
        default: self == other
        }
    }
}

struct HistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let route: Route
}

/// Back history as a stack: the current page on top, each page in it once. There is no forward —
/// going back drops the page it leaves — so only pages behind the current one are kept alive.
struct NavigationHistory {
    static let keptAlive = 8

    private(set) var entries: [HistoryEntry]
    /// Entries whose pages are mounted, in history order: the current one and up to `keptAlive`
    /// it was opened over. A page evicted from here is built again only once it is back on top,
    /// so going back does not mount (and load) the page that comes into the window behind.
    private(set) var live: [HistoryEntry]

    init() {
        entries = [HistoryEntry(route: .home)]
        live = entries
    }

    var current: HistoryEntry { entries[entries.count - 1] }
    var canGoBack: Bool { entries.count > 1 }

    /// Pushes `route`. A page already in the history is not opened again: its entry moves to the
    /// top, so a page still kept alive comes back as it was left — scroll offset, loaded data,
    /// tabs — and keeps the metadata it was opened with.
    mutating func open(_ route: Route) {
        guard !route.isSamePage(as: current.route) else { return }
        let index = entries.firstIndex { $0.route.isSamePage(as: route) }
        let entry = index.map { entries.remove(at: $0) } ?? HistoryEntry(route: route)
        entries.append(entry)
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        live.removeAll { $0.id == entry.id }
        live.append(entry)
        if live.count > Self.keptAlive + 1 { live.removeFirst(live.count - Self.keptAlive - 1) }
    }

    mutating func goBack() {
        guard canGoBack else { return }
        entries.removeLast()
        live.removeLast()
        if live.last?.id != current.id { live.append(current) }
    }
}
