import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsAITimingReviewTests {
    private func evidence(weak: Bool = false) -> LyricsAICTC.Evidence {
        .init(frames: 40, width: 3, blank: 0,
              logProbabilities: (0..<40).flatMap { _ in (weak ? [Float(0.98), 0.01, 0.01] : [Float(0.01), 0.98, 0.01]).map(log) },
              sustain: [], silent: [], duration: 0.8)
    }

    @Test func weakAcousticMatchesAreReviewedEvenWhenEveryBlockHasAValidInterval() {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "こ")])])
        let plan = LyricsAIPronunciation(tokens: [.init(label: 1, sustainClass: 5)],
            units: [.init(line: 0, syllable: 0, tokens: 0..<1, ruby: [], approximate: false)],
            lines: [0], estimatedCount: 0, backgroundCount: 0)
        let spans: [LyricsAICTC.Span] = [.init(start: 0, end: 0.8)]
        #expect(LyricsAITimingReview.descriptions(plan: plan, draft: draft, evidence: evidence(), rawSpans: spans, spans: spans).isEmpty)
        let review = LyricsAITimingReview.descriptions(plan: plan, draft: draft, evidence: evidence(weak: true), rawSpans: spans, spans: spans)
        #expect(review.count == 1)
        #expect(review[0].contains("声学证据偏弱"))
    }

    @Test func recoveredRepeatsRemainReviewableButInternalReadingsDoNotCreateDisplayWarnings() {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "い"), .init(text: "い")])])
        var plan = LyricsAIPronunciation(tokens: [.init(label: 1, sustainClass: 2), .init(label: 1, sustainClass: 2, endsLine: true)],
            units: [.init(line: 0, syllable: 0, tokens: 0..<1, ruby: [], approximate: false),
                    .init(line: 0, syllable: 1, tokens: 1..<2, ruby: [], approximate: false)],
            lines: [0], estimatedCount: 0, backgroundCount: 0)
        let raw: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.76)]
        let spans: [LyricsAICTC.Span] = [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)]
        let review = LyricsAITimingReview.descriptions(plan: plan, draft: draft, evidence: evidence(), rawSpans: raw, spans: spans)
        #expect(review.count == 1)
        #expect(review[0].contains("分配值"))
        plan.units = [.init(line: 0, syllable: 0, tokens: 0..<2, ruby: [], approximate: false)]
        #expect(LyricsAITimingReview.descriptions(plan: plan, draft: draft, evidence: evidence(), rawSpans: raw, spans: spans).isEmpty)
    }

    @Test func aSharedSoundIsDescribedAsDisplayTimingInsteadOfAWeakPhonemeMatch() {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "こ"), .init(text: "う")])])
        var plan = LyricsAIPronunciation(tokens: [.init(label: 1, sustainClass: 5),
                                                .init(label: 2, sustainClass: 3, endsLine: true, isStandaloneVowel: true)],
            units: [.init(line: 0, syllable: 0, tokens: 0..<1, ruby: [], approximate: false),
                    .init(line: 0, syllable: 1, tokens: 1..<2, ruby: [], approximate: false)],
            lines: [0], estimatedCount: 0, backgroundCount: 0)
        let raw: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.76)]
        let spans: [LyricsAICTC.Span] = [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)]
        let review = LyricsAITimingReview.descriptions(plan: plan, draft: draft, evidence: evidence(),
                                                       rawSpans: raw, spans: spans, sharedSounds: [0..<2])
        #expect(review.count == 1)
        #expect(review[0].contains("分配值"))
        #expect(!review[0].contains("声学证据偏弱"))
        plan.units = [.init(line: 0, syllable: 0, tokens: 0..<2, ruby: [], approximate: false)]
        #expect(LyricsAITimingReview.descriptions(plan: plan, draft: draft, evidence: evidence(),
                                                rawSpans: raw, spans: spans, sharedSounds: [0..<2]).isEmpty)
    }
}
