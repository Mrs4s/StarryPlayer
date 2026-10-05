import CryptoKit
import Foundation
import LyricsCore
import LyricsProviders
import MusicSources
import os
import StarryCore
import Testing
@testable import PluginHost

/// Subsonic as the app runs it (build/plugins/subsonic.js, built from plugins/subsonic): in
/// JavaScriptCore, through `PluginSource`, its account and its lyrics, against a stub of a
/// Navidrome 0.64 server. Its parts have their own tests (`npm test` in plugins/subsonic); the
/// live ones are `SubsonicPluginLive`.
@Suite(.serialized) struct SubsonicPluginTests {
    static var file: URL { Fixture.builtIn.appending(path: "subsonic.js") }

    static func source() throws -> PluginSource {
        PluginSource(plugin: try Plugin.load(file: file, options: Fixture.options()), settings: SourceSettingValues())
    }

    static func signedIn() async throws -> PluginSource {
        SubsonicServer.start()
        let source = try Self.source()
        _ = try await source.account.connect(to: "http://subsonic.test:4533")
        try await source.account.loginWithPassword(username: "family", password: "pw")
        return source
    }

    static func id(_ source: PluginSource, _ raw: String) async throws -> String {
        guard case .loggedIn(let profile) = await source.account.state else { throw CancellationError() }
        return "\(profile.userID.split(separator: ":")[0])/\(raw)"
    }

    /// A self-hosted server's source: any host, the server asked for first, a password, several
    /// accounts, its own Home shelves and library, no platform's extras.
    @Test func standsForAServer() throws {
        let source = try Self.source()
        #expect(source.id == .plugin(id: "moe.mrs4s.subsonic") && source.displayName == "Subsonic")
        #expect(source.plugin.manifest.hosts == ["*"])
        let account = source.account
        #expect(account.serverPrompt == ServerPrompt(placeholder: "http://192.168.1.10:4533"))
        #expect(!account.passwordOptional && account.supportsMultipleAccounts)
        #expect(account.supportedMethods == [.password])
        #expect(source.tiers.map(\.id) == ["128", "320", "lossless", "hi-res"])
        #expect(source.searchKinds == [.song, .artist, .album])
        #expect(source.collectableKinds == [.album, .artist])
        #expect(source.capability((any HomeShelfSource).self) != nil)
        #expect(source.capability((any AllMediaSource).self) != nil)
        #expect(source.capability((any LibraryBrowsingSource).self)?.librarySections == [.albums, .artists, .genres])
        #expect(source.albumSorts == [.title, .artist, .year, .recentlyAdded])
        #expect(source.capability((any RadioSource).self) != nil)
        #expect(source.capability((any ScrobblingSource).self) != nil)
        #expect(source.capability((any UserLibrarySource).self) != nil)
        #expect(source.capability((any RecommendationSource).self) == nil)
        #expect(source.capability((any CommentSource).self) == nil)
        #expect(source.capability((any ConfigurableSource).self) == nil)
        #expect(source.plugin.lyricsProviderID == LyricsProviderID(plugin: "moe.mrs4s.subsonic"))
    }

