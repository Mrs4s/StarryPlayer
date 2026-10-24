import Foundation

/// An acoustic change that may start a sung syllable, not a recognized character.
public struct VocalOnset: Sendable, Equatable {
    public var time: TimeInterval
    /// Relative salience, 0…1; not a calibrated probability of a syllable boundary.
    public var strength: Float

    public init(time: TimeInterval, strength: Float) {
        self.time = time
        self.strength = strength
    }
}

/// Offline onset suggestions for isolated vocals. The frequency maximum filter follows
/// the vibrato-suppression idea in Böck & Widmer (DAFx 2013); peak picking uses a local
/// median/MAD baseline and energy gating. An independent high-band envelope catches
/// unvoiced consonants; a following vowel can reinforce their earlier start.
public enum VocalOnsetDetector {
    public enum Sensitivity: String, CaseIterable, Sendable {
        case low, medium, high

        public var minimumStrength: Float {
            switch self {
            case .low: 0.8
            case .medium: 0.65
            case .high: 0.5
            }
        }
    }

    /// Supply already separated vocals. Chunked reads bound PCM memory; cancellation is
    /// checked between chunks. Times refer to the original audio, independently of zoom.
    public static func analyze(file: URL) throws -> [VocalOnset] {
        try Task.checkCancellation()
        let analyzer = try VocalActivityAnalyzer(file: file, model: nil, suppressVibrato: true)
        for start in stride(from: 0.0, to: analyzer.duration, by: 10) {
            try Task.checkCancellation()
            try analyzer.analyze(start...min(start + 10, analyzer.duration))
        }
        try Task.checkCancellation()
        let result = candidates(in: analyzer.activity, frameDuration: analyzer.frameDuration,
                                centerOffset: analyzer.frameCenterOffset, duration: analyzer.duration)
        try Task.checkCancellation()
        return result
    }

    static func candidates(in activity: VocalActivity, frameDuration: TimeInterval,
                           centerOffset: TimeInterval, duration: TimeInterval) -> [VocalOnset] {
        let count = activity.frameCount
        guard count >= 5, frameDuration > 0, frameDuration.isFinite,
              activity.flux.count == count, activity.valid.count == count else { return [] }
        var peaks = pickPeaks(energy: activity.energy, flux: activity.flux, valid: activity.valid, frameDuration: frameDuration)
        if activity.fricativeEnergy.count == count, activity.fricativeFlux.count == count {
            let fricatives = pickPeaks(energy: activity.fricativeEnergy, flux: activity.fricativeFlux,
                                      valid: activity.valid, frameDuration: frameDuration)
                .filter { isFricativeAttack($0.frame, in: activity, frameDuration: frameDuration) }
            for var fricative in fricatives {
                if Task.isCancelled { return [] }
                fricative.frame = fricativeStart(fricative.frame, in: activity, frameDuration: frameDuration)
                // Only join a later vowel when high-band sound continues to it and
                // the lower band grows. A silent gap or another /s/ stays separate.
                peaks.removeAll { peak in
                    guard followsFricative(peak.frame, start: fricative.frame, in: activity, frameDuration: frameDuration) else { return false }
                    fricative.strength = max(fricative.strength, peak.strength)
                    return true
                }
                peaks.append(fricative)
            }
        }
        // Competing peaks still merge within 80 ms; joined consonant/vowel attacks
        // already carry the consonant's time and the stronger of their saliences.
        var kept: [VocalOnset] = []
        for peak in peaks.sorted(by: { $0.strength == $1.strength ? $0.frame < $1.frame : $0.strength > $1.strength }) {
            // Flux compares frames two hops apart: its event lies one hop before
            // the current window centre.
            let time = Double(peak.frame - 1) * frameDuration + centerOffset
            guard time >= 0, time <= duration else { continue }
            if !kept.contains(where: { abs($0.time - time) < 0.08 }) {
                kept.append(VocalOnset(time: time, strength: peak.strength))
            }
        }
        return kept.sorted { $0.time < $1.time }
    }

    private struct Peak {
        var frame: Int
        var strength: Float
    }

