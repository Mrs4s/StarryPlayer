@preconcurrency import AVFoundation
import Foundation

/// Streaming conversion keeps full-song PCM out of memory. Downmix explicitly
/// before resampling so stereo uses the same (L + R) / 2 convention as analysis.
enum DuetPCM {
    static func convert(_ source: URL, to destination: URL, sampleRate: Double) throws {
        // Flush Objective-C audio file writers before another actor opens the CAF.
        try autoreleasepool { try write(source, to: destination, sampleRate: sampleRate) }
    }

    private static func write(_ source: URL, to destination: URL, sampleRate: Double) throws {
        let file = try AVAudioFile(forReading: source)
        let original = file.processingFormat
        guard original.commonFormat == .pcmFormatFloat32, !original.isInterleaved,
              (1...2).contains(original.channelCount), original.sampleRate > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: original.sampleRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: original, frameCapacity: 4096),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)
        else { throw VocalDuetSeparator.Failure.unsupportedAudio }
        let writer = try AVAudioFile(forWriting: destination, settings: target.settings)
        let expected = Int64((Double(file.length) / original.sampleRate * sampleRate).rounded())
        var written: Int64 = 0
        var readError: Error?
        while written < expected {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                guard file.framePosition < file.length else {
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                    mixed.frameLength = input.frameLength
                    let channels = Int(original.channelCount)
                    for i in 0..<Int(input.frameLength) {
                        var value: Float = 0
                        for channel in 0..<channels { value += input.floatChannelData![channel][i] }
                        mixed.floatChannelData![0][i] = value / Float(channels)
                    }
                    status.pointee = .haveData
                    return mixed
                } catch {
                    readError = error
                    status.pointee = .noDataNow
                    return nil
                }
            }
            if let readError { throw readError }
            if let error { throw error }
            guard status != .error else { throw VocalDuetSeparator.Failure.unsupportedAudio }
            if output.frameLength > 0 {
                output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), expected - written))
                try writer.write(from: output)
                written += Int64(output.frameLength)
            }
            if status == .endOfStream { break }
        }
        // Converter drain/rounding can leave a fractional output frame. Keep the
        // source timeline's rounded duration rather than truncating a track.
        guard expected - written <= 4096 else { throw VocalDuetSeparator.Failure.unsupportedAudio }
        while written < expected {
            try Task.checkCancellation()
            let count = Int(min(4096, expected - written))
            output.frameLength = AVAudioFrameCount(count)
            output.floatChannelData![0].update(repeating: 0, count: count)
            try writer.write(from: output)
            written += Int64(count)
        }
    }
}
