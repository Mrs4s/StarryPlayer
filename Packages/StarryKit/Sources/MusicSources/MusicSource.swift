import Foundation
import StarryCore

/// The single protocol every source implements. Extra abilities are opt-in sub-protocols,
/// discovered at runtime with `as?`; the UI shows a feature only for a source that has it, so
/// a source implements just what its platform offers and never stubs the rest.
public protocol MusicSource: AnyObject, Sendable {
    var id: SourceID { get }
    var displayName: String { get }

    /// Resolve a fresh playable asset of `tier` (one of `qualityTiers`), or of a lower one of the
    /// source's when the song or the account does not have it. Called late (armed stage)
    /// because direct links expire. Receives the whole `Track` so the source can use `fee` /
    /// `availableTiers` for error reporting.
    func resolvePlayableAsset(_ track: Track, tier: QualityTier) async throws -> PlayableAsset

    /// The item's page on the platform's website (copy link, open in browser); nil when it has none.
    func webURL(for page: WebPage) -> URL?

    var qualityTiers: [QualityTier] { get }

    var offersQualityChoice: Bool { get }

    /// Use `capability` rather than a cast: plugins conform to all source protocols
    /// but enable only the capabilities declared at runtime.
    func capability<T>(_ type: T.Type) -> T?
}

public extension MusicSource {
    func webURL(for page: WebPage) -> URL? { nil }
    var qualityTiers: [QualityTier] { [] }
    var offersQualityChoice: Bool { true }
    func capability<T>(_ type: T.Type) -> T? { self as? T }

    func supports<T>(_ type: T.Type) -> Bool { capability(type) != nil }

    var tiers: [QualityTier] {
        let own = qualityTiers
        return own.isEmpty ? AudioQuality.allCases.map { QualityTier($0) } : own
    }

    /// The tier the global preference stands for here: the best one that is not a spatial mix
    /// and counts as `level` or less (the lowest when every tier counts as more).
    func tier(for level: AudioQuality) -> QualityTier {
        let stereo = tiers.filter { !$0.isSpatial }
        return stereo.last { $0.level <= level } ?? stereo.first ?? QualityTier(level)
    }

    func requestedTier(preferred level: AudioQuality, override: String?) -> QualityTier {
        if let override, let tier = tiers.first(where: { $0.id == override }) { return tier }
        return tier(for: level)
    }
}

public enum WebPage: Sendable, Hashable {
    case song(String)
    case playlist(String)
    case album(String)
    case artist(String)
    case user(String)
}

public enum SearchKind: String, Sendable, CaseIterable {
    case song, album, artist, playlist
    case user
}

public struct SearchPage: Sendable {
    public var songs: [Track]
    public var albums: [Album]
    public var artists: [Artist]
    public var playlists: [Playlist]
    public var users: [UserProfile]
    public var hasMore: Bool
    /// Where the next page starts. A source may return fewer items than asked for, so it
    /// follows what came back, not the asked limit.
    public var nextPage: Page?
    public var total: Int?

    public init(songs: [Track] = [], albums: [Album] = [], artists: [Artist] = [], playlists: [Playlist] = [], users: [UserProfile] = [], hasMore: Bool = false, nextPage: Page? = nil, total: Int? = nil) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.users = users
        self.hasMore = hasMore
        self.nextPage = nextPage
        self.total = total
    }

    public var count: Int { songs.count + albums.count + artists.count + playlists.count + users.count }

    public static let empty = SearchPage()
}

public protocol SearchableSource: MusicSource {
    var searchKinds: [SearchKind] { get }
    func search(_ query: String, kind: SearchKind, page: Page) async throws -> SearchPage
    /// Queries completing what has been typed so far.
    func searchSuggestions(_ prefix: String) async throws -> [String]
    func searchOverview(_ query: String) async throws -> SearchOverview
    func trendingSearches() async throws -> [SearchTrend]
    func searchHints() async throws -> [SearchHint]
}

public extension SearchableSource {
    func searchSuggestions(_ prefix: String) async throws -> [String] { [] }
    func searchOverview(_ query: String) async throws -> SearchOverview { try await composedOverview(query) }
    func trendingSearches() async throws -> [SearchTrend] { [] }
    func searchHints() async throws -> [SearchHint] { [] }

    /// An overview from the four typed searches, for a source without an overview of its own: the
    /// first page of songs (required) with whatever the other three return, and the top result
    /// guessed from exact names (`SearchOverview.guessTopResult`).
    func composedOverview(_ query: String) async throws -> SearchOverview {
        async let artists = try? search(query, kind: .artist, page: Page(offset: 0, limit: 10))
        async let albums = try? search(query, kind: .album, page: Page(offset: 0, limit: 10))
        async let playlists = try? search(query, kind: .playlist, page: Page(offset: 0, limit: 10))
        let songs = try await search(query, kind: .song, page: Page(offset: 0, limit: 10)).songs
        var overview = SearchOverview(
            songs: songs,
            artists: await artists?.artists ?? [],
            albums: await albums?.albums ?? [],
            playlists: await playlists?.playlists ?? []
        )
        overview.topResult = SearchOverview.guessTopResult(for: query, in: overview)
        return overview
    }
}

