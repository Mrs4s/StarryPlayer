import AudioProcessing
import Foundation
import Testing
@testable import LyricsSync

@Suite struct LyricsAIRepeatedVowelsTests {
    private func evidence(frames: Int = 40) -> LyricsAICTC.Evidence {
        .init(frames: frames, width: 2, blank: 0,
              logProbabilities: (0..<frames).flatMap { _ in [Float(0.01), 0.99].map(log) },
              sustain: (0..<frames).flatMap { _ in [Float(0.001), 0.993, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001].map(log) },
              silent: .init(repeating: false, count: frames), duration: Double(frames) * 0.02)
    }

    private func tokens(_ count: Int) -> [LyricsAICTC.Token] {
        (0..<count).map { .init(label: 1, sustainClass: 1, endsLine: $0 == count - 1, isStandaloneVowel: true) }
    }

    @Test func continuousRepeatedVowelsRecoverAnInternalBoundaryAndKeepTheirOuterAnchors() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0.1, end: 0.72), .init(start: 0.74, end: 0.76)]
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: tokens(2), onsets: [])
        #expect(refined[0].start == original[0].start)
        #expect(refined[1].end == original[1].end)
        #expect(abs(refined[1].start - 0.43) <= 0.011)
        #expect(refined[0].end == refined[1].start)
        #expect(refined.allSatisfy { $0.end - $0.start >= 0.3 })
    }

    @Test func clearRearticulationAllowsUnequalDurationsInsteadOfForcingAnEqualSplit() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.04, end: 0.8)]
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: tokens(2),
                                                       onsets: [.init(time: 0.2, strength: 1)])
        #expect(abs(refined[1].start - 0.2) <= 0.02)
        #expect(refined[1].end - refined[1].start > 2 * (refined[0].end - refined[0].start))
    }

    @Test func normalUnequalVowelsAndVeryShortGroupsKeepTheirAcousticTiming() throws {
        let normal: [LyricsAICTC.Span] = [.init(start: 0, end: 0.12), .init(start: 0.14, end: 0.8)]
        #expect(try LyricsAIRepeatedVowels.refine(normal, evidence: evidence(), tokens: tokens(2), onsets: []) == normal)
        let short: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.04, end: 0.1)]
        #expect(try LyricsAIRepeatedVowels.refine(short, evidence: evidence(), tokens: tokens(2), onsets: []) == short)
    }

    @Test func unavailableOnsetAudioFallsBackToDurationEvidence() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.04, end: 0.8)]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("missing-vocals-\(UUID()).caf")
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: tokens(2), vocals: file)
        #expect(abs(refined[1].start - 0.4) < 0.021)
    }

    @Test func realPausesLineBreaksAndConsonantsNeverBecomeContinuousVowelGroups() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.76)]
        var interrupted = evidence()
        for frame in 10..<14 { interrupted.silent[frame] = true }
        #expect(try LyricsAIRepeatedVowels.refine(original, evidence: interrupted, tokens: tokens(2), onsets: []) == original)
        var rest = evidence()
        for frame in 10..<14 {
            rest.logProbabilities[frame * 2 + 1] = log(0.01)
            rest.sustain[frame * 8] = log(0.99)
            rest.sustain[frame * 8 + 1] = log(0.01)
        }
        #expect(try LyricsAIRepeatedVowels.refine(original, evidence: rest, tokens: tokens(2), onsets: []) == original)
        var lineBreak = tokens(2)
        lineBreak[0].endsLine = true
        #expect(try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: lineBreak, onsets: []) == original)
        var consonants = tokens(2)
        for i in consonants.indices { consonants[i].isStandaloneVowel = false }
        #expect(try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: consonants, onsets: []) == original)
        let gap: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.12, end: 0.76)]
        #expect(try LyricsAIRepeatedVowels.refine(gap, evidence: evidence(), tokens: tokens(2), onsets: []) == gap)
    }

    @Test func threeRepeatedVowelsRetainTheirCountAndMonotonicIntervals() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.04, end: 0.06), .init(start: 0.08, end: 0.78)]
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: tokens(3), onsets: [])
        #expect(refined.count == 3)
        #expect(refined[0].start == 0)
        #expect(refined[2].end == 0.78)
        #expect(refined.allSatisfy { abs(($0.end - $0.start) - 0.26) < 0.021 })
        #expect(zip(refined, refined.dropFirst()).allSatisfy { $0.end == $1.start })
    }
}
