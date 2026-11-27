import Foundation
import LyricsCore

enum LyricsAITimingReview {
    /// A token whose best frame stays below this log probability has no clear acoustic match.
    static let weakPeak = Float(log(0.02))
    /// The block starts at least this far ahead of its CTC match, usually because the blank fill reached back.
    static let earlyStart: TimeInterval = 0.3
    /// The block ends at least this far past its CTC match, usually because the blank fill held it.
    static let lateEnd: TimeInterval = 0.8
    /// Blocks longer than this are usually a misplaced word or a hold through someone else's line.
    static let longBlock: TimeInterval = 2.5
    /// Vocals-only vs mix-only placement disagreement above this threshold reliably flags residual alignment errors.
    static let sourceDisagreement: TimeInterval = 0.12

    // Thresholds were fitted to human corrections of 18 songs; they flag fewer blocks than the former
    // per-token weakness rule while catching more of the blocks that were off by over 300 ms.
    static func issues(plan: LyricsAIPronunciation, draft: LyricsDraft, evidence: LyricsAICTC.Evidence,
                       rawSpans: [LyricsAICTC.Span], spans: [LyricsAICTC.Span], sharedSounds: [Range<Int>] = [],
                       alternateSpans: (vocals: [LyricsAICTC.Span], mix: [LyricsAICTC.Span])? = nil) -> [LyricsAIReviewIssue] {
        guard rawSpans.count == plan.tokens.count, spans.count == plan.tokens.count else { return [] }
        var result: [LyricsAIReviewIssue] = []
        var previous: LyricsAIPronunciation.Unit?
        for unit in plan.units where !unit.tokens.isEmpty {
            defer { previous = unit }
            var reasons: [String] = []
            let weak = unit.tokens.contains { token in
                let continuation = plan.tokens[token].isStandaloneVowel || plan.tokens[token].isLongMark
                    || plan.tokens[token].sustainClass == 6
                if plan.tokens[token].label == 122 || (continuation && sharedSounds.contains(where: { $0.contains(token) })) { return false }
                let lower = max(0, Int((spans[token].start / evidence.frameSeconds).rounded(.down)))
                let upper = min(evidence.frames, Int((spans[token].end / evidence.frameSeconds).rounded(.up)))
                var peak: Float = -.infinity
                for frame in lower..<max(lower, upper) {
                    peak = max(peak, evidence.logProbabilities[frame * evidence.width + plan.tokens[token].label])
                }
                return peak < weakPeak
            }
            if weak { reasons.append("声学证据偏弱") }
            let first = unit.tokens.lowerBound, last = unit.tokens.upperBound - 1
            // Boundaries inside a shared sound are divided evenly on purpose; they are not fill errors.
            let shared = sharedSounds.contains { $0.lowerBound < first && $0.contains(first) }
            let sharedEnd = sharedSounds.contains { $0.contains(last) && last < $0.upperBound - 1 }
            if !shared, rawSpans[first].start - spans[first].start >= earlyStart - 1e-9 { reasons.append("起点比检测到的发音提前 0.3 秒以上") }
            if !sharedEnd, spans[last].end - rawSpans[last].end >= lateEnd - 1e-9 { reasons.append("终点比检测到的发音延后 0.8 秒以上") }
            if spans[last].end - spans[first].start > longBlock + 1e-9 { reasons.append("字块持续超过 2.5 秒") }
            if !shared, let previous, previous.line == unit.line, previous.tokens.upperBound == unit.tokens.lowerBound {
                let left = previous.tokens.upperBound - 1, right = unit.tokens.lowerBound
                if plan.tokens[left].label == plan.tokens[right].label, !plan.tokens[left].endsLine,
                   (1...6).contains(plan.tokens[right].sustainClass),
                   min(rawSpans[left].end - rawSpans[left].start, rawSpans[right].end - rawSpans[right].start) <= evidence.frameSeconds * 1.01,
                   spans[right].end - spans[left].start >= 0.24,
                   abs((spans[left].end - spans[left].start) - (spans[right].end - spans[right].start)) >= 0.001 {
                    reasons.append("连续同音的字间边界需核对")
                }
            }
            if let alternateSpans, alternateSpans.vocals.count == plan.tokens.count, alternateSpans.mix.count == plan.tokens.count {
                let startDiff = shared ? 0 : abs(alternateSpans.vocals[first].start - alternateSpans.mix[first].start)
                let endDiff = sharedEnd ? 0 : abs(alternateSpans.vocals[last].end - alternateSpans.mix[last].end)
                let residualStart = shared ? 0 : max(abs(spans[first].start - alternateSpans.vocals[first].start),
                                                     abs(spans[first].start - alternateSpans.mix[first].start))
                let residualEnd = sharedEnd ? 0 : max(abs(spans[last].end - alternateSpans.vocals[last].end),
                                                      abs(spans[last].end - alternateSpans.mix[last].end))
                if max(startDiff, endDiff) >= sourceDisagreement - 1e-9, max(residualStart, residualEnd) >= 0.06 - 1e-9 {
                    reasons.append("人声轨与原曲混音定位不一致")
                }
            }
            if !reasons.isEmpty {
                let syllable = draft.lines[unit.line].syllables[unit.syllable]
                result.append(.init(syllableIDs: [syllable.id], kind: .uncertainTiming,
                                    message: "第 \(unit.line + 1) 行「\(syllable.text.prefix(40))」：" + reasons.joined(separator: "；")))
            }
        }
        return result
    }
}
