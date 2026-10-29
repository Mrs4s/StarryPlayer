import AudioProcessing
import Foundation

enum LyricsAIRepeatedVowels {
    struct Refinement: Sendable {
        var spans: [LyricsAICTC.Span]
        var sharedSounds: [Range<Int>]
    }

    private struct Group {
        var morae: [Range<Int>]
        var sound: Int
        var continuous: Bool
        var tokens: Range<Int> { morae.first!.lowerBound..<morae.last!.upperBound }
    }

    static func refine(_ spans: [LyricsAICTC.Span], evidence: LyricsAICTC.Evidence,
                       tokens: [LyricsAICTC.Token], rawSpans: [LyricsAICTC.Span]? = nil,
                       displayBoundaries: Set<Int>? = nil, vocals: URL) throws -> [LyricsAICTC.Span] {
        try refinement(spans, evidence: evidence, tokens: tokens, rawSpans: rawSpans,
                       displayBoundaries: displayBoundaries, vocals: vocals).spans
    }

    static func refinement(_ spans: [LyricsAICTC.Span], evidence: LyricsAICTC.Evidence,
                           tokens: [LyricsAICTC.Token], rawSpans: [LyricsAICTC.Span]? = nil,
                           displayBoundaries: Set<Int>? = nil, vocals: URL) throws -> Refinement {
        var result = spans
        var shared: [Range<Int>] = []
        for group in candidates(spans, rawSpans: rawSpans, displayBoundaries: displayBoundaries, evidence: evidence, tokens: tokens) {
            try Task.checkCancellation()
            let range = span(group.tokens, in: spans)
            let onsets: [VocalOnset]
            do { onsets = try VocalOnsetDetector.analysis(file: vocals, range: range.start...range.end).onsets }
            catch is CancellationError { throw CancellationError() }
            catch { onsets = [] }
            if replace(group, in: &result, evidence: evidence, onsets: onsets) { shared.append(group.tokens) }
        }
        return .init(spans: result, sharedSounds: shared)
    }

    static func refine(_ spans: [LyricsAICTC.Span], evidence: LyricsAICTC.Evidence,
                       tokens: [LyricsAICTC.Token], rawSpans: [LyricsAICTC.Span]? = nil,
                       displayBoundaries: Set<Int>? = nil, onsets: [VocalOnset]) throws -> [LyricsAICTC.Span] {
        try refinement(spans, evidence: evidence, tokens: tokens, rawSpans: rawSpans,
                       displayBoundaries: displayBoundaries, onsets: onsets).spans
    }

    static func refinement(_ spans: [LyricsAICTC.Span], evidence: LyricsAICTC.Evidence,
                           tokens: [LyricsAICTC.Token], rawSpans: [LyricsAICTC.Span]? = nil,
                           displayBoundaries: Set<Int>? = nil, onsets: [VocalOnset]) throws -> Refinement {
        var result = spans
        var shared: [Range<Int>] = []
        for group in candidates(spans, rawSpans: rawSpans, displayBoundaries: displayBoundaries, evidence: evidence, tokens: tokens) {
            try Task.checkCancellation()
            if replace(group, in: &result, evidence: evidence, onsets: onsets) { shared.append(group.tokens) }
        }
        return .init(spans: result, sharedSounds: shared)
    }

    private static func span(_ range: Range<Int>, in spans: [LyricsAICTC.Span]) -> LyricsAICTC.Span {
        .init(start: spans[range.lowerBound].start, end: spans[range.upperBound - 1].end)
    }

    private static func candidates(_ spans: [LyricsAICTC.Span], rawSpans: [LyricsAICTC.Span]?, displayBoundaries: Set<Int>?, evidence: LyricsAICTC.Evidence,
                                   tokens: [LyricsAICTC.Token]) -> [Group] {
        guard spans.count == tokens.count, evidence.frameSeconds > 0,
              rawSpans == nil || rawSpans?.count == spans.count else { return [] }
        let raw = rawSpans ?? spans
        var morae: [Range<Int>] = []
        for index in tokens.indices {
            if tokens[index].isMoraContinuation, index > 0, !tokens[index - 1].endsLine, let last = morae.last {
                morae[morae.count - 1] = last.lowerBound..<(index + 1)
            } else { morae.append(index..<(index + 1)) }
        }
        var result: [Group] = []
        var first = 0
        while first < morae.count {
            let initial = morae[first], sound = tokens[initial.lowerBound].sustainClass
            guard (1...6).contains(sound) else { first += 1; continue }
            let labels = initial.map { tokens[$0].label }
            var end = first + 1
            var continuous = true
            while end < morae.count, !tokens[morae[end - 1].upperBound - 1].endsLine {
                let next = morae[end]
                let continuation: Bool
                if sound == 6 {
                    continuation = next.map { tokens[$0].label } == labels
                } else {
                    let token = tokens[next.lowerBound]
                    continuation = next.count == 1 && (token.isStandaloneVowel || token.isLongMark)
                        && (token.sustainClass == sound || (sound == 5 && token.sustainClass == 3)
                            || (sound == 4 && token.sustainClass == 2))
                }
                if end == first + 1 { continuous = continuation }
                guard continuous ? continuation : next.map({ tokens[$0].label }) == labels else { break }
                if continuous, morae[end - 1].map({ tokens[$0].label }) == next.map({ tokens[$0].label }),
                   independentlyHeard(morae[end - 1], next, spans: raw, evidence: evidence, tokens: tokens) { break }
                end += 1
            }
            guard end - first <= 32 else { first = end; continue }
            var accepted: Group?
            if end - first >= 2 {
                for finish in stride(from: end, through: first + 2, by: -1) {
                    let group = Group(morae: Array(morae[first..<finish]), sound: sound, continuous: continuous)
                    if let displayBoundaries, !group.morae.dropFirst().contains(where: { displayBoundaries.contains($0.lowerBound) }) { continue }
                    if eligible(group, spans: spans, raw: raw, evidence: evidence, tokens: tokens) {
                        accepted = group; break
                    }
                }
            }
            if let accepted {
                result.append(accepted)
                first += accepted.morae.count
            } else { first += 1 }
        }
        return result
    }

