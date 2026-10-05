import Foundation
import MusicSources
import StarryCore
import Testing
@testable import PluginHost

/// What a self-hosted server's plugin uses: a server address
/// before signing in, an optional password, a code entered on another device, page templates
/// set once the server is known, a library handed out by page, its own Home shelves, the library's
/// grids and transcoded streams.
@Suite struct SelfHostedPluginTests {
    static let script = """
    module.exports = {
      id: 'test.server', name: '自建', version: '1', apiVersion: 1, permissions: { hosts: ['*'] },
      source: {
        webPages: { song: 'https://static.test/{id}' },
        async resolve(track) {
          return { url: `${starry.storage.get('server') || 'https://none.test'}/a/${track.id}.flac`, transcoded: track.id === 't' };
        },
        async allMedia(page) {
          if (page.offset === 0) return { songs: [{ id: 'a', title: 'A', duration: 1 }, { id: 'b', title: 'B', duration: 1 }], total: 5, nextOffset: 3 };
          return [{ id: 'c', title: 'C', duration: 1 }];
        },
        async homeShelves() {
          return [
            { title: '最近添加', albums: [{ id: 'al', name: '专辑' }] },
            { id: 'empty', title: '空的', songs: [] },
            { id: 'top', title: '最常播放', songs: [{ id: 'a', title: 'A', duration: 1 }] },
            { title: '没有内容' },
          ];
        },
        albumSorts: ['year', 'title', 'shuffled'],
        async libraryAlbums(sort, genre, page) {
          if (genre) return [{ id: `${genre}-1`, name: `${sort} ${page.offset}` }];
          return { albums: [{ id: 'al', name: '专辑', artists: [{ id: 'ar', name: '歌手' }] }], total: page.offset + 2 };
        },
        async libraryArtists(page) {
          return [{ id: 'ar', name: '歌手', songCount: 3 }];
        },
        async libraryGenres() {
          return [{ name: 'Jazz', albumCount: 2, artwork: 'https://img.test/jazz.jpg' }, { name: '华语流行' }];
        },
      },
      account: {
        methods: ['password', 'code'],
        server: { placeholder: 'https://jellyfin.example.com' },
        passwordOptional: true,
        codeLogin: { title: '快速连接', hint: '在已登录的设备上输入' },
        async connect(address) {
          if (address === 'bad') throw starry.error('sourceUnreachable');
          const server = (address.includes('://') ? address : `http://${address}`).replace(/\\/+$/, '');
          starry.storage.set('pending', server);
          return { address: server, name: '家里的 NAS', version: '12.1.0', methods: ['password'] };
        },
        async loginWithPassword(username, password) {
          return this.signIn(username + (password === '' ? '（无密码）' : ''));
        },
        async beginCodeLogin() {
          starry.storage.set('polls', 0);
          return { key: 'k1', code: 123456 };
        },
        async pollCodeLogin(session) {
          const polls = starry.storage.get('polls') + 1;
          starry.storage.set('polls', polls);
          return polls < 2 ? 'waiting' : { status: 'confirmed', profile: this.signIn(`code ${session.key}`) };
        },
        signIn(name) {
          const server = starry.storage.get('pending');
          starry.storage.set('server', server);
          starry.setWebPages({ song: `${server}/web/#/details?id={id}` });
          return { userID: `u-${name}`, nickname: name, detail: '家里的 NAS' };
        },
        async refresh() { return null; },
        async logout() { starry.setWebPages(null); },
      },
    };
    """

    static func source() throws -> PluginSource {
        PluginSource(plugin: try Fixture.load(Self.script), settings: SourceSettingValues())
    }

    @Test func asksForTheServerFirst() async throws {
        let account = try Self.source().account
        #expect(account.serverPrompt == ServerPrompt(placeholder: "https://jellyfin.example.com"))
        #expect(account.passwordOptional)
        #expect(account.codeLogin == CodeLoginInfo(title: "快速连接", hint: "在已登录的设备上输入"))
        #expect(account.supportedMethods == [.password, .code])

        let server = try await account.connect(to: "nas.local:8096/")
        #expect(server == ServerInfo(address: "http://nas.local:8096", name: "家里的 NAS", version: "12.1.0", methods: [.password]))
        await #expect(throws: PlaybackError.sourceUnreachable) { _ = try await account.connect(to: "bad") }
    }

    @Test func signsInWithoutAPasswordAndSetsPageTemplates() async throws {
        let source = try Self.source()
        #expect(source.webURL(for: .song("x")) == URL(string: "https://static.test/x"))
        _ = try await source.account.connect(to: "https://music.home")
        try await source.account.loginWithPassword(username: "me", password: "")
        #expect(await source.account.state == .loggedIn(AccountProfile(userID: "u-me（无密码）", nickname: "me（无密码）", detail: "家里的 NAS")))
        #expect(source.webURL(for: .song("x")) == URL(string: "https://music.home/web/#/details?id=x"))
        try await source.account.logout()
        #expect(source.webURL(for: .song("x")) == URL(string: "https://static.test/x"))
    }

