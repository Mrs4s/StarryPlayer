import AVFoundation
import Foundation
import os

/// The fades of one song in a crossfade, as stretches of the song's own timeline in seconds.
/// Equal power: the incoming song rises as a sine and the outgoing one falls as a cosine, so two
/// unrelated songs keep their combined loudness through the overlap (a linear crossfade dips
/// about 3 dB in the middle).
public struct TransitionFades: Sendable, Equatable {
    public var fadeIn: ClosedRange<Double>?
    public var fadeOut: ClosedRange<Double>?

    public init(fadeIn: ClosedRange<Double>? = nil, fadeOut: ClosedRange<Double>? = nil) {
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var isEmpty: Bool { fadeIn == nil && fadeOut == nil }

    /// Gain at `time` of the song's timeline, 0…1.
    public func gain(at time: Double) -> Float {
        var gain: Double = 1
        if let fadeIn { gain *= sin(Self.progress(time, through: fadeIn) * .pi / 2) }
        if let fadeOut { gain *= cos(Self.progress(time, through: fadeOut) * .pi / 2) }
        return Float(gain)
    }

    func isUnity(from start: Double, to end: Double) -> Bool {
        if let fadeIn, start < fadeIn.upperBound { return false }
        if let fadeOut, end > fadeOut.lowerBound { return false }
        return true
    }

    private static func progress(_ time: Double, through range: ClosedRange<Double>) -> Double {
        let length = range.upperBound - range.lowerBound
        guard length > 0 else { return time < range.lowerBound ? 0 : 1 }
        return min(max((time - range.lowerBound) / length, 0), 1)
    }
}

public final class TransitionEnvelopeControl: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TransitionFades())

    public init() {}

    public var fades: TransitionFades {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Source-position crossfade envelope, after EQ and before spectrum analysis.
/// No latency or allocation; seeks and stalls follow the source clock.
public final class TransitionEnvelope: AudioProcessor, @unchecked Sendable {
    public var isEnabled = true
    public let latencyFrames = 0

    private let control: TransitionEnvelopeControl
    private var sampleRate = 44100.0
    private var nextIndex: Int64?

    public init(control: TransitionEnvelopeControl) {
        self.control = control
    }

    public func prepare(format: ProcessingFormat) {
        sampleRate = format.sampleRate
        nextIndex = nil
    }

    public func reset() {
        nextIndex = nil
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        process(buffers, frameCount: frameCount, sampleIndex: nil)
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, sampleIndex: Int64?) {
        let index = sampleIndex ?? nextIndex
        nextIndex = index.map { $0 + Int64(frameCount) }
        guard let index, frameCount > 0 else { return }
        let fades = control.fades
        guard !fades.isEmpty else { return }
        let start = Double(index) / sampleRate
        guard !fades.isUnity(from: start, to: Double(index + Int64(frameCount)) / sampleRate) else { return }
        for frame in 0..<frameCount {
            let gain = fades.gain(at: Double(index + Int64(frame)) / sampleRate)
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] *= gain
            }
        }
    }
}
