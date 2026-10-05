import Foundation
import LyricsCore
import MusicSources
import StarryCore
import Testing
@testable import LyricsProviders

@Suite struct CipherTests {
    @Test func krcDecodes() throws {
        let file = try #require(Data(base64Encoded: "a3JjMTjbGsglTQAh26O7LNoWnBsF0AUt25Zi0NGuCKS3O8vgqe433stsLQ4XkDd8L3Ro9xlCKGaf1+1u6Fek5IjrCyDZ2QfJTzTCZ1ywcR66/u6PmF+Jb12rcjEewB+dz2MiqPzgKoCsQHVH7NAViw=="))
        let text = try KRCCipher.text(from: file)
        let document = try KRCParser.parse(text)
        #expect(document.metadata["ti"] == "Test")
        #expect(document.lines.map(\.text) == ["你好"])
        #expect(document.lines[0].syllables[1].start == 1.3)
        #expect(throws: KRCCipher.Failure.self) { try KRCCipher.text(from: Data("nope".utf8)) }
    }

    @Test func amllURLTemplates() {
        #expect(AMLLDatabase.url(template: "https://amlldb.bikonoo.com/%p/%s.ttml", folder: "ncm-lyrics", id: "1")?.absoluteString == "https://amlldb.bikonoo.com/ncm-lyrics/1.ttml")
        #expect(AMLLDatabase.url(template: "https://amlldb.bikonoo.com/", folder: "qq-lyrics", id: "00a")?.absoluteString == "https://amlldb.bikonoo.com/qq-lyrics/00a.ttml")
        #expect(AMLLDatabase.url(template: " ", folder: "ncm-lyrics", id: "1") == nil)
    }
}

/// Lyric platforms (plugins') for the tests that do not care which; the songs' own sources match.
private extension LyricsProviderID {
    static let a = LyricsProviderID(plugin: "a")
    static let b = LyricsProviderID(plugin: "b")
    static let c = LyricsProviderID(plugin: "c")
}

private extension SourceID {
    static let a = SourceID.plugin(id: "a")
    static let b = SourceID.plugin(id: "b")
}

private func track(_ source: SourceID = .a, id: String = "1", title: String = "晴天", artist: String = "周杰伦", duration: TimeInterval = 269) -> Track {
    Track(id: TrackRef(source: source, id: id), title: title, artists: [ArtistRef(id: "a", name: artist)], duration: duration)
}

private let yrc = "[1000,2000](1000,500,0)故(1500,500,0)事(2000,1000,0)的"
private let lrc = "[00:01.00]故事的\n[00:05.00]小黄花"
private let qrc = "[1000,2000]故(1000,500)事(1500,500)的(2000,1000)"

private final class FakeProvider: LyricsProvider, @unchecked Sendable {
    let id: LyricsProviderID
    let ttmlFolder: String?
    let raw: RawLyrics?
    let mid: String?
    let delay: Duration
    let failsSearch: Bool
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ id: LyricsProviderID, _ format: RawLyrics.Format?, body: String? = nil, translation: String? = nil, ttmlFolder: String? = nil, mid: String? = nil, delay: Duration = .zero, failsSearch: Bool = false) {
        self.id = id
        self.ttmlFolder = ttmlFolder
        self.mid = mid
        self.delay = delay
        self.failsSearch = failsSearch
        raw = format.map { format in
            RawLyrics(format: format, body: body ?? (format == .yrc ? yrc : format == .qrc ? qrc : lrc), translation: translation, providerName: id.displayName)
        }
    }

    func lyrics(for track: Track) async throws -> ProviderLyrics? {
        lock.withLock { _calls += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        return raw.map { ProviderLyrics(raw: $0, provider: id, song: LyricsSongRef(id: "\(id.rawValue)-song", mid: mid)) }
    }

    /// One song when it has lyrics, none otherwise.
    func searchSongs(_ keyword: String) async throws -> [LyricsSearchResult] {
        if failsSearch { throw LyricsHTTP.Failure.status(500) }
        return raw == nil ? [] : [LyricsSearchResult(provider: id, song: LyricsSongRef(id: "\(id.rawValue)-song"), title: keyword, artists: [])]
    }

    func lyrics(of song: LyricsSongRef) async throws -> RawLyrics? { raw }
}

