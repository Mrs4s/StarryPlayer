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

    @Test func continuousRepeatedVowelsShareTimeAndKeepTheirOuterAnchors() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0.1, end: 0.72), .init(start: 0.74, end: 0.76)]
        let result = try LyricsAIRepeatedVowels.refinement(original, evidence: evidence(), tokens: tokens(2), onsets: [])
        let refined = result.spans
        #expect(result.sharedSounds == [0..<2])
        #expect(refined[0].start == original[0].start)
        #expect(refined[1].end == original[1].end)
        #expect(abs(refined[1].start - 0.43) < 1e-9)
        #expect(refined[0].end == refined[1].start)
    }

    @Test func independentAttacksAllowUnequalDurations() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.04, end: 0.8)]
        let result = try LyricsAIRepeatedVowels.refinement(original, evidence: evidence(), tokens: tokens(2),
                                                          onsets: [.init(time: 0.08, strength: 1)])
        let refined = result.spans
        #expect(result.sharedSounds.isEmpty)
        #expect(abs(refined[1].start - 0.08) <= 0.02 + 1e-9)
        #expect(refined[1].end - refined[1].start > 2 * (refined[0].end - refined[0].start))
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
        let short: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.04, end: 0.1)]
        #expect(try LyricsAIRepeatedVowels.refine(short, evidence: evidence(), tokens: tokens(2), onsets: []) == short)
    }

    @Test func blankExtensionDoesNotHideACollapsedRepeat() throws {
        let filled: [LyricsAICTC.Span] = [.init(start: 0, end: 1.18), .init(start: 1.2, end: 1.3)]
        let raw: [LyricsAICTC.Span] = [.init(start: 0.02, end: 1.18), .init(start: 1.2, end: 1.22)]
        var consonants = tokens(2)
        for index in consonants.indices { consonants[index].isStandaloneVowel = false }
        let refined = try LyricsAIRepeatedVowels.refine(filled, evidence: evidence(frames: 70), tokens: consonants,
                                                       rawSpans: raw, onsets: [.init(time: 0.52, strength: 1)])
        #expect(abs(refined[1].start - 0.52) <= 0.02)
        #expect(refined[0].start == 0)
        #expect(refined[1].end == 1.3)
        #expect(refined[0].end == refined[1].start)
    }

    @Test func repeatedConsonantKanaRequiresAnIndependentInteriorAttack() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.76)]
        var consonants = tokens(2)
        for index in consonants.indices { consonants[index].isStandaloneVowel = false }
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: consonants,
                                                       onsets: [.init(time: 0.28, strength: 1)])
        #expect(abs(refined[1].start - 0.28) <= 0.02)
        let weak = try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: consonants,
                                                    onsets: [.init(time: 0.28, strength: 0.2)])
        #expect(weak == original)
        let edges = try LyricsAIRepeatedVowels.refine(original, evidence: evidence(), tokens: consonants,
                                                     onsets: [.init(time: 0.01, strength: 1), .init(time: 0.75, strength: 1)])
        #expect(edges == original)
    }

    @Test func supportedUnequalDurationsSurviveEvenWithVeryStrongAlternativeOnsets() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.12), .init(start: 0.14, end: 0.8)]
        var heard = evidence()
        heard.logProbabilities[6 * 2] = log(0.99)
        heard.logProbabilities[6 * 2 + 1] = log(0.01)
        heard.sustain[6 * 8] = log(0.99)
        heard.sustain[6 * 8 + 1] = log(0.01)
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: heard, tokens: tokens(2),
                                                       rawSpans: original, onsets: [.init(time: 0.4, strength: 1)])
        #expect(refined == original)
    }

    private func heldEvidence(sound: Int) -> LyricsAICTC.Evidence {
        .init(frames: 40, width: 3, blank: 0,
              logProbabilities: (0..<40).flatMap { _ in [Float(0.01), 0.98, 0.01].map(log) },
              sustain: (0..<40).flatMap { _ -> [Float] in
                  var row = [Float](repeating: 0.001, count: 8)
                  row[sound] = 0.993
                  return row.map(log)
              }, silent: .init(repeating: false, count: 40), duration: 0.8)
    }

    @Test(arguments: [(5, 3), (4, 2), (5, 5)])
    func vowelContinuationsShareTimeOnlyWhenTheAudioKeepsTheSameSound(classes: (Int, Int)) throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.8)]
        let sequence: [LyricsAICTC.Token] = [.init(label: 1, sustainClass: classes.0),
            .init(label: 2, sustainClass: classes.1, endsLine: true, isStandaloneVowel: true)]
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: heldEvidence(sound: classes.0), tokens: sequence, onsets: [])
        #expect(refined == [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)])
        if classes.0 != classes.1 {
            var changed = heldEvidence(sound: classes.0)
            for frame in 20..<40 {
                changed.sustain[frame * 8 + classes.0] = log(0.001)
                changed.sustain[frame * 8 + classes.1] = log(0.993)
            }
            #expect(try LyricsAIRepeatedVowels.refine(original, evidence: changed, tokens: sequence, onsets: []) == original)
        }
    }

    @Test func twoDifferentConsonantsNeverMergeJustBecauseTheirVowelsMatch() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.8)]
        let sequence: [LyricsAICTC.Token] = [.init(label: 1, sustainClass: 1), .init(label: 2, sustainClass: 1, endsLine: true)]
        #expect(try LyricsAIRepeatedVowels.refine(original, evidence: heldEvidence(sound: 1), tokens: sequence, onsets: []) == original)
    }

    @Test func aSmallKanaStaysInsideItsMoraWhenTheFollowingVowelSharesTheHold() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.1), .init(start: 0.1, end: 0.72), .init(start: 0.74, end: 0.8)]
        let sequence: [LyricsAICTC.Token] = [.init(label: 1, sustainClass: 1),
            .init(label: 2, sustainClass: 1, isMoraContinuation: true),
            .init(label: 2, sustainClass: 1, endsLine: true, isStandaloneVowel: true)]
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: heldEvidence(sound: 1), tokens: sequence, onsets: [])
        #expect(abs(refined[1].end - 0.4) < 1e-9)
        #expect(refined[2].start == refined[1].end)
        #expect(abs(refined[0].end / refined[1].end - 0.1 / 0.72) < 1e-9)
    }

    @Test func longMarksAndRepeatedNasalsCanShareOneSustainedSound() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.8)]
        let mark: [LyricsAICTC.Token] = [.init(label: 1, sustainClass: 5),
            .init(label: 2, sustainClass: 5, endsLine: true, isLongMark: true)]
        let nasal: [LyricsAICTC.Token] = [.init(label: 1, sustainClass: 6), .init(label: 1, sustainClass: 6, endsLine: true)]
        let expected: [LyricsAICTC.Span] = [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)]
        #expect(try LyricsAIRepeatedVowels.refine(original, evidence: heldEvidence(sound: 5), tokens: mark, onsets: []) == expected)
        #expect(try LyricsAIRepeatedVowels.refine(original, evidence: heldEvidence(sound: 6), tokens: nasal, onsets: []) == expected)
    }

    @Test func aTrueRearticulationSeparatesTwoContinuousGroups() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.02), .init(start: 0.04, end: 0.44), .init(start: 0.46, end: 0.8)]
        var heard = evidence()
        heard.logProbabilities[22 * 2] = log(0.99)
        heard.logProbabilities[22 * 2 + 1] = log(0.01)
        heard.sustain[22 * 8] = log(0.99)
        heard.sustain[22 * 8 + 1] = log(0.01)
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: heard, tokens: tokens(3), rawSpans: original, onsets: [])
        #expect(abs(refined[0].end - 0.22) < 1e-9)
        #expect(refined[1].end == 0.44)
        #expect(refined[2] == original[2])
    }

    @Test func rearticulationIsPreservedAfterAConsonantPrefixedContinuation() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.2), .init(start: 0.2, end: 0.44), .init(start: 0.46, end: 0.8)]
        let sequence: [LyricsAICTC.Token] = [.init(label: 1, sustainClass: 1),
            .init(label: 2, sustainClass: 1, isStandaloneVowel: true),
            .init(label: 2, sustainClass: 1, endsLine: true, isStandaloneVowel: true)]
        var heard = heldEvidence(sound: 1)
        for frame in 10..<40 {
            heard.logProbabilities[frame * 3 + 1] = log(0.01)
            heard.logProbabilities[frame * 3 + 2] = log(0.98)
        }
        heard.logProbabilities[22 * 3] = log(0.98)
        heard.logProbabilities[22 * 3 + 2] = log(0.01)
        heard.sustain[22 * 8] = log(0.99)
        heard.sustain[22 * 8 + 1] = log(0.01)
        let refined = try LyricsAIRepeatedVowels.refine(original, evidence: heard, tokens: sequence, rawSpans: original, onsets: [])
        #expect(abs(refined[0].end - 0.22) < 1e-9)
        #expect(refined[1].end == 0.44)
        #expect(refined[2] == original[2])
    }

    @Test func longVowelRunsShareTimeAsOneGroup() throws {
        var original = (0..<8).map { LyricsAICTC.Span(start: Double($0) * 0.02, end: Double($0 + 1) * 0.02) }
        original.append(.init(start: 0.16, end: 0.8))
        let result = try LyricsAIRepeatedVowels.refinement(original, evidence: evidence(), tokens: tokens(9), onsets: [])
        let refined = result.spans
        #expect(result.sharedSounds == [0..<9])
        #expect(refined[0].start == 0)
        #expect(refined[8].end == 0.8)
        #expect(refined.allSatisfy { abs(($0.end - $0.start) - 0.8 / 9) < 1e-9 })
        #expect(zip(refined, refined.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func alreadyMergedBlocksKeepTheirInternalAcousticAndEnglishSyllableTiming() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.72), .init(start: 0.74, end: 0.8)]
        let merged = try LyricsAIRepeatedVowels.refinement(original, evidence: evidence(), tokens: tokens(2),
                                                          displayBoundaries: [0], onsets: [])
        #expect(merged.spans == original)
        #expect(merged.sharedSounds.isEmpty)
        let split = try LyricsAIRepeatedVowels.refinement(original, evidence: evidence(), tokens: tokens(2),
                                                         displayBoundaries: [0, 1], onsets: [])
        #expect(split.spans == [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)])
    }

    @Test func twoStrongCTCPiecesAndTheirBlankDoNotOverrideAnUnbrokenSustainedVowel() throws {
        let original: [LyricsAICTC.Span] = [.init(start: 0, end: 0.12), .init(start: 0.14, end: 0.8)]
        var held = evidence()
        held.logProbabilities[6 * 2] = log(0.99)
        held.logProbabilities[6 * 2 + 1] = log(0.01)
        let result = try LyricsAIRepeatedVowels.refinement(original, evidence: held, tokens: tokens(2), rawSpans: original, onsets: [])
        #expect(result.spans == [.init(start: 0, end: 0.4), .init(start: 0.4, end: 0.8)])
        #expect(result.sharedSounds == [0..<2])
    }
}
