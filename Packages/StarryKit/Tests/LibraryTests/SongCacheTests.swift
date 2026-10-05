import Foundation
import StarryCore
import Testing
@testable import Library

struct SongCacheTests {
    /// A clock the tests move by hand, so play order is exact.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval = 60) { lock.withLock { date += seconds } }
    }

    private let root = FileManager.default.temporaryDirectory.appending(path: "songcache-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var directory: URL { root.appending(path: "songs", directoryHint: .isDirectory) }

    private func track(_ id: String, source: SourceID = .example) -> Track {
        Track(id: TrackRef(source: source, id: id), title: "Song \(id)", duration: 200)
    }

    private func download(_ bytes: Int, ext: String = "mp3") throws -> URL {
        let folder = root.appending(path: "downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(UUID().uuidString).\(ext)")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func cache(limit: Int64? = nil, clock: Clock = Clock()) -> SongCache {
        SongCache(directory: directory, limit: limit, now: { clock.now })
    }

    @Test func keepsAFileThatOutlivesTheDownload() async throws {
        let cache = cache()
        let file = try download(1000)
        #expect(await cache.add(file, for: track("1"), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.hq)))
        try FileManager.default.removeItem(at: file)
        let asset = try #require(await cache.asset(for: track("1"), tier: QualityTier(.hq)))
        #expect(asset.provider == .cache)
        #expect(asset.url.isFileURL)
        #expect(asset.url.lastPathComponent == "plugin-example-1.mp3")
        #expect(try Data(contentsOf: asset.url).count == 1000)
        #expect(asset.gain == nil)
        #expect(await cache.summary() == .init(count: 1, size: 1000, limit: nil))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func keepsTheLoudness() async throws {
        let gain = ReplayGain(trackGain: -7.4, albumGain: -6.9)
        #expect(await cache().add(try download(100), for: track("g"), container: .flac, tier: QualityTier(.lossless), requested: QualityTier(.lossless), gain: gain))
        #expect(await cache().asset(for: track("g"), tier: QualityTier(.lossless))?.gain == gain)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func qualityRules() async throws {
        let cache = cache()
        try await cache.add(download(10), for: track("hq"), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.hq))
        try await cache.add(download(10), for: track("capped"), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.lossless))
        try await cache.add(download(10, ext: "flac"), for: track("flac"), container: .flac, tier: QualityTier(.lossless), requested: QualityTier(.lossless))

        #expect(await cache.asset(for: track("hq"), tier: QualityTier(.sq)) != nil)
        #expect(await cache.asset(for: track("hq"), tier: QualityTier(.hq)) != nil)
        #expect(await cache.asset(for: track("hq"), tier: QualityTier(.lossless)) == nil)
        #expect(await cache.asset(for: track("capped"), tier: QualityTier(.lossless)) != nil)
        #expect(await cache.asset(for: track("capped"), tier: QualityTier(.hiRes)) == nil)
        #expect(await cache.asset(for: track("flac"), tier: QualityTier(.lq))?.container == .flac)
        try? FileManager.default.removeItem(at: root)
    }

    /// A spatial mix (such as Dolby Atmos) is not a better stereo file: it only answers a request
    /// for itself, and between it and a stereo file the one heard last stays. Entries kept
    /// before tiers read as stereo files of their level.
    @Test func spatialMixStandsApart() async throws {
        let cache = cache()
        let dolby = QualityTier(id: "dolby", name: "杜比全景声", level: .hiRes, isSpatial: true)
        try await cache.add(download(10, ext: "mp4"), for: track("1"), container: .mp4, tier: dolby, requested: dolby)
        #expect(await cache.asset(for: track("1"), tier: dolby)?.tier.isSpatial == true)
        #expect(await cache.asset(for: track("1"), tier: QualityTier(.hiRes)) == nil)
        #expect(await cache.asset(for: track("1"), tier: QualityTier(.hq)) == nil)
        #expect(try await cache.add(download(20, ext: "flac"), for: track("1"), container: .flac, tier: QualityTier(.hiRes), requested: QualityTier(.hiRes)))
        #expect(await cache.asset(for: track("1"), tier: QualityTier(.hiRes))?.container == .flac)
        #expect(await cache.asset(for: track("1"), tier: dolby) == nil)
        try await cache.add(download(20, ext: "flac"), for: track("2"), container: .flac, tier: QualityTier(.hiRes), requested: dolby)
        #expect(await cache.asset(for: track("2"), tier: dolby)?.tier.id == "hi-res")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func betterFileReplacesWorseNeverTheOtherWay() async throws {
        let cache = cache()
        try await cache.add(download(100), for: track("1"), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.hq))
        #expect(try await cache.add(download(300, ext: "flac"), for: track("1"), container: .flac, tier: QualityTier(.lossless), requested: QualityTier(.lossless)))
        #expect(try await !cache.add(download(50), for: track("1"), container: .mp3, tier: QualityTier(.sq), requested: QualityTier(.sq)))
        let entry = try #require(await cache.entry(for: track("1").id))
        #expect(entry.quality == .lossless)
        #expect(entry.file == "plugin-example-1.flac")
        #expect(await cache.summary().size == 300)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "index.json" }
        #expect(names == ["plugin-example-1.flac"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func evictsLeastRecentlyPlayed() async throws {
        let clock = Clock()
        let cache = cache(limit: 250, clock: clock)
        for id in ["a", "b"] {
            try await cache.add(download(100), for: track(id), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.hq))
            clock.advance()
        }
        _ = await cache.asset(for: track("a"), tier: QualityTier(.hq))
        clock.advance()
        try await cache.add(download(100), for: track("c"), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.hq))
        #expect(await cache.allEntries().map(\.track.id.id) == ["c", "a"])
        #expect(await cache.summary().size == 200)

        await cache.setLimit(150)
        #expect(await cache.allEntries().map(\.track.id.id) == ["c"])
        await cache.setLimit(nil)
        #expect(await cache.summary().limit == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func removeAndRemoveAll() async throws {
        let cache = cache()
        for id in ["1", "2", "3"] {
            try await cache.add(download(10), for: track(id), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.hq))
        }
        await cache.remove(track("2").id)
        #expect(await cache.allEntries().count == 2)
        #expect(await cache.asset(for: track("2"), tier: QualityTier(.hq)) == nil)
        await cache.removeAll()
        #expect(await cache.summary() == .init(count: 0, size: 0, limit: nil))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try await cache.add(download(10), for: track("4"), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.hq))
        #expect(await cache.asset(for: track("4"), tier: QualityTier(.hq)) != nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func reopensAndTidies() async throws {
        do {
            let cache = cache()
            for id in ["1", "2"] {
                try await cache.add(download(10), for: track(id), container: .mp3, tier: QualityTier(.hq), requested: QualityTier(.lossless))
            }
        }
        try FileManager.default.removeItem(at: directory.appending(path: "plugin-example-2.mp3"))
        try Data(count: 5).write(to: directory.appending(path: ".incoming-leftover"))
        try Data(count: 5).write(to: directory.appending(path: "plugin-example-9.mp3"))

        let reopened = cache()
        let entries = await reopened.allEntries()
        #expect(entries.map(\.track.id.id) == ["1"])
        #expect(entries.first?.requestedQuality == .lossless)
        #expect(entries.first?.track.title == "Song 1")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["index.json", "plugin-example-1.mp3"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func damagedIndexStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appending(path: "index.json"))
        try Data(count: 5).write(to: directory.appending(path: "plugin-example-1.mp3"))
        let cache = cache()
        #expect(await cache.summary().count == 0)
        #expect(await cache.asset(for: track("1"), tier: QualityTier(.hq)) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func fileNames() {
        #expect(SongCache.fileName(for: TrackRef(source: .example, id: "186016"), extension: "MP3") == "plugin-example-186016.mp3")
        #expect(SongCache.fileName(for: TrackRef(source: .subsonic(serverID: "home"), id: "ab_c-1"), extension: "flac") == "subsonic-home-ab_c-1.flac")
        let odd = SongCache.fileName(for: TrackRef(source: .plugin(id: "x"), id: "../../etc/passwd"), extension: "mp3")
        #expect(odd.hasPrefix("plugin-x-") && odd.hasSuffix(".mp3") && !odd.contains("/"))
    }
}
