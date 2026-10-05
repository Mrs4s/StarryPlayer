import Foundation
import MusicSources
import StarryCore

/// Asks the track's own source for lyrics: tracks from sources that are not lyric platforms
/// (self-hosted servers, local files) and the "follow the track's source" preference.
/// Uncached, since such sources are local or already cache on their side.
public struct TrackSourceLyricsProvider: Sendable {
    private let lookup: @Sendable (SourceID) async -> (any MusicSource)?

    public init(lookup: @escaping @Sendable (SourceID) async -> (any MusicSource)?) {
        self.lookup = lookup
    }

    public func lyrics(for track: Track) async throws -> RawLyrics? {
        guard let source = await lookup(track.id.source)?.capability((any LyricsSource).self) else { return nil }
        if let hit = try await source.lyrics(for: track.id) { return hit }
        return try await source.lyrics(matching: LyricQuery(track: track))
    }
}
