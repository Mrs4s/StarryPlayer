import Foundation
import MusicSources
import os
import StarryCore

public struct LyricsProviderID: RawRepresentable, Sendable, Codable, Hashable, Identifiable {
    public static let netease = LyricsProviderID(known: "netease")
    public static let qqmusic = LyricsProviderID(known: "qqmusic")
    public static let kugou = LyricsProviderID(known: "kugou")

    public static let known: [LyricsProviderID] = [.netease, .qqmusic, .kugou]

    public let rawValue: String

    /// nil unless `rawValue` is a known platform's or a plugin's (`plugin:<id>`), so the other
    /// words a setting holds (`auto`, `self`) never read as a provider.
    public init?(rawValue: String) {
        guard Self.known.contains(where: { $0.rawValue == rawValue }) || Self.pluginID(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(known rawValue: String) {
        self.rawValue = rawValue
    }

    public init(plugin id: String) {
        rawValue = SourceID.plugin(id: id).key
    }

    public init?(source: SourceID) {
        self.init(rawValue: source.key)
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a lyrics provider: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var id: String { rawValue }

    public var sourceID: SourceID { SourceID(key: rawValue) ?? .plugin(id: rawValue) }

    public var displayName: String {
        switch self {
        case .netease: "网易云音乐"
        case .qqmusic: "QQ音乐"
        case .kugou: "酷狗音乐"
        default: Self.registered(self)?.name ?? rawValue
        }
    }

    public var detail: String? { Self.registered(self)?.detail }

    private static func pluginID(_ rawValue: String) -> String? {
        guard case .plugin(let id)? = SourceID(key: rawValue) else { return nil }
        return id
    }

    private struct Registration: Sendable {
        var name: String
        var detail: String?
    }

    private static let registrations = OSAllocatedUnfairLock(initialState: [LyricsProviderID: Registration]())

    public static func register(_ id: LyricsProviderID, name: String, detail: String?) {
        registrations.withLock { $0[id] = Registration(name: name, detail: detail) }
    }

    private static func registered(_ id: LyricsProviderID) -> Registration? {
        registrations.withLock { $0[id] }
    }
}

public struct LyricsSongRef: Sendable, Codable, Hashable {
    public var id: String
    /// A second id, when the platform has two; the AMLL TTML DB is asked with it
    /// before `id`.
    public var mid: String?
    public var title: String?
    public var duration: TimeInterval?

    public init(id: String, mid: String? = nil, title: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.mid = mid
        self.title = title
        self.duration = duration
    }
}

public struct ProviderLyrics: Sendable {
    public var raw: RawLyrics
    public var provider: LyricsProviderID
    public var song: LyricsSongRef

    public init(raw: RawLyrics, provider: LyricsProviderID, song: LyricsSongRef) {
        self.raw = raw
        self.provider = provider
        self.song = song
    }
}

public struct LyricsSearchResult: Sendable, Codable, Hashable, Identifiable {
    public var provider: LyricsProviderID
    public var song: LyricsSongRef
    public var title: String
    public var artists: [String]
    public var album: String?
    public var duration: TimeInterval?

    public init(provider: LyricsProviderID, song: LyricsSongRef, title: String, artists: [String], album: String? = nil, duration: TimeInterval? = nil) {
        self.provider = provider
        self.song = song
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
    }

    public var id: String { "\(provider.rawValue):\(song.id)" }
}

public protocol LyricsProvider: Sendable {
    var id: LyricsProviderID { get }
    var detail: String? { get }
    /// The AMLL TTML DB folder (`%p`) its songs' ids are keys in, when it has one: the ids of the
    /// songs it matches, and of the tracks of its own platform, are asked there.
    var ttmlFolder: String? { get }
    /// Lyrics for `track`: by id when the track is from this platform, otherwise by searching
    /// the platform and picking the matching recording.
    func lyrics(for track: Track) async throws -> ProviderLyrics?
    func searchSongs(_ keyword: String) async throws -> [LyricsSearchResult]
    func lyrics(of song: LyricsSongRef) async throws -> RawLyrics?
}

public extension LyricsProvider {
    var detail: String? { id.detail }
    var ttmlFolder: String? { nil }
}

protocol MatchingLyricsProvider: LyricsProvider {
    var cache: LyricsCache { get }
    func ownSong(of track: Track) -> LyricsSongRef?
    func search(keyword: String) async throws -> [LyricCandidate<LyricsSongRef>]
    func fetch(_ song: LyricsSongRef) async throws -> RawLyrics?
}

extension MatchingLyricsProvider {
    func matchedLyrics(for track: Track) async throws -> ProviderLyrics? {
        guard let song = try await song(for: track) else { return nil }
        return try await cachedLyrics(of: song).map { ProviderLyrics(raw: $0, provider: id, song: song) }
    }

    func cachedLyrics(of song: LyricsSongRef) async throws -> RawLyrics? {
        try await cache.lyrics(provider: id, songID: song.id) { try await fetch(song) }
    }

    func song(for track: Track) async throws -> LyricsSongRef? {
        if let own = ownSong(of: track) { return own }
        let query = LyricQuery(track: track)
        let fingerprint = LyricCandidateMatcher.fingerprint(for: query)
        return try await cache.match(provider: id, fingerprint: fingerprint) {
            guard let best = LyricCandidateMatcher.best(try await search(keyword: LyricCandidateMatcher.searchKeyword(for: query)), for: query) else { return nil }
            return Self.song(best)
        }
    }

    func searchResults(_ keyword: String) async throws -> [LyricsSearchResult] {
        try await search(keyword: keyword).map { candidate in
            LyricsSearchResult(provider: id, song: Self.song(candidate), title: candidate.title, artists: candidate.artists, album: candidate.album, duration: candidate.duration)
        }
    }

    private static func song(_ candidate: LyricCandidate<LyricsSongRef>) -> LyricsSongRef {
        var song = candidate.payload
        song.title = song.title ?? candidate.title
        song.duration = song.duration ?? candidate.duration
        return song
    }
}
