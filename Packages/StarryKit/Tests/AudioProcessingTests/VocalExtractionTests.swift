import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalExtractionTests {
    @Test func networksRunAtTheirDeclaredRate() {
        let declared = VocalSeparationModel(source: .systemVoice, output: .accompaniment, name: "test", sampleRate: 44100)
        #expect(declared.processingRate(for: 48000) == 44100)
        #expect(declared.processingRate(for: 44100) == 44100)
        #expect(VocalSeparationModel.systemVoice.processingRate(for: 48000) == 48000)
        let invalid = VocalSeparationModel(source: .systemVoice, output: .accompaniment, name: "test", sampleRate: 0)
        #expect(invalid.processingRate(for: 48000) == 48000)
    }

    @Test func resamplingKeepsTheExactLengthAndAddsNoDelay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocal-extraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.caf")
        let down = directory.appendingPathComponent("down.caf")
        let back = directory.appendingPathComponent("back.caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        // Longer than one conversion block, with clicks near the start, middle and end.
        let length = 48000, clicks = [600, 30000, 47000]
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)))
        buffer.frameLength = AVAudioFrameCount(length)
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(repeating: 0, count: length)
            for click in clicks { buffer.floatChannelData![channel][click] = 1 }
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        try VocalExtraction.resample(AVAudioFile(forReading: source), to: 44100, into: down, frames: 44100)
        let converted = try samples(down)
        #expect(converted.rate == 44100)
        #expect(converted.samples.count == 44100)
        for click in clicks {
            let expected = Double(click) * 44100 / 48000
            #expect(abs(Double(peak(in: converted.samples, near: Int(expected.rounded()))) - expected) <= 1, "click at \(click)")
        }

        try VocalExtraction.resample(AVAudioFile(forReading: down), to: 48000, into: back, frames: Int64(length), settings: format.settings)
        let restored = try samples(back)
        #expect(restored.rate == 48000)
        #expect(restored.samples.count == length)
        for click in clicks {
            #expect(abs(peak(in: restored.samples, near: click) - click) <= 1, "click at \(click)")
        }
    }

    @Test func resamplingPadsAShortConversionWithSilence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocal-extraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.caf")
        let output = directory.appendingPathComponent("output.caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000))
        buffer.frameLength = 1000
        buffer.floatChannelData![0].update(repeating: 0.25, count: 1000)
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try VocalExtraction.resample(AVAudioFile(forReading: source), to: 48000, into: output, frames: 5000)
        let result = try samples(output)
        #expect(result.samples.count == 5000)
        #expect(result.samples[4000...].allSatisfy { $0 == 0 })
    }

    private func samples(_ url: URL) throws -> (rate: Double, samples: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (file.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    }

    private func peak(in samples: [Float], near index: Int) -> Int {
        let window = max(0, index - 200)..<min(samples.count, index + 200)
        return window.max { abs(samples[$0]) < abs(samples[$1]) } ?? -1
    }
}