    @Test func signsInWithACode() async throws {
        let account = try Self.source().account
        _ = try await account.connect(to: "https://music.home")
        let session = try await account.beginCodeLogin()
        #expect(session == CodeLoginSession(key: "k1", code: "123456"))
        #expect(try await account.pollCodeLogin(session) == .waiting)
        #expect(try await account.pollCodeLogin(session) == .confirmed)
        guard case .loggedIn(let profile) = await account.state else { Issue.record("not signed in"); return }
        #expect(profile.nickname == "code k1" && profile.detail == "家里的 NAS")
    }

    @Test func handsOutTheLibraryByPage() async throws {
        let source = try Self.source()
        let first = try await source.allMedia(page: Page(offset: 0, limit: 2))
        #expect(first.tracks.map(\.id.id) == ["a", "b"])
        #expect(first.total == 5 && first.nextOffset == 3 && first.hasMore)
        let last = try await source.allMedia(page: Page(offset: 3, limit: 2))
        #expect(last.tracks.map(\.title) == ["C"] && last.total == nil && !last.hasMore)
    }

    @Test func namesItsHomeShelves() async throws {
        let source = try Self.source()
        #expect(source.capability((any HomeShelfSource).self) != nil)
        #expect(PluginSource(plugin: try Fixture.plugin(""), settings: SourceSettingValues()).capability((any HomeShelfSource).self) == nil)
        let shelves = try await source.homeShelves()
        #expect(shelves.map(\.id) == ["0", "top"])
        #expect(shelves.map(\.title) == ["最近添加", "最常播放"])
        guard case .albums(let albums) = shelves[0].items, case .songs(let songs) = shelves[1].items else {
            Issue.record("wrong kinds: \(shelves)")
            return
        }
        #expect(albums.map(\.id) == ["al"] && albums.first?.source == source.id)
        #expect(songs.map(\.id) == [TrackRef(source: source.id, id: "a")])
    }

    @Test func browsesItsLibrary() async throws {
        let source = try Self.source()
        let browsing = try #require(source.capability((any LibraryBrowsingSource).self))
        #expect(browsing.librarySections == [.albums, .artists, .genres])
        // Orders the app does not know are left out; the first is the default.
        #expect(browsing.albumSorts == [.year, .title])

        let albums = try await browsing.libraryAlbums(sort: .year, genre: nil, page: Page(offset: 0, limit: 60))
        #expect(albums.items.map(\.id) == ["al"] && albums.items.first?.source == source.id)
        #expect(albums.items.first?.artists == [ArtistRef(id: "ar", name: "歌手")])
        #expect(albums.total == 2 && albums.hasMore)
        let genre = try await browsing.libraryAlbums(sort: .title, genre: "Jazz", page: Page(offset: 60, limit: 60))
        #expect(genre.items.map(\.name) == ["title 60"] && genre.items.first?.id == "Jazz-1")
        #expect(genre.total == nil && !genre.hasMore)

        let artists = try await browsing.libraryArtists(page: Page(offset: 0, limit: 80))
        #expect(artists.items.map(\.songCount) == [3] && !artists.hasMore)

        let genres = try await browsing.libraryGenres()
        #expect(genres.map(\.name) == ["Jazz", "华语流行"])
        #expect(genres.map(\.albumCount) == [2, 0])
        #expect(genres.first?.artwork?.url == URL(string: "https://img.test/jazz.jpg"))
        #expect(genres.last?.artwork == nil)

        // A plugin with artists alone: no albums, so no genres either.
        let artistsOnly = PluginSource(plugin: try Fixture.plugin("source: { async resolve() { return { url: 'https://a.test/x.mp3' }; }, async libraryArtists() { return []; }, async libraryGenres() { return []; } },"), settings: SourceSettingValues())
        #expect(artistsOnly.capability((any LibraryBrowsingSource).self)?.librarySections == [.artists])
        #expect(artistsOnly.albumSorts == [.title])
        #expect(PluginSource(plugin: try Fixture.plugin(""), settings: SourceSettingValues()).capability((any LibraryBrowsingSource).self) == nil)
    }

    @Test func marksTranscodes() async throws {
        let source = try Self.source()
        let tier = source.tiers[0]
        let transcode = try await source.resolvePlayableAsset(Track(id: TrackRef(source: source.id, id: "t"), title: "T", duration: 1), tier: tier)
        let file = try await source.resolvePlayableAsset(Track(id: TrackRef(source: source.id, id: "f"), title: "F", duration: 1), tier: tier)
        #expect(transcode.isTranscode && !file.isTranscode)
        #expect(transcode.container == .flac)
    }

    @Test func checksTheAccountGroup() throws {
        func load(_ account: String) throws {
            _ = try Fixture.plugin("account: { async refresh() { return null; }, async logout() {}, \(account) },")
        }
        try load("methods: ['password'], server: {}, async connect(a) { return { address: a }; },")
        #expect(throws: PluginError.self) { try load("methods: ['password'], server: {},") }
        #expect(throws: PluginError.self) { try load("methods: ['code'], async beginCodeLogin() {}, async pollCodeLogin() {},") }
        #expect(throws: PluginError.self) { try load("methods: ['code'], codeLogin: { title: '快速连接' },") }
    }
}
