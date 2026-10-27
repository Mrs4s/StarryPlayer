import AudioProcessing
import Foundation
import LyricsCore

/// Existing timings are soft anchors in calibration mode.
public enum LyricsLineAligner {
    public enum Mode: String, Sendable, Hashable {
        case arrange, calibrate
    }

    public enum Failure: Error, LocalizedError {
        case invalidRange, noOnsets, noPath

        public var errorDescription: String? {
            switch self {
            case .invalidRange: "这一行的范围太短或无效，请重新设置开始和结束时间。"
            case .noOnsets: "这个范围内没有可用的起字点，请调整范围或手动打点。"
            case .noPath: "没能找到顺序合理的对齐结果，请扩大范围或改用重新排字。"
            }
        }
    }

    public struct Result: Sendable {
        public var line: LyricsDraft.Line
        /// Per display block; false means its start was estimated without an onset.
        public var matched: [Bool]
        public var matchedCount: Int { matched.filter { $0 }.count }
        public var estimatedCount: Int { matched.count - matchedCount }
    }

    private struct Candidate {
        var time: Double
        var strength: Float?
    }

    public static func align(_ line: LyricsDraft.Line, in range: ClosedRange<TimeInterval>,
                             analysis: VocalOnsetDetector.Analysis, mode: Mode = .arrange,
                             language: LyricsTimingWeights.Language = .automatic,
                             maximumAdjustment: TimeInterval = 0.35) throws -> Result {
        try Task.checkCancellation()
        let count = line.syllables.count
        let minimum = 0.02
        guard count > 0, range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound >= 0,
              range.upperBound - range.lowerBound >= Double(count) * minimum,
              maximumAdjustment.isFinite, maximumAdjustment > 0 else { throw Failure.invalidRange }
        let hints = analysis.onsets.filter {
            $0.time.isFinite && range.contains($0.time) && $0.strength.isFinite && $0.strength >= 0.5 && $0.strength <= 1
        }.sorted { $0.time < $1.time }
        let guide = ActivityGuide(analysis: analysis, range: range, arranging: mode == .arrange)
        guard !hints.isEmpty || guide.hasActivity else { throw Failure.noOnsets }
        let profile = LyricsTimingWeights.profile(for: line, language: language)
        let weights = profile.syllables.map(\.weight)
        let adaptive = mode == .arrange && guide.hasActivity
        let total = weights.reduce(0, +)
        let span = max(guide.voicedDuration, Double(count) * minimum)
        var offset = 0.0
        let expected = weights.enumerated().map { index, weight -> Double in
            defer { offset += weight }
            if mode == .calibrate, let start = line.syllables[index].start, start.isFinite {
                return start
            }
            return guide.time(at: offset / total)
        }
        var layers: [[Candidate]] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let floor = range.lowerBound + Double(index) * minimum
            let ceiling = range.upperBound - Double(count - index) * minimum
            let anchor = min(max(expected[index], floor), ceiling)
            let calibrated = mode == .calibrate && line.syllables[index].start?.isFinite == true
            let radius = calibrated ? maximumAdjustment : (adaptive ? range.upperBound - range.lowerBound : max(0.5, span / total * weights[index] * 2))
            var choices = hints.filter { $0.time >= floor && $0.time <= ceiling && abs($0.time - expected[index]) <= radius }
                .sorted { abs($0.time - anchor) < abs($1.time - anchor) }
                .prefix(64).map { Candidate(time: $0.time, strength: $0.strength) }
            if (!calibrated || abs(anchor - expected[index]) <= radius), !choices.contains(where: { abs($0.time - anchor) < 0.001 }) {
                choices.append(Candidate(time: anchor, strength: nil))
            }
            if adaptive {
                // Missing vowel/glide boundaries need candidates between detected attacks.
                let first = max(floor, expected[index] - radius), last = min(ceiling, expected[index] + radius)
                let step = max(0.025, (last - first) / 64)
                for time in stride(from: first, through: last, by: step) {
                    if !choices.contains(where: { abs($0.time - time) < ($0.strength == nil ? 0.005 : 0.04) }) {
                        choices.append(Candidate(time: time, strength: nil))
                    }
                }
            }
            guard !choices.isEmpty else { throw Failure.noPath }
            layers.append(choices.sorted { $0.time < $1.time })
        }
        // Anchor the opening to a silence-to-voice transition, not a later, louder mora.
        let openings = (guide.phraseStarts + (adaptive ? guide.sustainedOnsets.map(\.time) : [])).filter { opening in
            layers[0].contains { $0.strength != nil && abs($0.time - opening) < 0.001 }
        }
        let phraseStart = adaptive ? openings.min() : openings.min { abs($0 - expected[0]) < abs($1 - expected[0]) }
        // A pitch change in a held vowel must not move the final block's start.
        let tail = guide.sustainedOnsets.last
        let tailAnchor: Double? = adaptive && count > 1 && weights[count - 1] <= 1
            && (tail?.strength ?? 0) >= 0.65 && guide.risingOnsets.contains(tail?.time ?? -.infinity)
            && !guide.hasPhraseBreak(before: tail?.time ?? -.infinity)
            ? tail?.time : nil
        let significant = hints.filter { $0.strength >= 0.65 }.map(\.time)
        let pace = nominalSpacing(hints: hints, guide: guide, fallback: span / total)

