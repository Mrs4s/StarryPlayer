import AVFoundation
import Foundation
import Library
import StarryCore
import Testing
@testable import StarryPlayer

@Suite(.serialized)
@MainActor
struct TransitionPlaybackTests {
    /// Gapless: the second song takes over from the engine; the player never loads it.
    @Test func gaplessTakesOverWithoutALoad() async throws {
        let (player, songs) = try makePlayer(count: 2, gapless: true)
        defer { finish(player, songs) }
        var loads: [String] = []
        let resolve = player.resolveAsset!
        player.resolveAsset = { track, tier in
            loads.append(track.id.id)
            return try await resolve(track, tier)
        }

        player.play(songs.tracks)
        try await waitUntil { player.engine.armedTrack?.id == "s1" }
        try await waitUntil(seconds: 6) { player.current?.id.id == "s1" }
        #expect(player.engine.currentTrack?.id == "s1")
        #expect(player.isPlaying)
        #expect(!player.isLoading)
        #expect(player.index == 1)
        #expect(loads == ["s0", "s1"])
    }

    @Test func shufflePlaysTheSongItArmed() async throws {
        let (player, songs) = try makePlayer(count: 5, gapless: true)
        defer { finish(player, songs) }
        player.shuffle = true
        player.play(songs.tracks, startAt: 0)
        try await waitUntil { player.engine.armedTrack != nil }
        let armed = try #require(player.engine.armedTrack)
        try await waitUntil(seconds: 6) { player.current?.id != songs.tracks[0].id }
        #expect(player.current?.id == armed)
    }

    @Test func playNextRearms() async throws {
        let (player, songs) = try makePlayer(count: 3, gapless: true)
        defer { finish(player, songs) }
        player.play(Array(songs.tracks.prefix(2)))
        try await waitUntil { player.engine.armedTrack?.id == "s1" }
        player.playNext(songs.tracks[2])
        try await waitUntil { player.engine.armedTrack?.id == "s2" }
        try await waitUntil(seconds: 6) { player.current?.id.id == "s2" }
        #expect(player.queue.map(\.id.id) == ["s0", "s2", "s1"])
    }

    @Test func withoutTransitionsTheEndLoads() async throws {
        let (player, songs) = try makePlayer(count: 2, gapless: false)
        defer { finish(player, songs) }
        player.play(songs.tracks)
        try await waitUntil { player.engine.armedTrack?.id == "s1" }
        try await waitUntil(seconds: 6) { player.current?.id.id == "s1" }
        #expect(player.engine.currentTrack?.id == "s1")
    }

    struct Songs {
        var tracks: [Track]
        var files: [URL]
    }

    private func makePlayer(count: Int, gapless: Bool) throws -> (PlayerController, Songs) {
        let player = PlayerController()
        // Not `setVolume`: that is saved for the app.
        player.engine.volume = 0
        var transitions = AppSettings.Transition()
        transitions.gapless = gapless
        player.transitions = transitions
        let files = try (0..<count).map { _ in try Self.tone(seconds: 2.5) }
        let tracks = (0..<count).map { Track(id: TrackRef(source: .local, id: "s\($0)"), title: "Song \($0)", duration: 2.5) }
        let byID = Dictionary(uniqueKeysWithValues: zip(tracks.map(\.id), files))
        player.resolveAsset = { track, _ in
            PlayableAsset(url: byID[track.id]!, container: .wav, tier: QualityTier(.lossless), supportsTap: true, provider: .local)
        }
        return (player, Songs(tracks: tracks, files: files))
    }

    private func finish(_ player: PlayerController, _ songs: Songs) {
        player.stop()
        for file in songs.files { try? FileManager.default.removeItem(at: file) }
    }

    private static func tone(seconds: Double) throws -> URL {
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

    private func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