    private static func independentlyHeard(_ left: Range<Int>, _ right: Range<Int>, spans: [LyricsAICTC.Span],
                                          evidence: LyricsAICTC.Evidence, tokens: [LyricsAICTC.Token]) -> Bool {
        let a = span(left, in: spans), b = span(right, in: spans)
        func heard(_ range: Range<Int>, _ interval: LyricsAICTC.Span) -> Bool {
            let label = tokens[range.lowerBound].label
            let lower = max(0, Int((interval.start / evidence.frameSeconds).rounded()))
            let upper = min(evidence.frames, Int((interval.end / evidence.frameSeconds).rounded()))
            let count = (lower..<max(lower, upper)).filter {
                evidence.logProbabilities[$0 * evidence.width + label] >= log(0.2)
            }.count
            return Double(count) * evidence.frameSeconds >= 0.06 - 1e-9
        }
        guard heard(left, a), heard(right, b) else { return false }
        let lower = max(0, Int((a.end / evidence.frameSeconds).rounded()))
        let upper = min(evidence.frames, Int((b.start / evidence.frameSeconds).rounded()))
        let label = tokens[left.upperBound - 1].label
        let sound = tokens[left.upperBound - 1].sustainClass
        return (lower..<max(lower, upper)).contains {
            let closure = evidence.silent[$0] || (evidence.sustain[$0 * 8] > log(0.5)
                && evidence.sustain[$0 * 8 + sound] < log(0.3))
            return closure && evidence.logProbabilities[$0 * evidence.width + label] < log(0.2)
                && evidence.logProbabilities[$0 * evidence.width + evidence.blank] > log(0.5)
        }
    }

    private static func eligible(_ group: Group, spans: [LyricsAICTC.Span], raw: [LyricsAICTC.Span],
                                 evidence: LyricsAICTC.Evidence, tokens: [LyricsAICTC.Token]) -> Bool {
        let bounds = span(group.tokens, in: spans), count = group.morae.count
        let lower = Int((bounds.start / evidence.frameSeconds).rounded())
        let upper = Int((bounds.end / evidence.frameSeconds).rounded())
        let length = upper - lower
        guard lower >= 0, upper <= evidence.frames, length >= count * 4, bounds.end - bounds.start <= 8,
              zip(group.morae, group.morae.dropFirst()).allSatisfy({
                  span($1, in: spans).start - span($0, in: spans).end <= 0.06 + 1e-9
              }) else { return false }
        if !group.continuous {
            let collapsed = group.morae.contains {
                let value = span($0, in: raw)
                return value.end - value.start <= evidence.frameSeconds * Double($0.count) * 1.01
            }
            let shortest = group.morae.map { value -> Double in
                let interval = span(value, in: spans)
                return interval.end - interval.start
            }.min() ?? 0
            guard collapsed, shortest <= (bounds.end - bounds.start) / Double(count) * 0.35 else { return false }
        }
        let aliases = group.morae.dropFirst().contains { tokens[$0.lowerBound].sustainClass != group.sound }
        let differentLabels = group.morae.dropFirst().contains {
            $0.map { tokens[$0].label } != group.morae[0].map { tokens[$0].label }
        }
        var restRun = 0, changedRun = 0
        var voiced: Float = 0, heldTotal: Float = 0
        for frame in lower..<upper {
            let held = exp(evidence.sustain[frame * 8 + group.sound])
            let heard = exp(evidence.logProbabilities[frame * evidence.width + tokens[group.tokens.lowerBound].label])
            voiced += max(held, heard); heldTotal += held
            let rest = exp(evidence.sustain[frame * 8])
            if evidence.silent[frame] || (rest > 0.7 && max(held, heard) < 0.3) {
                restRun += 1
                if Double(restRun) * evidence.frameSeconds >= 0.06 - 1e-9 { return false }
            } else { restRun = 0 }
            if aliases {
                let other = group.morae.dropFirst().map {
                    exp(evidence.sustain[frame * 8 + tokens[$0.lowerBound].sustainClass])
                }.max() ?? 0
                if other > 0.65 && held < 0.3 {
                    changedRun += 1
                    if Double(changedRun) * evidence.frameSeconds >= 0.06 - 1e-9 { return false }
                } else { changedRun = 0 }
            }
        }
        return voiced / Float(length) >= 0.6 && (!differentLabels || heldTotal / Float(length) >= 0.6)
    }

