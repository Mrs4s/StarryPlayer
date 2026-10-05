import Foundation
import LyricsCore
import LyricsProviders
import MusicSources
import os
import StarryCore
import Testing
@testable import PluginHost

/// Jellyfin as the app runs it (build/plugins/jellyfin.js, built from plugins/jellyfin): in
/// JavaScriptCore, through `PluginSource`, its account and its lyrics, against a stub of a 12.1
/// server. Its parts have their own tests (`npm test` in plugins/jellyfin); the live ones are
/// `JellyfinPluginLive`.
@Suite(.serialized) struct JellyfinPluginTests {
    static var file: URL { Fixture.builtIn.appending(path: "jellyfin.js") }

    static func source() throws -> PluginSource {
        PluginSource(plugin: try Plugin.load(file: file, options: Fixture.options()), settings: SourceSettingValues())
    }

    /// A self-hosted server's source: any host, the server asked for first, an optional password
    /// or Quick Connect (`快速连接`), several accounts, its own Home shelves and library, no
    /// platform's extras.
    @Test func standsForAServer() throws {
        let source = try Self.source()
        #expect(source.id == .plugin(id: "moe.mrs4s.jellyfin") && source.displayName == "Jellyfin")
        #expect(source.plugin.manifest.hosts == ["*"])
        let account = source.account
        #expect(account.serverPrompt == ServerPrompt(placeholder: "http://192.168.1.10:8096"))
        #expect(account.passwordOptional && account.supportsMultipleAccounts)
        #expect(account.supportedMethods == [.password, .code])
        #expect(account.codeLogin?.title == "快速连接")
        #expect(source.tiers.map(\.id) == ["128", "320", "lossless", "hi-res"])
        #expect(source.tiers.map(\.level) == [.lq, .hq, .lossless, .hiRes])
        #expect(source.searchKinds == [.song, .artist, .album, .playlist])
        #expect(source.collectableKinds == [.album, .artist])
        #expect(source.capability((any HomeShelfSource).self) != nil)
        #expect(source.capability((any AllMediaSource).self) != nil)
        #expect(source.capability((any LibraryBrowsingSource).self)?.librarySections == [.albums, .artists, .genres])
        #expect(source.albumSorts == [.title, .artist, .year, .recentlyAdded])
        #expect(source.capability((any RadioSource).self) != nil)
        #expect(source.capability((any ScrobblingSource).self) != nil)
        #expect(source.capability((any UserLibrarySource).self) != nil)
        #expect(source.capability((any RecommendationSource).self) == nil)
        #expect(source.capability((any DailyRecommendationSource).self) == nil)
        #expect(source.capability((any CommentSource).self) == nil)
        #expect(source.capability((any ConfigurableSource).self) == nil)
        #expect(source.plugin.lyricsProviderID == LyricsProviderID(plugin: "moe.mrs4s.jellyfin"))
    }

    /// The server, then a user without a password: the account names the server, links go to its
    /// web pages; Home, All Media, the library and an album come from it.
    @Test func signsInAndBrowses() async throws {
        JellyfinServer.start()
        let source = try Self.source()
        let server = try await source.account.connect(to: "jellyfin.test:8096/")
        #expect(server == ServerInfo(address: "http://jellyfin.test:8096", name: "家里的 NAS", version: "12.1.0", methods: [.password, .code]))
        try await source.account.loginWithPassword(username: "family", password: "")
        #expect(await source.account.state == .loggedIn(AccountProfile(userID: "srv1:u1", nickname: "family", detail: "家里的 NAS")))
        #expect(source.webURL(for: .album("al1")) == URL(string: "http://jellyfin.test:8096/web/#/details?id=al1&serverId=srv1"))
        let login = try #require(JellyfinServer.requests.first { $0.url?.path == "/Users/AuthenticateByName" })
        let header = try #require(login.value(forHTTPHeaderField: "Authorization"))
        #expect(header.hasPrefix("MediaBrowser Client=\"Starry%20Player\", Device=\"") && !header.contains("Token="))

        let shelves = try await source.homeShelves()
        #expect(shelves.map(\.title) == ["随便听听", "最近添加", "最常播放"])
        let page = try await source.allMedia(page: Page(offset: 0, limit: 2))
        #expect(page.tracks.map(\.id.id) == ["s-mp3", "s-wv"] && page.total == 3 && page.hasMore)
        let albums = try await source.libraryAlbums(sort: .recentlyAdded, genre: "Test", page: Page(offset: 0, limit: 60))
        #expect(albums.items.map(\.name) == ["格式测试专辑"] && albums.total == 1 && !albums.hasMore)
        let albumQuery = try #require(JellyfinServer.requests.last?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        #expect(albumQuery.contains(URLQueryItem(name: "Genres", value: "Test")) && albumQuery.contains(URLQueryItem(name: "SortBy", value: "DateCreated,SortName")))
        let artists = try await source.libraryArtists(page: Page(offset: 0, limit: 80))
        #expect(artists.items.map(\.name) == ["测试歌手"] && artists.items.first?.songCount == 3 && artists.total == 1)
        let genres = try await source.libraryGenres()
        #expect(genres.map(\.name) == ["Test"] && genres.first?.albumCount == 1)
        #expect(genres.first?.artwork?.url?.path == "/Items/g-test/Images/Primary")
        let album = try await source.album(id: "al1")
        #expect(album.album.name == "格式测试专辑" && album.tracks.count == 3)
        #expect(album.tracks.map(\.availableTiers) == [["128", "320"], ["128", "320", "lossless"], ["128", "320", "lossless"]])
        #expect(album.tracks.first?.artwork?.sized(200)?.absoluteString == "http://jellyfin.test:8096/Items/al1/Images/Primary?fillWidth=200&fillHeight=200&quality=90&tag=cover")
        let browse = try #require(JellyfinServer.requests.last)
        #expect(browse.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Token=\"tok\"") == true)
    }

