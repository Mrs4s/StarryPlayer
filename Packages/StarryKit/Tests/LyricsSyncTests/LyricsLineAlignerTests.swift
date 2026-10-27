import AudioProcessing
import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsLineAlignerTests {
    private func analysis(_ times: [Double], voiced: [ClosedRange<Double>] = []) -> VocalOnsetDetector.Analysis {
        var activity = VocalActivity(frameCount: 2_000)
        activity.energy = .init(repeating: -100, count: activity.frameCount)
        if !voiced.isEmpty {
            activity.valid = .init(repeating: true, count: activity.frameCount)
            for i in activity.energy.indices where voiced.contains(where: { $0.contains(Double(i) / 100) }) {
                activity.energy[i] = -15
            }
        }
        return VocalOnsetDetector.Analysis(onsets: times.map { VocalOnset(time: $0, strength: 0.9) },
                                          activity: activity, frameDuration: 0.01, centerOffset: 0)
    }

    private func line(_ text: String) -> LyricsDraft.Line {
        LyricsDraft.Line(syllables: LyricsDraftImport.syllables(in: text))
    }

    @Test func lrcLineUsesAttacksInsteadOfEqualDurations() throws {
        var line = line("我爱你")
        line.start = 2
        line.end = 5
        let result = try LyricsLineAligner.align(line, in: 2...5, analysis: analysis([2.05, 2.65, 3.9]))
        #expect(result.line.syllables.map(\.start) == [2.05, 2.65, 3.9])
        #expect(result.matchedCount == 3)
        #expect(result.line.start == nil && result.line.end == nil)
        #expect(result.line.syllables.map(\.id) == line.syllables.map(\.id))
    }

    @Test func extraAttacksCanBeSkippedAndAMissingAttackDoesNotShiftTheRest() throws {
        let result = try LyricsLineAligner.align(line("我爱这世界"), in: 1...6,
                                                 analysis: analysis([1, 1.12, 2, 4, 5]))
        #expect(result.line.syllables.map(\.start) == [1, 2, 3, 4, 5])
        #expect(result.matched == [true, true, false, true, true])
    }

    @Test func calibrationCanMoveBothEarlierAndLaterAndPreservesMetadataAndRuby() throws {
        var line = line("我爱你")
        for (i, time) in [2.2, 3.2, 4.2].enumerated() {
            line.syllables[i].start = time
            line.syllables[i].end = time + 0.8
        }
        line.syllables[1].ruby = [.init(text: "ai", span: 0.1...0.9)]
        line.translation = "I love you"
        line.track = UUID()
        let result = try LyricsLineAligner.align(line, in: 1.8...5.4, analysis: analysis([2.0, 3.35, 4.0]), mode: .calibrate)
        #expect(result.line.syllables.map(\.start) == [2.0, 3.35, 4.0])
        #expect(result.line.syllables[1].ruby == line.syllables[1].ruby)
        #expect(result.line.translation == line.translation && result.line.track == line.track)
    }

    @Test func calibrationKeepsAnUnmatchedStartAndIgnoresDistantAttacks() throws {
        var line = line("我爱你")
        for (i, time) in [2.0, 3.0, 4.0].enumerated() {
            line.syllables[i].start = time
            line.syllables[i].end = time + 0.8
        }
        let result = try LyricsLineAligner.align(line, in: 1...6, analysis: analysis([2.1, 3.6, 4.1]),
                                                 mode: .calibrate, maximumAdjustment: 0.2)
        #expect(result.line.syllables.map(\.start) == [2.1, 3, 4.1])
        #expect(result.matched == [true, false, true])
        #expect(abs(result.line.syllables[1].end! - 3.8) < 0.001)
    }

    @Test func manualRangeRejectsOutsideAttacksAndClipsEveryBoundary() throws {
        let result = try LyricsLineAligner.align(line("你好"), in: 2...4, analysis: analysis([1.9, 2.1, 3.1, 4.1]))
        #expect(result.line.syllables.map(\.start) == [2.1, 3.1])
        for syllable in result.line.syllables {
            #expect(syllable.start! >= 2 && syllable.end! <= 4)
            #expect(syllable.end! - syllable.start! >= 0.02 - 1e-9)
        }
    }

    @Test func vocalActivityKeepsPausesAndDoesNotFillTrailingInstrumentalSilence() throws {
        let result = try LyricsLineAligner.align(line("你好"), in: 1...8,
                                                 analysis: analysis([2, 4], voiced: [2...2.6, 4...4.7]))
        #expect(result.line.syllables.map(\.start) == [2, 4])
        #expect(abs(result.line.syllables[0].end! - 2.625) < 0.02)
        #expect(abs(result.line.syllables[1].end! - 4.725) < 0.02)
    }

    @Test func japaneseRubyWeightsAllowSeveralAttacksInsideOneKanjiBlock() throws {
        var line = line("君は")
        line.syllables[0].ruby = [.init(text: "きみ")]
        let result = try LyricsLineAligner.align(line, in: 1...4, analysis: analysis([1, 2, 3]), language: .japanese)
        #expect(result.line.syllables.map(\.start) == [1, 3])
        #expect(result.matchedCount == 2)
        #expect(LyricsTimingWeights.weights(for: line, language: .japanese) == [2, 1])
    }

    @Test func calibrationKeepsThePhraseOpeningInsteadOfTheLaterMoraOfSora() throws {
        var line = line("空に")
        line.syllables[0].ruby = [.init(text: "そら")]
        line.syllables[0].start = 2.28
        line.syllables[0].end = 2.9
        line.syllables[1].start = 2.9
        line.syllables[1].end = 3.5
        var evidence = analysis([2, 2.27, 2.9], voiced: [2...3.5])
        evidence.onsets[0].strength = 0.65
        evidence.onsets[1].strength = 0.99
        let result = try LyricsLineAligner.align(line, in: 1.93...3.85, analysis: evidence,
                                                 mode: .calibrate, language: .japanese)
        #expect(result.line.syllables[0].start == 2)
        #expect(result.line.syllables[1].start == 2.9)
    }

    @Test func calibrationDoesNotTreatAnEarlierAttackInContinuousSingingAsALineOpening() throws {
        var line = line("空に")
        line.syllables[0].start = 2.28
        line.syllables[0].end = 2.9
        line.syllables[1].start = 2.9
        line.syllables[1].end = 3.5
        let result = try LyricsLineAligner.align(line, in: 1.93...3.85,
                                                 analysis: analysis([2, 2.27, 2.9], voiced: [1.6...3.5]), mode: .calibrate)
        #expect(result.line.syllables[0].start == 2.27)
    }

    @Test func calibrationDoesNotExtendTheLastBlockToThePaddedSearchBoundary() throws {
        var line = line("你好")
        line.syllables[0].start = 2
        line.syllables[0].end = 3
        line.syllables[1].start = 3
        line.syllables[1].end = 3.7
        let result = try LyricsLineAligner.align(line, in: 1.65...4.05, analysis: analysis([2, 3]), mode: .calibrate)
        #expect(result.line.syllables[1].end == 3.7)
    }

    @Test func calibrationEndsBeforeTheNextPhraseInsideTheSearchPadding() throws {
        var line = line("你好")
        line.syllables[0].start = 2
        line.syllables[0].end = 3
        line.syllables[1].start = 3
        line.syllables[1].end = 3.6
        let result = try LyricsLineAligner.align(line, in: 1.65...3.95,
                                                 analysis: analysis([2, 3, 3.8], voiced: [2...3.55, 3.8...4.2]), mode: .calibrate)
        #expect(abs(result.line.syllables[1].end! - 3.575) < 0.02)
    }

    @Test func arrangingDoesNotAttachTheFollowingPhraseToTheLastBlock() throws {
        let result = try LyricsLineAligner.align(line("你好"), in: 1.8...5,
                                                 analysis: analysis([2, 3, 4.4], voiced: [2...2.6, 3...3.6, 4.4...4.8]))
        #expect(result.line.syllables.map(\.start) == [2, 3])
        #expect(abs(result.line.syllables[1].end! - 3.625) < 0.02)
    }

    @Test func aShortGapInsideTheFinalJapaneseBlockDoesNotCutOffItsLaterMora() throws {
        var line = line("は|今日")
        line.syllables[1].ruby = [.init(text: "きょう")]
        let result = try LyricsLineAligner.align(line, in: 1.8...5,
                                                 analysis: analysis([2, 2.8, 3.21, 4.2], voiced: [2...2.3, 2.8...3.1, 3.21...3.7, 4.2...4.5]),
                                                 language: .japanese)
        #expect(result.line.syllables.map(\.start) == [2, 2.8])
        #expect(abs(result.line.syllables[1].end! - 3.725) < 0.02)
    }

    @Test(arguments: [LyricsLineAligner.Mode.arrange, .calibrate])
    func aRealHeldNoteIsNotShortenedToAnAverageMoraDuration(mode: LyricsLineAligner.Mode) throws {
        var line = line("空")
        line.syllables[0].ruby = [.init(text: "そら")]
        line.syllables[0].start = 2
        line.syllables[0].end = 6
        let result = try LyricsLineAligner.align(line, in: 1.65...6.35,
                                                 analysis: analysis([2, 3, 4, 5], voiced: [2...5.95]), mode: mode, language: .japanese)
        #expect(result.line.syllables[0].start == 2)
        #expect(result.line.syllables[0].end! > 5.9)
    }

    @Test func invalidOrSilentInputsDoNotProduceAnApparentlyAlignedLine() throws {
        #expect(throws: LyricsLineAligner.Failure.self) {
            try LyricsLineAligner.align(line("你好"), in: 1...1.01, analysis: analysis([1]))
        }
        #expect(throws: LyricsLineAligner.Failure.self) {
            try LyricsLineAligner.align(line("你好"), in: 1...4, analysis: analysis([]))
        }
        var evidence = analysis([2])
        evidence.onsets = [VocalOnset(time: .nan, strength: 1), VocalOnset(time: 2, strength: .nan)]
        #expect(throws: LyricsLineAligner.Failure.self) {
            try LyricsLineAligner.align(line("你好"), in: 1...4, analysis: evidence)
        }
    }

    @Test func continuousRepeatedVowelsWithoutAttacksCanBePreviewedAsEstimates() throws {
        let result = try LyricsLineAligner.align(line("ああああ"), in: 1...2, analysis: analysis([], voiced: [1...2]))
        #expect(result.matchedCount == 0)
        #expect(result.estimatedCount == 4)
        for index in result.line.syllables.indices {
            let syllable = result.line.syllables[index]
            #expect(syllable.start! >= 1 && syllable.end! <= 2)
            #expect(syllable.end! - syllable.start! >= 0.02 - 1e-9)
            if index > 0 { #expect(syllable.start! >= result.line.syllables[index - 1].end!) }
        }
    }

    @Test func aShortVoicedLineIsNotRejectedWhenItsOnlyAttackBelongsToTheRelease() throws {
        let result = try LyricsLineAligner.align(line("僕は"), in: 1...1.65, analysis: analysis([1.6], voiced: [1...1.5]), language: .japanese)
        #expect(result.line.syllables.count == 2)
        #expect(result.estimatedCount > 0)
        #expect(result.line.syllables.allSatisfy { $0.start != nil && $0.end != nil })
    }
}