        var costs: [[Double]] = []
        var back: [[Int]] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let calibrated = mode == .calibrate && line.syllables[index].start?.isFinite == true
            let scale = calibrated ? maximumAdjustment : max(0.1, span * weights[index] / total)
            var row = [Double](repeating: .infinity, count: layers[index].count)
            var previous = [Int](repeating: -1, count: row.count)
            for (j, candidate) in layers[index].enumerated() {
                let reading = profile.syllables[index]
                let estimated: Double = profile.japanese
                    ? (reading.approximateReading ? 0.45 : (reading.attack == .vowel ? 0.25 : (reading.attack == .sonorant ? 0.45 : 0.7))) : 1
                let evidence = candidate.strength.map { 0.2 + Double(1 - $0) * 0.6 } ?? estimated
                let drift = (candidate.time - expected[index]) / scale
                var local = evidence + (calibrated ? 0.45 : 0.18) * drift * drift
                if index == 0, let phraseStart {
                    local += min(3, max(0, abs(candidate.time - phraseStart) - 0.035) / 0.08)
                }
                if index == count - 1, let tailAnchor {
                    local += min(3, max(0, abs(candidate.time - tailAnchor) - 0.015) / 0.08)
                }
                if index == 0 { row[j] = local; continue }
                for (k, before) in layers[index - 1].enumerated() where candidate.time - before.time >= minimum - 1e-9 {
                    let duration = max(minimum, guide.duration(from: before.time, to: candidate.time))
                    let prior: Double
                    if mode == .calibrate, expected[index] > expected[index - 1] {
                        prior = max(minimum, guide.duration(from: expected[index - 1], to: expected[index]))
                    } else if adaptive {
                        prior = max(minimum, pace * weights[index - 1])
                    } else {
                        prior = max(minimum, span * weights[index - 1] / total)
                    }
                    let rhythm = log(duration / prior)
                    var skipped = 0.0
                    if adaptive {
                        let internalCount = Double(max(0, lowerBound(significant, candidate.time - 0.04) - lowerBound(significant, before.time + 0.04)))
                        let excess = max(0, internalCount - max(0, weights[index - 1] - 1))
                        let missing = max(0, profile.syllables[index - 1].internalAttacks - internalCount)
                        skipped = 0.6 * excess + 0.25 * missing
                    }
                    let cost = costs[index - 1][k] + local + (calibrated ? 0.12 : 0.35) * rhythm * rhythm + skipped
                    if cost < row[j] { row[j] = cost; previous[j] = k }
                }
            }
            costs.append(row)
            back.append(previous)
        }
        guard let last = costs.last else { throw Failure.noPath }
        let originalEnd = (line.syllables.last?.end ?? line.end).flatMap { $0.isFinite ? $0 : nil }
        let lastPrior = mode == .calibrate ? originalEnd.flatMap { end in
            end > expected[count - 1] ? guide.duration(from: expected[count - 1], to: end) : nil
        } : nil
        let endingPrior = max(minimum, lastPrior ?? (adaptive ? pace * weights[count - 1] : span * weights[count - 1] / total))
        let endTimes = layers[count - 1].map {
            guide.lineEnd(from: $0.time, preferred: mode == .calibrate ? originalEnd : nil,
                          maximumAdjustment: maximumAdjustment, expectedDuration: endingPrior)
        }
        let endings = layers[count - 1].enumerated().map { index, candidate in
            let remaining = max(minimum, guide.duration(from: candidate.time, to: endTimes[index]))
            let rhythm = log(remaining / endingPrior)
            return last[index] + (mode == .calibrate ? 0.05 : (adaptive ? 0 : 0.2)) * rhythm * rhythm
        }
        guard var best = endings.indices.min(by: { endings[$0] < endings[$1] }), endings[best].isFinite else { throw Failure.noPath }
        let finalEnd = endTimes[best]
        var selected = [Candidate](repeating: Candidate(time: 0, strength: nil), count: count)
        for index in (0..<count).reversed() {
            selected[index] = layers[index][best]
            if index > 0 { best = back[index][best] }
        }
        guard selected.contains(where: { $0.strength != nil }) || guide.hasActivity else { throw Failure.noOnsets }
        var aligned = line
        for index in 0..<count {
            let start = selected[index].time
            let ceiling = index + 1 < count ? selected[index + 1].time : range.upperBound
            var end = index + 1 == count ? finalEnd : guide.end(from: start, to: ceiling)
            // Without usable activity, retain a known pause during calibration.
            if !guide.hasActivity, mode == .calibrate, index + 1 < count,
               let oldStart = line.syllables[index].start, let oldEnd = line.syllables[index].end,
               let next = line.syllables[index + 1].start, oldEnd < next - 0.08, oldEnd > oldStart {
                end = min(end, start + oldEnd - oldStart)
            }
            aligned.syllables[index].start = start
            aligned.syllables[index].end = max(start + minimum, min(end, ceiling))
        }
        aligned.start = nil
        aligned.end = nil
        return Result(line: aligned, matched: selected.map { $0.strength != nil })
    }

    private static func lowerBound(_ values: [Double], _ value: Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func nominalSpacing(hints: [VocalOnset], guide: ActivityGuide, fallback: Double) -> Double {
        guard let first = guide.spans.first?.lowerBound, let last = guide.spans.last?.upperBound else { return fallback }
        let active = hints.filter { $0.time >= first - 0.15 && $0.time <= last + 0.03 }
        let intervals = zip(active, active.dropFirst()).map { $1.time - $0.time }.filter { $0 >= 0.08 && $0 <= 0.6 }.sorted()
        guard !intervals.isEmpty else { return fallback }
        // Use shorter gaps to avoid stretching the pace to match held notes.
        let half = Array(intervals.prefix((intervals.count + 1) / 2))
        let middle = half.count / 2
        return half.count.isMultiple(of: 2) ? (half[middle - 1] + half[middle]) / 2 : half[middle]
    }
}