    /// The file itself when it plays here (byte ranges, the token in the header), with the
    /// loudness the server measured for the song and its album; a WavPack converted to FLAC,
    /// which the player downloads before it plays.
    @Test func playsFilesAndTranscodes() async throws {
        JellyfinServer.start()
        let source = try Self.source()
        _ = try await source.account.connect(to: "http://jellyfin.test:8096")
        try await source.account.loginWithPassword(username: "family", password: "")
        let lossless = try #require(source.tiers.first { $0.id == "lossless" })
        let mp3 = try await source.resolvePlayableAsset(Track(id: TrackRef(source: source.id, id: "s-mp3"), title: "MP3", duration: 60), tier: lossless)
        #expect(mp3.url.absoluteString == "http://jellyfin.test:8096/Audio/s-mp3/stream.mp3?static=true")
        #expect(mp3.container == .mp3 && !mp3.isTranscode && mp3.tier.id == "320")
        #expect(mp3.headers["Authorization"]?.hasSuffix("Token=\"tok\"") == true)
        #expect(mp3.gain == ReplayGain(trackGain: -7.4, albumGain: -6.9))
        #expect(abs(Loudness(mode: .album).factor(for: mp3.gain) - Float(pow(10, -6.9 / 20))) < 0.0001)
        let wavpack = try await source.resolvePlayableAsset(Track(id: TrackRef(source: source.id, id: "s-wv"), title: "WV", duration: 60), tier: lossless)
        #expect(wavpack.isTranscode && wavpack.container == .flac && wavpack.tier.id == "lossless")
        let query = URLComponents(url: wavpack.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(wavpack.url.path == "/Audio/s-wv/stream.flac")
        #expect(query.contains(URLQueryItem(name: "static", value: "false")) && query.contains { $0.name == "playSessionId" })
    }

    /// Enhanced LRC on the server comes word by word, by the song's id.
    @Test func ownLyricsWordByWord() async throws {
        JellyfinServer.start()
        let source = try Self.source()
        _ = try await source.account.connect(to: "http://jellyfin.test:8096")
        try await source.account.loginWithPassword(username: "family", password: "")
        let provider = try #require(source.plugin.lyricsProvider(cache: LyricsCache(directory: nil)))
        let track = Track(id: TrackRef(source: source.id, id: "s-mp3"), title: "MP3", duration: 60)
        let result = try #require(try await provider.lyrics(for: track))
        #expect(result.raw.format == .ttml)
        let document = try LyricsParsing.parse(result.raw.body, format: .ttml)
        #expect(document.hasSyllables)
        #expect(document.lines.map(\.text) == ["Word by word", "逐字歌词"])
        #expect(document.lines.first?.words.first?.start == 1)
        // A song without lyrics on the server is none, asked once.
        let none = Track(id: TrackRef(source: source.id, id: "s-wv"), title: "WV", duration: 60)
        #expect(try await provider.lyrics(for: none) == nil)
        #expect(!JellyfinServer.requests.contains { $0.url?.path == "/Audio/s-wv/Lyrics" })
    }

    @Test func editsPlaylists() async throws {
        JellyfinServer.start()
        let source = try Self.source()
        _ = try await source.account.connect(to: "http://jellyfin.test:8096")
        try await source.account.loginWithPassword(username: "family", password: "")
        let editing = source.playlistEditing
        #expect(editing.canCreate && editing.canEdit && editing.canDelete && editing.canAdd && editing.canRemove && editing.canReorder)
        #expect(editing.keepsPrivacy && editing.privateByDefault && !editing.keepsDescription && !editing.publicIsFinal && editing.nameLimit == nil)

        let made = try await source.createPlaylist(PlaylistDraft(name: "新歌单", isPrivate: true))
        #expect(made.id == "pl-new" && made.name == "新歌单" && made.isOwned && made.isPrivate == true && made.trackCount == 0)
        #expect(try await source.addTracks(["s-mp3", "s-wv"], toPlaylist: "pl-new") == 2)
        #expect(try await source.addTracks(["s-wv", "s-flac"], toPlaylist: "pl-new") == 1)
        #expect(JellyfinServer.entries == ["s-mp3", "s-wv", "s-flac"])
        try await source.reorderPlaylist("pl-new", trackIDs: ["s-flac", "s-mp3", "s-wv"])
        #expect(JellyfinServer.entries == ["s-flac", "s-mp3", "s-wv"])
        try await source.removeTracks(["s-mp3"], fromPlaylist: "pl-new")
        #expect(JellyfinServer.entries == ["s-flac", "s-wv"])
        try await source.editPlaylist("pl-new", changes: PlaylistChanges(name: "改名", isPrivate: false))
        let rename = try #require(JellyfinServer.requests.last { $0.httpMethod == "POST" && $0.url?.path == "/Playlists/pl-new" })
        #expect((try JSONSerialization.jsonObject(with: rename.httpBody ?? Data())) as? [String: AnyHashable] == ["Name": "改名", "IsPublic": true])
        try await source.deletePlaylist("pl-new")
        #expect(JellyfinServer.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/Items/pl-new" })
    }
}

/// A Jellyfin 12.1 server at `jellyfin.test`: one album of three songs (MP3 with enhanced LRC,
/// WavPack, FLAC), one user who has no password.
enum JellyfinServer {
    static let host = "jellyfin.test"
    private static let seen = OSAllocatedUnfairLock(initialState: [URLRequest]())
    /// The songs of the playlist made in `editsPlaylists`, as the server keeps them.
    private static let playlist = OSAllocatedUnfairLock(initialState: [String]())

