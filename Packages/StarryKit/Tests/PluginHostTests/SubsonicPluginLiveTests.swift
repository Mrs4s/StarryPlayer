import Foundation
import LyricsCore
import LyricsProviders
import MusicSources
@testable import PluginHost
import StarryCore
import Testing

/// `SUBSONIC_LIVE=<server> SUBSONIC_USER=… SUBSONIC_PASSWORD=… swift test --filter SubsonicPluginLive`:
/// the Subsonic plugin against a real server (local ones in Docker from
/// plugins/subsonic/test/test-servers.sh, or `https://demo.navidrome.org` with demo / demo). It
/// only reads, except `editsPlaylists` (`SUBSONIC_WRITE=1`), which makes a playlist and deletes it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUBSONIC_LIVE"] != nil), .serialized)
struct SubsonicPluginLiveTests {
    static let environment = ProcessInfo.processInfo.environment

    /// A fresh plugin signed in to the server.
    static func signedIn() async throws -> PluginSource {
        let source = PluginSource(plugin: try Plugin.load(file: SubsonicPluginTests.file, options: Plugin.Options(appVersion: "live")), settings: SourceSettingValues())
        let server = try await source.account.connect(to: environment["SUBSONIC_LIVE"] ?? "")
        print("subsonic: \(server.name ?? "-") \(server.version ?? "-") at \(server.address)")
        try await source.account.loginWithPassword(username: environment["SUBSONIC_USER"] ?? "demo", password: environment["SUBSONIC_PASSWORD"] ?? "demo")
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

        let tracks = try await Self.everySong(source)
        print("all media:", tracks.count, "songs:", tracks.prefix(20).map { "\($0.title) [\($0.availableTiers.joined(separator: ","))]" })
        #expect(!tracks.isEmpty)
        let shelves = try await source.homeShelves()
        print("home:", shelves.map { "\($0.title)" })
        #expect(!shelves.isEmpty)

        let song = try #require(tracks.first)
        let album = try await source.album(id: try #require(song.album?.id))
        print("album:", album.album.name, album.album.artists.map(\.name), album.tracks.count, "songs, artwork", album.album.artwork?.sized(300)?.absoluteString.prefix(80) ?? "-")
        #expect(album.tracks.contains { $0.id == song.id })
        if let artistID = song.artists.first(where: { !$0.id.isEmpty })?.id {
            let artist = try await source.artist(id: artistID)
            let albums = try await source.artistAlbums(id: artistID, page: Page(offset: 0, limit: 20))
            let songs = try await source.artistSongs(id: artistID, order: .time, page: Page(offset: 0, limit: 50))
            let similar = try await source.similarArtists(id: artistID)
            print("artist:", artist.artist.name, artist.topTracks.count, "top songs,", albums.count, "albums,", songs.count, "songs, similar", similar.map(\.name), "bio", artist.artist.description?.prefix(40) ?? "-")
            #expect(!songs.isEmpty)
        }

        let word = String(song.title.prefix(2))
        let found = try await source.search(word, kind: .song, page: Page(offset: 0, limit: 10))
        print("search \(word):", found.songs.map(\.title))
        #expect(found.songs.contains { $0.title.contains(word) })
        print("suggestions:", try await source.searchSuggestions(word))
        let playlists = try await source.userPlaylists()
        print("playlists:", playlists.map { "\($0.name) (\($0.trackCount)) owned \($0.isOwned)" })
        let byID = try await source.songs(ids: tracks.prefix(5).map(\.id.id).reversed())
        #expect(byID.map(\.id) == tracks.prefix(5).map(\.id).reversed())

        for sort in source.albumSorts {
            let shelf = try await source.libraryAlbums(sort: sort, genre: nil, page: Page(offset: 0, limit: 60))
            print("library albums by \(sort):", shelf.items.map { "\($0.name) \($0.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) } ?? 0)" })
            #expect(!shelf.items.isEmpty)
        }
        let everyone = try await source.libraryArtists(page: Page(offset: 0, limit: 80))
        print("library artists:", everyone.total ?? -1, everyone.items.map { "\($0.name) (\($0.albumCount))" })
        #expect(!everyone.items.isEmpty)
        let genres = try await source.libraryGenres()
        print("library genres:", genres.map { "\($0.name) (\($0.albumCount)) \($0.artwork == nil ? "" : "🖼")" })
        if let genre = genres.first, genre.albumCount > 0 {
            let ofGenre = try await source.libraryAlbums(sort: .title, genre: genre.name, page: Page(offset: 0, limit: 60))
            #expect(ofGenre.items.count == min(genre.albumCount, 60), "\(genre.name)")
        }
    }

    @Test func streams() async throws {
        let source = try await Self.signedIn()
        let tracks = try await Self.everySong(source)
        for track in tracks.prefix(20) {
            var row: [String] = []
            var gain: ReplayGain?
            for tier in source.tiers {
                let asset: PlayableAsset
                do {
                    asset = try await source.resolvePlayableAsset(track, tier: tier)
                } catch PluginError.script(_, "notPlayable", let message) {
                    // The server would send what this Mac cannot play (Airsonic's Opus): told, not played.
                    row.append("\(tier.id): \(message)")
                    continue
                }
                gain = asset.gain
                var request = URLRequest(url: asset.url)
                if !asset.isTranscode { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "-"
                row.append("\(tier.id)→\(asset.tier.id) \(asset.container.rawValue)\(asset.isTranscode ? "*" : "") \(status) \(type.prefix(16)) \(data.count / 1024)k")
                #expect(asset.isTranscode ? status == 200 : status == 206, "\(track.title) \(tier.id): \(status)")
                #expect(!type.contains("xml") && !type.contains("json"), "\(track.title) \(tier.id): \(type)")
            }
            let loudness = gain.map { "gain \($0.trackGain.map { String($0) } ?? "-") / album \($0.albumGain.map { String($0) } ?? "-") dB" } ?? "no gain"
            print("\(track.title):", row.joined(separator: " | "), "|", loudness)
        }
    }

    @Test func lyrics() async throws {
        let source = try await Self.signedIn()
        let provider = try #require(source.plugin.lyricsProvider(cache: LyricsCache(directory: nil)))
        for track in try await Self.everySong(source).prefix(40) {
            guard let result = try await provider.lyrics(for: track) else { continue }
            var document = try LyricsParsing.parse(result.raw.body, format: LyricsDocument.Format(rawValue: result.raw.format.rawValue)!)
            LyricsParsing.attach(translation: result.raw.translation, romanization: result.raw.romanization, to: &document)
            print("\(track.title): \(result.raw.format) \(document.lines.count) lines, word-timed \(document.hasSyllables):", document.lines.prefix(2).map { "\($0.start) \($0.text) / \($0.translation ?? "-")" })
            #expect(!document.lines.isEmpty)
        }
    }

    /// Creating a playlist, adding to it, reordering, removing, renaming and deleting on the real server.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUBSONIC_WRITE"] != nil)) func editsPlaylists() async throws {
        let source = try await Self.signedIn()
        let tracks = Array(try await Self.everySong(source).prefix(4))
        try #require(tracks.count == 4)
        let ids = tracks.map(\.id.id)
        let made = try await source.createPlaylist(PlaylistDraft(name: "Starry 测试歌单", description: "简介", isPrivate: false))
        defer { Task { try? await source.deletePlaylist(made.id) } }
        #expect(try await source.addTracks(Array(ids.prefix(3)), toPlaylist: made.id) == 3)
        #expect(try await source.addTracks([ids[2], ids[3]], toPlaylist: made.id) == 1)
        var reordered = true
        do {
            try await source.reorderPlaylist(made.id, trackIDs: [ids[3], ids[0], ids[1], ids[2]])
        } catch {
            // Airsonic-Advanced keeps an order of its own.
            print("reorder refused:", error)
            reordered = false
        }
        var detail = try await source.playlist(id: made.id)
        if reordered { #expect(detail.tracks.map(\.id.id) == [ids[3], ids[0], ids[1], ids[2]]) }
        try await source.removeTracks([ids[0]], fromPlaylist: made.id)
        detail = try await source.playlist(id: made.id)
        if reordered { #expect(detail.tracks.map(\.id.id) == [ids[3], ids[1], ids[2]]) }
        #expect(Set(detail.tracks.map(\.id.id)) == [ids[3], ids[1], ids[2]])
        print("after edits:", detail.playlist.name, detail.playlist.description ?? "-", "private", detail.playlist.isPrivate.map { "\($0)" } ?? "-")
        try await source.editPlaylist(made.id, changes: PlaylistChanges(name: "Starry 改名", isPrivate: true))
        try await source.removeTracks([ids[3], ids[1], ids[2]], fromPlaylist: made.id)
        detail = try await source.playlist(id: made.id)
        print("emptied:", detail.playlist.name, detail.tracks.count, "songs, private", detail.playlist.isPrivate.map { "\($0)" } ?? "-")
        #expect(detail.tracks.isEmpty && detail.playlist.name == "Starry 改名" && detail.playlist.isPrivate == true)
        try await source.deletePlaylist(made.id)
    }
}
