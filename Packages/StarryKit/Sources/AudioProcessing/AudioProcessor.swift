import AVFoundation
import Foundation

/// Float32, non-interleaved, at the source sample rate.
public struct ProcessingFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int
    public var maxFrames: Int

    public init(sampleRate: Double, channelCount: Int, maxFrames: Int = 8192) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.maxFrames = maxFrames
    }
}

/// One stage of the per-item processing chain hosted by an `MTAudioProcessingTap`.
/// Runs on the real-time audio thread: no allocation, no locks, no Swift async.
public protocol AudioProcessor: AnyObject {
    var isEnabled: Bool { get set }
    var latencyFrames: Int { get }
    func prepare(format: ProcessingFormat)
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int)
    /// Same as `process(_:frameCount:)` with the source position of the first frame (nil when the
    /// tap does not know it). A position that does not follow the previous block is a seek.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, sampleIndex: Int64?)
    func reset()
}

public extension AudioProcessor {
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, sampleIndex: Int64?) {
        process(buffers, frameCount: frameCount)
    }
}

public final class AudioProcessorChain {
    public private(set) var processors: [any AudioProcessor] = []
    public private(set) var format: ProcessingFormat?

    public init() {}

    public func append(_ processor: any AudioProcessor) {
        processors.append(processor)
        if let format { processor.prepare(format: format) }
    }

    public func prepare(format: ProcessingFormat) {
        self.format = format
        processors.forEach { $0.prepare(format: format) }
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, sampleIndex: Int64? = nil) {
        for processor in processors where processor.isEnabled {
            processor.process(buffers, frameCount: frameCount, sampleIndex: sampleIndex)
        }
    }
}
