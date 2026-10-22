import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite(.serialized) struct VocalExtractionTests {
    @MainActor
    private func speech() async throws -> (samples: [Float], rate: Double) {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "Hello darkness, my old friend. I've come to talk with you again.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        return try await withCheckedThrowingContinuation { continuation in
            var samples: [Float] = []
            var rate = 0.0
            var done = false
            synthesizer.write(utterance) { buffer in
                guard !done, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    done = true
                    continuation.resume(returning: (samples, rate))
                    return
                }
                rate = pcm.format.sampleRate
                if let data = pcm.floatChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength)))
                } else if let data = pcm.int16ChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength)).map { Float($0) / 32768 })
                }
            }
            _ = synthesizer
        }
    }

    private func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384)!
        var samples: [Float] = []
        // A read can return less than asked: read until the end.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// How much of `part` is in `mix`: the projection of one onto the other, 1 for all of it.
    private func share(of part: [Float], in mix: [Float]) -> Double {
        var dot = 0.0, norm = 0.0
        for i in 0..<min(part.count, mix.count) {
            dot += Double(part[i]) * Double(mix[i])
            norm += Double(part[i]) * Double(part[i])
        }
        return norm > 0 ? dot / norm : 0
    }

    @Test func keepsTheVoiceAndDropsTheBass() async throws {
        guard #available(macOS 15, *) else { return }
        let (voice, rate) = try await speech()
        try #require(voice.count > Int(rate), "no speech synthesised")
        let padded = [Float](repeating: 0, count: Int(rate / 2)) + voice + [Float](repeating: 0, count: Int(rate / 2))
        let bass = (0..<padded.count).map { i in 0.25 * Float(sin(2 * .pi * 55 * Double(i) / rate) + 0.5 * sin(2 * .pi * 110 * Double(i) / rate)) }
        let directory = FileManager.default.temporaryDirectory
        let mixURL = directory.appendingPathComponent("vocals-mix-\(UUID().uuidString).caf")
        let vocalsURL = directory.appendingPathComponent("vocals-out-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: mixURL)
            try? FileManager.default.removeItem(at: vocalsURL)
        }
        try write(zip(padded, bass).map { $0 + $1 }, rate: rate, to: mixURL)

        let reports = Reports()
        try await VocalExtraction.extractVocals(from: mixURL, to: vocalsURL, model: .systemVoice) { reports.add($0) }
        let vocals = try read(vocalsURL)
        let voiceShare = share(of: padded, in: vocals), bassShare = share(of: bass, in: vocals)
        let mixLength = try AVAudioFile(forReading: mixURL).length
        let vocalsLength = try AVAudioFile(forReading: vocalsURL).length
        #expect(vocals.count == padded.count, "\(vocals.count) vs \(padded.count), mix file \(mixLength), vocals file \(vocalsLength)")
        #expect(voiceShare > 0.6, "voice \(voiceShare)")
        #expect(abs(bassShare) < 0.15, "bass \(bassShare)")
        #expect(reports.last == 1)
    }

    @Test func moreThanTwoChannelsIsUnsupported() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocals-6ch-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        try file.write(from: buffer)
        await #expect(throws: VocalExtraction.Failure.unsupported) {
            try await VocalExtraction.extractVocals(from: url, to: url.appendingPathExtension("out"), model: .systemVoice)
        }
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double? { lock.withLock { values.last } }
}
