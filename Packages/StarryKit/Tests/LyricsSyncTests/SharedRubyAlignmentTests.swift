import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct SharedRubyAlignmentTests {
    private let alphabet = Array("あいうえおかきくけこがぎぐげござじずぜぞさしすせそたちつてとだぢづでどなにぬねのはひふへほばびぶべぼぱぴぷぺぽまみむめもやゆよらりるれろわをんっゃゅょぃー")
    private let english = ["destiny": "デスティニー"]

    private var vocabulary: [String: Int] {
        Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { (String($0.element), $0.offset) })
    }

    private func draft(_ texts: [String], sharing ruby: [String], over run: ClosedRange<Int>) -> LyricsDraft {
        var draft = LyricsDraft(lines: [.init(syllables: texts.map { .init(text: $0) })])
        draft.setGroupRuby(ruby.joined(separator: "|"), over: run.map { .init(line: 0, syllable: $0) })
        return draft
    }

    private func text(_ plan: LyricsAIPronunciation, _ tokens: Range<Int>) -> String {
        let inverse = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })
        return tokens.map { inverse[plan.tokens[$0].label] ?? "?" }.joined()
    }

    private func spans(_ durations: [Double], start: Double = 1) -> [LyricsAICTC.Span] {
        var time = start
        return durations.map { duration in
            defer { time += duration }
            return .init(start: time, end: time + duration)
        }
    }

    @Test func kanjiSungAsAnEnglishWordAreReadAsThatWord() throws {
        let draft = draft(["運", "命", "を"], sharing: ["destiny"], over: 0...1)
        let plan = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: english)
        #expect(text(plan, 0..<plan.tokens.count) == "ですてぃにーお")
        let units = plan.units
        #expect(units[0].tokens.lowerBound == 0 && units[0].tokens.upperBound == units[1].tokens.lowerBound && units[1].tokens.upperBound == 6)
        #expect(units[0].groupRuby == [0..<6] && units[1].groupRuby.isEmpty)
        #expect(units[0].approximate && units[1].approximate && !units[2].approximate)
        #expect(!plan.words.contains { $0.text.contains("運") })
    }

    @Test(arguments: ["スポットライト", "ｽﾎﾟｯﾄﾗｲﾄ"], [false, true])
    func englishRubyOnKatakanaUsesTheWrittenJapaneseSounds(surface: String, hasDictionary: Bool) throws {
        let dictionary = hasDictionary ? ["spot": "スパット", "light": "ライト"] : [:]
        let original = LyricsDraft(lines: [.init(syllables: [
            .init(text: "「\(surface)！」", ruby: [.init(text: "spot", span: 0...0.4), .init(text: "light", span: 0.4...1)])
        ])])
        let plan = try LyricsAIPronunciation.make(draft: original, vocabulary: vocabulary, english: dictionary)
        #expect(text(plan, 0..<plan.tokens.count) == "すぽっとらいと")
        #expect(plan.estimatedCount == 0)
        #expect(plan.units.allSatisfy { $0.ruby.isEmpty && $0.groupRuby.isEmpty && $0.english.isEmpty })

        let result = try LyricsAIAligner.apply(spans(Array(repeating: 0.1, count: plan.tokens.count)), plan: plan, to: original)
        let syllable = result.draft.lines[0].syllables[0]
        #expect(syllable.ruby == original.lines[0].syllables[0].ruby)
        #expect(syllable.id == original.lines[0].syllables[0].id)
        #expect(syllable.text == original.lines[0].syllables[0].text)
        #expect(syllable.start == 1 && abs(syllable.end! - 1.7) < 1e-9)
        #expect(result.reviewIssues.isEmpty)
    }

    @Test(arguments: [["spotlight"], ["spot", "light"], ["ＳＰＯＴ", "ＬＩＧＨＴ"]], [false, true])
    func sharedEnglishRubyOnKatakanaDoesNotChangeReadingsOrBoundaries(ruby: [String], hasDictionary: Bool) throws {
        let dictionary = hasDictionary ? ["spotlight": "スパットライト", "spot": "スパット", "light": "ライト"] : [:]
        var original = draft(["スポット", "ライト", "を", "愛"], sharing: ruby, over: 0...1)
        original.lines[0].syllables[3].ruby = [.init(text: "あ"), .init(text: "い")]
        let plan = try LyricsAIPronunciation.make(draft: original, vocabulary: vocabulary, english: dictionary)
        #expect(plan.units.map { text(plan, $0.tokens) } == ["すぽっと", "らいと", "お", "あい"])
        #expect(plan.units.prefix(2).allSatisfy { $0.ruby.isEmpty && $0.groupRuby.isEmpty && !$0.approximate })
        #expect(plan.units[3].ruby == [8..<9, 9..<10])

        let result = try LyricsAIAligner.apply(spans(Array(repeating: 0.1, count: plan.tokens.count)), plan: plan, to: original)
        let syllables = result.draft.lines[0].syllables
        #expect(syllables[0].groupRuby == original.lines[0].syllables[0].groupRuby)
        #expect(syllables.map(\.joinsRubyGroup) == [false, true, false, false])
        #expect(syllables.map(\.id) == original.lines[0].syllables.map(\.id))
        #expect(syllables.map(\.text) == original.lines[0].syllables.map(\.text))
        #expect(abs(syllables[0].end! - 1.4) < 1e-9 && syllables[0].end == syllables[1].start)
        #expect(abs(syllables[1].end! - 1.7) < 1e-9)
        #expect(syllables[3].ruby?.map(\.text) == ["あ", "い"])
        #expect(syllables[3].ruby?.allSatisfy { $0.span != nil } == true)
        #expect(result.reviewIssues.isEmpty)
    }

    @Test func kanaRubyOnKatakanaStillOverridesItsWrittenPronunciation() throws {
        let original = LyricsDraft(lines: [.init(syllables: [
            .init(text: "スポットライト", ruby: [.init(text: "すぱっとらいと")])
        ])])
        let plan = try LyricsAIPronunciation.make(draft: original, vocabulary: vocabulary, english: [:])
        #expect(text(plan, 0..<plan.tokens.count) == "すぱっとらいと")
        #expect(plan.units[0].ruby == [0..<7])

        let shared = draft(["スポット", "ライト"], sharing: ["すぱっと", "らいと"], over: 0...1)
        let sharedPlan = try LyricsAIPronunciation.make(draft: shared, vocabulary: vocabulary, english: [:])
        #expect(sharedPlan.units.map { text(sharedPlan, $0.tokens) } == ["すぱっと", "らいと"])
        #expect(sharedPlan.units[0].groupRuby == [0..<4, 4..<7])
    }

    @Test func piecesMatchingTheSyllablesTimeTheRunPieceByPiece() throws {
        let draft = draft(["Christ", "mas"], sharing: ["クリス", "マス"], over: 0...1)
        let plan = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: [:])
        #expect(plan.units.map { text(plan, $0.tokens) } == ["くりす", "ます"])
        #expect(plan.units.allSatisfy { !$0.approximate && $0.english.isEmpty })
        #expect(plan.units[0].groupRuby == [0..<3, 3..<5])
        let result = try LyricsAIAligner.apply(spans([0.1, 0.1, 0.2, 0.2, 0.4]), plan: plan, to: draft)
        let syllables = result.draft.lines[0].syllables
        #expect(syllables.map(\.text) == ["Christ", "mas"])
        #expect(syllables[0].start == 1 && abs(syllables[0].end! - 1.4) < 1e-9 && abs(syllables[1].end! - 2) < 1e-9)
        let ruby = try #require(syllables[0].groupRuby)
        #expect(ruby.map(\.text) == ["クリス", "マス"])
        #expect(abs(ruby[0].span!.upperBound - 0.4) < 1e-9 && abs(ruby[1].span!.lowerBound - 0.4) < 1e-9 && ruby[1].span!.upperBound == 1)
        #expect(result.reviewIssues.isEmpty)
        let shared = result.draft.document().lines[0].syllables[0].groupRuby
        #expect(abs(shared[0].end - 1.4) < 1e-9 && abs(shared[1].start - 1.4) < 1e-9)
    }

    @Test func aPieceThatCannotBeReadIsAnUnknownSoundRatherThanAnError() throws {
        let draft = draft(["運", "命", "を"], sharing: ["Ω"], over: 0...1)
        let plan = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: english)
        #expect(plan.tokens.first?.label == 122)
        #expect(plan.units[0].approximate && plan.units[1].approximate)
        #expect(text(plan, plan.units[2].tokens) == "お")
    }
}
