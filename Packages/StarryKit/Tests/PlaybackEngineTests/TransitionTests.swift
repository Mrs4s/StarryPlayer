import AudioProcessing
import AVFoundation
import Foundation
import StarryCore
import Testing
@testable import PlaybackEngine

@MainActor
@Suite(.serialized) struct TransitionTests {
    @Test(arguments: [false, true])
    func gaplessStartsAtTheExactEnd(tapped: Bool) async throws {
        let (a, b) = (try Self.tone(seconds: 4.5), try Self.tone(seconds: 3))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.gapless)
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: tapped), track: Self.first, autoplay: true)
        #expect(await engine.arm(next: Self.asset(b, tapped: tapped), track: Self.second))
        try await Self.waitUntil { engine.state == .scheduled(next: Self.second) }
        let current = engine.active
        let end = try #require(current.exactEnd)
        let endHost = CMSyncConvertTime(end, from: try #require(current.itemTimebase), to: CMClockGetHostTimeClock())

        try await Self.waitUntil { log.pivots == [Self.second] }
        #expect(engine.currentTrack == Self.second)
        let incoming = engine.active
        try await Self.waitUntil { incoming.rawTime > 0.2 }
        let startHost = CMSyncConvertTime(.zero, from: try #require(incoming.itemTimebase), to: CMClockGetHostTimeClock())
        #expect(abs((startHost - endHost).seconds) < 0.001, "seam \((startHost - endHost).seconds * 1000) ms")

        try await Self.waitUntil { log.ended == 1 }
        #expect(!log.events.contains("playbackEnded"))
        #expect(!log.events.contains("transitionBegan"))
        #expect(engine.state == .playing)
        #expect(engine.idle.asset == nil, "the previous song is unloaded once it has ended")
    }

    @Test func crossfadeOverlapsTheSongs() async throws {
        let (a, b) = (try Self.tone(seconds: 5), try Self.tone(seconds: 4))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.crossfade(seconds: 1))
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: true), track: Self.first, autoplay: true)
        #expect(await engine.arm(next: Self.asset(b, tapped: true), track: Self.second))
        try await Self.waitUntil { engine.state == .scheduled(next: Self.second) }
        let current = engine.active
        let end = try #require(current.exactEnd).seconds
        #expect(current.fades == TransitionFades(fadeOut: (end - 1)...end))
        #expect(engine.idle.fades == TransitionFades(fadeIn: 0...1))
        let overlapHost = CMSyncConvertTime(CMTime(seconds: end - 1, preferredTimescale: 1_000_000_000), from: try #require(current.itemTimebase), to: CMClockGetHostTimeClock())

        try await Self.waitUntil { log.pivots == [Self.second] }
        #expect(engine.state == .overlapping(previous: Self.first))
        // Not before the overlap (a busy main thread may get to it a little later).
        #expect(current.rawTime >= end - 1.01, "pivot at \(current.rawTime) of \(end)")
        let incoming = engine.active
        try await Self.waitUntil { incoming.rawTime > 0.2 }
        let startHost = CMSyncConvertTime(.zero, from: try #require(incoming.itemTimebase), to: CMClockGetHostTimeClock())
        #expect(abs((startHost - overlapHost).seconds) < 0.001)
        #expect(current.player.rate > 0, "the previous song plays on through the overlap")

        try await Self.waitUntil { log.ended == 1 }
        #expect(log.events.filter { $0 == "transitionBegan" }.count == 1)
        #expect(engine.state == .playing)
        #expect(incoming.fades.isEmpty)
        #expect(!log.events.contains("playbackEnded"))
    }

    @Test func crossfadeFadesWhatIsHeard() async throws {
        let (a, b) = (try Self.tone(seconds: 6), try Self.tone(seconds: 5))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.crossfade(seconds: 2))
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: true), track: Self.first, autoplay: true)
        await engine.arm(next: Self.asset(b, tapped: true), track: Self.second)
        try await Self.waitUntil { log.pivots == [Self.second] }
        let outgoing = engine.idle, incoming = engine.active
        let level = { (deck: Deck) in deck.processing?.spectrum.snapshot().bands.max() ?? 0 }
        try await Task.sleep(for: .milliseconds(300))
        let (early, earlyIn) = (level(outgoing), level(incoming))
        try await Task.sleep(for: .milliseconds(1200))
        let (late, lateIn) = (level(outgoing), level(incoming))
        #expect(late < early - 0.1, "previous song \(early) → \(late)")
        #expect(lateIn > earlyIn + 0.03, "next song \(earlyIn) → \(lateIn)")
    }

    @Test func cutFadeLeavesAReusedDeckAlone() async throws {
        let (a, b, c) = (try Self.tone(seconds: 5), try Self.tone(seconds: 5), try Self.tone(seconds: 3))
        defer { Self.remove(a, b, c) }
        let engine = Self.engine(.crossfade(seconds: 2))
        engine.volume = 0.001
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: true), track: Self.first, autoplay: true)
        await engine.arm(next: Self.asset(b, tapped: true), track: Self.second)
        try await Self.waitUntil { log.pivots == [Self.second] }
        await engine.seek(to: 0.5)
        let third = TrackRef(source: .local, id: "third")
        #expect(await engine.arm(next: Self.asset(c, tapped: true), track: third))
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.idle.asset != nil, "the armed song is still loaded")
        #expect(engine.idle.player.volume > 0, "volume \(engine.idle.player.volume)")
    }

    /// A crossfade longer than half of either song meets as gapless instead.
    @Test func crossfadeTooLongForTheSongsIsGapless() async throws {
        let (a, b) = (try Self.tone(seconds: 2.5), try Self.tone(seconds: 3))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.crossfade(seconds: 5))
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: true), track: Self.first, autoplay: true)
        await engine.arm(next: Self.asset(b, tapped: true), track: Self.second)
        try await Self.waitUntil { log.pivots == [Self.second] }
        #expect(engine.active.fades.isEmpty)
        #expect(!log.events.contains("transitionBegan"))
    }

    @Test func seekReschedules() async throws {
        let (a, b) = (try Self.tone(seconds: 5), try Self.tone(seconds: 3))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.gapless)
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: false), track: Self.first, autoplay: true)
        await engine.arm(next: Self.asset(b, tapped: false), track: Self.second)
        try await Self.waitUntil { engine.state == .scheduled(next: Self.second) }
        let incoming = engine.idle
        await engine.seek(to: 0.5)
        #expect(engine.state == .armed(next: Self.second))
        try await Task.sleep(for: .milliseconds(300))
        #expect(incoming.player.rate == 0)
        #expect(incoming.asset != nil, "the next song stays loaded")

        try await Self.waitUntil { log.pivots == [Self.second] }
        #expect(engine.currentTrack == Self.second)
        #expect(!log.events.contains("transitionCancelled"))
    }

    /// Pausing takes the scheduled start back (the next song must not start while the current
    /// one waits); playing on schedules it again.
    @Test func pauseHoldsTheNextSong() async throws {
        let (a, b) = (try Self.tone(seconds: 4.5), try Self.tone(seconds: 3))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.gapless)
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: false), track: Self.first, autoplay: true)
        await engine.arm(next: Self.asset(b, tapped: false), track: Self.second)
        try await Self.waitUntil { engine.state == .scheduled(next: Self.second) }
        let incoming = engine.idle
        engine.pause(fade: false)
        try await Task.sleep(for: .seconds(2))
        #expect(incoming.player.rate == 0)
        #expect(log.pivots.isEmpty)
        #expect(engine.currentTrack == Self.first)

        engine.play()
        try await Self.waitUntil { log.pivots == [Self.second] }
    }

    @Test func noTransitionReportsTheEnd() async throws {
        let (a, b) = (try Self.tone(seconds: 2), try Self.tone(seconds: 3))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.none)
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: false), track: Self.first, autoplay: true)
        await engine.arm(next: Self.asset(b, tapped: false), track: Self.second)
        #expect(engine.idle.player.volume == 0)
        try await Self.waitUntil { log.events.contains("playbackEnded") }
        #expect(log.pivots.isEmpty)
        #expect(engine.currentTrack == Self.first)
    }

    /// A song that cannot be scheduled (its exact end comes too late, here: armed in its last
    /// second) starts as soon as the current one ends, still without `.playbackEnded`.
    @Test func lateArmStartsAtTheEnd() async throws {
        let (a, b) = (try Self.tone(seconds: 2), try Self.tone(seconds: 3))
        defer { Self.remove(a, b) }
        let engine = Self.engine(.gapless)
        defer { engine.stop() }
        let log = Self.record(engine)
        defer { log.task.cancel() }

        try await engine.load(Self.asset(a, tapped: false), track: Self.first, autoplay: true)
        try await Self.waitUntil { engine.active.rawTime > 1.8 }
        await engine.arm(next: Self.asset(b, tapped: false), track: Self.second)
        try await Self.waitUntil { log.pivots == [Self.second] }
        #expect(!log.events.contains("playbackEnded"))
        try await Self.waitUntil { engine.active.rawTime > 0.3 }
        #expect(engine.active.player.rate > 0)
    }

    static let first = TrackRef(source: .local, id: "first")
    static let second = TrackRef(source: .local, id: "second")

    final class Log {
        var events: [String] = []
        var pivots: [TrackRef] = []
        var ended = 0
        var task: Task<Void, Never>!
    }

    static func record(_ engine: AVDeckEngine) -> Log {
        let log = Log()
        log.task = Task { @MainActor in
            for await event in engine.events {
                switch event {
                case .transitionPivoted(let track):
                    log.pivots.append(track)
                    log.events.append("transitionPivoted")
                case .transitionBegan: log.events.append("transitionBegan")
                case .transitionEnded:
                    log.ended += 1
                    log.events.append("transitionEnded")
                case .transitionCancelled: log.events.append("transitionCancelled")
                case .playbackEnded: log.events.append("playbackEnded")
                default: break
                }
            }
        }
        return log
    }

    static func engine(_ mode: TransitionMode) -> AVDeckEngine {
        let engine = AVDeckEngine()
        engine.volume = 0
        engine.transitionMode = mode
        return engine
    }

    static func asset(_ url: URL, tapped: Bool) -> PlayableAsset {
        PlayableAsset(url: url, container: .wav, tier: QualityTier(.lossless), supportsTap: tapped, provider: .local)
    }

    /// A 440 Hz tone (not all zeros, so the tap has something to process).
    static func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transition-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 44_100) }
        }
        try file.write(from: buffer)
        return url
    }

    static func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    static func waitUntil(timeout: Duration = .seconds(8), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