private struct ActivityGuide {
    var spans: [ClosedRange<Double>]
    var phraseStarts: [Double] = []
    var sustainedOnsets: [VocalOnset] = []
    var risingOnsets: Set<Double> = []
    let range: ClosedRange<Double>
    var hasActivity: Bool { !spans.isEmpty }
    var voicedDuration: Double { hasActivity ? spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound } : range.upperBound - range.lowerBound }

    init(analysis: VocalOnsetDetector.Analysis, range: ClosedRange<Double>, arranging: Bool) {
        self.range = range
        spans = []
        let activity = analysis.activity, hop = analysis.frameDuration
        guard hop.isFinite, hop > 0, analysis.centerOffset.isFinite, activity.valid.count == activity.frameCount else { return }
        let energy = activity.boundaryEnergy
        let frames = energy.indices.filter {
            activity.valid[$0] && energy[$0].isFinite && range.contains(Double($0) * hop + analysis.centerOffset)
        }
        let levels = frames.map { energy[$0] }.sorted()
        guard !levels.isEmpty else { return }
        let high = levels[min(levels.count - 1, levels.count * 9 / 10)]
        guard high > -60 else { return }
        let threshold = max(-55, high - (arranging ? 18 : 28))
        let quietThreshold = max(-55, high - 28)
        for frame in frames where energy[frame] >= threshold {
            let time = Double(frame) * hop + analysis.centerOffset
            let start = max(range.lowerBound, time - hop / 2), end = min(range.upperBound, time + hop / 2)
            if let last = spans.indices.last, start - spans[last].upperBound <= 0.08 {
                spans[last] = spans[last].lowerBound...end
            } else {
                spans.append(start...end)
            }
        }
        spans.removeAll { $0.upperBound - $0.lowerBound < 0.04 }

        func observed(_ lower: Double, _ upper: Double) -> [Int] {
            let first = max(0, Int(ceil((lower - analysis.centerOffset) / hop)))
            let last = min(energy.count - 1, Int(floor((upper - analysis.centerOffset) / hop)))
            guard last >= first else { return [] }
            return (first...last).filter { activity.valid[$0] && energy[$0].isFinite }
        }
        for onset in analysis.onsets where onset.time.isFinite && range.contains(onset.time) {
            let before = observed(onset.time - 0.18, onset.time - 0.04)
            let sustained = observed(onset.time, min(range.upperBound, onset.time + 0.16)).filter { energy[$0] >= threshold }
            if Double(sustained.count) * hop >= 0.08 {
                sustainedOnsets.append(onset)
                let lead = observed(onset.time - 0.12, onset.time - 0.04).map { energy[$0] }
                let following = observed(onset.time + 0.01, min(range.upperBound, onset.time + 0.08)).map { energy[$0] }.sorted()
                if let floor = lead.min(), !following.isEmpty, following[following.count / 2] - floor >= 6 {
                    risingOnsets.insert(onset.time)
                }
            }
            guard Double(before.count) * hop >= 0.12,
                  before.allSatisfy({ energy[$0] < quietThreshold }) else { continue }
            let after = observed(onset.time - 0.02, onset.time + 0.25).filter { energy[$0] >= threshold }
            guard Double(after.count) * hop >= 0.08,
                  let first = after.first, Double(first) * hop + analysis.centerOffset <= onset.time + 0.16 else { continue }
            phraseStarts.append(onset.time)
        }
    }

    func time(at fraction: Double) -> Double {
        guard hasActivity else { return range.lowerBound + fraction * voicedDuration }
        var remaining = fraction * voicedDuration
        for span in spans {
            let length = span.upperBound - span.lowerBound
            if remaining <= length { return span.lowerBound + remaining }
            remaining -= length
        }
        return spans.last!.upperBound
    }

    func duration(from start: Double, to end: Double) -> Double {
        guard hasActivity else { return max(0, end - start) }
        return spans.reduce(0) { $0 + max(0, min(end, $1.upperBound) - max(start, $1.lowerBound)) }
    }

    func hasPhraseBreak(before time: Double) -> Bool {
        zip(spans, spans.dropFirst()).contains { previous, next in
            next.lowerBound <= time && next.lowerBound - previous.upperBound >= 0.35
        }
    }

    func end(from start: Double, to end: Double) -> Double {
        guard let last = spans.last(where: { $0.lowerBound < end - 0.04 && $0.upperBound > start + 0.02 }) else { return end }
        let voicedEnd = min(last.upperBound + 0.02, end)
        return end - voicedEnd >= 0.12 ? max(start + 0.02, voicedEnd) : end
    }

    // The search window may contain the next phrase; prefer a release near the original end.
    func lineEnd(from start: Double, preferred: Double?, maximumAdjustment: Double, expectedDuration: Double) -> Double {
        let offsets = spans.indices.compactMap { index -> Double? in
            let span = spans[index]
            let next = index + 1 < spans.count ? spans[index + 1].lowerBound : range.upperBound
            guard span.upperBound > start + 0.04, next - span.upperBound >= 0.12 else { return nil }
            return min(span.upperBound + 0.02, range.upperBound)
        }
        if let preferred {
            let local = offsets.filter { $0 > start + 0.02 && abs($0 - preferred) <= maximumAdjustment }
            return local.min { abs($0 - preferred) < abs($1 - preferred) }
                ?? min(max(preferred, start + 0.02), range.upperBound)
        }
        let requiredVoice = max(0.04, expectedDuration * 0.35)
        return offsets.first { duration(from: start, to: $0) >= requiredVoice }
            ?? end(from: start, to: range.upperBound)
    }
}
