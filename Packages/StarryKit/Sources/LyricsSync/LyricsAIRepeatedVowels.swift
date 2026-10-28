import AudioProcessing
import Foundation

enum LyricsAIRepeatedVowels {
    static func refine(_ spans: [LyricsAICTC.Span], evidence: LyricsAICTC.Evidence,
                       tokens: [LyricsAICTC.Token], vocals: URL) throws -> [LyricsAICTC.Span] {
        var result = spans
        for group in candidates(spans, evidence: evidence, tokens: tokens) {
            try Task.checkCancellation()
            let range = spans[group.lowerBound].start...spans[group.upperBound - 1].end
            let onsets: [VocalOnset]
            do { onsets = try VocalOnsetDetector.analysis(file: vocals, range: range).onsets }
            catch is CancellationError { throw CancellationError() }
            catch { onsets = [] }
            replace(group, in: &result, evidence: evidence, onsets: onsets)
        }
        return result
    }

    static func refine(_ spans: [LyricsAICTC.Span], evidence: LyricsAICTC.Evidence,
                       tokens: [LyricsAICTC.Token], onsets: [VocalOnset]) throws -> [LyricsAICTC.Span] {
        var result = spans
        for group in candidates(spans, evidence: evidence, tokens: tokens) {
            try Task.checkCancellation()
            replace(group, in: &result, evidence: evidence, onsets: onsets)
        }
        return result
    }

    private static func candidates(_ spans: [LyricsAICTC.Span], evidence: LyricsAICTC.Evidence,
                                   tokens: [LyricsAICTC.Token]) -> [Range<Int>] {
        guard spans.count == tokens.count, evidence.frameSeconds > 0 else { return [] }
        var result: [Range<Int>] = []
        var first = 0
        while first < tokens.count {
            var end = first + 1
            while end < tokens.count, !tokens[end - 1].endsLine,
                  tokens[first].isStandaloneVowel, tokens[end].isStandaloneVowel,
                  tokens[end].label == tokens[first].label,
                  tokens[end].sustainClass == tokens[first].sustainClass {
                end += 1
            }
            defer { first = end }
            let count = end - first, vowel = tokens[first].sustainClass
            guard count >= 2, count <= 8, (1...5).contains(vowel) else { continue }
            let lower = Int((spans[first].start / evidence.frameSeconds).rounded())
            let upper = Int((spans[end - 1].end / evidence.frameSeconds).rounded())
            let length = upper - lower
            guard lower >= 0, upper <= evidence.frames, length >= count * 4,
                  Double(length) * evidence.frameSeconds <= 8,
                  spans[first..<end].contains(where: { $0.end - $0.start <= evidence.frameSeconds * 1.01 }),
                  (first..<(end - 1)).allSatisfy({ spans[$0 + 1].start - spans[$0].end <= 0.06 + 1e-9 }) else { continue }
            var restRun = 0
            var voiced: Float = 0
            var interrupted = false
            for frame in lower..<upper {
                let held = exp(evidence.sustain[frame * 8 + vowel])
                let heard = exp(evidence.logProbabilities[frame * evidence.width + tokens[first].label])
                voiced += max(held, heard)
                let rest = exp(evidence.sustain[frame * 8])
                if evidence.silent[frame] || (rest > 0.7 && max(held, heard) < 0.3) {
                    restRun += 1
                    if Double(restRun) * evidence.frameSeconds >= 0.06 - 1e-9 { interrupted = true; break }
                } else { restRun = 0 }
            }
            guard !interrupted, voiced / Float(length) >= 0.6 else { continue }
            result.append(first..<end)
        }
        return result
    }

    private static func replace(_ group: Range<Int>, in spans: inout [LyricsAICTC.Span],
                                evidence: LyricsAICTC.Evidence, onsets: [VocalOnset]) {
        let start = spans[group.lowerBound].start, end = spans[group.upperBound - 1].end
        let lower = Int((start / evidence.frameSeconds).rounded())
        let length = Int((end / evidence.frameSeconds).rounded()) - lower
        let count = group.count, expected = Double(length) / Double(count)
        let minimum = max(2, Int(ceil(0.06 / evidence.frameSeconds)))
        guard length >= count * minimum else { return }

        // A broad duration prior lets clear onsets outweigh equal-length splits.
        let durationScores = (0...length).map { frames -> Double in
            guard frames >= minimum else { return -.infinity }
            let deviation = log(Double(frames) / expected) / 0.7
            return -0.5 * deviation * deviation
        }
        var boundaryScores = [Double](repeating: 0, count: length + 1)
        let hints = onsets.filter { $0.time.isFinite && $0.strength.isFinite && $0.strength >= 0.65 }
        for frame in minimum...(length - minimum) {
            let time = Double(lower + frame) * evidence.frameSeconds
            let onset = hints.map { hint -> Double in
                let distance = (hint.time - time) / 0.025
                return Double(min(hint.strength, 1)) * exp(-0.5 * distance * distance)
            }.max() ?? 0
            let blank = exp(evidence.logProbabilities[(lower + frame) * evidence.width + evidence.blank])
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
                    if score > current[finish] {
                        current[finish] = score
                        back[part][finish] = begin
                    }
                }
            }
            previous = current
        }
        guard previous[length].isFinite else { return }
        var boundaries = [Int](repeating: 0, count: count + 1)
        boundaries[count] = length
        for part in (1...count).reversed() {
            boundaries[part - 1] = back[part][boundaries[part]]
        }
        for part in 0..<count {
            spans[group.lowerBound + part] = .init(
                start: part == 0 ? start : Double(lower + boundaries[part]) * evidence.frameSeconds,
                end: part == count - 1 ? end : Double(lower + boundaries[part + 1]) * evidence.frameSeconds
            )
        }
    }
}
