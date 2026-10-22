import AVFoundation
import Foundation
import PlaybackEngine
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorAudioTests {
    @Test func localSongResolvesDecodesAndControlsPlayback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-audio-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3)!
            buffer.frameLength = buffer.frameCapacity
            for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = 0.3 * Float(sin(Double(i) * 0.06)) } }
            try file.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = LyricsEditorAudio()
        audio.setVolume(0)
        audio.resolve = { _ in PlayableAsset(url: url, container: .wav, tier: QualityTier(.default)) }
        var played = false
        audio.willPlay = { played = true }
        audio.load(Track(id: TrackRef(source: .local, id: "tone"), title: "Tone", artists: [], album: nil, duration: 0))
        for _ in 0..<50 where !audio.isReady { try await Task.sleep(for: .milliseconds(50)) }
        #expect(audio.isReady)
        #expect(audio.isPrecise)
        #expect(abs(audio.duration - 3) < 0.001)
        #expect(audio.waveform != nil)
        let decoded = try FileManager.default.contentsOfDirectory(at: PCMPlayer.directory, includingPropertiesForKeys: nil)
        #expect(decoded.count == 1)

        audio.seek(to: 1)
        #expect(audio.currentTime == 1)
        audio.play()
        #expect(played)
        #expect(audio.isPlaying)
        #expect(audio.clock().rate == 1)
        audio.setRate(0.5)
        #expect(audio.clock().rate == 0.5)
        audio.pause()
        #expect(!audio.isPlaying)
        #expect(audio.clock().rate == 0)

        audio.stop()
        #expect(!audio.isReady)
        #expect(try FileManager.default.contentsOfDirectory(at: PCMPlayer.directory, includingPropertiesForKeys: nil).isEmpty)
    }
}