public struct PlaylistDetail: Sendable {
    public var playlist: Playlist
    public var tracks: [Track]
    public var pendingTrackIDs: [String]
    /// Counters the source keeps for the playlist; nil when it has none.
    public var subscribedCount: Int?
    public var commentCount: Int?
    public var isSubscribed: Bool?

    public init(playlist: Playlist, tracks: [Track], pendingTrackIDs: [String] = [], subscribedCount: Int? = nil, commentCount: Int? = nil, isSubscribed: Bool? = nil) {
        self.playlist = playlist
        self.tracks = tracks
        self.pendingTrackIDs = pendingTrackIDs
        self.subscribedCount = subscribedCount
        self.commentCount = commentCount
        self.isSubscribed = isSubscribed
    }
}

public struct AlbumDetail: Sendable {
    public var album: Album
    public var tracks: [Track]
    /// Counters the source keeps for the album; nil when it has none or the call failed.
    public var subscribedCount: Int?
    public var commentCount: Int?
    public var isSubscribed: Bool?

    public init(album: Album, tracks: [Track], subscribedCount: Int? = nil, commentCount: Int? = nil, isSubscribed: Bool? = nil) {
        self.album = album
        self.tracks = tracks
        self.subscribedCount = subscribedCount
        self.commentCount = commentCount
        self.isSubscribed = isSubscribed
    }
}

public struct ArtistDetail: Sendable {
    public struct Section: Hashable, Sendable {
        public var title: String
        public var text: String

        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    public var artist: Artist
    public var topTracks: [Track]
    public var photo: Artwork?
    public var videoCount: Int?
    public var isFollowed: Bool?
    public var introduction: [Section]

    public init(artist: Artist, topTracks: [Track] = [], photo: Artwork? = nil, videoCount: Int? = nil, isFollowed: Bool? = nil, introduction: [Section] = []) {
        self.artist = artist
        self.topTracks = topTracks
        self.photo = photo
        self.videoCount = videoCount
        self.isFollowed = isFollowed
        self.introduction = introduction
    }
}

public enum ArtistSongOrder: String, Sendable, CaseIterable {
    case hot
    case time
}

public protocol CatalogSource: MusicSource {
    /// First order is the default.
    var artistSongOrders: [ArtistSongOrder] { get }
    func songs(ids: [String]) async throws -> [Track]
    func album(id: String) async throws -> AlbumDetail
    func artist(id: String) async throws -> ArtistDetail
    func artistSongs(id: String, order: ArtistSongOrder, page: Page) async throws -> [Track]
    func artistAlbums(id: String, page: Page) async throws -> [Album]
    func similarArtists(id: String) async throws -> [Artist]
    func playlist(id: String) async throws -> PlaylistDetail
}

public extension CatalogSource {
    func similarArtists(id: String) async throws -> [Artist] { [] }
}

public protocol UserLibrarySource: MusicSource {
    func likedTrackIDs() async throws -> [String]
    func setLiked(_ track: TrackRef, liked: Bool) async throws
    func userPlaylists() async throws -> [Playlist]
    /// The playlist holding the liked songs, when the source keeps them as one; nil when it does not, and the liked page lists `likedTrackIDs` instead.
    func likedPlaylistID() async throws -> String?
}

public extension UserLibrarySource {
    func likedPlaylistID() async throws -> String? { nil }
}

public enum CollectionItem: Hashable, Sendable {
    case playlist(String)
    case album(String)
    case artist(String)

    public enum Kind: Hashable, Sendable, CaseIterable {
        case playlist, album, artist
    }

    public var kind: Kind {
        switch self {
        case .playlist: .playlist
        case .album: .album
        case .artist: .artist
        }
    }
}

public struct PlaylistDraft: Hashable, Sendable {
    public var name: String
    public var description: String?
    public var isPrivate: Bool?

    public init(name: String, description: String? = nil, isPrivate: Bool? = nil) {
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
    }
}

public struct PlaylistChanges: Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var isPrivate: Bool?

    public init(name: String? = nil, description: String? = nil, isPrivate: Bool? = nil) {
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
    }

    public var isEmpty: Bool { name == nil && description == nil && isPrivate == nil }
}

