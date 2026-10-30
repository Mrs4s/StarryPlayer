import Foundation
import LyricsCore

enum LyricsAITimingReview {
    static func issues(plan: LyricsAIPronunciation, draft: LyricsDraft, evidence: LyricsAICTC.Evidence,
                       rawSpans: [LyricsAICTC.Span], spans: [LyricsAICTC.Span], sharedSounds: [Range<Int>] = []) -> [LyricsAIReviewIssue] {
        guard rawSpans.count == plan.tokens.count, spans.count == plan.tokens.count else { return [] }
        var result: [LyricsAIReviewIssue] = []
        var previous: LyricsAIPronunciation.Unit?
        for unit in plan.units where !unit.tokens.isEmpty {
            defer { previous = unit }
            var weak = 0
            for token in unit.tokens {
                let continuation = plan.tokens[token].isStandaloneVowel || plan.tokens[token].isLongMark
                    || plan.tokens[token].sustainClass == 6
                if plan.tokens[token].label == 122 || (continuation && sharedSounds.contains(where: { $0.contains(token) })) { continue }
                let lower = max(0, Int((spans[token].start / evidence.frameSeconds).rounded(.down)))
                let upper = min(evidence.frames, Int((spans[token].end / evidence.frameSeconds).rounded(.up)))
                var peak: Float = -.infinity
                for frame in lower..<max(lower, upper) {
                    peak = max(peak, evidence.logProbabilities[frame * evidence.width + plan.tokens[token].label])
                }
                if peak < log(0.1) { weak += 1 }
            }
            var reasons: [String] = []
            if weak > 0, weak * 2 >= unit.tokens.count { reasons.append("声学证据偏弱") }
            let shared = sharedSounds.contains { $0.lowerBound < unit.tokens.lowerBound && $0.contains(unit.tokens.lowerBound) }
            if shared {
                reasons.append("连读音的字间时间为分配值")
            } else if let previous, previous.line == unit.line, previous.tokens.upperBound == unit.tokens.lowerBound {
                let left = previous.tokens.upperBound - 1, right = unit.tokens.lowerBound
                if plan.tokens[left].label == plan.tokens[right].label, !plan.tokens[left].endsLine,
                   (1...6).contains(plan.tokens[right].sustainClass),
                   min(rawSpans[left].end - rawSpans[left].start, rawSpans[right].end - rawSpans[right].start) <= evidence.frameSeconds * 1.01,
                   spans[right].end - spans[left].start >= 0.24 {
                    let leftDuration = spans[left].end - spans[left].start
                    let rightDuration = spans[right].end - spans[right].start
                    reasons.append(abs(leftDuration - rightDuration) < 0.001
                        ? "连读音的字间时间为分配值" : "连续同音的字间边界需核对")
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