private final class FakeLyricsSource: LyricsSource {
    let id = SourceID.local
    let displayName = "本地文件"

    func resolvePlayableAsset(_ track: Track, tier: QualityTier) async throws -> PlayableAsset { throw SourceError.notImplemented("test") }
    func lyrics(for track: TrackRef) async throws -> RawLyrics? { RawLyrics(format: .lrc, body: lrc, providerName: displayName) }
    func lyrics(matching query: LyricQuery) async throws -> RawLyrics? { nil }
}

private func resolver(_ providers: [any LyricsProvider], cache: LyricsCache = LyricsCache(directory: nil), trackSource: TrackSourceLyricsProvider? = nil) -> LyricsResolver {
    LyricsResolver(providers: providers, trackSource: trackSource, database: AMLLDatabase(cache: cache), cache: cache)
}

private func collect(_ resolver: LyricsResolver, _ track: Track, _ options: LyricsResolverOptions) async -> [ResolvedLyrics] {
    var results: [ResolvedLyrics] = []
    for await result in resolver.resolve(track, options: options) { results.append(result) }
    return results
}

private func offline() -> LyricsResolverOptions {
    var options = LyricsResolverOptions()
    options.ttmlDatabase = nil
    return options
}

private let ttml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
<p begin="00:01.000" end="00:03.000"><span begin="00:01.000" end="00:02.000">故事</span><span begin="00:02.000" end="00:03.000">的</span></p>
</div></body></tt>
"""

@Suite struct ResolverTests {
    @Test func candidatesListEverySource() async {
        let a = FakeProvider(.a, .yrc)
        let b = FakeProvider(.b, .qrc, delay: .milliseconds(30))
        let c = FakeProvider(.c, nil)
        var options = offline()
        options.providerOrder = [.b, .c, .a]
        let resolver = resolver([a, b, c])
        #expect(resolver.candidateSources(for: track(), options: options) == [.provider(.a), .provider(.b), .provider(.c)])
        var answers: [LyricsCandidateSource: String] = [:]
        for await candidate in resolver.candidates(for: track(), options: options) {
            answers[candidate.source] = candidate.lyrics?.document.format.rawValue ?? "none"
        }
        #expect(answers == [.provider(.b): "qrc", .provider(.c): "none", .provider(.a): "yrc"])
        // All asked, though b's word-timed QRC would have stopped the usual walk.
        #expect(a.calls == 1 && b.calls == 1 && c.calls == 1)
    }

    @Test func pinnedSourceIsAskedAlone() async {
        let a = FakeProvider(.a, .yrc)
        let b = FakeProvider(.b, .qrc)
        let resolver = resolver([a, b])
        let found = await resolver.lyrics(for: track(), from: .provider(.a), options: offline())
        #expect(found?.origin == .provider(.a))
        #expect(b.calls == 0)
        #expect(await resolver.lyrics(for: track(), from: .ttmlDatabase, options: offline()) == nil)
    }

    @Test func candidateSourceKeysRoundTrip() {
        let sources: [LyricsCandidateSource] = [.localRepository, .ttmlDatabase, .trackSource] + LyricsProviderID.known.map { .provider($0) }
        #expect(sources.map { LyricsCandidateSource(key: $0.key) } == sources)
        #expect(LyricsCandidateSource(key: "provider:nope") == nil)
        #expect(LyricsCandidateSource(origin: .trackSource("自建")) == .trackSource)
    }

    @Test func ownPlatformWordTimedComesFirst() async {
        let a = FakeProvider(.a, .yrc)
        let b = FakeProvider(.b, .qrc)
        let c = FakeProvider(.c, .krc)
        var options = offline()
        options.providerOrder = [.b, .c, .a]
        let results = await collect(resolver([a, b, c]), track(.a), options)
        #expect(results.map(\.origin) == [.provider(.a)])
        #expect(b.calls == 0 && c.calls == 0)
    }

    @Test func orderFollowsWhenOwnPlatformHasNone() async {
        let a = FakeProvider(.a, nil)
        let b = FakeProvider(.b, .qrc)
        let c = FakeProvider(.c, .krc)
        var options = offline()
        options.providerOrder = [.b, .c, .a]
        let results = await collect(resolver([a, b, c]), track(.a), options)
        #expect(results.map(\.origin) == [.provider(.b)])
        #expect(a.calls == 1 && c.calls == 0)
    }

    @Test func wordTimedElsewhereReplacesLineTimed() async {
        let a = FakeProvider(.a, .lrc)
        let b = FakeProvider(.b, .lrc)
        let c = FakeProvider(.c, .krc, body: "[1000,2000]<0,500,0>故<500,500,0>事<1000,1000,0>的")
        var options = offline()
        options.providerOrder = [.b, .c, .a]
        let results = await collect(resolver([a, b, c]), track(.a), options)
        #expect(results.map(\.origin) == [.provider(.a), .provider(.c)])
        #expect(results.last?.document.hasSyllables == true)
    }

    @Test func firstLineTimedStandsWhenNoneIsWordTimed() async {
        let a = FakeProvider(.a, .lrc)
        let b = FakeProvider(.b, .lrc)
        var options = offline()
        options.providerOrder = [.b, .a]
        let results = await collect(resolver([a, b]), track(.a), options)
        #expect(results.map(\.origin) == [.provider(.a)])
        #expect(b.calls == 1)
    }

    /// Off, the order alone decides; a platform turned off is not asked, the song's own included.
    @Test func orderAloneWhenOwnPlatformIsNotPreferred() async {
        let a = FakeProvider(.a, .yrc)
        let b = FakeProvider(.b, .qrc)
        var options = offline()
        options.preferTrackPlatform = false
        options.providerOrder = [.b, .a]
        let resolver = resolver([a, b])
        #expect(await collect(resolver, track(.a), options).map(\.origin) == [.provider(.b)])
        #expect(a.calls == 0)

        options.preferTrackPlatform = true
        options.providerOrder = [.b]
        #expect(await collect(resolver, track(.a), options).map(\.origin) == [.provider(.b)])
        #expect(a.calls == 0)
    }

    /// Racing asks every platform at once but chooses as the walk would: the slow own platform's
    /// line-timed lyrics first, then the next one's word-timed lyrics, not the faster ones after.
    @Test func raceChoosesLikeTheWalk() async {
        let a = FakeProvider(.a, .lrc, delay: .milliseconds(100))
        let b = FakeProvider(.b, .qrc, delay: .milliseconds(50))
        let c = FakeProvider(.c, .krc, body: "[1000,2000]<0,500,0>故<500,500,0>事<1000,1000,0>的")
        var options = offline()
        options.raceProviders = true
        options.providerOrder = [.b, .c, .a]
        let results = await collect(resolver([a, b, c]), track(.a), options)
        #expect(results.map(\.origin) == [.provider(.a), .provider(.b)])
        #expect(a.calls == 1 && b.calls == 1 && c.calls == 1)
    }

    @Test func ownSourceOfANonPlatformSong() async {
        let b = FakeProvider(.b, .qrc)
        let own = TrackSourceLyricsProvider { _ in FakeLyricsSource() }
        let resolver = resolver([b], trackSource: own)
        var options = offline()
        options.providerOrder = [.b]
        let local = track(.local, id: "/Music/a.flac")
        #expect(resolver.candidateSources(for: local, options: options) == [.trackSource, .provider(.b)])
        #expect(await collect(resolver, local, options).map(\.origin) == [.trackSource("本地文件"), .provider(.b)])

        options.preferTrackPlatform = false
        #expect(resolver.candidateSources(for: local, options: options) == [.provider(.b), .trackSource])
        #expect(await collect(resolver, local, options).map(\.origin) == [.provider(.b)])
    }

    @Test func unparsableResultsAreSkipped() async {
        let broken = FakeProvider(.a, .yrc, body: "   ")
        let b = FakeProvider(.b, .lrc)
        var options = offline()
        options.providerOrder = [.a, .b]
        let results = await collect(resolver([broken, b]), track(), options)
        #expect(results.map(\.origin) == [.provider(.b)])
    }

    @Test func creditLinesAreStripped() async {
        let body = "[00:00.00]晴天 - 周杰伦\n[00:00.50]词：周杰伦\n[00:01.00]故事的\n[00:05.00]小黄花"
        var options = offline()
        options.providerOrder = [.a]
        let results = await collect(resolver([FakeProvider(.a, .lrc, body: body)]), track(), options)
        #expect(results.first?.document.lines.map(\.text) == ["故事的", "小黄花"])
    }

    @Test func ttmlUpgradeBorrowsTranslation() async throws {
        let cache = LyricsCache(directory: nil)
        // Prime the AMLL cache for the track's own id, in its provider's folder, so no request is made.
        _ = try await cache.ttml(platform: "amlldb.bikonoo.com/ncm-lyrics", id: "42") { ttml }
        let a = FakeProvider(.a, .yrc, translation: "[00:01.00]从前从前", ttmlFolder: "ncm-lyrics")
        var options = LyricsResolverOptions()
        options.providerOrder = [.a]
        let results = await collect(resolver([a], cache: cache), track(.a, id: "42"), options)
        // The cached TTML is shown directly instead of flashing the YRC first.
        #expect(results.map(\.origin) == [.ttmlDatabase])
        #expect(results.first?.document.format == .ttml)
        #expect(results.first?.document.lines.first?.translation == "从前从前")
    }

    @Test func ttmlUsesTheMatchedSong() async throws {
        let cache = LyricsCache(directory: nil)
        _ = try await cache.ttml(platform: "amlldb.bikonoo.com/qq-lyrics", id: "mid-1") { ttml }
        let b = FakeProvider(.b, .qrc, ttmlFolder: "qq-lyrics", mid: "mid-1")
        var options = LyricsResolverOptions()
        options.providerOrder = [.b]
        let results = await collect(resolver([b], cache: cache), track(.local, id: "/tmp/a.flac"), options)
        #expect(results.map(\.origin) == [.provider(.b), .ttmlDatabase])
    }

    @Test func ttmlUsesTheTracksOwnEntries() async throws {
        let cache = LyricsCache(directory: nil)
        _ = try await cache.ttml(platform: "amlldb.bikonoo.com/am-lyrics", id: "1440818839") { ttml }
        var song = track(.local, id: "/tmp/a.flac")
        song.ttml = [TTMLKey(folder: "am-lyrics", id: "1440818839")]
        let results = await collect(resolver([], cache: cache), song, LyricsResolverOptions())
        #expect(results.map(\.origin) == [.ttmlDatabase])

        let folder = FileManager.default.temporaryDirectory.appending(path: "starry-ttml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "am-lyrics"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ttml.write(to: folder.appending(path: "am-lyrics/1440818839.ttml"), atomically: true, encoding: .utf8)
        var options = offline()
        options.localRepository = folder
        #expect(await collect(resolver([]), song, options).map(\.origin) == [.localRepository])
    }

    @Test func noFolderNoTTML() async throws {
        let cache = LyricsCache(directory: nil)
        _ = try await cache.ttml(platform: "amlldb.bikonoo.com/ncm-lyrics", id: "42") { ttml }
        let a = FakeProvider(.a, .yrc)
        var options = LyricsResolverOptions()
        options.providerOrder = [.a]
        let results = await collect(resolver([a], cache: cache), track(.a, id: "42"), options)
        #expect(results.map(\.origin) == [.provider(.a)])
    }

    @Test func localRepositoryWins() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "starry-ttml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "qq-lyrics"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let withMeta = ttml.replacingOccurrences(of: "<body>", with: "<head><metadata><amll:meta key=\"musicName\" value=\"晴天\"/><amll:meta key=\"artists\" value=\"周杰伦\"/></metadata></head><body>")
        try withMeta.write(to: folder.appending(path: "sunny.ttml"), atomically: true, encoding: .utf8)
        try ttml.write(to: folder.appending(path: "qq-lyrics/186016.ttml"), atomically: true, encoding: .utf8)

        let a = FakeProvider(.a, .yrc, ttmlFolder: "qq-lyrics")
        var options = offline()
        options.providerOrder = [.a]
        options.localRepository = folder
        let byID = await collect(resolver([a]), track(.a, id: "186016", title: "别的歌"), options)
        #expect(byID.map(\.origin) == [.localRepository])
        let byTitle = await collect(resolver([a]), track(.b, id: "9"), options)
        #expect(byTitle.map(\.origin) == [.localRepository])
        let otherArtist = await collect(resolver([a]), track(.b, id: "9", artist: "孙燕姿"), options)
        #expect(otherArtist.map(\.origin) == [.provider(.a)])
        #expect(a.calls == 1)
    }
}

private struct FakeSearchProvider: MatchingLyricsProvider {
    let id = LyricsProviderID.b
    let cache: LyricsCache
    let counter: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func hit(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
        subscript(_ key: String) -> Int { lock.withLock { values[key] ?? 0 } }
    }

    func lyrics(for track: Track) async throws -> ProviderLyrics? { try await matchedLyrics(for: track) }

    func searchSongs(_ keyword: String) async throws -> [LyricsSearchResult] { try await searchResults(keyword) }

    func lyrics(of song: LyricsSongRef) async throws -> RawLyrics? { try await cachedLyrics(of: song) }

    func ownSong(of track: Track) -> LyricsSongRef? {
        track.id.source == .b ? LyricsSongRef(id: track.id.id) : nil
    }

    func search(keyword: String) async throws -> [LyricCandidate<LyricsSongRef>] {
        counter.hit("search")
        return [
            LyricCandidate(title: "晴天 (Live)", artists: ["周杰伦"], duration: 300, payload: LyricsSongRef(id: "live")),
            LyricCandidate(title: "晴天", artists: ["周杰伦"], duration: 270, payload: LyricsSongRef(id: "studio")),
        ]
    }

    func fetch(_ song: LyricsSongRef) async throws -> RawLyrics? {
        counter.hit("fetch-\(song.id)")
        try await Task.sleep(for: .milliseconds(20))
        return RawLyrics(format: .lrc, body: lrc, providerName: "fake")
    }
}

@Suite struct MatchingFlowTests {
    @Test func searchesOnceAndCachesMatchAndLyrics() async throws {
        let provider = FakeSearchProvider(cache: LyricsCache(directory: nil), counter: .init())
        let song = track(.a, id: "1")
        async let a = provider.lyrics(for: song)
        async let b = provider.lyrics(for: song)
        let (first, second) = try await (a, b)
        #expect(first?.song.id == "studio")
        #expect(first?.song.title == "晴天")
        #expect(second?.song.id == "studio")
        _ = try await provider.lyrics(for: song)
        #expect(provider.counter["search"] == 1)
        #expect(provider.counter["fetch-studio"] == 1)
        _ = try await provider.lyrics(for: track(.b, id: "own"))
        #expect(provider.counter["search"] == 1)
        #expect(provider.counter["fetch-own"] == 1)
    }

    @Test func cacheExpiresMissesSooner() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let cache = LyricsCache(directory: FileManager.default.temporaryDirectory.appending(path: "starry-cache-\(UUID().uuidString)"), now: { clock.now })
        defer { Task { await cache.clear() } }
        final class Loads: @unchecked Sendable { var count = 0 }
        let loads = Loads()
        let miss: @Sendable () async throws -> RawLyrics? = { loads.count += 1; return nil }
        _ = try await cache.lyrics(provider: .c, songID: "abc", load: miss)
        _ = try await cache.lyrics(provider: .c, songID: "abc", load: miss)
        #expect(loads.count == 1)
        clock.now += 86_400 + 1
        _ = try await cache.lyrics(provider: .c, songID: "abc", load: miss)
        #expect(loads.count == 2)
        #expect(await cache.size() > 0)
    }
}

@Suite struct ManualLyricsTests {
    /// A typed search asks every provider, the enabled ones first; a failing one answers nil
    /// and nothing typed asks no one.
    @Test func searchAsksEveryProvider() async {
        var options = offline()
        options.providerOrder = [.c]
        let resolver = resolver([FakeProvider(.a, .yrc), FakeProvider(.b, .qrc, failsSearch: true), FakeProvider(.c, nil)])
        #expect(resolver.searchProviders(options: options) == [.c, .a, .b])
        var counts: [LyricsProviderID: Int] = [:]
        for await answer in resolver.searchSongs(" 晴天 ", options: options) {
            counts[answer.provider] = answer.results?.count ?? -1
        }
        #expect(counts == [.a: 1, .b: -1, .c: 0])
        var asked = false
        for await _ in resolver.searchSongs("  ", options: options) { asked = true }
        #expect(!asked)
    }

    @Test func pickedSongIsFetchedOnce() async throws {
        let provider = FakeSearchProvider(cache: LyricsCache(directory: nil), counter: .init())
        let resolver = resolver([provider])
        var results: [LyricsSearchResult] = []
        for await answer in resolver.searchSongs("晴天", options: offline()) { results += answer.results ?? [] }
        #expect(results.map(\.song.id) == ["live", "studio"])
        #expect(results[0].song.title == "晴天 (Live)" && results[0].song.duration == 300)
        let picked = try await resolver.lyrics(of: results[0], for: track(), options: offline())
        #expect(picked?.origin == .pickedSong(.b))
        let pinned = await resolver.lyrics(for: track(), pinnedTo: .song(results[0]), options: offline())
        #expect(pinned?.document.lines.count == 2)
        #expect(provider.counter["fetch-live"] == 1)
        #expect(provider.counter["fetch-studio"] == 0)
        #expect(LyricsCandidateSource(origin: .pickedSong(.b)) == nil)
    }

    /// A file is read as its extension says, by its content when that does not parse or the
    /// extension says nothing, and gives nothing when nothing in it is timed.
    @Test func filesParseByExtensionThenContent() async {
        let resolver = resolver([])
        let pinned = await resolver.lyrics(for: track(), pinnedTo: .file(LyricsFile(name: "晴天.lrc", text: lrc)), options: offline())
        #expect(pinned?.origin == .file("晴天.lrc"))
        #expect(pinned?.document.format == .lrc)
        #expect(resolver.lyrics(from: LyricsFile(name: "晴天.lrc", text: yrc), for: track(), options: offline())?.document.format == .yrc)
        #expect(resolver.lyrics(from: LyricsFile(name: "晴天.txt", text: ttml), for: track(), options: offline())?.document.format == .ttml)
        #expect(resolver.lyrics(from: LyricsFile(name: "notes.txt", text: "just words"), for: track(), options: offline()) == nil)
    }

    /// GB 18030 (older Chinese LRC), UTF-8 with a BOM, UTF-16 and an encrypted .krc all
    /// read as text; an empty file does not.
    @Test func fileEncodings() throws {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        #expect(LyricsFile(name: "a.lrc", data: try #require(lrc.data(using: gb18030)))?.text == lrc)
        #expect(LyricsFile(name: "a.lrc", data: Data([0xEF, 0xBB, 0xBF]) + Data(lrc.utf8))?.text == lrc)
        #expect(LyricsFile(name: "a.lrc", data: try #require(lrc.data(using: .utf16)))?.text == lrc)
        let krc = try #require(Data(base64Encoded: "a3JjMTjbGsglTQAh26O7LNoWnBsF0AUt25Zi0NGuCKS3O8vgqe433stsLQ4XkDd8L3Ro9xlCKGaf1+1u6Fek5IjrCyDZ2QfJTzTCZ1ywcR66/u6PmF+Jb12rcjEewB+dz2MiqPzgKoCsQHVH7NAViw=="))
        #expect(try KRCParser.parse(try #require(LyricsFile(name: "a.krc", data: krc)).text).lines.map(\.text) == ["你好"])
        #expect(LyricsFile(name: "a.lrc", data: Data()) == nil)
    }
}