public struct PlaylistEditing: Hashable, Sendable {
    public var canCreate = false
    public var canEdit = false
    public var canDelete = false
    public var canAdd = false
    public var canRemove = false
    public var canReorder = false
    public var keepsDescription = false
    public var keepsPrivacy = false
    /// A new playlist starts private (a server's playlists are its owner's until shared).
    public var privateByDefault = false
    /// A public playlist cannot be made private again.
    public var publicIsFinal = false
    /// The longest name it takes, in characters; nil when it does not say.
    public var nameLimit: Int?

    public init() {}
}

public protocol PlaylistEditingSource: MusicSource {
    var playlistEditing: PlaylistEditing { get }
    func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist
    func editPlaylist(_ id: String, changes: PlaylistChanges) async throws
    func deletePlaylist(_ id: String) async throws
    func addTracks(_ trackIDs: [String], toPlaylist id: String) async throws -> Int
    func removeTracks(_ trackIDs: [String], fromPlaylist id: String) async throws
    func reorderPlaylist(_ id: String, trackIDs: [String]) async throws
}

public protocol CollectionSource: MusicSource {
    var collectableKinds: Set<CollectionItem.Kind> { get }
    func setCollected(_ item: CollectionItem, collected: Bool) async throws
}

public enum RadioMode: Sendable, CaseIterable {
    case `default`
    case familiar
    case explore
    case scene
    case puzzle
}

public protocol RadioSource: MusicSource {
    func personalFM(mode: RadioMode, firstFetch: Bool) async throws -> [Track]
    func skipFM(_ track: TrackRef, playedSeconds: TimeInterval) async throws
    func trashFM(_ track: TrackRef, playedSeconds: TimeInterval) async throws
}

public extension RadioSource {
    func skipFM(_ track: TrackRef, playedSeconds: TimeInterval) async throws {}
}

public struct TrackPage: Sendable {
    public var tracks: [Track]
    public var total: Int?
    public var hasMore: Bool
    /// Where the next page starts, when it is not the page's offset plus the songs in it (the
    /// source left out entries it could not make songs of).
    public var nextOffset: Int?

    public init(tracks: [Track], total: Int? = nil, hasMore: Bool, nextOffset: Int? = nil) {
        self.tracks = tracks
        self.total = total
        self.hasMore = hasMore
        self.nextOffset = nextOffset
    }
}

/// All media: every song the account keeps on the platform — the songs it uploaded, or a
/// server's whole library — a page at a time.
public protocol AllMediaSource: MusicSource {
    func allMedia(page: Page) async throws -> TrackPage
}

/// What a comment thread hangs off.
public enum CommentTarget: Hashable, Sendable {
    case song(String)
    case album(String)
    case playlist(String)
}

public struct Comment: Identifiable, Hashable, Sendable {
    public struct Quote: Hashable, Sendable {
        public var commentID: String?
        /// The quoted comment's author, for their page; nil when the source does not say.
        public var userID: String?
        public var userName: String
        public var content: String

        public init(commentID: String? = nil, userID: String? = nil, userName: String, content: String) {
            self.commentID = commentID
            self.userID = userID
            self.userName = userName
            self.content = content
        }
    }

    public var id: String
    /// The author, for their page; nil when the source does not say.
    public var userID: String?
    public var userName: String
    public var avatar: Artwork?
    public var content: String
    public var time: Date
    public var likedCount: Int
    public var isLiked: Bool
    public var location: String?
    public var replyTo: Quote?
    /// Replies under this comment (threaded replies); 0 when there are none or the source
    /// does not say.
    public var replyCount: Int

    public init(id: String, userID: String? = nil, userName: String, avatar: Artwork? = nil, content: String, time: Date, likedCount: Int = 0, isLiked: Bool = false, location: String? = nil, replyTo: Quote? = nil, replyCount: Int = 0) {
        self.id = id
        self.userID = userID
        self.userName = userName
        self.avatar = avatar
        self.content = content
        self.time = time
        self.likedCount = likedCount
        self.isLiked = isLiked
        self.location = location
        self.replyTo = replyTo
        self.replyCount = replyCount
    }
}

public struct CommentPage: Sendable {
    /// Only the first page includes hot comments.
    public var hot: [Comment]
    public var latest: [Comment]
    public var total: Int
    public var hasMore: Bool

    public init(hot: [Comment] = [], latest: [Comment] = [], total: Int = 0, hasMore: Bool = false) {
        self.hot = hot
        self.latest = latest
        self.total = total
        self.hasMore = hasMore
    }
}

/// The orders a thread can be read in (recommended / hottest / newest).
public enum CommentSort: String, Sendable, CaseIterable, Hashable {
    case recommended, hot, latest
}

/// One page of a sorted thread, or of the replies under a comment.
public struct CommentSlice: Sendable {
    public var comments: [Comment]
    /// Comments in the thread, or replies under the comment.
    public var total: Int
    /// Where the next page starts, for the next call; nil when this was the last.
    public var next: String?