    static var requests: [URLRequest] { seen.withLock { $0 } }
    static var entries: [String] { playlist.withLock { $0 } }

    static func song(_ id: String, _ name: String, container: String, codec: String, index: Int, lyrics: Bool) -> [String: Any] {
        [
            "Id": id, "Name": name, "Type": "Audio", "RunTimeTicks": 600_000_000, "Container": container, "HasLyrics": lyrics, "NormalizationGain": -7.4, "AlbumNormalizationGain": -6.9,
            "IndexNumber": index, "ParentIndexNumber": 1, "Album": "格式测试专辑", "AlbumId": "al1", "AlbumPrimaryImageTag": "cover",
            "ArtistItems": [["Name": "测试歌手", "Id": "ar1"]], "AlbumArtists": [["Name": "测试歌手", "Id": "ar1"]],
            "MediaStreams": [["Type": "Audio", "Codec": codec, "BitRate": 320_000, "SampleRate": 44100, "Channels": 2]],
            "MediaSources": [["Id": id, "Container": container, "Size": 1000, "MediaStreams": [["Type": "Audio", "Codec": codec, "BitRate": 320_000, "SampleRate": 44100, "Channels": 2]]]],
        ]
    }

    nonisolated(unsafe) static let songs = [
        song("s-mp3", "MP3 歌曲", container: "mp3", codec: "mp3", index: 1, lyrics: true),
        song("s-wv", "WavPack Song", container: "wv", codec: "wavpack", index: 2, lyrics: false),
        song("s-flac", "FLAC 长歌", container: "flac", codec: "flac", index: 3, lyrics: false),
    ]
    nonisolated(unsafe) static let album: [String: Any] = ["Id": "al1", "Name": "格式测试专辑", "Type": "MusicAlbum", "ChildCount": 3, "ImageTags": ["Primary": "cover"], "AlbumArtists": [["Name": "测试歌手", "Id": "ar1"]]]
    nonisolated(unsafe) static let lyrics: [String: Any] = ["Metadata": [:], "Lyrics": [
        ["Text": "Word by word", "Start": 10_000_000, "Cues": [
            ["Position": 0, "EndPosition": 5, "Start": 10_000_000, "End": 15_000_000],
            ["Position": 5, "EndPosition": 8, "Start": 15_000_000, "End": 20_000_000],
            ["Position": 8, "EndPosition": 12, "Start": 20_000_000, "End": 40_000_000],
        ]],
        ["Text": "逐字歌词", "Start": 40_000_000, "Cues": [
            ["Position": 0, "EndPosition": 2, "Start": 40_000_000, "End": 44_000_000],
            ["Position": 2, "EndPosition": 4, "Start": 44_000_000],
        ]],
    ]]

