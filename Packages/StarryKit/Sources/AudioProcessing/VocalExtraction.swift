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
    /// at the source's rate and channels, as long as the source. `progress` (0…1) is called off
    /// the main thread. Returns the network used (the system's when `model` cannot take the
    /// file). Cancelling stops it part-way and throws `CancellationError`.
    @discardableResult
    public static func extractVocals(from source: URL, to destination: URL, model: VocalSeparationModel, progress: (@Sendable (Double) -> Void)? = nil) async throws -> VocalSeparationModel {
        try await Task.detached(priority: .userInitiated) {
            try run(source: source, destination: destination, model: model, progress: progress)
        }.value
    }

    static func run(source: URL, destination: URL, model: VocalSeparationModel, progress: (@Sendable (Double) -> Void)?) throws -> VocalSeparationModel {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let block = 4096
        guard (1...2).contains(channels), let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else { throw Failure.unsupported }
        let processing = ProcessingFormat(sampleRate: format.sampleRate, channelCount: channels, maxFrames: block)
        let feed = InputFeed(channels: channels, maxFrames: block)
        let unit: IsolationUnit? = if model.accepts(channelCount: channels), let unit = IsolationUnit(format: processing, model: model, feed: feed) {
            unit
        } else if model != .systemVoice, VocalSeparationModel.systemVoice.accepts(channelCount: channels) {
            IsolationUnit(format: processing, model: .systemVoice, feed: feed)
        } else {
            nil
        }
        guard let unit else { throw Failure.unsupported }
        AudioUnitSetParameter(unit.unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        let subtracts = unit.output == .accompaniment

        try? FileManager.default.removeItem(at: destination)
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
        return unit.model
    }
}
