import AVFoundation
import Foundation

/// Ten biquads per channel, followed by preamp and peak limiter.
/// Glide gain changes to avoid clicks; no latency, and allocation only in `prepare`.
public final class EqualizerProcessor: AudioProcessor, @unchecked Sendable {
    public var isEnabled = true
    public let latencyFrames = 0

    static let glide: Double = 0.03
    static let step = 32
    static let ceiling: Double = 1
    static let release: Double = 0.15
    /// A band at 0 dB stops being processed after this long (its filter has rung out).
    static let idleAfter: Double = 0.5

    private let control: EqualizerControl
    private let bands = EqualizerBands.count

    // Set in `prepare`, then audio thread only.
    private var sampleRate = 44100.0
    private var channels = 0
    private var filterState: UnsafeMutablePointer<Double>?
    private var coefficients = [Biquad](repeating: .identity, count: EqualizerBands.count)
    private var current = [Double](repeating: 0, count: EqualizerBands.count)
    private var target = [Double](repeating: 0, count: EqualizerBands.count)
    /// Frames each band has sat at 0 dB.
    private var idleFrames = [Int](repeating: 0, count: EqualizerBands.count)
    private var active = [Bool](repeating: false, count: EqualizerBands.count)
    private var activeList = [Int](repeating: 0, count: EqualizerBands.count)
    private var activeCount = 0
    private var preampGain = 1.0
    private var preampTarget = 1.0
    private var limiterGain = 1.0
    private var limiting = false
    private var glideCoefficient = 0.0
    private var releaseCoefficient = 0.0

    public init(control: EqualizerControl) {
        self.control = control
    }

    deinit { filterState?.deallocate() }

    public func prepare(format: ProcessingFormat) {
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100
        channels = max(format.channelCount, 0)
        filterState?.deallocate()
        let words = max(channels, 1) * bands * 2
        filterState = .allocate(capacity: words)
        filterState?.initialize(repeating: 0, count: words)
        glideCoefficient = 1 - exp(-Double(Self.step) / (Self.glide * sampleRate))
        releaseCoefficient = 1 - exp(-1 / (Self.release * sampleRate))
        let state = control.current
        readTargets(state)
        for band in 0..<bands {
            current[band] = target[band]
            coefficients[band] = filter(band, gain: current[band])
            active[band] = current[band] != 0
            idleFrames[band] = 0
        }
        rebuildActiveList()
        preampGain = preampTarget
        limiting = state.enabled && state.clipGuard
        limiterGain = 1
    }

    public func reset() {
        guard let filterState else { return }
        filterState.update(repeating: 0, count: max(channels, 1) * bands * 2)
        limiterGain = 1
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0, let filterState, channels > 0, buffers.count >= channels else { return }
        let state = control.current
        readTargets(state)
        limiting = state.enabled && state.clipGuard
        if isBypassed { return }

        var offset = 0
        while offset < frameCount {
            let count = min(Self.step, frameCount - offset)
            glide(frames: count)
            let gainFrom = preampGain
            preampGain += (preampTarget - preampGain) * glideCoefficient
            if abs(preampTarget - preampGain) < 1e-5 { preampGain = preampTarget }
            for channel in 0..<channels {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                runFilters(data + offset, count: count, state: filterState + channel * bands * 2)
            }
            applyGain(buffers, offset: offset, count: count, from: gainFrom, to: preampGain)
            offset += count
        }
    }

    private func readTargets(_ state: EqualizerControl.State) {
        for band in 0..<bands { target[band] = state.enabled ? state.filterGains[band] : 0 }
        preampTarget = state.enabled ? pow(10, state.preamp / 20) : 1
    }

    private var isBypassed: Bool {
        activeCount == 0 && preampGain == 1 && preampTarget == 1 && !limiting && limiterGain >= 1
            && !target.contains { $0 != 0 }
    }

    private func glide(frames: Int) {
        var listChanged = false
        for band in 0..<bands {
            let goal = target[band]
            if current[band] != goal {
                var next = current[band] + (goal - current[band]) * glideCoefficient
                if abs(goal - next) < 0.001 { next = goal }
                current[band] = next
                coefficients[band] = filter(band, gain: next)
            }
            if current[band] != 0 {
                idleFrames[band] = 0
                if !active[band] {
                    active[band] = true
                    listChanged = true
                }
            } else if active[band] {
                idleFrames[band] += frames
                if Double(idleFrames[band]) > Self.idleAfter * sampleRate {
                    active[band] = false
                    listChanged = true
                    clearState(band: band)
                }
            }
        }
        if listChanged { rebuildActiveList() }
    }

    private func filter(_ band: Int, gain: Double) -> Biquad {
        Biquad.peaking(frequency: EqualizerBands.frequencies[band], q: EqualizerBands.q, gain: gain, sampleRate: sampleRate)
    }

    private func rebuildActiveList() {
        activeCount = 0
        for band in 0..<bands where active[band] {
            activeList[activeCount] = band
            activeCount += 1
        }
    }

    private func clearState(band: Int) {
        guard let filterState else { return }
        for channel in 0..<channels {
            let base = filterState + channel * bands * 2 + band * 2
            base[0] = 0
            base[1] = 0
        }
    }

    private func runFilters(_ samples: UnsafeMutablePointer<Float>, count: Int, state: UnsafeMutablePointer<Double>) {
        guard activeCount > 0 else { return }
        coefficients.withUnsafeBufferPointer { filters in
            activeList.withUnsafeBufferPointer { list in
                for frame in 0..<count {
                    var x = Double(samples[frame])
                    for slot in 0..<activeCount {
                        let band = list[slot]
                        let f = filters[band]
                        let s = state + band * 2
                        let y = f.b0 * x + s[0]
                        s[0] = f.b1 * x - f.a1 * y + s[1]
                        s[1] = f.b2 * x - f.a2 * y
                        x = y
                    }
                    samples[frame] = Float(x)
                }
            }
        }
        // A filter left in an invalid state starts over rather than staying silent.
        for slot in 0..<activeCount where !state[activeList[slot] * 2].isFinite {
            state.update(repeating: 0, count: bands * 2)
            break
        }
    }

    private func applyGain(_ buffers: UnsafeMutableAudioBufferListPointer, offset: Int, count: Int, from: Double, to: Double) {
        let flat = from == 1 && to == 1
        guard !flat || limiting || limiterGain < 1 else { return }
        let slope = (to - from) / Double(count)
        for frame in 0..<count {
            let preamp = from + slope * Double(frame + 1)
            var gain = preamp
            if limiting || limiterGain < 1 {
                var peak: Float = 0
                for channel in 0..<channels {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    peak = max(peak, abs(data[offset + frame]))
                }
                let wanted = limiting && Double(peak) * preamp > Self.ceiling ? Self.ceiling / (Double(peak) * preamp) : 1
                if wanted < limiterGain {
                    limiterGain = wanted
                } else {
                    limiterGain += (wanted - limiterGain) * releaseCoefficient
                    if limiterGain > 0.99999 { limiterGain = 1 }
                }
                gain *= limiterGain
            }
            if gain == 1 { continue }
            let g = Float(gain)
            for channel in 0..<channels {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[offset + frame] *= g
            }
        }
    }
}
