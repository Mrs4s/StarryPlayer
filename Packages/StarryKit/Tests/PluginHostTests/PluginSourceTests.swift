import Foundation
import LyricsProviders
import MusicSources
import StarryCore
import Testing
@testable import PluginHost

@Suite struct PluginSourceTests {
    static let script = """
    source: {
      qualityTiers: [
        { id: 'std', name: '标准', level: 'lq' },
        { id: 'sq', name: '无损', detail: 'FLAC', level: 'lossless' },
        { id: 'atmos', name: '全景声', level: 'lossless', spatial: true },
      ],
      searchKinds: ['playlist', 'song', 'user'],
      webPages: { song: 'https://music.test/song/{id}' },
      async resolve(track, tier) {
        if (track.id === 'vip') throw starry.error('vipRequired');
        const gain = track.id === 's1' ? { trackGain: -6.5, trackPeak: 0.98, albumGain: -7.25 } : track.id === 'odd' ? { trackPeak: 0.5 } : undefined;
        return { url: `https://cdn.test/${track.id}.flac?t=${tier.id}`, tier: tier.id === 'atmos' ? 'atmos' : 'sq', headers: { Referer: 'https://music.test/' }, expiresIn: 60, gain };
      },
      async search(query, kind, page) {
        if (kind !== 'song') return { playlists: [{ id: 7, name: query, trackCount: 3, createdAt: 1700000000000 }] };
        return {
          songs: [
            { id: 123, title: query, artists: [{ id: 'a1', name: '歌手' }], album: { id: 'al', name: '专辑', artwork: 'https://img.test/al.jpg' }, duration: 200.5, tiers: ['std', 'sq'], fee: 'vip',
              ttml: [{ folder: 'am-lyrics', id: 1440818839 }, { folder: ' ', id: '1' }, { folder: 'ncm-lyrics' }, { folder: 'ncm-lyrics', id: '186016' }] },
            { id: 'x', title: '二', duration: 10, artwork: { url: 'https://img.test/{w}.jpg', sizedTemplate: 'https://img.test/{width}x{height}.jpg', sizeSteps: [500, 150] } },
          ],
          hasMore: true,
          total: 40,
        };
      },
      async album(id) { return { album: { id, name: '专辑', releaseDate: '2024-05-01', artists: [{ id: 'a1', name: '歌手' }] }, tracks: [{ id: 't', title: 'T', duration: 1 }] }; },
      async searchHints() { return ['晴天', { display: '晴天 - 周杰伦', query: '晴天' }]; },
    },
    settings: [{ id: 'main', title: '连接', settings: [
      { key: 'region', title: '地区', type: 'choice', default: 'cn', choices: [{ value: 'cn', title: '大陆' }, { value: 'hk', title: '香港' }] },
      { key: 'hq', title: '优先无损', type: 'toggle', default: true },
      { key: 'broken', title: '坏的', type: 'slider' },
    ] }],
    onSettingsChanged(values) { starry.storage.set('changed', values.region); },
    test: { settings() { return { values: starry.settings, changed: starry.storage.get('changed') || null }; } },
    """

    static func source(values: SourceSettingValues = SourceSettingValues()) throws -> PluginSource {
        let plugin = try Fixture.load("""
        module.exports = { id: 'test.music', name: '测试音乐', version: '2.0', apiVersion: 1, icon: 'music.note', permissions: { hosts: [] },
        \(script)
        };
        """)
        return PluginSource(plugin: plugin, settings: values)
    }

    @Test func answersOnlyForWhatItExports() throws {
        let source = try Self.source()
        #expect(source.id == .plugin(id: "test.music"))
        #expect(source.displayName == "测试音乐")
        #expect(source.capability((any SearchableSource).self) != nil)
        #expect(source.capability((any CatalogSource).self) != nil)
        #expect(source.capability((any ConfigurableSource).self) != nil)
        #expect(source.capability((any RecommendationSource).self) == nil)
        #expect(!source.supports((any AccountSource).self))
        #expect(source.supports((any MusicSource).self))
        #expect(source.searchKinds == [.song, .playlist])
        #expect(source.qualityTiers.map(\.id) == ["std", "sq", "atmos"])
        #expect(source.qualityTiers.last?.isSpatial == true)
        #expect(source.webURL(for: .song("a b")) == URL(string: "https://music.test/song/a%20b"))
        #expect(source.webURL(for: .album("1")) == nil)
        #expect(source.settingsSymbol == "music.note")

        let bare = PluginSource(plugin: try Fixture.plugin(""), settings: SourceSettingValues())
        #expect(!bare.supports((any SearchableSource).self))
        #expect(!bare.supports((any CatalogSource).self))
        #expect(!bare.supports((any ConfigurableSource).self))
        #expect(bare.tiers.map(\.id) == AudioQuality.allCases.map(\.rawValue))
    }

