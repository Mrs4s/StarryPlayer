import Foundation
import LyricsCore
import LyricsProviders
import MusicSources
@testable import PluginHost
import StarryCore
import Testing

/// `JELLYFIN_LIVE=<server> [JELLYFIN_USER=…] [JELLYFIN_PASSWORD=…] swift test --filter JellyfinPluginLive`:
/// the Jellyfin plugin against a real server (a local one in Docker, or
/// `https://demo.jellyfin.org/stable` with the user `demo`). It only reads.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JELLYFIN_LIVE"] != nil), .serialized)
struct JellyfinPluginLiveTests {
    static let environment = ProcessInfo.processInfo.environment

    /// A fresh plugin signed in to the server.
    static func signedIn() async throws -> PluginSource {
        let source = PluginSource(plugin: try Plugin.load(file: JellyfinPluginTests.file, options: Plugin.Options(appVersion: "live")), settings: SourceSettingValues())
        let server = try await source.account.connect(to: environment["JELLYFIN_LIVE"] ?? "")
        print("jellyfin: \(server.name ?? "-") \(server.version ?? "-") at \(server.address), ways \(server.methods ?? [])")
        try await source.account.loginWithPassword(username: environment["JELLYFIN_USER"] ?? "demo", password: environment["JELLYFIN_PASSWORD"] ?? "")
        return source
    }

    static func everySong(_ source: PluginSource) async throws -> [Track] {
        var tracks: [Track] = []
        var offset = 0
        while true {
            let page = try await source.allMedia(page: Page(offset: offset, limit: 200))
            tracks += page.tracks
            guard page.hasMore, let next = page.nextOffset, next > offset else { return tracks }
            offset = next
        }
    }

    @Test func browses() async throws {
        let source = try await Self.signedIn()
        guard case .loggedIn(let profile) = await source.account.state else { Issue.record("not signed in"); return }
        print("account:", profile.userID, profile.nickname, profile.detail ?? "-")
        #expect(profile.detail != nil)

        let tracks = try await Self.everySong(source)
        print("all media:", tracks.count, "songs")
        #expect(!tracks.isEmpty)
        let shelves = try await source.homeShelves()
        print("home:", shelves.map { "\($0.title)" })
        #expect(!shelves.isEmpty)

        let song = try #require(tracks.first)
        let album = try await source.album(id: try #require(song.album?.id))
        print("album:", album.album.name, album.tracks.count, "songs, artwork", album.album.artwork?.sized(300)?.absoluteString ?? "-")
        #expect(album.tracks.contains { $0.id == song.id })
        let artist = try await source.artist(id: try #require(song.artists.first?.id))
        let albums = try await source.artistAlbums(id: artist.artist.id, page: Page(offset: 0, limit: 20))
        print("artist:", artist.artist.name, artist.topTracks.count, "top songs,", albums.count, "albums")
        #expect(!artist.topTracks.isEmpty)

        let word = String(song.title.prefix(2))
        let found = try await source.search(word, kind: .song, page: Page(offset: 0, limit: 10))
        print("search \(word):", found.songs.map(\.title))
        #expect(found.songs.contains { $0.title.contains(word) })
        print("suggestions:", try await source.searchSuggestions(word))
        let playlists = try await source.userPlaylists()
        print("playlists:", playlists.map { "\($0.name) (\($0.trackCount ?? 0))" })
        if let first = playlists.first {
            let detail = try await source.playlist(id: first.id)
            #expect(detail.tracks.count + detail.pendingTrackIDs.count > 0)
        }
        let byID = try await source.songs(ids: tracks.prefix(5).map(\.id.id).reversed())
        #expect(byID.map(\.id) == tracks.prefix(5).map(\.id).reversed())

        let shelf = try await source.libraryAlbums(sort: .year, genre: nil, page: Page(offset: 0, limit: 60))
        print("library albums by year:", shelf.total ?? -1, shelf.items.map { "\($0.name) \($0.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) } ?? 0)" })
        #expect(!shelf.items.isEmpty)
        let everyone = try await source.libraryArtists(page: Page(offset: 0, limit: 80))
        print("library artists:", everyone.total ?? -1, everyone.items.map { "\($0.name) (\($0.songCount))" })
        #expect(!everyone.items.isEmpty)
        let genres = try await source.libraryGenres()
        print("library genres:", genres.map { "\($0.name) (\($0.albumCount))" })
        if let genre = genres.first {
            let ofGenre = try await source.libraryAlbums(sort: .title, genre: genre.name, page: Page(offset: 0, limit: 60))
            #expect(ofGenre.items.count == genre.albumCount, "\(genre.name)")
        }
    }

    /// Every song at every tier: what it comes as, and that the address answers (a byte range
    /// of the file, the start of a conversion); the loudness the server measured, if it did.
    @Test func streams() async throws {
        let source = try await Self.signedIn()
        let tracks = try await Self.everySong(source)
        for track in tracks.prefix(12) {
            var row: [String] = []
            var gain: ReplayGain?
            for tier in source.tiers {
                let asset = try await source.resolvePlayableAsset(track, tier: tier)
                gain = asset.gain
                var request = URLRequest(url: asset.url)
                asset.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                if !asset.isTranscode, asset.container != .hls { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                row.append("\(tier.id)→\(asset.tier.id) \(asset.container.rawValue)\(asset.isTranscode ? "*" : "") \(status) \(data.count / 1024)k")
                #expect(asset.isTranscode || asset.container == .hls ? status == 200 : status == 206, "\(track.title) \(tier.id): \(status)")
            }
            let loudness = gain.map { "gain \($0.trackGain.map { String($0) } ?? "-") / album \($0.albumGain.map { String($0) } ?? "-") dB" } ?? "no gain"
            print("\(track.title):", row.joined(separator: " | "), "|", loudness)
        }
    }

    @Test func lyrics() async throws {
        let source = try await Self.signedIn()
        let provider = try #require(source.plugin.lyricsProvider(cache: LyricsCache(directory: nil)))
        for track in try await Self.everySong(source).prefix(20) {
            guard let result = try await provider.lyrics(for: track) else { continue }
            let document = try LyricsParsing.parse(result.raw.body, format: LyricsDocument.Format(rawValue: result.raw.format.rawValue)!)
            print("\(track.title): \(result.raw.format) \(document.lines.count) lines, word-timed \(document.hasSyllables):", document.lines.prefix(2).map(\.text))
            #expect(!document.lines.isEmpty)
        }
    }
}
