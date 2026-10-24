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
/// median/MAD baseline, energy gating, and suppression of nearby competing peaks.
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
        let radius = max(2, Int((0.25 / frameDuration).rounded()))
        var envelope = [Float](repeating: 0, count: count)
        for i in 1..<(count - 1) where activity.valid[i] {
            guard activity.flux[(i - 1)...(i + 1)].allSatisfy({ $0.isFinite }) else { continue }
            envelope[i] = max(0, (activity.flux[i - 1] + 2 * activity.flux[i] + activity.flux[i + 1]) / 4)
        }
        var peaks: [VocalOnset] = []
        for i in 2..<(count - 2) where activity.valid[i] {
            if Task.isCancelled { return [] }
            let peak = envelope[i]
            guard peak > 0.035, peak > envelope[i - 1], peak >= envelope[i + 1],
                  peak >= envelope[i - 2], peak >= envelope[i + 2] else { continue }
            let window = max(0, i - radius)...min(count - 1, i + radius)
            let valid = window.filter { activity.valid[$0] && activity.energy[$0].isFinite }
            guard !valid.isEmpty else { continue }
            let localEnergy = valid.map { activity.energy[$0] }.max()!
            // Reject silence and tiny rises in the tails of a phrase.
            guard activity.energy[i].isFinite, activity.energy[i] > max(-40, localEnergy - 35) else { continue }
            let values = valid.map { envelope[$0] }.sorted()
            let baseline = values[values.count / 2]
            let deviations = values.map { abs($0 - baseline) }.sorted()
            let contrast = (peak - baseline) / max(0.035, 3 * deviations[deviations.count / 2])
            guard contrast >= 1 else { continue }
            // The flux compares frames two hops apart, so its event lies one hop before
            // the current window centre. Do not backtrack to distant phrase silences.
            let time = Double(i - 1) * frameDuration + centerOffset
            guard time >= 0, time <= duration else { continue }
            peaks.append(VocalOnset(time: time, strength: contrast / (1 + contrast)))
        }
        // Stronger peaks win within 80 ms (e.g. consonant followed by its vowel).
        var kept: [VocalOnset] = []
        for peak in peaks.sorted(by: { $0.strength == $1.strength ? $0.time < $1.time : $0.strength > $1.strength }) {
            if !kept.contains(where: { abs($0.time - peak.time) < 0.08 }) { kept.append(peak) }
        }
        return kept.sorted { $0.time < $1.time }
    }
}
