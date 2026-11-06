import AudioToolbox
import AVFoundation
import Foundation

/// Offline vocal isolation with latency removed to keep vocals aligned with the source.
/// Accompaniment models yield vocals by subtracting their output from the source.
public enum VocalExtraction {
    public enum Failure: Error, Equatable {
        /// No network takes this audio (more than two channels, or a Mac without the system's
        /// voice model and no other).
        case unsupported
        case renderFailed(OSStatus)
    }

    /// Writes the vocals of `source` (anything AVAudioFile opens) to `destination` as a float file
    /// at the source's rate and channels, as long as the source. A network that declares its
    /// training rate runs at that rate, with the song converted to it and the vocals converted
    /// back. `progress` (0…1) is called off the main thread. Returns the network used (the
    /// system's when `model` cannot take the file). Cancelling stops it part-way and throws
    /// `CancellationError`.
    @discardableResult
    public static func extractVocals(from source: URL, to destination: URL, model: VocalSeparationModel, progress: (@Sendable (Double) -> Void)? = nil) async throws -> VocalSeparationModel {
        let worker = Task.detached(priority: .userInitiated) {
            try run(source: source, destination: destination, model: model, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static let block = 4096

    static func run(source: URL, destination: URL, model: VocalSeparationModel, progress: (@Sendable (Double) -> Void)?) throws -> VocalSeparationModel {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        guard (1...2).contains(channels) else { throw Failure.unsupported }
        let feed = InputFeed(channels: channels, maxFrames: block)
        func unit(for model: VocalSeparationModel) -> (IsolationUnit, Double)? {
            guard model.accepts(channelCount: channels) else { return nil }
            let rate = model.processingRate(for: format.sampleRate)
            let processing = ProcessingFormat(sampleRate: rate, channelCount: channels, maxFrames: block)
            return IsolationUnit(format: processing, model: model, feed: feed).map { ($0, rate) }
        }
        guard let chosen = unit(for: model) ?? (model != .systemVoice ? unit(for: .systemVoice) : nil) else {
            throw Failure.unsupported
        }
        let (unit, rate) = chosen
        AudioUnitSetParameter(unit.unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        try? FileManager.default.removeItem(at: destination)
        guard rate != format.sampleRate else {
            try separate(input, unit: unit, to: destination, progress: progress)
            return unit.model
        }

        // A network fed another rate than it was trained at leaves much more accompaniment in
        // the vocals; the AU's own conversion does not avoid this.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vocals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let converted = scratch.appendingPathComponent("song.caf")
        let separated = scratch.appendingPathComponent("vocals.caf")
        let frames = Int64((Double(input.length) * rate / format.sampleRate).rounded())
        try resample(input, to: rate, into: converted, frames: frames)
        progress?(0.05)
        try separate(AVAudioFile(forReading: converted), unit: unit, to: separated) { progress?(0.05 + $0 * 0.9) }
        try resample(AVAudioFile(forReading: separated), to: format.sampleRate, into: destination, frames: input.length,
                     settings: format.settings)
        progress?(1)
        return unit.model
    }

    /// Renders `input` through `unit`, which must run at the file's rate.
    private static func separate(_ input: AVAudioFile, unit: IsolationUnit, to destination: URL, progress: ((Double) -> Void)?) throws {
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let feed = unit.feed
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else { throw Failure.unsupported }
        let subtracts = unit.output == .accompaniment

        let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = input.length
        var written: Int64 = 0
        var toSkip = unit.latencyFrames
        var renderTime: Float64 = 0
        // The song not yet matched with the unit's output (it trails by its latency).
        var dry = [[Float]](repeating: [], count: channels)
        var reported = -1

        while written < total {
            try Task.checkCancellation()
            // The song, then silence to flush what the unit still holds.
            if input.framePosition < total {
                try input.read(into: inBuffer, frameCount: AVAudioFrameCount(block))
            } else {
                inBuffer.frameLength = AVAudioFrameCount(block)
                for channel in 0..<channels { inBuffer.floatChannelData![channel].update(repeating: 0, count: block) }
            }
            let frames = Int(inBuffer.frameLength)
            guard frames > 0 else { break }
            for channel in 0..<channels {
                let samples = inBuffer.floatChannelData![channel]
                (feed.samples + channel * feed.maxFrames).update(from: samples, count: frames)
                if subtracts { dry[channel].append(contentsOf: UnsafeBufferPointer(start: samples, count: frames)) }
            }

            outBuffer.frameLength = AVAudioFrameCount(frames)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = renderTime
            timestamp.mFlags = .sampleTimeValid
            renderTime += Float64(frames)
            let status = AudioUnitRender(unit.unit, &flags, &timestamp, 0, UInt32(frames), outBuffer.mutableAudioBufferList)
            guard status == noErr else { throw Failure.renderFailed(status) }

            // The unit's first `latency` frames come before the song.
            let start = min(toSkip, frames)
            toSkip -= start
            let usable = min(frames - start, Int(total - written))
            guard usable > 0 else { continue }
            writeBuffer.frameLength = AVAudioFrameCount(usable)
            for channel in 0..<channels {
                let wet = outBuffer.floatChannelData![channel] + start
                let out = writeBuffer.floatChannelData![channel]
                if subtracts {
                    dry[channel].withUnsafeBufferPointer { song in
                        for i in 0..<usable { out[i] = song[i] - wet[i] }
                    }
                    dry[channel].removeFirst(usable)
                } else {
                    out.update(from: wet, count: usable)
                }
            }
            try output.write(from: writeBuffer)
            written += Int64(usable)
            let percent = Int(Double(written) / Double(max(total, 1)) * 100)
            if percent != reported {
                reported = percent
                progress?(Double(written) / Double(max(total, 1)))
            }
        }
    }

    /// Converts `input` to `rate` as a float file of exactly `frames` frames. The converter adds
    /// no delay: its tail is flushed, and any remaining shortfall is filled with silence.
    static func resample(_ input: AVAudioFile, to rate: Double, into destination: URL, frames: Int64,
                         settings: [String: Any]? = nil) throws {
        let from = input.processingFormat
        guard let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: from.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(block)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(block)) else { throw Failure.unsupported }
        converter.primeMethod = .normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination, settings: settings ?? to.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let reader = BlockReader(file: input, buffer: inBuffer)
        var written: Int64 = 0
        while written < frames {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, state in
                guard let buffer = reader.next() else {
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return buffer
            }
            if let failure = reader.failure { throw failure }
            guard status != .error else { throw error ?? Failure.unsupported }
            let usable = min(Int64(outBuffer.frameLength), frames - written)
            if usable > 0 {
                outBuffer.frameLength = AVAudioFrameCount(usable)
                try output.write(from: outBuffer)
                written += usable
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }
        outBuffer.frameLength = 0
        while written < frames {
            let count = Int(min(Int64(block), frames - written))
            outBuffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(to.channelCount) { outBuffer.floatChannelData![channel].update(repeating: 0, count: count) }
            try output.write(from: outBuffer)
            written += Int64(count)
        }
    }

    /// Supplies a file block by block to an AVAudioConverter input callback.
    private final class BlockReader {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        private(set) var failure: Error?

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
            self.file = file
            self.buffer = buffer
        }

        func next() -> AVAudioPCMBuffer? {
            guard failure == nil, file.framePosition < file.length else { return nil }
            do {
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
            } catch {
                failure = error
                return nil
            }
            return buffer.frameLength > 0 ? buffer : nil
        }
    }
}
