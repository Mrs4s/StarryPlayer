import AVFoundation
import Foundation

/// A biquad per channel for each slot of `EqualizerControl.State`, followed by preamp and peak
/// limiter. Parameter changes glide (frequency and Q on a log scale) to avoid clicks, and a
/// filter arriving, leaving or changing type fades in or out of the dry signal; no latency, and
/// allocation only in `prepare`.
public final class EqualizerProcessor: AudioProcessor, @unchecked Sendable {
    public var isEnabled = true
    public let latencyFrames = 0

    static let glide: Double = 0.03
    /// How long a filter takes to fade in or out.
    static let fade: Double = 0.04
    static let step = 32
    static let ceiling: Double = 1
    static let release: Double = 0.15
    /// A slot that passes the sound unchanged stops being processed after this long (its
    /// filter has rung out).
    static let idleAfter: Double = 0.5
    static let slots = ParametricEqualizer.maxBands

    /// A slot's filter as played.
    struct Setting {
        var filter: ParametricFilter?
        var logFrequency = 0.0
        var gain = 0.0
        var logQ = 0.0
        /// How much of the filter is in (0…1), between it and the dry signal.
        var amount = 0.0

        var isIdentity: Bool {
            guard let filter, amount > 0 else { return true }
            return filter.hasGain && gain == 0
        }
    }

    private let control: EqualizerControl

    // Set in `prepare`, then audio thread only.
    private var sampleRate = 44100.0
    private var channels = 0
    private var filterState: UnsafeMutablePointer<Double>?
    private var coefficients = [Biquad](repeating: .identity, count: slots)
    private var current = [Setting](repeating: Setting(), count: slots)
    private var target = [Setting](repeating: Setting(), count: slots)
    /// Frames each slot has passed the sound unchanged.
    private var idleFrames = [Int](repeating: 0, count: slots)
    private var active = [Bool](repeating: false, count: slots)
    private var activeList = [Int](repeating: 0, count: slots)
    private var activeCount = 0
    /// Some target changes the sound.
    private var targetAudible = false
    private var preampGain = 1.0
    private var preampTarget = 1.0
    private var limiterGain = 1.0
    private var limiting = false
    private var glideCoefficient = 0.0
    private var fadeStep = 0.0
    private var releaseCoefficient = 0.0

    public init(control: EqualizerControl) {
        self.control = control
    }

    deinit { filterState?.deallocate() }

    public func prepare(format: ProcessingFormat) {
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100
        channels = max(format.channelCount, 0)
        filterState?.deallocate()
        let words = max(channels, 1) * Self.slots * 2
        filterState = .allocate(capacity: words)
        filterState?.initialize(repeating: 0, count: words)
        glideCoefficient = 1 - exp(-Double(Self.step) / (Self.glide * sampleRate))
        fadeStep = Double(Self.step) / (Self.fade * sampleRate)
        releaseCoefficient = 1 - exp(-1 / (Self.release * sampleRate))
        let state = control.current
        readTargets(state)
        for slot in 0..<Self.slots {
            current[slot] = target[slot]
            coefficients[slot] = filter(current[slot])
            active[slot] = !current[slot].isIdentity
            idleFrames[slot] = 0
        }
        rebuildActiveList()
        preampGain = preampTarget
        limiting = state.enabled && state.clipGuard
        limiterGain = 1
    }

    public func reset() {
        guard let filterState else { return }
        filterState.update(repeating: 0, count: max(channels, 1) * Self.slots * 2)
        limiterGain = 1
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0, let filterState, channels > 0, buffers.count >= channels else { return }
        let state = control.current
        readTargets(state)
        limiting = state.enabled && state.clipGuard
        if isBypassed {
            settleIdleSlots()
            return
        }

        var offset = 0
        while offset < frameCount {
            let count = min(Self.step, frameCount - offset)
            glide(frames: count)
            let gainFrom = preampGain
            preampGain += (preampTarget - preampGain) * glideCoefficient
            if abs(preampTarget - preampGain) < 1e-5 { preampGain = preampTarget }
            for channel in 0..<channels {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                runFilters(data + offset, count: count, state: filterState + channel * Self.slots * 2)
            }
            applyGain(buffers, offset: offset, count: count, from: gainFrom, to: preampGain)
            offset += count
        }
    }