    public init(comments: [Comment] = [], total: Int = 0, next: String? = nil) {
        self.comments = comments
        self.total = total
        self.next = next
    }
}

public protocol CommentSource: MusicSource {
    /// The orders `comments(on:sort:cursor:limit:)` reads a thread in, the first being the
    /// default; the panel offers a switch only when there is more than one.
    var commentSorts: [CommentSort] { get }
    var canLikeComments: Bool { get }
    func comments(on target: CommentTarget, page: Page) async throws -> CommentPage
    /// The thread in `sort` order, one page from `cursor` (nil for the first).
    func comments(on target: CommentTarget, sort: CommentSort, cursor: String?, limit: Int) async throws -> CommentSlice
    /// The replies under a comment, one page from `cursor` (nil for the first).
    func replies(to commentID: String, on target: CommentTarget, cursor: String?, limit: Int) async throws -> CommentSlice
    func setCommentLiked(_ commentID: String, on target: CommentTarget, liked: Bool) async throws
}

public extension CommentSource {
    var canLikeComments: Bool { false }
    /// A source without threaded replies reports `replyCount` 0, so this is never asked.
    func replies(to commentID: String, on target: CommentTarget, cursor: String?, limit: Int) async throws -> CommentSlice { CommentSlice() }
    func setCommentLiked(_ commentID: String, on target: CommentTarget, liked: Bool) async throws {
        throw SourceError.notImplemented("评论点赞")
    }
}

/// Discovery feeds for Home; they work anonymously. A source fills the shelves it has, and an
/// empty shelf is not shown.
public protocol RecommendationSource: MusicSource {
    func recommendedPlaylists() async throws -> [Playlist]
    func newSongs() async throws -> [Track]
    func newAlbums(page: Page) async throws -> [Album]
    func topArtists(page: Page) async throws -> [Artist]
}

public extension RecommendationSource {
    func recommendedPlaylists() async throws -> [Playlist] { [] }
    func newSongs() async throws -> [Track] { [] }
    func newAlbums(page: Page) async throws -> [Album] { [] }
    func topArtists(page: Page) async throws -> [Artist] { [] }
}

/// A shelf of Home the source names itself (a server's recently added, most played…): one kind of item.
public struct HomeShelf: Sendable, Equatable, Identifiable {
    public enum Items: Sendable, Equatable {
        case songs([Track])
        case albums([Album])
        case artists([Artist])
        case playlists([Playlist])

        public var isEmpty: Bool {
            switch self {
            case .songs(let items): items.isEmpty
            case .albums(let items): items.isEmpty
            case .artists(let items): items.isEmpty
            case .playlists(let items): items.isEmpty
            }
        }
    }

    public var id: String
    public var title: String
    public var items: Items

    public init(id: String, title: String, items: Items) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Home's shelves in the source's own words, after the discovery shelves
/// (`RecommendationSource`) when it has those too: for a library whose shelves are not a
/// streaming service's (new songs, new albums).
public protocol HomeShelfSource: MusicSource {
    func homeShelves() async throws -> [HomeShelf]
}

public protocol DailyRecommendationSource: MusicSource {
    func dailyRecommendations() async throws -> [Track]
    func dailyPlaylists() async throws -> [Playlist]
}

public extension DailyRecommendationSource {
    func dailyPlaylists() async throws -> [Playlist] { [] }
}

public struct RawLyrics: Sendable, Hashable, Codable {
    public enum Format: String, Sendable, Codable, CaseIterable {
        case ttml, yrc, qrc, krc, lrc
    }

    public var format: Format
    public var body: String
    public var translation: String?
    public var romanization: String?
    public var providerName: String

    public init(format: Format, body: String, translation: String? = nil, romanization: String? = nil, providerName: String) {
        self.format = format
        self.body = body
        self.translation = translation
        self.romanization = romanization
        self.providerName = providerName
    }
}

public struct LyricQuery: Sendable, Hashable {
    public var title: String
    public var artists: [String]
    public var album: String?
    public var duration: TimeInterval?

    public init(title: String, artists: [String] = [], album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
    }

    public init(title: String, artist: String?, album: String? = nil, duration: TimeInterval? = nil) {
        self.init(title: title, artists: artist.map { [$0] } ?? [], album: album, duration: duration)
    }

    public init(track: Track) {
        self.init(title: track.title, artists: track.artists.map(\.name), album: track.album?.name, duration: track.duration > 0 ? track.duration : nil)
    }

    public var artist: String? { artists.first }
}

public protocol LyricsSource: MusicSource {
    func lyrics(for track: TrackRef) async throws -> RawLyrics?
    func lyrics(matching query: LyricQuery) async throws -> RawLyrics?
}

public protocol ScrobblingSource: MusicSource {
    func reportPlayback(_ report: PlaybackReport) async
}
