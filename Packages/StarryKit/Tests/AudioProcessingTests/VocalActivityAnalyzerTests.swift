import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite(.serialized) struct VocalActivityAnalyzerTests {
    /// Stereo 44.1 kHz file: a buzzy "voice" (harmonics with vibrato) in bursts at `bursts`
    /// seconds, 0.8 s each, over quiet noise.
    static func makeFile(duration: TimeInterval = 40, bursts: [TimeInterval]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "starry-activity-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frames = AVAudioFrameCount(duration * 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        var seed: UInt64 = 0x1234
        for i in 0..<Int(frames) {
            let t = Double(i) / 44100
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            var value = Float(Int64(bitPattern: seed >> 11) % 1000) / 1000 * 0.01
            if bursts.contains(where: { t >= $0 && t < $0 + 0.8 }) {
                let pitch = 220 * (1 + 0.02 * sin(2 * .pi * 5 * t))
                value += Float((1...8).reduce(0.0) { $0 + sin(2 * .pi * pitch * Double($1) * t) / Double($1) } * 0.2)
            }
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    @Test func measuresOnlyTheRequestedStretchOnTheFrameGrid() throws {
        let bursts = [11.0, 14.3, 17.9, 22.05]
        let url = try Self.makeFile(bursts: bursts)
        defer { try? FileManager.default.removeItem(at: url) }
        let analyzer = try VocalActivityAnalyzer(file: url, model: nil)
        #expect(abs(analyzer.duration - 40) < 1e-6)
        #expect(analyzer.activity.frameCount == 4001)
        try analyzer.analyze(10...25)
        let activity = analyzer.activity
        #expect(activity.valid.firstIndex(of: true) == 1000)
        #expect(activity.valid.lastIndex(of: true) == 2499)
        #expect(activity.valid.filter { $0 }.count == 1500)
        #expect(analyzer.separatedDuration == 0)
        for burst in bursts {
            let onset = Int((burst * 100).rounded())
            let rise = (onset - 8...onset + 2).first { activity.energy[$0] > activity.energy[onset - 20] + 20 }
            #expect(rise != nil && rise! >= onset - 5 && rise! <= onset, "burst \(burst): rise at \(String(describing: rise))")
            #expect(activity.energy[onset + 40] > activity.energy[onset - 30] + 30)
            let quiet = activity.flux[(onset - 40)..<(onset - 10)].max()!
            #expect(activity.flux[(onset - 6)...(onset + 1)].max()! > 5 * quiet, "burst \(burst)")
        }
    }

    @Test func rejectsUnreadableFiles() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "starry-not-audio-\(UUID().uuidString).mp3")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: VocalActivityError.unreadable) { try VocalActivityAnalyzer(file: url, model: nil) }
    }
}
