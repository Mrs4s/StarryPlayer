import Foundation
import LyricsProviders
import MusicSources
import StarryCore
import Testing
@testable import PluginHost

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLUGINS_LIVE"] != nil), .serialized)
struct ExamplePluginLiveTests {
    static func plugin(_ name: String) throws -> Plugin {
        try Plugin.load(file: Fixture.examples.appending(path: name), options: Plugin.Options(appVersion: "live-test"))
    }

    @Test func lrclibFindsSyncedLyrics() async throws {
        let plugin = try Self.plugin("lrclib.js")
        let provider = try #require(plugin.lyricsProvider(cache: LyricsCache(directory: nil)))
        let track = Track(id: TrackRef(source: .local, id: "/Music/晴天.flac"), title: "晴天", artists: [ArtistRef(id: "a", name: "周杰伦")], album: AlbumRef(id: "b", name: "叶惠美"), duration: 269)
        let found = try #require(try await provider.lyrics(for: track))
        print("lrclib:", found.song, found.raw.body.prefix(120))
        #expect(found.raw.format == .lrc)
        #expect(found.raw.body.contains("["))
    }

    @Test func audiusSearchesAndPlays() async throws {
        let source = PluginSource(plugin: try Self.plugin("audius.js"), settings: SourceSettingValues())
        let page = try await source.search("lofi", kind: .song, page: Page(offset: 0, limit: 10))
        print("audius songs:", page.songs.map { "\($0.title) — \($0.artistText)" }.prefix(5))
        let song = try #require(page.songs.first)
        let asset = try await source.resolvePlayableAsset(song, tier: source.tiers[0])
        print("audius asset:", asset.url.host() ?? "-", asset.container)
        #expect(asset.container == .mp3)
        var request = URLRequest(url: asset.url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect([200, 206].contains((response as? HTTPURLResponse)?.statusCode ?? 0))
        #expect(data.count > 0)

        let artistID = try #require(song.artists.first?.id)
        let artist = try await source.artist(id: artistID)
        #expect(!artist.artist.name.isEmpty)
        let playlists = try await source.recommendedPlaylists()
        let playlistID = try #require(playlists.first?.id)
        let playlist = try await source.playlist(id: playlistID)
        print("audius playlist:", playlist.playlist.name, playlist.tracks.count, "tracks")
        #expect(!playlist.tracks.isEmpty)
        let again = try await source.songs(ids: playlist.tracks.prefix(2).map(\.id.id))
        #expect(again.map(\.id) == Array(playlist.tracks.prefix(2).map(\.id)))
    }
}
