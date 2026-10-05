import Foundation
import StarryCore

/// The grids of a source's whole library: its albums, artists, genres and folders, for a
/// library the listener owns (local files, a server of their own) rather than a streaming
/// catalogue. Each part is optional; `librarySections` says which the source has.
public protocol LibraryBrowsingSource: MusicSource {
    var librarySections: [LibrarySection] { get }
    var albumSorts: [LibraryAlbumSort] { get }
    func libraryAlbums(sort: LibraryAlbumSort, genre: String?, page: Page) async throws -> LibraryPage<Album>
    func libraryArtists(page: Page) async throws -> LibraryPage<Artist>
    func libraryGenres() async throws -> [LibraryGenre]
    /// A folder's subfolders and songs; nil for the top (the library's folders).
    func libraryFolder(_ path: String?) async throws -> LibraryFolderPage
    func libraryFolderSongs(_ path: String) async throws -> [Track]
}

public extension LibraryBrowsingSource {
    var albumSorts: [LibraryAlbumSort] { [.title] }
    func libraryGenres() async throws -> [LibraryGenre] { [] }
    func libraryFolder(_ path: String?) async throws -> LibraryFolderPage { LibraryFolderPage(path: nil, title: "") }
    func libraryFolderSongs(_ path: String) async throws -> [Track] { [] }
}

public enum LibrarySection: String, Sendable, CaseIterable, Hashable {
    case albums, artists, genres, folders
}

public enum LibraryAlbumSort: String, Sendable, CaseIterable, Hashable {
    case title, artist, year, recentlyAdded

    public var title: String {
        switch self {
        case .title: "名称"
        case .artist: "歌手"
        case .year: "年份"
        case .recentlyAdded: "最近添加"
        }
    }
}

public struct LibraryPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var total: Int?
    public var hasMore: Bool

    public init(items: [Item], total: Int? = nil, hasMore: Bool) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
    }
}

public struct LibraryGenre: Sendable, Hashable, Identifiable {
    public var name: String
    public var albumCount: Int
    public var artwork: Artwork?

    public init(name: String, albumCount: Int, artwork: Artwork? = nil) {
        self.name = name
        self.albumCount = albumCount
        self.artwork = artwork
    }

    public var id: String { name }
}

public struct LibraryFolderPage: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var path: String
        public var name: String
        public var songCount: Int
        /// Its volume is not there now.
        public var isOffline: Bool

        public init(path: String, name: String, songCount: Int, isOffline: Bool = false) {
            self.path = path
            self.name = name
            self.songCount = songCount
            self.isOffline = isOffline
        }

        public var id: String { path }
    }

    /// nil at the top.
    public var path: String?
    public var title: String
    public var trail: [Entry]
    public var folders: [Entry]
    public var tracks: [Track]
    public var songCount: Int
    public var location: URL?

    public init(path: String?, title: String, trail: [Entry] = [], folders: [Entry] = [], tracks: [Track] = [], songCount: Int = 0, location: URL? = nil) {
        self.path = path
        self.title = title
        self.trail = trail
        self.folders = folders
        self.tracks = tracks
        self.songCount = songCount
        self.location = location
    }
}
