import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsAIEnglishSyllablesTests {
    @Test(arguments: ["ne|ver", "beau|ti|ful", "wan|ted", "Re-|en|ter", "CA|FÉ", "Ｎｅ|ｖｅｒ", "zor|bi|na|ting"])
    func spellingAndBundledSingingCutsKeepTheOriginalCharacters(pattern: String) {
        let word = pattern.replacingOccurrences(of: "|", with: "")
        let chars = Array(word), edges = [0] + LyricsAIEnglishSyllables.cuts(word) + [chars.count]
        let pieces = zip(edges, edges.dropFirst()).map { String(chars[$0..<$1]) }
        #expect(pieces.joined(separator: "|") == pattern)
    }

    @Test(arguments: ["like", "rhythm", "don’t", "rock’n’roll"])
    func singleSyllablesAndContractionsStayWhole(word: String) {
        #expect(LyricsAIEnglishSyllables.cuts(word).isEmpty)
    }

    @Test(arguments: [
        ["dreaming", "どりーみんぐ", "drea=どりー|ming=みんぐ"],
        ["going", "ごーいんぐ", "go=ごー|ing=いんぐ"],
        ["beautiful", "びゅーてぃふる", "beau=びゅー|ti=てぃ|ful=ふる"],
        ["reflection", "りふれくしょん", "re=り|flec=ふれく|tion=しょん"],
        ["happy", "はっぴー", "ha=はっ|ppy=ぴー"],
        ["silhouettes", "しるえっつ", "sil=しる|houettes=えっつ"]
    ])
    func syllablesOwnTheirOnsetMoraeRatherThanEqualShares(example: [String]) {
        let reading = Array(example[1])
        let pieces = LyricsAIEnglishSyllables.pieces(text: example[0], wordRange: NSRange(location: 0, length: example[0].utf16.count), reading: reading)
        #expect(pieces.map { $0.text + "=" + String(reading[$0.tokens]) }.joined(separator: "|") == example[2])
    }

    @Test func fewerMoraeThanSyllablesNeverProduceEmptyPieces() {
        let pieces = LyricsAIEnglishSyllables.pieces(text: "everybody", wordRange: NSRange(location: 0, length: 9), reading: Array("えぶ"))
        #expect(pieces.map(\.text) == ["e", "verybody"])
        #expect(pieces.map(\.tokens) == [0..<1, 1..<2])
    }

    private func plan(_ draft: LyricsDraft, dictionary: [String: String]) throws -> LyricsAIPronunciation {
        let kana = Array(Set("あい" + dictionary.values.joined()))
        let vocabulary = Dictionary(uniqueKeysWithValues: kana.enumerated().map { (String($0.element), $0.offset + 1) })
        return try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: dictionary)
    }

    private func spans(_ durations: [Double], start: Double = 1) -> [LyricsAICTC.Span] {
        var time = start
        return durations.map { duration in
            defer { time += duration }
            return .init(start: time, end: time + duration)
        }
    }

    @Test func alignmentSplitsWordsUsingTokenTimesAndPreservesTextMetadataAndPerformers() throws {
        let original = LyricsDraft(lines: [
            .init(syllables: [.init(text: "あ"), .init(text: "👩‍🚀“Beautiful!”  ", agentIDs: ["singer"])],
                  translation: "美丽", romanization: "a beautiful", isParagraphStart: true),
            .init(syllables: [.init(text: "beautiful", start: 8, end: 9)], isBackground: true)
        ], metadata: ["title": "fixture"])
        let plan = try plan(original, dictionary: ["beautiful": "びゅーてぃふる"])
        let issue = LyricsAIReviewIssue(syllableIDs: [original.lines[0].syllables[1].id], kind: .uncertainTiming, message: "声学证据偏弱")
        let result = try LyricsAIAligner.apply(spans([0.2, 0.1, 0.1, 0.25, 0.1, 0.1, 0.2, 0.35]), plan: plan, to: original, reviewIssues: [issue])
        let line = result.draft.lines[0]
        #expect(line.syllables.map(\.text) == ["あ", "👩‍🚀“Beau", "ti", "ful!”  "])
        #expect(line.syllables.compactMap(\.start).map { Int(($0 * 1000).rounded()) } == [1000, 1200, 1650, 1850])
        #expect(abs(line.syllables.last!.end! - 2.4) < 1e-9)
        #expect(line.text == original.lines[0].text)
        #expect(line.id == original.lines[0].id)
        #expect(line.syllables[1].id == original.lines[0].syllables[1].id)
        #expect(Set(line.syllables.map(\.id)).count == line.syllables.count)
        #expect(line.syllables.dropFirst().allSatisfy { $0.agentIDs == ["singer"] })
        #expect(line.translation == "美丽" && line.romanization == "a beautiful" && line.isParagraphStart)
        #expect(result.draft.lines[1] == original.lines[1])
        #expect(result.draft.metadata == original.metadata)
        #expect(result.alignedSyllables == 4 && result.skippedBackgroundLines == 1)
        #expect(result.reviewIssues.first?.syllableIDs == line.syllables.dropFirst().map(\.id))
        let roundTrip = try TTMLParser.parse(TTMLWriter.write(result.draft.document()))
        #expect(roundTrip.lines[0].syllables.map(\.text) == line.syllables.map { $0.text.trimmingCharacters(in: .whitespaces) })
        #expect(roundTrip.lines[0].syllables.map(\.start).map { Int(($0 * 1000).rounded()) } == [1000, 1200, 1650, 1850])
    }

    @Test func modesMergeOnlyShortAutomaticPiecesAndWordModeRetainsTheSourceBlock() throws {
        let original = LyricsDraft(lines: [.init(syllables: [.init(text: "dreaming")])])
        let plan = try plan(original, dictionary: ["dreaming": "どりーみんぐ"])
        let timing = spans([0.1, 0.1, 0.1, 0.02, 0.02, 0.02])
        let automatic = try LyricsAIAligner.apply(timing, plan: plan, to: original)
        let split = try LyricsAIAligner.apply(timing, plan: plan, to: original, englishSplit: .syllable)
        let word = try LyricsAIAligner.apply(timing, plan: plan, to: original, englishSplit: .word)
        #expect(automatic.draft.lines[0].syllables.map(\.text) == ["dreaming"])
        #expect(split.draft.lines[0].syllables.map(\.text) == ["drea", "ming"])
        #expect(word.draft.lines[0].syllables.map(\.id) == original.lines[0].syllables.map(\.id))
        #expect(word.draft.lines[0].syllables.map(\.text) == ["dreaming"])
        #expect(split.alignedSyllables == 2 && automatic.alignedSyllables == 1 && word.alignedSyllables == 1)
        let shortFirst = try LyricsAIAligner.apply(spans([0.02, 0.02, 0.02, 0.2, 0.2, 0.2]), plan: plan, to: original)
        #expect(shortFirst.draft.lines[0].syllables.count == 1)
        let zero = try LyricsAIAligner.apply(spans([0, 0, 0, 0.2, 0.2, 0.2]), plan: plan, to: original, englishSplit: .syllable)
        #expect(zero.draft.lines[0].syllables.map(\.text) == ["dreaming"])
    }

    @Test(arguments: [LyricsAIEnglishSplit.automatic, .syllable])
    func heldLongMarkHandsItsNoteToTheFollowingSyllable(mode: LyricsAIEnglishSplit) throws {
        let original = LyricsDraft(lines: [.init(syllables: [.init(text: "dreaming")])])
        let plan = try plan(original, dictionary: ["dreaming": "どりーみんぐ"])
        let timing = spans([0.07, 0.2, 2.96, 0.02, 0.02, 0.02], start: 74.83)
        let result = try LyricsAIAligner.apply(timing, plan: plan, to: original, englishSplit: mode)
        let pieces = result.draft.lines[0].syllables
        #expect(pieces.map(\.text) == ["drea", "ming"])
        #expect(abs(pieces[0].end! - 75.1) < 1e-9 && pieces[0].end == pieces[1].start)
        #expect(abs(pieces[1].end! - 78.12) < 1e-9)
    }

    @Test func manualAndImportedCutsKeepTheirStructureAndGetOnsetBasedReadings() throws {
        let original = LyricsDraft(lines: [.init(syllables: [.init(text: "re"), .init(text: "flec"), .init(text: "tion")])])
        let plan = try plan(original, dictionary: ["reflection": "りふれくしょん"])
        #expect(plan.units.map(\.tokens) == [0..<1, 1..<4, 4..<7])
        let result = try LyricsAIAligner.apply(spans(Array(repeating: 0.1, count: 7)), plan: plan, to: original)
        #expect(result.draft.lines[0].syllables.map(\.id) == original.lines[0].syllables.map(\.id))
        #expect(result.draft.lines[0].syllables.map(\.text) == ["re", "flec", "tion"])
    }

    @Test func annotationsRhythmAndCoarseMultipleWordBlocksAreNotResplit() throws {
        let original = LyricsDraft(lines: [.init(syllables: [
            .init(text: "beautiful ", ruby: [.init(text: "びゅーてぃふる")]),
            .init(text: "beautiful ", checkpoints: [0, nil]),
            .init(text: "beautiful ", hasRelease: true),
            .init(text: "beautiful beautiful")
        ])])
        let plan = try plan(original, dictionary: ["beautiful": "びゅーてぃふる"])
        let result = try LyricsAIAligner.apply(spans(Array(repeating: 0.1, count: plan.tokens.count)), plan: plan, to: original)
        #expect(result.draft.lines[0].syllables.map(\.id) == original.lines[0].syllables.map(\.id))
        #expect(result.draft.lines[0].syllables[1].checkpoints == [0, nil])
        #expect(result.draft.lines[0].syllables[2].hasRelease)
    }

    @Test func structuralPunctuationKeepsItsReservedIntervalAfterSplitting() throws {
        let original = LyricsDraft(lines: [.init(syllables: [.init(text: "dreaming"), .init(text: "！")])])
        let plan = try plan(original, dictionary: ["dreaming": "どりーみんぐ"])
        let result = try LyricsAIAligner.apply(spans(Array(repeating: 0.1, count: plan.tokens.count)), plan: plan, to: original)
        let pieces = result.draft.lines[0].syllables
        #expect(pieces.map(\.text) == ["drea", "ming", "！"])
        #expect(pieces[1].end == pieces[2].start)
        #expect(pieces.allSatisfy { $0.end! > $0.start! })
    }

    @Test func restBlocksKeepTheirOffsetsAndTheFollowingEnglishWordCanStillSplit() throws {
        let original = LyricsDraft(lines: [.init(syllables: [.init(text: "▨", isRest: true), .init(text: "dreaming")])])
        let plan = try plan(original, dictionary: ["dreaming": "どりーみんぐ"])
        let result = try LyricsAIAligner.apply(spans(Array(repeating: 0.1, count: plan.tokens.count)), plan: plan, to: original)
        #expect(result.draft.lines[0].syllables.map(\.text) == ["▨", "drea", "ming"])
        #expect(result.draft.lines[0].syllables[0].isRest)
    }
}