    @Test func mapsSearchResults() async throws {
        let source = try Self.source()
        let page = try await source.search("晴天", kind: .song, page: Page(offset: 0, limit: 2))
        #expect(page.songs.count == 2)
        let first = page.songs[0]
        #expect(first.id == TrackRef(source: .plugin(id: "test.music"), id: "123"))
        #expect(first.artists == [ArtistRef(id: "a1", name: "歌手")])
        #expect(first.album?.name == "专辑")
        #expect(first.artwork?.url == URL(string: "https://img.test/al.jpg"))
        #expect(first.duration == 200.5)
        #expect(first.availableTiers == ["std", "sq"])
        #expect(first.fee == .vip)
        #expect(first.ttml == [TTMLKey(folder: "am-lyrics", id: "1440818839"), TTMLKey(folder: "ncm-lyrics", id: "186016")])
        #expect(page.songs[1].ttml == nil)
        #expect(page.songs[1].artwork?.sized(300) == URL(string: "https://img.test/500x500.jpg"))
        #expect(page.hasMore)
        #expect(page.nextPage == Page(offset: 2, limit: 2))
        #expect(page.total == 40)

        let playlists = try await source.search("x", kind: .playlist, page: .first)
        #expect(playlists.playlists.first?.id == "7")
        #expect(playlists.playlists.first?.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!playlists.hasMore)

        let hints = try await source.searchHints()
        #expect(hints == [SearchHint(display: "晴天", query: "晴天"), SearchHint(display: "晴天 - 周杰伦", query: "晴天")])
        #expect(try await source.searchSuggestions("q").isEmpty)
    }

    @Test func resolvesAssets() async throws {
        let source = try Self.source()
        let track = Track(id: TrackRef(source: source.id, id: "s1"), title: "S", duration: 100)
        let asset = try await source.resolvePlayableAsset(track, tier: source.qualityTiers[1])
        #expect(asset.url == URL(string: "https://cdn.test/s1.flac?t=sq"))
        #expect(asset.container == .flac)
        #expect(asset.tier.id == "sq")
        #expect(asset.headers == ["Referer": "https://music.test/"])
        #expect(asset.pluginID == "test.music")
        #expect(asset.provider == .source)
        #expect(asset.supportsTap)
        let expires = try #require(asset.expiresAt)
        #expect(abs(expires.timeIntervalSinceNow - 60) < 5)
        #expect(asset.gain == ReplayGain(trackGain: -6.5, trackPeak: 0.98, albumGain: -7.25))
        let odd = try await source.resolvePlayableAsset(Track(id: TrackRef(source: source.id, id: "odd"), title: "O", duration: 1), tier: source.qualityTiers[0])
        #expect(odd.gain == nil)

        let atmos = try await source.resolvePlayableAsset(track, tier: source.qualityTiers[2])
        #expect(atmos.tier.isSpatial)
        #expect(!atmos.supportsTap)

        let vip = Track(id: TrackRef(source: source.id, id: "vip"), title: "V", duration: 1)
        await #expect(throws: PlaybackError.vipRequired) { _ = try await source.resolvePlayableAsset(vip, tier: source.qualityTiers[0]) }
    }

    @Test func catalogCallsWhatItHas() async throws {
        let source = try Self.source()
        let album = try await source.album(id: "al")
        #expect(album.album.source == source.id)
        #expect(album.album.releaseDate == Date(timeIntervalSince1970: 1_714_521_600))
        #expect(album.tracks.map(\.title) == ["T"])
        await #expect(throws: SourceError.notImplemented("测试音乐的歌单")) { _ = try await source.playlist(id: "p") }
        #expect(try await source.similarArtists(id: "a").isEmpty)
    }

    @Test func settingsReachThePlugin() async throws {
        var values = SourceSettingValues()
        values["hq"] = .bool(false)
        let source = try Self.source(values: values)
        #expect(source.settingsSections.first?.settings.map(\.key) == ["region", "hq"])
        let initial: AnyJSON = try await source.plugin.call("test.settings")
        #expect(initial["values"] as? [String: AnyHashable] == ["region": "cn", "hq": false])
        #expect(initial["changed"] is NSNull)

        values["region"] = .string("hk")
        await source.applySettings(values)
        try await Task.sleep(for: .milliseconds(50))
        let changed: AnyJSON = try await source.plugin.call("test.settings")
        #expect(changed["values"] as? [String: AnyHashable] == ["region": "hk", "hq": false])
        #expect(changed["changed"] as? String == "hk")
    }
}

