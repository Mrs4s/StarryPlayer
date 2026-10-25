import AVFoundation
import AudioProcessing
import Foundation
import PlaybackEngine
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor @Suite(.serialized)
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

    @Test func separateVoicesCanBeSelectedAndCompletedHintsAreReused() async throws {
        let gate = DuetGate()
        let audio = LyricsEditorAudio(duetWork: { try await gate.run($0) })
        let source = try Self.makeSource()
        defer { audio.stop(); try? FileManager.default.removeItem(at: source) }
        try await prepare(audio, source: source)
        audio.prepareDuetOnsets()
        for _ in 0..<100 where await gate.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await gate.count == 1)
        try await gate.finish()
        try await waitUntil { audio.duetStatus == .ready }
        let a = audio.duetOnsets(for: .a), b = audio.duetOnsets(for: .b)
        #expect(a.contains { abs($0.time - 0.4) < 0.05 })
        #expect(b.contains { abs($0.time - 1.5) < 0.05 })
        #expect(!a.contains { abs($0.time - 1.5) < 0.05 })
        #expect(audio.duetOnsets(for: .all).count == a.count + b.count)
        audio.cancelDuetOnsets()
        audio.prepareDuetOnsets()
        #expect(audio.duetStatus == .ready)
        #expect(await gate.count == 1)
        #expect(audio.duetOnsets(for: .a) == a)
    }

    @Test func lateCancelledWorkCannotRestoreHintsAndItsFilesAreRemoved() async throws {
        let gate = DuetGate()
        let audio = LyricsEditorAudio(duetWork: { try await gate.run($0) })
        let source = try Self.makeSource()
        defer { audio.stop(); try? FileManager.default.removeItem(at: source) }
        try await prepare(audio, source: source)
        audio.prepareDuetOnsets()
        for _ in 0..<100 where await gate.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        audio.discardVocals()
        let files = try await gate.finish()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: files.first.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(audio.duetStatus == .none)
        #expect(audio.duetOnsets(for: .all).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.first.path))
        #expect(!FileManager.default.fileExists(atPath: files.second.path))
    }

    @Test func combinedVoiceHintsKeepDistinctEventsAndUseTheStrongerCoincidentHint() {
        let result = LyricsEditorAudio.combinedHints(
            [VocalOnset(time: 1, strength: 0.6), VocalOnset(time: 2, strength: 0.8)],
            [VocalOnset(time: 1, strength: 0.9), VocalOnset(time: 1.02, strength: 0.7)])
        #expect(result == [VocalOnset(time: 1, strength: 0.9), VocalOnset(time: 1.02, strength: 0.7), VocalOnset(time: 2, strength: 0.8)])
    }

    @Test func failedSeparationCanRetryAndPopulateBothVoiceHints() async throws {
        let gate = DuetGate()
        let audio = LyricsEditorAudio(duetWork: { try await gate.run($0) })
        let source = try Self.makeSource()
        defer { audio.stop(); try? FileManager.default.removeItem(at: source) }
        try await prepare(audio, source: source)
        audio.prepareDuetOnsets()
        for _ in 0..<100 where await gate.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        await gate.fail()
        try await waitUntil {
            if case .failed = audio.duetStatus { return true }
            return false
        }
        #expect(audio.duetOnsets(for: .all).isEmpty)
        audio.prepareDuetOnsets()
        for _ in 0..<100 where await gate.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        try await gate.finish()
        try await waitUntil { audio.duetStatus == .ready }
        #expect(await gate.count == 2)
        #expect(!audio.duetOnsets(for: .a).isEmpty && !audio.duetOnsets(for: .b).isEmpty)
    }

    private func prepare(_ audio: LyricsEditorAudio, source: URL) async throws {
        audio.setVolume(0)
        audio.vocalModel = VocalSeparationModelLocator.locate(in: [], bundle: .main)
        audio.resolve = { _ in PlayableAsset(url: source, container: .wav, tier: QualityTier(.default)) }
        audio.load(Track(id: TrackRef(source: .local, id: UUID().uuidString), title: "Duet fixture", artists: [], album: nil, duration: 0))
        try await waitUntil { audio.isPrecise }
        audio.prepareVocals()
        try await waitUntil { audio.vocals == .ready }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 where !predicate() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }

    private nonisolated static func makeSource() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-duet-\(UUID().uuidString).wav")
        try writePulses(to: url, start: 0.4)
        return url
    }

    private nonisolated static func writePulses(to url: URL, start: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i)/44100, elapsed = Double(i)/44100-start
            let envelope = elapsed >= 0 && elapsed < 0.4 ? min(elapsed/0.015,1)*min((0.4-elapsed)/0.06,1) : 0
            buffer.floatChannelData![0][i] = Float(0.3*envelope*sin(2 * .pi * 700 * t))
        }
        try file.write(from: buffer)
    }

    private actor DuetGate {
        var count = 0
        var request: LyricsEditorAudio.DuetRequest?
        var continuation: CheckedContinuation<VocalDuetSeparation, Error>?
        func run(_ request: LyricsEditorAudio.DuetRequest) async throws -> VocalDuetSeparation {
            count += 1
            self.request = request
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func fail() {
            continuation?.resume(throwing: VocalDuetSeparator.Failure.invalidOutput)
            continuation = nil
        }
        @discardableResult
        func finish() throws -> VocalDuetSeparation {
            let request = try #require(request)
            try LyricsEditorAudioTests.writePulses(to: request.first, start: 0.4)
            try LyricsEditorAudioTests.writePulses(to: request.second, start: 1.5)
            let result = VocalDuetSeparation(first: request.first, second: request.second)
            continuation?.resume(returning: result)
            continuation = nil
            return result
        }
    }
}
