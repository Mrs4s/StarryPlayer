import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsAITimingReviewTests {
    private func evidence(weak: Bool = false, frames: Int = 40, row: [Float]? = nil) -> LyricsAICTC.Evidence {
        let row = row ?? (weak ? [0.98, 0.01, 0.01] : [0.01, 0.98, 0.01])
        return .init(frames: frames, width: 3, blank: 0, logProbabilities: (0..<frames).flatMap { _ in row.map(log) },
                     sustain: [], silent: [], duration: Double(frames) * 0.02)
    }

    private func line(_ texts: [String], labels: [Int]) -> (LyricsDraft, LyricsAIPronunciation) {
        let draft = LyricsDraft(lines: [.init(syllables: texts.map { .init(text: $0) })])
        let tokens = labels.enumerated().map { index, label in
            LyricsAICTC.Token(label: label, sustainClass: 1, endsLine: index == labels.count - 1)
        }
        let units = texts.indices.map { LyricsAIPronunciation.Unit(line: 0, syllable: $0, tokens: $0..<($0 + 1), ruby: [], approximate: false) }
        return (draft, .init(tokens: tokens, units: units, lines: [0], estimatedCount: 0, backgroundCount: 0))
    }

    @Test func weakAcousticMatchesAreReviewedEvenWhenEveryBlockHasAValidInterval() {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "こ")])])
        let plan = LyricsAIPronunciation(tokens: [.init(label: 1, sustainClass: 5)],
            units: [.init(line: 0, syllable: 0, tokens: 0..<1, ruby: [], approximate: false)],
            lines: [0], estimatedCount: 0, backgroundCount: 0)
        let spans: [LyricsAICTC.Span] = [.init(start: 0, end: 0.8)]
        #expect(LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(), rawSpans: spans, spans: spans).isEmpty)
        let review = LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(weak: true), rawSpans: spans, spans: spans)
        #expect(review.count == 1)
        #expect(review[0].message.contains("声学证据偏弱"))
    }

    @Test func repeatedSoundsAreReviewedOnlyWhenTheirBoundaryIsUneven() {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "い"), .init(text: "い")])])
        var plan = LyricsAIPronunciation(tokens: [.init(label: 1, sustainClass: 2), .init(label: 1, sustainClass: 2, endsLine: true)],
            units: [.init(line: 0, syllable: 0, tokens: 0..<1, ruby: [], approximate: false),
                    .init(line: 0, syllable: 1, tokens: 1..<2, ruby: [], approximate: false)],
            lines: [0], estimatedCount: 0, backgroundCount: 0)
        let raw: [LyricsAICTC.Span] = [.init(start: 0, end: 0.6), .init(start: 0.62, end: 0.64)]
        let uneven: [LyricsAICTC.Span] = [.init(start: 0, end: 0.5), .init(start: 0.5, end: 0.8)]
        let review = LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(), rawSpans: raw, spans: uneven)
        #expect(review.count == 1)
        #expect(review[0].message.contains("连续同音的字间边界需核对"))
        #expect(review[0].syllableIDs == [draft.lines[0].syllables[1].id])
        let even: [LyricsAICTC.Span] = [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)]
        #expect(LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(), rawSpans: raw, spans: even).isEmpty)
        plan.units = [.init(line: 0, syllable: 0, tokens: 0..<2, ruby: [], approximate: false)]
        #expect(LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(), rawSpans: raw, spans: uneven).isEmpty)
    }

    @Test func aSharedSoundIsNotReviewedForItsDividedBoundary() {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "こ"), .init(text: "う")])])
        let plan = LyricsAIPronunciation(tokens: [.init(label: 1, sustainClass: 5),
                                                  .init(label: 2, sustainClass: 3, endsLine: true, isStandaloneVowel: true)],
            units: [.init(line: 0, syllable: 0, tokens: 0..<1, ruby: [], approximate: false),
                    .init(line: 0, syllable: 1, tokens: 1..<2, ruby: [], approximate: false)],
            lines: [0], estimatedCount: 0, backgroundCount: 0)
        // The shared boundary sits 0.34 s ahead of the raw match for う, and う itself is weak.
        let raw: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.76)]
        let spans: [LyricsAICTC.Span] = [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)]
        #expect(LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(),
                                            rawSpans: raw, spans: spans, sharedSounds: [0..<2]).isEmpty)
        let weak = LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(weak: true),
                                               rawSpans: raw, spans: spans, sharedSounds: [0..<2])
        #expect(weak.map(\.syllableIDs) == [[draft.lines[0].syllables[0].id]])
        #expect(weak[0].message.contains("声学证据偏弱"))
        let unshared = LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: evidence(), rawSpans: raw, spans: spans)
        #expect(unshared.map(\.syllableIDs) == [[draft.lines[0].syllables[1].id]])
        #expect(unshared[0].message.contains("声学证据偏弱"))
        #expect(unshared[0].message.contains("起点比检测到的发音提前"))
    }

    @Test func blocksStretchedFarFromTheirDetectedSoundAreReviewed() {
        let (draft, plan) = line(["あ", "い", "う", "え"], labels: [1, 2, 1, 2])
        let both = evidence(frames: 250, row: [0.02, 0.49, 0.49])
        let raw: [LyricsAICTC.Span] = [.init(start: 0.5, end: 0.6), .init(start: 0.7, end: 0.8),
                                       .init(start: 1.8, end: 4.0), .init(start: 4.5, end: 4.9)]
        let spans: [LyricsAICTC.Span] = [.init(start: 0.1, end: 0.6), .init(start: 0.7, end: 1.6),
                                         .init(start: 1.8, end: 4.4), .init(start: 4.42, end: 4.9)]
        let review = LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: both, rawSpans: raw, spans: spans)
        let ids = draft.lines[0].syllables.map(\.id)
        #expect(review.map(\.syllableIDs) == [[ids[0]], [ids[1]], [ids[2]]])
        #expect(review[0].message.hasSuffix("起点比检测到的发音提前 0.3 秒以上"))
        #expect(review[1].message.hasSuffix("终点比检测到的发音延后 0.8 秒以上"))
        #expect(review[2].message.hasSuffix("字块持续超过 2.5 秒"))
        let near: [LyricsAICTC.Span] = [.init(start: 0.3, end: 0.6), .init(start: 0.7, end: 1.4),
                                        .init(start: 1.8, end: 4.2), .init(start: 4.42, end: 4.9)]
        #expect(LyricsAITimingReview.issues(plan: plan, draft: draft, evidence: both, rawSpans: raw, spans: near).isEmpty)
    }
}