@Suite struct PluginLyricsTests {
    static let script = """
    module.exports = {
      id: 'test.lyrics', name: '测试歌词', version: '1', apiVersion: 1, permissions: { hosts: [] },
      lyrics: {
        detail: 'LRC',
        ttmlFolder: 'test-lyrics',
        async search(keyword) {
          return [
            { id: 1, title: '晴天 (Live)', artists: '周杰伦', duration: 300 },
            { id: 2, title: '晴天', artists: ['周杰伦'], album: '叶惠美', duration: 269 },
          ];
        },
        async fetch(song) {
          return song.id === '2' ? { format: 'LRC', body: `[00:01.00]${song.title}` } : null;
        },
      },
    };
    """

    @Test func searchesMatchesAndFetches() async throws {
        let plugin = try Fixture.load(Self.script)
        let id = LyricsProviderID(plugin: "test.lyrics")
        #expect(plugin.lyricsProviderID == id)
        #expect(id.displayName == "测试歌词")
        #expect(id.detail == "LRC")
        let provider = try #require(plugin.lyricsProvider(cache: LyricsCache(directory: nil)))
        #expect(provider.ttmlFolder == "test-lyrics")
        let track = Track(id: TrackRef(source: .local, id: "1"), title: "晴天", artists: [ArtistRef(id: "j", name: "周杰伦")], duration: 270)
        let found = try #require(try await provider.lyrics(for: track))
        #expect(found.provider == id)
        #expect(found.song.id == "2")
        #expect(found.raw.format == .lrc)
        #expect(found.raw.body == "[00:01.00]晴天")
        #expect(found.raw.providerName == "测试歌词")

        let results = try await provider.searchSongs("晴天")
        #expect(results.map(\.song.id) == ["1", "2"])
        #expect(results[0].artists == ["周杰伦"])
        #expect(try await provider.lyrics(of: results[0].song) == nil)
    }

    @Test func ownTracksAreFetchedByID() async throws {
        let plugin = try Fixture.load(Self.script.replacingOccurrences(of: "test.lyrics", with: "test.own"))
        let provider = try #require(plugin.lyricsProvider(cache: LyricsCache(directory: nil)))
        let track = Track(id: TrackRef(source: .plugin(id: "test.own"), id: "2"), title: "别的名字", duration: 1)
        let found = try await provider.lyrics(for: track)
        #expect(found?.raw.body == "[00:01.00]别的名字")
    }
}

@Suite struct ProviderIDTests {
    @Test func parsesOnlyProviders() {
        #expect(LyricsProviderID(rawValue: "netease") == .netease)
        #expect(LyricsProviderID(rawValue: "kugou")?.sourceID == .kugou)
        #expect(LyricsProviderID(rawValue: "auto") == nil)
        #expect(LyricsProviderID(rawValue: "self") == nil)
        #expect(LyricsProviderID(rawValue: "plugin:") == nil)
        let plugin = LyricsProviderID(rawValue: "plugin:net.lrclib.lyrics")
        #expect(plugin == LyricsProviderID(plugin: "net.lrclib.lyrics"))
        #expect(plugin?.sourceID == .plugin(id: "net.lrclib.lyrics"))
        #expect(LyricsProviderID(source: .plugin(id: "a.b"))?.rawValue == "plugin:a.b")
        #expect(LyricsProviderID(source: .local) == nil)
    }

    @Test func roundTripsAsAString() throws {
        let data = try JSONEncoder().encode([LyricsProviderID.qqmusic, LyricsProviderID(plugin: "a.b")])
        #expect(String(decoding: data, as: UTF8.self) == #"["qqmusic","plugin:a.b"]"#)
        #expect(try JSONDecoder().decode([LyricsProviderID].self, from: data) == [.qqmusic, LyricsProviderID(plugin: "a.b")])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([LyricsProviderID].self, from: Data(#"["auto"]"#.utf8)) }
    }

    @Test func sourceKeysRoundTrip() {
        for id: SourceID in [.netease, .qqMusic, .kugou, .local, .subsonic(serverID: "s:1"), .jellyfin(serverID: "j"), .plugin(id: "a.b")] {
            #expect(SourceID(key: id.key) == id)
        }
        #expect(SourceID(key: "nope") == nil)
        #expect(SourceID(key: "plugin:") == nil)
    }
}