    private static func pickPeaks(energy: [Float], flux: [Float], valid: [Bool], frameDuration: TimeInterval) -> [Peak] {
        let count = energy.count
        let radius = max(2, Int((0.25 / frameDuration).rounded()))
        var envelope = [Float](repeating: 0, count: count)
        for i in 1..<(count - 1) where valid[i] {
            guard ((i - 1)...(i + 1)).allSatisfy({ valid[$0] && flux[$0].isFinite }) else { continue }
            envelope[i] = max(0, (flux[i - 1] + 2 * flux[i] + flux[i + 1]) / 4)
        }
        var peaks: [Peak] = []
        for i in 2..<(count - 2) where valid[i] {
            if Task.isCancelled { return [] }
            let peak = envelope[i]
            guard peak > 0.035, peak > envelope[i - 1], peak >= envelope[i + 1],
                  peak >= envelope[i - 2], peak >= envelope[i + 2] else { continue }
            let window = max(0, i - radius)...min(count - 1, i + radius)
            let frames = window.filter { valid[$0] && energy[$0].isFinite }
            guard !frames.isEmpty else { continue }
            let localEnergy = frames.map { energy[$0] }.max()!
            // Reject silence and tiny rises in the tails of a phrase.
            guard energy[i].isFinite, energy[i] > max(-40, localEnergy - 35) else { continue }
            let values = frames.map { envelope[$0] }.sorted()
            let baseline = values[values.count / 2]
            let deviations = values.map { abs($0 - baseline) }.sorted()
            let contrast = (peak - baseline) / max(0.035, 3 * deviations[deviations.count / 2])
            guard contrast >= 1 else { continue }
            peaks.append(Peak(frame: i, strength: contrast / (1 + contrast)))
        }
        return peaks
    }

    private static func isFricativeAttack(_ frame: Int, in activity: VocalActivity, frameDuration: TimeInterval) -> Bool {
        let lookback = max(4, Int((0.12 / frameDuration).rounded()))
        let gap = max(2, Int((0.04 / frameDuration).rounded()))
        let sustain = max(2, Int((0.03 / frameDuration).rounded()))
        guard frame >= gap, frame + sustain < activity.frameCount else { return false }
        let first = max(2, frame - lookback)
        guard first <= frame - gap else { return false }
        let before = first...(frame - gap)
        let last = min(frame + sustain, activity.frameCount - sustain - 1)
        guard (first...(last + sustain)).allSatisfy({ activity.valid[$0] && activity.fricativeEnergy[$0].isFinite && activity.energy[$0].isFinite }) else { return false }
        let preceding = before.map { activity.fricativeEnergy[$0] }.sorted()
        // A preceding vowel may have equally strong upper harmonics. Its low band
        // recedes as the consonant takes over, even without a large high-band rise.
        let precedingBalance = before.map { activity.fricativeEnergy[$0] - activity.energy[$0] }.sorted()
        // Allow up to 60 ms for that vowel to recede, requiring a sustained high-band
        // dominance. This avoids promoting upper harmonics of ordinary vowel attacks.
        return (frame...last).contains { start in
            let after = start...(start + sustain)
            let following = after.map { activity.fricativeEnergy[$0] }.sorted()
            let followingBalance = after.map { activity.fricativeEnergy[$0] - activity.energy[$0] }.sorted()
            let balance = followingBalance[followingBalance.count / 2]
            return balance > 3 && (following[following.count / 2] > preceding[preceding.count / 2] + 10
                || balance > precedingBalance[precedingBalance.count / 2] + 10)
        }
    }

    private static func fricativeStart(_ frame: Int, in activity: VocalActivity, frameDuration: TimeInterval) -> Int {
        let limit = max(2, frame - Int((0.06 / frameDuration).rounded()))
        let floor = max(-40, activity.fricativeEnergy[frame] - 12)
        var start = frame
        while start > limit {
            let previous = start - 1
            guard activity.valid[previous], activity.fricativeEnergy[previous] > floor,
                  activity.fricativeEnergy[previous] > activity.energy[previous] + 3 else { break }
            start = previous
        }
        return start
    }

    private static func followsFricative(_ frame: Int, start: Int, in activity: VocalActivity, frameDuration: TimeInterval) -> Bool {
        guard frame >= start, Double(frame - start) * frameDuration <= 0.22 else { return false }
        if Double(frame - start) * frameDuration <= 0.03 { return true }
        let head = start...min(frame, start + max(1, Int((0.04 / frameDuration).rounded())))
        guard head.contains(where: { activity.fricativeEnergy[$0] > activity.energy[$0] + 3 }),
              let trough = (start...frame).map({ activity.energy[$0] }).min(),
              activity.energy[frame] > trough + 6 else { return false }
        let floor = max(-40, activity.fricativeEnergy[start] - 12)
        let end = max(start, frame - max(1, Int((0.03 / frameDuration).rounded())))
        return (start...end).allSatisfy { activity.valid[$0] && activity.fricativeEnergy[$0] > floor }
    }
}