    /// The server, then a user: a token (never the password) in every request, the account named
    /// after the server; Home, All Media, the library and an album come from it, ids carrying the
    /// server.
    @Test func signsInAndBrowses() async throws {
        let source = try await Self.signedIn()
        guard case .loggedIn(let profile) = await source.account.state else { Issue.record("not signed in"); return }
        #expect(profile.nickname == "family" && profile.detail == "Navidrome · subsonic.test:4533")
        let login = try #require(SubsonicServer.requests.last { $0.url?.path == "/rest/ping" })
        let query = URLComponents(url: try #require(login.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "t" } && query.contains { $0.name == "s" } && !query.contains { $0.name == "p" })
        #expect(query.contains(URLQueryItem(name: "c", value: "Starry Player")) && query.contains(URLQueryItem(name: "f", value: "json")))

        let shelves = try await source.homeShelves()
        #expect(shelves.map(\.title) == ["随便听听", "最近添加", "最近播放", "最常播放", "我的歌单"])
        let page = try await source.allMedia(page: Page(offset: 0, limit: 2))
        #expect(page.tracks.map(\.id.id) == [try await Self.id(source, "s-mp3"), try await Self.id(source, "s-wv")] && page.hasMore)
        let albums = try await source.libraryAlbums(sort: .recentlyAdded, genre: nil, page: Page(offset: 0, limit: 60))
        #expect(albums.items.map(\.name) == ["格式测试专辑"])
        let artists = try await source.libraryArtists(page: Page(offset: 0, limit: 80))
        #expect(artists.items.map(\.name) == ["测试歌手"] && artists.total == 1)
        let genres = try await source.libraryGenres()
        #expect(genres.map(\.name) == ["华语流行"] && genres.first?.albumCount == 1)
        let album = try await source.album(id: try await Self.id(source, "al1"))
        #expect(album.album.name == "格式测试专辑" && album.tracks.count == 3)
        #expect(album.tracks.map(\.availableTiers) == [["128", "320"], ["128", "320", "lossless"], ["128", "320", "lossless", "hi-res"]])
        let cover = try #require(album.tracks.first?.artwork?.sized(200))
        #expect(cover.path == "/rest/getCoverArt" && cover.query?.contains("id=mf-s-mp3") == true && cover.query?.hasSuffix("size=200") == true)
    }

    /// The file itself when it plays here (byte ranges, `format=raw`), with its ReplayGain; a
    /// WavPack converted to FLAC as the server decides, which the player downloads before it plays.
    @Test func playsFilesAndTranscodes() async throws {
        let source = try await Self.signedIn()
        let lossless = try #require(source.tiers.first { $0.id == "lossless" })
        let mp3 = try await source.resolvePlayableAsset(Track(id: TrackRef(source: source.id, id: try await Self.id(source, "s-mp3")), title: "MP3", duration: 60), tier: lossless)
        #expect(mp3.url.path == "/rest/stream" && mp3.url.query?.contains("format=raw") == true)
        #expect(mp3.container == .mp3 && !mp3.isTranscode && mp3.tier.id == "320")
        #expect(mp3.gain == ReplayGain(trackGain: -6.5, trackPeak: 0.988, albumGain: -7, albumPeak: 0.995))
        let wavpack = try await source.resolvePlayableAsset(Track(id: TrackRef(source: source.id, id: try await Self.id(source, "s-wv")), title: "WV", duration: 60), tier: lossless)
        #expect(wavpack.isTranscode && wavpack.container == .flac && wavpack.tier.id == "lossless")
        #expect(wavpack.url.path == "/rest/getTranscodeStream" && wavpack.url.query?.contains("transcodeParams=jwt-wv") == true)
        let decision = try #require(SubsonicServer.requests.last { $0.url?.path == "/rest/getTranscodeDecision" })
        let body = try #require((try JSONSerialization.jsonObject(with: decision.httpBody ?? Data())) as? [String: Any])
        #expect(decision.httpMethod == "POST" && (body["transcodingProfiles"] as? [[String: Any]])?.first?["container"] as? String == "flac")
    }

    /// Enhanced LRC on the server comes word by word (Navidrome's cues), by the song's id;
    /// a song without lyrics is none.
    @Test func ownLyricsWordByWord() async throws {
        let source = try await Self.signedIn()
        let provider = try #require(source.plugin.lyricsProvider(cache: LyricsCache(directory: nil)))
        let track = Track(id: TrackRef(source: source.id, id: try await Self.id(source, "s-mp3")), title: "MP3", duration: 60)
        let result = try #require(try await provider.lyrics(for: track))
        #expect(result.raw.format == .ttml)
        var document = try LyricsParsing.parse(result.raw.body, format: .ttml)
        LyricsParsing.attach(translation: result.raw.translation, romanization: nil, to: &document)
        #expect(document.hasSyllables)
        #expect(document.lines.map(\.text) == ["Word by word", "逐字歌词"])
        #expect(document.lines.first?.words.first?.start == 1)
        #expect(document.lines.last?.translation == "Word by word lyrics")
        let none = Track(id: TrackRef(source: source.id, id: try await Self.id(source, "s-wv")), title: "WV", duration: 60)
        #expect(try await provider.lyrics(for: none) == nil)
    }

    @Test func editsPlaylists() async throws {
        let source = try await Self.signedIn()
        let editing = source.playlistEditing
        #expect(editing.canCreate && editing.canEdit && editing.canDelete && editing.canAdd && editing.canRemove && editing.canReorder)
        #expect(editing.keepsPrivacy && editing.privateByDefault && editing.keepsDescription && !editing.publicIsFinal && editing.nameLimit == nil)
        let made = try await source.createPlaylist(PlaylistDraft(name: "新歌单", isPrivate: true))
        #expect(made.id == (try await Self.id(source, "pl-new")) && made.name == "新歌单" && made.isOwned && made.isPrivate == true && made.trackCount == 0)
        let mp3 = try await Self.id(source, "s-mp3"), wv = try await Self.id(source, "s-wv"), flac = try await Self.id(source, "s-flac")
        #expect(try await source.addTracks([mp3, wv], toPlaylist: made.id) == 2)
        #expect(try await source.addTracks([wv, flac], toPlaylist: made.id) == 1)
        #expect(SubsonicServer.entries == ["s-mp3", "s-wv", "s-flac"])
        try await source.reorderPlaylist(made.id, trackIDs: [flac, mp3, wv])
        #expect(SubsonicServer.entries == ["s-flac", "s-mp3", "s-wv"])
        try await source.removeTracks([mp3], fromPlaylist: made.id)
        #expect(SubsonicServer.entries == ["s-flac", "s-wv"])
        try await source.editPlaylist(made.id, changes: PlaylistChanges(name: "改名", description: "简介", isPrivate: false))
        let rename = try #require(SubsonicServer.requests.last { $0.url?.path == "/rest/updatePlaylist" })
        let items = URLComponents(url: try #require(rename.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "name", value: "改名")) && items.contains(URLQueryItem(name: "comment", value: "简介")) && items.contains(URLQueryItem(name: "public", value: "true")))
        try await source.deletePlaylist(made.id)
        #expect(SubsonicServer.requests.contains { $0.url?.path == "/rest/deletePlaylist" })
    }
}

/// A Navidrome 0.64 server at `subsonic.test`: one album of three songs (MP3 with enhanced LRC,
/// WavPack, 96 kHz FLAC), one user `family` with the password `pw`.
enum SubsonicServer {
    static let host = "subsonic.test"
    private static let seen = OSAllocatedUnfairLock(initialState: [URLRequest]())
    /// The songs of the playlist made in `editsPlaylists`, as the server keeps them.
    private static let playlist = OSAllocatedUnfairLock(initialState: [String]())

    static var requests: [URLRequest] { seen.withLock { $0 } }
    static var entries: [String] { playlist.withLock { $0 } }

    static func song(_ id: String, _ title: String, suffix: String, contentType: String, bitRate: Int, samplingRate: Int, track: Int) -> [String: Any] {
        [
            "id": id, "title": title, "album": "格式测试专辑", "albumId": "al1", "artist": "测试歌手", "artistId": "ar1", "artists": [["id": "ar1", "name": "测试歌手"]],
            "duration": 60, "suffix": suffix, "contentType": contentType, "bitRate": bitRate, "samplingRate": samplingRate, "channelCount": 2, "size": 1000,
            "coverArt": "mf-\(id)", "track": track, "discNumber": 1, "year": 2024,
            "replayGain": ["trackGain": -6.5, "albumGain": -7, "trackPeak": 0.988, "albumPeak": 0.995],
        ]
    }

    nonisolated(unsafe) static let songs = [
        song("s-mp3", "MP3 歌曲", suffix: "mp3", contentType: "audio/mpeg", bitRate: 320, samplingRate: 44100, track: 1),
        song("s-wv", "WavPack Song", suffix: "wv", contentType: "audio/x-wavpack", bitRate: 900, samplingRate: 44100, track: 2),
        song("s-flac", "Hi-Res FLAC", suffix: "flac", contentType: "audio/flac", bitRate: 2800, samplingRate: 96000, track: 3),
    ]
    nonisolated(unsafe) static let album: [String: Any] = ["id": "al1", "name": "格式测试专辑", "artist": "测试歌手", "artistId": "ar1", "songCount": 3, "year": 2024, "coverArt": "al-al1", "genre": "华语流行"]

    static func start() {
        seen.withLock { $0 = [] }
        playlist.withLock { $0 = [] }
        StubProtocol.route(host) { request in
            seen.withLock { $0.append(request) }
            let url = request.url!
            var items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let body = request.httpBody, request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true {
                items += URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
            }
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            func all(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
            func ok(_ payload: [String: Any] = [:]) -> (status: Int, headers: [String: String], body: Data) {
                var envelope: [String: Any] = ["status": "ok", "version": "1.16.1", "type": "navidrome", "serverVersion": "0.64.2", "openSubsonic": true]
                payload.forEach { envelope[$0] = $1 }
                return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: ["subsonic-response": envelope]))
            }
            func failed(_ code: Int, _ message: String) -> (status: Int, headers: [String: String], body: Data) {
                (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: ["subsonic-response": ["status": "failed", "version": "1.16.1", "type": "navidrome", "serverVersion": "0.64.2", "openSubsonic": true, "error": ["code": code, "message": message]]]))
            }
            let method = url.lastPathComponent.replacingOccurrences(of: ".view", with: "")
            if method != "getOpenSubsonicExtensions", method != "ping" || query["u"] != nil {
                let token = md5Hex("pw" + (query["s"] ?? ""))
                guard query["u"] == "family", query["t"] == token else { return failed(40, "Wrong username or password") }
            }
            switch method {
            case "ping":
                return query["u"] == nil ? failed(10, "missing parameter: 'u'") : ok()
            case "getOpenSubsonicExtensions":
                return ok(["openSubsonicExtensions": [["name": "songLyrics", "versions": [1, 2]], ["name": "transcoding", "versions": [1]], ["name": "formPost", "versions": [1]]]])
            case "search3":
                let offset = Int(query["songOffset"] ?? "") ?? 0
                let count = Int(query["songCount"] ?? "") ?? 20
                return ok(["searchResult3": ["song": Array(songs.dropFirst(offset).prefix(count))]])
            case "getRandomSongs":
                return ok(["randomSongs": ["song": songs]])
            case "getAlbumList2":
                return ok(["albumList2": ["album": [album]]])
            case "getArtists":
                return ok(["artists": ["index": [["name": "C", "artist": [["id": "ar1", "name": "测试歌手", "albumCount": 1]]]]]])
            case "getGenres":
                return ok(["genres": ["genre": [["value": "华语流行", "songCount": 3, "albumCount": 1]]]])
            case "getAlbum":
                var detail = album
                detail["song"] = songs
                return ok(["album": detail])
            case "getSong":
                return songs.first { $0["id"] as? String == query["id"] }.map { ok(["song": $0]) } ?? failed(70, "Song not found")
            case "getPlaylists":
                return ok(["playlists": ["playlist": [["id": "pl-new", "name": "新歌单", "owner": "family", "songCount": playlist.withLock { $0.count }]]]])
            case "getStarred2":
                return ok(["starred2": [:]])
            case "getTranscodeDecision":
                if query["mediaId"] == "s-wv" {
                    return ok(["transcodeDecision": ["canDirectPlay": false, "canTranscode": true, "transcodeParams": "jwt-wv", "transcodeStream": ["protocol": "http", "container": "flac", "codec": "flac", "audioChannels": 2, "audioSamplerate": 44100, "audioBitdepth": 16]]])
                }
                return ok(["transcodeDecision": ["canDirectPlay": true, "canTranscode": false]])
            case "getLyricsBySongId":
                guard query["id"] == "s-mp3" else { return ok(["lyricsList": [:]]) }
                return ok(["lyricsList": ["structuredLyrics": [
                    [
                        "lang": "xxx", "kind": "main", "synced": true,
                        "line": [["start": 1000, "value": "Word by word"], ["start": 4000, "value": "逐字歌词"], ["start": 4000, "value": "Word by word lyrics"]],
                        "cueLine": [
                            ["index": 0, "start": 1000, "end": 4000, "value": "Word by word", "cue": [
                                ["start": 1000, "end": 1500, "byteStart": 0, "byteEnd": 4, "value": "Word "],
                                ["start": 1500, "end": 2000, "byteStart": 5, "byteEnd": 7, "value": "by "],
                                ["start": 2000, "end": 4000, "byteStart": 8, "byteEnd": 11, "value": "word"],
                            ]],
                            ["index": 1, "start": 4000, "value": "逐字歌词", "cue": [
                                ["start": 4000, "end": 4400, "byteStart": 0, "byteEnd": 2, "value": "逐"],
                                ["start": 4400, "end": 4800, "byteStart": 3, "byteEnd": 5, "value": "字"],
                                ["start": 4800, "byteStart": 6, "byteEnd": 11, "value": "歌词"],
                            ]],
                        ],
                    ],
                ]]])
            case "createPlaylist":
                if query["playlistId"] == "pl-new" {
                    let ids = all("songId")
                    if !ids.isEmpty { playlist.withLock { $0 = ids } }
                    return ok()
                }
                return ok(["playlist": ["id": "pl-new", "name": query["name"] ?? "", "owner": "family", "songCount": 0, "public": false]])
            case "getPlaylist":
                let ids = playlist.withLock { $0 }
                return ok(["playlist": ["id": "pl-new", "name": "新歌单", "owner": "family", "entry": ids.compactMap { id in songs.first { $0["id"] as? String == id } }]])
            case "updatePlaylist":
                let added = all("songIdToAdd")
                let removed = Set(all("songIndexToRemove").compactMap(Int.init))
                playlist.withLock { list in list = list.enumerated().filter { !removed.contains($0.offset) }.map(\.element) + added }
                return ok()
            case "deletePlaylist":
                return ok()
            default:
                return failed(0, "not stubbed: \(method)")
            }
        }
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
