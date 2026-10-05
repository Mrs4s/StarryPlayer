import AVFoundation
import Foundation
import StarryCore
import Testing
@testable import PlaybackEngine

@Suite struct HeardClockTests {
    @Test func holdsWhenLatencyAppears() {
        var clock = HeardClock()
        #expect(clock.time(raw: 10, latency: 0) == 10)
        #expect(clock.time(raw: 10.1, latency: 0.5) == 10)
        #expect(clock.time(raw: 10.4, latency: 0.5) == 10)
        #expect(abs(clock.time(raw: 10.7, latency: 0.5) - 10.2) < 1e-9)
        #expect(abs(clock.time(raw: 10.8, latency: 0) - 10.8) < 1e-9)
    }

    @Test func seekResetsTheFloor() {
        var clock = HeardClock()
        _ = clock.time(raw: 60, latency: 0.1)
        clock.reset(to: 20)
        #expect(clock.time(raw: 20, latency: 0.1) == 20)
        #expect(abs(clock.time(raw: 20.3, latency: 0.1) - 20.2) < 1e-9)
    }
}

@MainActor
@Suite struct VocalAttenuationEngineTests {
    /// With the switch on, a tapped item starts processed by the system voice model: the status
    /// turns active with the unit's latency, and the engine's clock trails the item by it.
    /// Switching off returns to no latency.
    @Test func switchDrivesStatusAndClock() async throws {
        guard #available(macOS 15, *) else { return }
        let file = try Self.toneFile(seconds: 20)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVDeckEngine()
        engine.volume = 0
        engine.vocalModel = .systemVoice
        engine.vocalAttenuationEnabled = true
        engine.vocalLevel = 20
        let asset = PlayableAsset(url: file, container: .wav, tier: QualityTier(.lossless), supportsTap: true, provider: .local)
        try await engine.load(asset, track: TrackRef(source: .local, id: "tone"), autoplay: true)
        defer { engine.stop() }

        try await Self.waitUntil { engine.vocalStatus.isActive }
        let status = engine.vocalStatus
        #expect(status.enabled)
        #expect(status.unavailable == nil || status.unavailable == .thermal || status.unavailable == .lowPowerMode)
        #expect(status.modelName == VocalSeparationModelName.system)
        #expect(!status.usesMusicModel)
        #expect(status.latency > 0.05 && status.latency < 0.2, "latency \(status.latency)")

        try await Task.sleep(for: .seconds(1))
        #expect(engine.currentTime <= engine.rawItemTime - status.latency + 0.01)

        // The tap reports source positions, so a seek resets the unit (primes again).
        await engine.seek(to: 5)
        #expect(engine.currentTime >= 5)
        try await Self.waitUntil { (engine.activeAttenuatorStatus?.seekResets ?? 0) >= 1 }

        engine.vocalAttenuationEnabled = false
        try await Self.waitUntil { !engine.vocalStatus.isActive }
        #expect(engine.vocalStatus.latency == 0)
    }

    /// Without a tap (HLS-like sources) the vocals cannot be controlled.
    @Test func untappedSourceIsUnavailable() async throws {
        let file = try Self.toneFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVDeckEngine()
        engine.volume = 0
        engine.vocalAttenuationEnabled = true
        let asset = PlayableAsset(url: file, container: .wav, tier: QualityTier(.lossless), supportsTap: false, provider: .local)
        try await engine.load(asset, track: TrackRef(source: .local, id: "tone"), autoplay: false)
        defer { engine.stop() }
        #expect(engine.vocalStatus.unavailable == .unsupportedSource)
    }

    private enum VocalSeparationModelName {
        static let system = "系统人声隔离"
    }

    private static func toneFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocal-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { data[i] = Float(0.2 * sin(2 * .pi * 440 * Double(i) / 44_100)) }
        }
        try file.write(from: buffer)
        return url
    }

    private static func waitUntil(timeout: Duration = .seconds(8), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
