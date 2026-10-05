import AVFoundation
import Foundation
import StarryCore
import Testing
@testable import PlaybackEngine

/// `keepsDownloads` (the song cache setting): every streamed song plays through one download to disk, and
/// the finished file is reported for the current song only, so the song cache can keep it
/// without fetching it again.
@MainActor
@Suite(.serialized) struct KeptDownloadTests {
    @Test func reportsTheFinishedFileOfAStreamedSong() async throws {
        let data = try Self.caf(seconds: 8)
        let (url, server) = try StubRangeProtocol.register(data, name: "song.caf")
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.keepsDownloads = true
        engine.volume = 0
        defer { engine.stop() }
        let finished = Self.collectDownloads(of: engine)
        defer { finished.task.cancel() }

        let track = TrackRef(source: .example, id: "1")
        try await engine.load(Self.asset(url), track: track, autoplay: true)
        try await Self.waitUntil { !finished.reports.isEmpty }
        let report = try #require(finished.reports.first)
        #expect(report.track == track)
        #expect(try Data(contentsOf: report.file) == data)
        #expect(server.served <= server.size + StubRangeProtocol.chunk)
        try await Self.waitUntil { engine.currentTime > 0.3 }
    }

    @Test func streamsDirectlyOtherwise() async throws {
        let (url, server) = try StubRangeProtocol.register(Self.caf(seconds: 4), name: "song.caf")
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        let finished = Self.collectDownloads(of: engine)
        defer { finished.task.cancel() }

        try await engine.load(Self.asset(url), track: TrackRef(source: .example, id: "off"), autoplay: true)
        engine.keepsDownloads = true
        var trial = Self.asset(url)
        trial.isTrial = true
        try await engine.load(trial, track: TrackRef(source: .example, id: "trial"), autoplay: true)
        try await Task.sleep(for: .milliseconds(800))
        // AVPlayer's own loading never reaches the stub (it is only in the download session).
        #expect(server.served == 0)
        #expect(finished.reports.isEmpty)
    }

    @Test func armedSongReportsWhenItPlays() async throws {
        let (currentURL, _) = try StubRangeProtocol.register(Self.caf(seconds: 8), name: "current.caf")
        let (nextURL, nextServer) = try StubRangeProtocol.register(Self.caf(seconds: 4), name: "next.caf")
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.keepsDownloads = true
        engine.volume = 0
        defer { engine.stop() }
        let finished = Self.collectDownloads(of: engine)
        defer { finished.task.cancel() }

        let current = TrackRef(source: .example, id: "current")
        let next = TrackRef(source: .example, id: "next")
        try await engine.load(Self.asset(currentURL), track: current, autoplay: true)
        await engine.arm(next: Self.asset(nextURL), track: next)
        try await Self.waitUntil { nextServer.served >= nextServer.size && finished.reports.count >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished.reports.map(\.track) == [current])

        try await engine.load(Self.asset(nextURL), track: next, autoplay: true)
        try await Self.waitUntil { finished.reports.count == 2 }
        #expect(finished.reports.last?.track == next)
        #expect(nextServer.served <= nextServer.size + StubRangeProtocol.chunk)
    }

    @Test func pivotReportsTheArmedDownload() async throws {
        let (currentURL, _) = try StubRangeProtocol.register(Self.caf(seconds: 3), name: "current.caf")
        let (nextURL, nextServer) = try StubRangeProtocol.register(Self.caf(seconds: 3), name: "next.caf")
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.keepsDownloads = true
        engine.transitionMode = .gapless
        engine.volume = 0
        defer { engine.stop() }
        let finished = Self.collectDownloads(of: engine)
        defer { finished.task.cancel() }

        let current = TrackRef(source: .example, id: "current")
        let next = TrackRef(source: .example, id: "next")
        try await engine.load(Self.asset(currentURL), track: current, autoplay: true)
        await engine.arm(next: Self.asset(nextURL), track: next)
        try await Self.waitUntil { nextServer.served >= nextServer.size }
        try await Self.waitUntil(timeout: .seconds(6)) { engine.currentTrack == next }
        try await Self.waitUntil { finished.reports.count == 2 }
        #expect(finished.reports.map(\.track) == [current, next])
    }

    private final class Reports {
        var reports: [(track: TrackRef, file: URL)] = []
        var task: Task<Void, Never>!
    }

    private static func collectDownloads(of engine: AVDeckEngine) -> Reports {
        let reports = Reports()
        reports.task = Task { @MainActor in
            for await event in engine.events {
                if case .downloadFinished(let track, let file) = event { reports.reports.append((track, file)) }
            }
        }
        return reports
    }

    private static func asset(_ url: URL) -> PlayableAsset {
        PlayableAsset(url: url, container: .wav, tier: QualityTier(.hq), supportsTap: false, provider: .source)
    }

    /// A tone, so the file is not all zeros.
    private static func caf(seconds: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "kept-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(seconds * format.sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<2 {
                let samples = buffer.floatChannelData![channel]
                for i in 0..<Int(frames) { samples[i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
            }
            try file.write(from: buffer)
        }()
        return try Data(contentsOf: url)
    }

    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