    private func readTargets(_ state: EqualizerControl.State) {
        var audible = false
        for slot in 0..<Self.slots {
            var goal = Setting()
            if state.enabled, let filter = ParametricFilter(code: state.filters[slot]) {
                goal.filter = filter
                goal.logFrequency = log(max(state.frequencies[slot], 1))
                goal.gain = state.gains[slot]
                goal.logQ = log(max(state.qs[slot], 0.01))
                goal.amount = 1
                if !goal.isIdentity { audible = true }
            }
            target[slot] = goal
        }
        targetAudible = audible
        preampTarget = state.enabled ? pow(10, state.preamp / 20) : 1
    }

    private var isBypassed: Bool {
        activeCount == 0 && preampGain == 1 && preampTarget == 1 && !limiting && limiterGain >= 1 && !targetAudible
    }

    /// While bypassed every slot passes the sound unchanged, and so does every target: they take
    /// on their targets at once, so a band moved meanwhile does not later sweep from where it was.
    private func settleIdleSlots() {
        for slot in 0..<Self.slots {
            current[slot] = target[slot]
            coefficients[slot] = .identity
        }
    }

    private func glide(frames: Int) {
        var listChanged = false
        for slot in 0..<Self.slots {
            var setting = current[slot]
            let goal = target[slot]
            var changed = false
            if setting.filter != goal.filter {
                if setting.isIdentity {
                    // Nothing to fade out: the new filter fades in from nothing.
                    setting = goal
                    setting.amount = 0
                    clearState(slot: slot)
                } else {
                    setting.amount = max(setting.amount - fadeStep, 0)
                }
                changed = true
            } else if setting.filter != nil {
                changed = approach(&setting.logFrequency, goal.logFrequency, snap: 1e-4)
                changed = approach(&setting.gain, goal.gain, snap: 0.001) || changed
                changed = approach(&setting.logQ, goal.logQ, snap: 1e-4) || changed
                if setting.amount < 1 {
                    setting.amount = min(setting.amount + fadeStep, 1)
                    changed = true
                }
            }
            if changed {
                current[slot] = setting
                coefficients[slot] = filter(setting)
            }
            if !setting.isIdentity {
                idleFrames[slot] = 0
                if !active[slot] {
                    active[slot] = true
                    listChanged = true
                }
            } else if active[slot] {
                idleFrames[slot] += frames
                if Double(idleFrames[slot]) > Self.idleAfter * sampleRate {
                    active[slot] = false
                    listChanged = true
                    clearState(slot: slot)
                }
            }
        }
        if listChanged { rebuildActiveList() }
    }

    /// One glide step of `value` towards `goal`; whether it moved.
    private func approach(_ value: inout Double, _ goal: Double, snap: Double) -> Bool {
        guard value != goal else { return false }
        var next = value + (goal - value) * glideCoefficient
        if abs(goal - next) < snap { next = goal }
        value = next
        return true
    }

    /// A shelf or peak fades by its gain; the others by mixing with the dry signal.
    private func filter(_ setting: Setting) -> Biquad {
        guard let kind = setting.filter, setting.amount > 0 else { return .identity }
        let frequency = exp(setting.logFrequency)
        let q = exp(setting.logQ)
        if kind.hasGain {
            return Biquad.make(kind, frequency: frequency, q: q, gain: setting.gain * setting.amount, sampleRate: sampleRate)
        }
        let full = Biquad.make(kind, frequency: frequency, q: q, gain: 0, sampleRate: sampleRate)
        return setting.amount < 1 ? full.blended(setting.amount) : full
    }

    private func rebuildActiveList() {
        activeCount = 0
        for slot in 0..<Self.slots where active[slot] {
            activeList[activeCount] = slot
            activeCount += 1
        }
    }

    private func clearState(slot: Int) {
        guard let filterState else { return }
        for channel in 0..<channels {
            let base = filterState + channel * Self.slots * 2 + slot * 2
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
                    for index in 0..<activeCount {
                        let slot = list[index]
                        let f = filters[slot]
                        let s = state + slot * 2
                        let y = f.b0 * x + s[0]
                        s[0] = f.b1 * x - f.a1 * y + s[1]
                        s[1] = f.b2 * x - f.a2 * y
                        x = y
                    }
                    samples[frame] = Float(x)
                }
            }
        }
        for index in 0..<activeCount {
            let s = state + activeList[index] * 2
            // A filter left in an invalid state starts over rather than staying silent.
            guard s[0].isFinite, s[1].isFinite else {
                state.update(repeating: 0, count: Self.slots * 2)
                break
            }
            // A decaying tail in silence ends at zero rather than in subnormals, which are slow
            // on Intel.
            if abs(s[0]) < Double.leastNormalMagnitude { s[0] = 0 }
            if abs(s[1]) < Double.leastNormalMagnitude { s[1] = 0 }
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