    static func start() {
        seen.withLock { $0 = [] }
        playlist.withLock { $0 = [] }
        StubProtocol.route(host) { request in
            seen.withLock { $0.append(request) }
            let url = request.url!
            let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            func json(_ value: Any, status: Int = 200) -> (status: Int, headers: [String: String], body: Data) {
                (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
            }
            let notFound: (status: Int, headers: [String: String], body: Data) = (404, [:], Data())
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/System/Info/Public"):
                return json(["ServerName": "家里的 NAS", "Version": "12.1.0", "Id": "srv1", "ProductName": "Jellyfin Server", "StartupWizardCompleted": true])
            case ("GET", "/QuickConnect/Enabled"):
                return json(true)
            case ("POST", "/Users/AuthenticateByName"):
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                guard body?["Username"] as? String == "family", body?["Pw"] as? String == "" else { return json([:], status: 401) }
                return json(["AccessToken": "tok", "ServerId": "srv1", "User": ["Id": "u1", "Name": "family"]])
            case ("GET", "/Users/Me"):
                return json(["Id": "u1", "Name": "family"])
            case ("GET", "/Items"):
                switch query["IncludeItemTypes"] {
                case "Audio":
                    let start = Int(query["StartIndex"] ?? "") ?? 0
                    let limit = Int(query["Limit"] ?? "") ?? songs.count
                    let page = Array(songs.dropFirst(start).prefix(limit))
                    return json(["Items": query["Filters"] == "IsFavorite" ? [] : page, "TotalRecordCount": songs.count])
                case "MusicAlbum" where query["Filters"] == nil:
                    return json(["Items": [album], "TotalRecordCount": 1])
                case "MusicGenre":
                    // A genre of the albums, and one the server's metadata gave an artist.
                    return json(["Items": [
                        ["Id": "g-test", "Name": "Test", "Type": "MusicGenre", "AlbumCount": 1, "SongCount": 3, "ImageTags": ["Primary": "collage"]],
                        ["Id": "g-pop", "Name": "mandopop", "Type": "MusicGenre", "AlbumCount": 0, "SongCount": 0, "ImageTags": [:]],
                    ], "TotalRecordCount": 2])
                default:
                    return json(["Items": [], "TotalRecordCount": 0])
                }
            case ("GET", "/Artists"):
                return json(["Items": [["Id": "ar1", "Name": "测试歌手", "Type": "MusicArtist", "AlbumCount": 1, "SongCount": 3]], "TotalRecordCount": 1])
            case ("GET", "/Items/al1"):
                return json(album)
            case ("GET", let path) where path.hasPrefix("/Items/"):
                let id = String(path.dropFirst("/Items/".count))
                return songs.first { $0["Id"] as? String == id }.map { json($0) } ?? notFound
            case ("GET", "/Audio/s-mp3/Lyrics"):
                return json(lyrics)
            case ("POST", "/Playlists"):
                return json(["Id": "pl-new"])
            case ("GET", "/Playlists/pl-new"):
                return json(["OpenAccess": false, "ItemIds": playlist.withLock { $0 }])
            case ("POST", "/Playlists/pl-new/Items"):
                let ids = (query["ids"] ?? "").split(separator: ",").map(String.init)
                playlist.withLock { $0 += ids }
                return (204, [:], Data())
            case ("POST", "/Playlists/pl-new"):
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                if let ids = body?["Ids"] as? [String] { playlist.withLock { $0 = ids } }
                return (204, [:], Data())
            case ("DELETE", "/Items/pl-new"):
                return (204, [:], Data())
            default:
                return notFound
            }
        }
    }
}
