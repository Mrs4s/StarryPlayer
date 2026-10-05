import AVFoundation
import Foundation
import StarryCore
import Testing
@testable import PlaybackEngine

@MainActor
@Suite struct DeckEventTests {
    /// Arming preloads the next item into the idle deck ~30 s before the end. Its status
    /// becoming ready must not report the next item's duration (or time) as the current one.
    @Test func armedDeckDoesNotLeakDuration() async throws {
        let current = try Self.silentFile(seconds: 3)
        let next = try Self.silentFile(seconds: 9)
        defer {
            try? FileManager.default.removeItem(at: current)
            try? FileManager.default.removeItem(at: next)
        }

        let engine = AVDeckEngine()
        var durations: [TimeInterval] = []
        var times: [TimeInterval] = []
        let collector = Task { @MainActor in
            for await event in engine.events {
                switch event {
                case .duration(let d): durations.append(d)
                case .time(let t): times.append(t)
                default: break
                }
            }
        }
        defer { collector.cancel() }

        try await engine.load(Self.asset(current), track: TrackRef(source: .local, id: "current"), autoplay: false)
        try await Self.waitUntil { !durations.isEmpty }
        #expect(abs(durations[0] - 3) < 0.1)

        await engine.seek(to: 1.5)
        times.removeAll()
        await engine.arm(next: Self.asset(next), track: TrackRef(source: .local, id: "next"))
        try await Task.sleep(for: .seconds(1.5))

        #expect(durations.allSatisfy { abs($0 - 3) < 0.1 }, "durations reported: \(durations)")
        #expect(times.allSatisfy { $0 > 1 }, "times reported after arming: \(times)")
        #expect(abs(engine.duration - 3) < 0.1)
    }

    /// Resuming inside the 300 ms pause fade must win: the fade stops where it is and never lands
    /// its pause, and the player is back at the engine volume.
    @Test func resumeDuringPauseFadeKeepsPlaying() async throws {
        let file = try Self.silentFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: file) }

        let engine = AVDeckEngine()
        engine.volume = 0.5
        try await engine.load(Self.asset(file), track: TrackRef(source: .local, id: "t"), autoplay: true)
        engine.pause(fade: true)
        try await Task.sleep(for: .milliseconds(100))
        engine.play()
        try await Task.sleep(for: .milliseconds(500))

        #expect(engine.rate == 1)
        #expect(engine.active.player.volume == 0.5)
    }

    /// A new item loaded while the previous one fades out starts at the engine volume, and volume
    /// changes during a fade wait for the next `play()` instead of jumping back up.
    @Test func pauseFadeOwnsVolumeUntilItEnds() async throws {
        let first = try Self.silentFile(seconds: 5)
        let second = try Self.silentFile(seconds: 5)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let engine = AVDeckEngine()
        engine.volume = 0.8
        try await engine.load(Self.asset(first), track: TrackRef(source: .local, id: "a"), autoplay: true)
        engine.pause(fade: true)
        try await Task.sleep(for: .milliseconds(100))
        engine.volume = 1
        #expect(engine.active.player.volume < 0.8)

        // The 300 ms step fade lands; wait for it rather than a fixed sleep (other suites share
        // the main actor and can stretch the fade's steps).
        try await Self.waitUntil(timeout: .seconds(2)) { engine.rate == 0 && engine.active.player.volume == 0 }
        #expect(engine.rate == 0)
        #expect(engine.active.player.volume == 0)

        engine.pause(fade: true)
        try await Task.sleep(for: .milliseconds(50))
        try await engine.load(Self.asset(second), track: TrackRef(source: .local, id: "b"), autoplay: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.rate == 0)
        #expect(engine.active.player.volume == 1)
    }

    /// A seek still waiting for its data when another song loads into the deck (a slow network,
    /// the start position of a restored song, an expired address) lands on nothing: the new
    /// song's clock must not take the old target as its floor, which would hold it there (even
    /// past the song's end) until the song's own time passed it.
    @Test func seekInFlightDoesNotCarryIntoNextItem() async throws {
        let first = try Self.silentFile(seconds: 10)
        let second = try Self.silentFile(seconds: 5)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let engine = AVDeckEngine()
        var times: [TimeInterval] = []
        let collector = Task { @MainActor in
            for await event in engine.events {
                if case .time(let t) = event { times.append(t) }
            }
        }
        defer { collector.cancel() }

        try await engine.load(Self.asset(first), track: TrackRef(source: .local, id: "first"), autoplay: true)
        try await Task.sleep(for: .milliseconds(300))
        let seek = Task { @MainActor in await engine.seek(to: 8) }
        await Task.yield()
        try await engine.load(Self.asset(second), track: TrackRef(source: .local, id: "second"), autoplay: true)
        times.removeAll()
        await seek.value
        try await Task.sleep(for: .milliseconds(600))

        #expect(engine.currentTime < 2, "second song's clock: \(engine.currentTime)")
        #expect(times.allSatisfy { $0 < 2 }, "times reported after the switch: \(times)")
    }

    private static func asset(_ url: URL) -> PlayableAsset {
        PlayableAsset(url: url, container: .wav, tier: QualityTier(.lossless), supportsTap: false, provider: .local)
    }

    private static func silentFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
