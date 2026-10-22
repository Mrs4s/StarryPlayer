import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite struct WaveformPeaksTests {

    private func writeTestFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID().uuidString).wav")
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 3))!
        buffer.frameLength = buffer.frameCapacity
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        for i in 0..<Int(buffer.frameLength) {
            let tone = Float(sin(Double(i) * 2 * .pi * 440 / rate))
            switch i / Int(rate) {
            case 0: left[i] = 0; right[i] = 0
            case 1: left[i] = 0.5 * tone; right[i] = 0.5 * tone
            default: left[i] = 0; right[i] = 0.25 * tone
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func peaksFollowTheLoudness() async throws {
        let url = try writeTestFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let waveform = try #require(await WaveformPeaks.read(url, resolution: 100))
        #expect(waveform.peaks.count == 300)
        #expect(abs(waveform.duration - 3) < 0.011)
        #expect(waveform.peak(from: 0, to: 0.99) == 0)
        #expect(abs(waveform.peak(from: 1.1, to: 1.9) - 0.5) < 0.01)
        #expect(abs(waveform.peak(from: 2.1, to: 2.9) - 0.25) < 0.01)
        #expect(waveform.peak(from: 4, to: 5) == 0)
    }

    @Test func unreadableFileGivesNothing() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        try? Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await WaveformPeaks.read(url) == nil)
    }
}