    private static func replace(_ group: Group, in spans: inout [LyricsAICTC.Span],
                                evidence: LyricsAICTC.Evidence, onsets: [VocalOnset]) -> Bool {
        let bounds = span(group.tokens, in: spans), start = bounds.start, end = bounds.end
        let lower = Int((start / evidence.frameSeconds).rounded())
        let length = Int((end / evidence.frameSeconds).rounded()) - lower
        let count = group.morae.count, expected = Double(length) / Double(count)
        let minimum = max(2, Int(ceil(0.06 / evidence.frameSeconds)))
        guard length >= count * minimum else { return false }
        let hints = onsets.filter {
            $0.time.isFinite && $0.strength.isFinite && $0.strength >= 0.65
                && $0.time >= start + Double(minimum) * evidence.frameSeconds
                && $0.time <= end - Double(minimum) * evidence.frameSeconds
        }.sorted { $0.strength > $1.strength }.reduce(into: [VocalOnset]()) { result, hint in
            if result.allSatisfy({ abs($0.time - hint.time) >= Double(minimum) * evidence.frameSeconds }) { result.append(hint) }
        }
        if group.continuous, hints.isEmpty {
            // A single sustained sound has no acoustic boundary between display blocks.
            var edges = (0...count).map { start + (end - start) * Double($0) / Double(count) }
            edges[0] = start; edges[count] = end
            assign(group, edges: edges, to: &spans)
            return true
        }
        guard group.continuous || hints.count >= count - 1 else { return false }
        let durationScores = (0...length).map { frames -> Double in
            guard frames >= minimum else { return -.infinity }
            let deviation = log(Double(frames) / expected) / 0.7
            return -0.5 * deviation * deviation
        }
        var boundaryScores = [Double](repeating: 0, count: length + 1)
        for frame in minimum...(length - minimum) {
            let time = Double(lower + frame) * evidence.frameSeconds
            let distance = hints.map { abs($0.time - time) }.min() ?? .infinity
            if group.continuous, hints.count >= count - 1, distance > evidence.frameSeconds + 1e-9 {
                boundaryScores[frame] = -.infinity
                continue
            }
            let onset = hints.map { hint -> Double in
                let distance = (hint.time - time) / 0.025
                return Double(min(hint.strength, 1)) * exp(-0.5 * distance * distance)
            }.max() ?? 0
            let blank = group.continuous ? 0 : exp(evidence.logProbabilities[(lower + frame) * evidence.width + evidence.blank])
            boundaryScores[frame] = 2 * onset + Double(blank)
        }
        var previous = [Double](repeating: -.infinity, count: length + 1)
        previous[0] = 0
        var back = [[Int]](repeating: [Int](repeating: -1, count: length + 1), count: count + 1)
        for part in 1...count {
            var current = [Double](repeating: -.infinity, count: length + 1)
            let last = length - (count - part) * minimum
            for finish in (part * minimum)...last {
                if part == count, finish != length { continue }
                for begin in ((part - 1) * minimum)...(finish - minimum) where previous[begin].isFinite {
                    let score = previous[begin] + durationScores[finish - begin]
                        + (part < count ? boundaryScores[finish] : 0)
                    if score > current[finish] { current[finish] = score; back[part][finish] = begin }
                }
            }
            previous = current
        }
        guard previous[length].isFinite else { return false }
        var boundaries = [Int](repeating: 0, count: count + 1)
        boundaries[count] = length
        for part in (1...count).reversed() { boundaries[part - 1] = back[part][boundaries[part]] }
        var edges = boundaries.map { Double(lower + $0) * evidence.frameSeconds }
        edges[0] = start; edges[count] = end
        assign(group, edges: edges, to: &spans)
        return false
    }

    private static func assign(_ group: Group, edges: [Double], to spans: inout [LyricsAICTC.Span]) {
        for (part, mora) in group.morae.enumerated() {
            let original = span(mora, in: spans)
            let scale = (edges[part + 1] - edges[part]) / (original.end - original.start)
            for token in mora {
                spans[token] = .init(start: edges[part] + (spans[token].start - original.start) * scale,
                                     end: edges[part] + (spans[token].end - original.start) * scale)
            }
            spans[mora.lowerBound].start = edges[part]
            spans[mora.upperBound - 1].end = edges[part + 1]
        }
    }
}
