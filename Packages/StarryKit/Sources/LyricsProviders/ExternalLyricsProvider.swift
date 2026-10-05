import Foundation
import MusicSources
import StarryCore

public struct ExternalLyricsProvider: MatchingLyricsProvider {
    public struct Hit: Sendable {
        public var song: LyricsSongRef
        public var title: String
        public var artists: [String]
        public var album: String?
        public var duration: TimeInterval?

        public init(song: LyricsSongRef, title: String, artists: [String], album: String? = nil, duration: TimeInterval? = nil) {
            self.song = song
            self.title = title
            self.artists = artists
            self.album = album
            self.duration = duration
        }
    }

    public let id: LyricsProviderID
    public let ttmlFolder: String?
    let cache: LyricsCache
    private let searchSongs: @Sendable (String) async throws -> [Hit]
    private let fetchLyrics: @Sendable (LyricsSongRef) async throws -> RawLyrics?

    public init(id: LyricsProviderID, ttmlFolder: String? = nil, cache: LyricsCache, search: @escaping @Sendable (String) async throws -> [Hit], fetch: @escaping @Sendable (LyricsSongRef) async throws -> RawLyrics?) {
        self.id = id
        self.ttmlFolder = ttmlFolder
        self.cache = cache
        searchSongs = search
        fetchLyrics = fetch
    }

    public func lyrics(for track: Track) async throws -> ProviderLyrics? {
        try await matchedLyrics(for: track)
    }

    public func searchSongs(_ keyword: String) async throws -> [LyricsSearchResult] {
        try await searchResults(keyword)
    }

    public func lyrics(of song: LyricsSongRef) async throws -> RawLyrics? {
        try await cachedLyrics(of: song)
    }

    func ownSong(of track: Track) -> LyricsSongRef? {
        track.id.source == id.sourceID ? LyricsSongRef(id: track.id.id, title: track.title, duration: track.duration) : nil
    }

    func search(keyword: String) async throws -> [LyricCandidate<LyricsSongRef>] {
        try await searchSongs(keyword).map { hit in
            LyricCandidate(title: hit.title, artists: hit.artists, album: hit.album, duration: hit.duration, payload: hit.song)
        }
    }

    func fetch(_ song: LyricsSongRef) async throws -> RawLyrics? {
        try await fetchLyrics(song)
    }
}
