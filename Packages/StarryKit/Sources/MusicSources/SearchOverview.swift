import Foundation
import StarryCore

public struct SearchOverview: Sendable {
    public enum TopResult: Sendable, Hashable {
        case song(Track)
        case artist(Artist)
        case album(Album)
        case playlist(Playlist)
    }

    public var topResult: TopResult?
    public var songs: [Track]
    public var artists: [Artist]
    public var albums: [Album]
    public var playlists: [Playlist]

    public init(topResult: TopResult? = nil, songs: [Track] = [], artists: [Artist] = [], albums: [Album] = [], playlists: [Playlist] = []) {
        self.topResult = topResult
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.playlists = playlists
    }

    public var isEmpty: Bool {
        topResult == nil && songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }

    /// The result whose name is the query (ignoring case, width and spaces): an artist first,
    /// then a song, then an album; else the first song. Nil with nothing found.
    public static func guessTopResult(for query: String, in overview: SearchOverview) -> TopResult? {
        let key = matchKey(query)
        let names = { (artist: Artist) in [artist.name] + (artist.alias?.components(separatedBy: " / ") ?? []) }
        if let artist = overview.artists.first(where: { names($0).contains { matchKey($0) == key } }) {
            return .artist(artist)
        }
        if let song = overview.songs.first(where: { matchKey($0.title) == key }) { return .song(song) }
        if let album = overview.albums.first(where: { matchKey($0.name) == key }) { return .album(album) }
        if let song = overview.songs.first { return .song(song) }
        if let artist = overview.artists.first { return .artist(artist) }
        if let album = overview.albums.first { return .album(album) }
        return overview.playlists.first.map { .playlist($0) }
    }

    static func matchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
    }
}

public struct SearchTrend: Sendable, Hashable {
    public enum Badge: String, Sendable {
        case hot
        case new
        case surging
        case rising
    }

    public var query: String
    public var badge: Badge?

    public init(query: String, badge: Badge? = nil) {
        self.query = query
        self.badge = badge
    }
}

public struct SearchHint: Sendable, Hashable {
    public var display: String
    public var query: String

    public init(display: String, query: String) {
        self.display = display
        self.query = query
    }
}
