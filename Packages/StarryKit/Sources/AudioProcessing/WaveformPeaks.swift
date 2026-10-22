import Accelerate
import AVFoundation
import Foundation

/// A song's loudest sample in each short slice of time, all channels together, for drawing its
/// waveform: `peaks[i]` covers `i / resolution` to `(i + 1) / resolution` seconds, 0…1.
public struct WaveformPeaks: Sendable, Equatable {
    /// Slices per second.
    public var resolution: Double
    public var peaks: [Float]

    public init(resolution: Double, peaks: [Float]) {
        self.resolution = resolution
        self.peaks = peaks
    }

    public var duration: TimeInterval { Double(peaks.count) / resolution }

    public func peak(from start: TimeInterval, to end: TimeInterval) -> Float {
        let lo = max(0, Int((start * resolution).rounded(.down)))
        let hi = min(peaks.count, max(lo + 1, Int((end * resolution).rounded(.up))))
        guard lo < hi else { return 0 }
        return peaks[lo..<hi].max() ?? 0
    }

    /// Reads `url` (anything AVAudioFile opens: MP3, AAC, ALAC, FLAC, WAV, AIFF) in blocks,
    /// off the caller's thread. Nil when the file cannot be read or the task is cancelled.
    public static func read(_ url: URL, resolution: Double = 100) async -> WaveformPeaks? {
        await Task.detached(priority: .utility) { readNow(url, resolution: resolution) }.value
    }

    static func readNow(_ url: URL, resolution: Double) -> WaveformPeaks? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(64 * 1024)
        guard format.sampleRate > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        var accumulator = Accumulator(sampleRate: format.sampleRate, resolution: resolution, expectedFrames: file.length)
        while file.framePosition < file.length {
            guard !Task.isCancelled else { return nil }
            do { try file.read(into: buffer, frameCount: frames) } catch { break }
            guard buffer.frameLength > 0 else { break }
            accumulator.add(buffer)
        }
        let peaks = accumulator.finish()
        return peaks.peaks.isEmpty ? nil : peaks
    }

    public struct Accumulator: Sendable {
        private let slice: Int
        private let resolution: Double
        private var peaks: [Float] = []
        /// The slice being measured carries over from one block to the next.
        private var current: Float = 0
        private var filled = 0

        public init(sampleRate: Double, resolution: Double = 100, expectedFrames: AVAudioFramePosition = 0) {
            slice = max(1, Int((sampleRate / resolution).rounded()))
            self.resolution = resolution
            peaks.reserveCapacity(Int(expectedFrames) / slice + 1)
        }

        public mutating func add(_ buffer: AVAudioPCMBuffer) {
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { return }
            var offset = 0
            while offset < count {
                let take = min(slice - filled, count - offset)
                for channel in 0..<Int(buffer.format.channelCount) {
                    var level: Float = 0
                    vDSP_maxmgv(channels[channel] + offset, 1, &level, vDSP_Length(take))
                    current = max(current, level)
                }
                filled += take
                offset += take
                if filled == slice {
                    peaks.append(min(current, 1))
                    current = 0
                    filled = 0
                }
            }
        }

        public func finish() -> WaveformPeaks {
            WaveformPeaks(resolution: resolution, peaks: filled > 0 ? peaks + [min(current, 1)] : peaks)
        }
    }
}
