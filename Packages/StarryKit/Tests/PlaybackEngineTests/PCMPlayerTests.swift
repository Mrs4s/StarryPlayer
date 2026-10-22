import AVFoundation
import Foundation
import Testing
@testable import PlaybackEngine

/// Exercises transport behavior at volume 0.
@Suite(.serialized)
@MainActor
struct PCMPlayerTests {
    private func decodedTone(seconds: Double) async throws -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-tone-\(UUID().uuidString).wav")
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                for i in 0..<Int(buffer.frameLength) { data[i] = 0.5 * Float(sin(Double(i) * 2 * .pi * 440 / rate)) }
            }
            try file.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: source) }
        let decoded = PCMPlayer.directory.appendingPathComponent("tone-\(UUID().uuidString).caf")
        let waveform = try await PCMPlayer.decode(source, to: decoded)
        #expect(abs(waveform.duration - seconds) < 0.011)
        #expect(abs(waveform.peak(from: 0.1, to: seconds - 0.1) - 0.5) < 0.01)
        return decoded
    }

    @Test func clockFollowsPlaySeekSpeedAndPause() async throws {
        let url = try await decodedTone(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try PCMPlayer(file: url)
        defer { player.close() }
        player.volume = 0
        let latency = player.outputLatency
        player.play()
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(player.currentTime - (0.5 - latency)) < 0.06, "\(player.currentTime)")

        player.seek(to: 3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(player.currentTime - (3.3 - latency)) < 0.06, "\(player.currentTime)")

        let before = player.currentTime
        player.setRate(0.5)
        let stretched = player.outputLatency
        #expect(stretched > latency)
        try await Task.sleep(for: .milliseconds(400))
        // Half speed: 0.2 s of song, less the latency at that speed.
        #expect(abs(player.currentTime - before - (0.2 - stretched * 0.5)) < 0.04, "\(player.currentTime - before)")

        player.pause()
        let paused = player.currentTime
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.currentTime == paused)
        #expect(!player.isPlaying)
        player.seek(to: 1)
        #expect(player.currentTime == 1)
    }

    @Test func endingStopsAndReports() async throws {
        let url = try await decodedTone(seconds: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try PCMPlayer(file: url)
        defer { player.close() }
        player.volume = 0
        var ended = false
        player.onEnded = { ended = true }
        player.play()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(ended)
        #expect(!player.isPlaying)
        #expect(abs(player.currentTime - 0.4) < 0.001)
        player.play()
        #expect(player.isPlaying)
        #expect(player.currentTime < 0.05)
    }

    @Test func undecodableFileThrows() async {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        try? Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: (any Error).self) {
            _ = try await PCMPlayer.decode(source, to: PCMPlayer.directory.appendingPathComponent("never.caf"))
        }
    }
}
