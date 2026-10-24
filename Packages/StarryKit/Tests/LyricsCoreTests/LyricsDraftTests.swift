import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricsDraftImportTests {
    private func texts(_ line: String) -> [String] {
        LyricsDraftImport.syllables(in: line).map(\.text)
    }

    @Test func chineseAndJapaneseSplitByCharacterAndOtherScriptsByWord() {
        #expect(texts("我爱你") == ["我", "爱", "你"])
        #expect(texts("Hello world") == ["Hello ", "world"])
        #expect(texts("2024年 love") == ["2024", "年 ", "love"])
        #expect(texts("사랑해") == ["사", "랑", "해"])
    }

    @Test func smallKanaAndLongVowelsStayWithTheSyllableBefore() {
        #expect(texts("きゃっと") == ["きゃっ", "と"])
        #expect(texts("ラーメン") == ["ラー", "メ", "ン"])
    }

    @Test func punctuationJoinsTheSyllableBeforeAndBracketsTheOneAfter() {
        #expect(texts("你好，世界！") == ["你", "好，", "世", "界！"])
        #expect(texts("(ooh) yeah, don't") == ["(ooh) ", "yeah, ", "don't"])
        #expect(texts("「君の名は」") == ["「君", "の", "名", "は」"])
        #expect(texts("say \"hi\"") == ["say ", "\"hi\""])
    }

    @Test func barsSetSyllablesByHand() {
        #expect(texts("Hel|lo world") == ["Hel", "lo ", "world"])
        #expect(texts("君の|名は") == ["君の", "名は"])
    }

    @Test func plainTextGivesALinePerLineAndBlankLinesStartParagraphs() throws {
        let draft = try LyricsDraftImport.draft(from: "第一行\n第二行\n\nThird line\n")
        #expect(draft.lines.map(\.text) == ["第一行", "第二行", "Third line"])
        #expect(draft.lines.map(\.isParagraphStart) == [true, false, true])
        #expect(draft.timedCount == 0)
        #expect(LyricsDraftImport.kind(of: "第一行") == .plainText)
        #expect(LyricsDraftImport.kind(of: "  \n") == .empty)
    }

    @Test func lrcKeepsLineTimesAndPairsTranslations() throws {
        let lrc = """
        [ti:Song]
        [00:01.00]Hello world
        [00:01.00]你好世界
        [00:04.50]
        [00:06.00][00:12.00]Again
        """
        #expect(LyricsDraftImport.kind(of: lrc) == .lineTimed)
        let draft = try LyricsDraftImport.draft(from: lrc)
        #expect(draft.lines.map(\.text) == ["Hello world", "Again", "Again"])
        #expect(draft.lines[0].translation == "你好世界")
        #expect(draft.lines[0].start == 1)
        #expect(draft.lines[0].end == 4.5)
        #expect(draft.lines[1].start == 6)
        #expect(draft.lines[1].end == 12)
        #expect(draft.lines[2].end == nil)
        let separate = try LyricsDraftImport.draft(from: lrc, pairsTranslations: false)
        #expect(separate.lines.map(\.text) == ["Hello world", "你好世界", "Again", "Again"])
    }

    @Test func ttmlKeepsSyllableTimingAndBackgroundVocalsBecomeTheirOwnLine() throws {
        #expect(LyricsDraftImport.kind(of: TTMLTests.sample) == .syllableTimed(.ttml))
        let draft = try LyricsDraftImport.draft(from: TTMLTests.sample)
        #expect(draft.lines.map(\.text) == ["Hello world", "(ooh yeah)", "Second voice", "Plain line"])
        #expect(draft.lines[0].syllables.map(\.text) == ["Hel", "lo ", "world"])
        #expect(draft.lines[0].syllables[1].start == 1.4)
        #expect(draft.lines[0].translation == "你好世界")
        #expect(draft.lines[1].isBackground)
        #expect(draft.lines[2].singer == .secondary)
        #expect(draft.metadata["ncmMusicId"] == "123")
    }
}

@Suite struct LyricsDraftTimingTests {
    private func line(_ parts: [(String, Double?, Double?)], start: Double? = nil, end: Double? = nil, background: Bool = false) -> LyricsDraft.Line {
        LyricsDraft.Line(syllables: parts.map { LyricsDraft.Syllable(text: $0.0, start: $0.1, end: $0.2) }, isBackground: background, start: start, end: end)
    }

    @Test func untimedSyllablesShareTheTimeBetweenTimedOnesByLength() throws {
        let draft = LyricsDraft(lines: [line([("a", 1, 2), ("bb", nil, nil), ("c", nil, nil), ("d", 5, 6)])])
        let syllables = try #require(draft.document().lines.first).syllables
        #expect(syllables.map(\.start) == [1, 2, 4, 5])
        #expect(syllables.map(\.end) == [2, 4, 5, 6])
    }

    @Test func aLineTimedAsAWholeSpreadsOverItsSyllables() throws {
        let draft = LyricsDraft(lines: [line([("ab", nil, nil), ("cd", nil, nil)], start: 10, end: 14)])
        let syllables = try #require(draft.document().lines.first).syllables
        #expect(syllables.map(\.start) == [10, 12])
        #expect(syllables.map(\.end) == [12, 14])
    }

    @Test func linesWithoutTimingShareTheGapBetweenTimedLines() {
        let draft = LyricsDraft(lines: [
            line([("a", 0, 2)]),
            line([("b", nil, nil)]),
            line([("c", nil, nil)]),
            line([("d", 8, 9)]),
        ])
        let lines = draft.document().lines
        #expect(lines.map(\.start) == [0, 2, 5, 8])
        #expect(lines.map(\.end) == [2, 5, 8, 9])
    }

    @Test func aStartedSyllableWithoutAnEndRunsOnBriefly() throws {
        let draft = LyricsDraft(lines: [line([("a", 1, 1.5), ("b", 2, nil)]), line([("c", 2.1, 3)])])
        let first = try #require(draft.document().lines.first)
        #expect(first.syllables[1].start == 2)
        #expect(first.syllables[1].end == 2.1)
    }

    @Test func backgroundLinesJoinTheLineAbove() throws {
        let draft = LyricsDraft(lines: [line([("main", 1, 2)]), line([("(ooh)", 1.5, 3)], background: true), line([("next", 4, 5)])])
        let lines = draft.document().lines
        #expect(lines.count == 2)
        let background = try #require(lines[0].background)
        #expect(background.text == "(ooh)")
        #expect(lines[0].end == 3)
        #expect(lines[0].primaryEnd == 2)
    }
}

@Suite struct LyricsDraftEditingTests {
    @Test func editableTextMarksSyllablesWithinAWord() {
        let line = LyricsDraft.Line(syllables: LyricsDraftImport.syllables(in: "Hel|lo world"))
        #expect(LyricsDraft.editableText(of: line) == "Hel|lo world")
        let chinese = LyricsDraft.Line(syllables: LyricsDraftImport.syllables(in: "我爱你"))
        #expect(LyricsDraft.editableText(of: chinese) == "我|爱|你")
    }

    @Test func changingTheTextKeepsTimingOfTheSyllablesThatStay() {
        var draft = LyricsDraft(lines: [LyricsDraft.Line(syllables: [
            .init(text: "我", start: 1, end: 2), .init(text: "爱", start: 2, end: 3), .init(text: "你", start: 3, end: 4),
        ])])
        draft.setText("我|很|爱|你", ofLine: 0)
        #expect(draft.lines[0].syllables.map(\.text) == ["我", "很", "爱", "你"])
        #expect(draft.lines[0].syllables.map(\.start) == [1, nil, 2, 3])
    }

    @Test func splittingSharesTimeAndMergingJoins() {
        var draft = LyricsDraft(lines: [LyricsDraft.Line(syllables: [.init(text: "abcd ", start: 0, end: 4), .init(text: "e", start: 5, end: 6)])])
        draft.splitSyllable(at: .init(line: 0, syllable: 0))
        #expect(draft.lines[0].syllables.map(\.text) == ["a", "b", "c", "d ", "e"])
        #expect(draft.lines[0].syllables.map(\.start) == [0, 1, 2, 3, 5])
        draft.mergeWithNext(at: .init(line: 0, syllable: 2))
        #expect(draft.lines[0].syllables.map(\.text) == ["a", "b", "cd ", "e"])
        #expect(draft.lines[0].syllables[2].start == 2)
        #expect(draft.lines[0].syllables[2].end == 4)
    }

    @Test func positionsWalkAcrossLinesSkippingEmptyOnes() {
        let draft = LyricsDraft(lines: [
            LyricsDraft.Line(syllables: [.init(text: "a"), .init(text: "b")]),
            LyricsDraft.Line(syllables: []),
            LyricsDraft.Line(syllables: [.init(text: "c")]),
        ])
        #expect(draft.position(after: .init(line: 0, syllable: 1)) == .init(line: 2, syllable: 0))
        #expect(draft.position(before: .init(line: 2, syllable: 0)) == .init(line: 0, syllable: 1))
        #expect(draft.position(after: .init(line: 2, syllable: 0)) == nil)
    }

    @Test func shiftingNeverGoesBeforeZero() {
        var draft = LyricsDraft(lines: [LyricsDraft.Line(syllables: [.init(text: "a", start: 0.2, end: 1)])])
        draft.shift(by: -0.5)
        #expect(draft.lines[0].syllables[0].start == 0)
        #expect(draft.lines[0].syllables[0].end == 0.5)
    }

    @Test func syllablesMovedToANewLineKeepTheirTimingAndLeaveNoEmptyLines() throws {
        var draft = try LyricsDraftImport.draft(from: "我爱你\n再见\n\n好")
        draft.lines[0].syllables[1].start = 1
        draft.lines[1].singer = .secondary
        #expect(draft.moveSyllablesToNewLine([.init(line: 0, syllable: 2), .init(line: 0, syllable: 1)]) == 1)
        #expect(draft.lines.map(\.text) == ["我", "爱你", "再见", "好"])
        #expect(draft.lines[1].syllables[0].start == 1)
        #expect(draft.lines[1].singer == .primary)
        #expect(draft.moveSyllablesToNewLine([.init(line: 1, syllable: 0), .init(line: 1, syllable: 1), .init(line: 2, syllable: 0)]) == 2)
        #expect(draft.lines.map(\.text) == ["我", "见", "爱你再", "好"])
        let before = draft
        #expect(draft.moveSyllablesToNewLine([.init(line: 3, syllable: 0)]) == 3)
        #expect(draft == before)
        #expect(draft.moveSyllablesToNewLine([.init(line: 9, syllable: 0)]) == nil)
    }

    @Test func syllablesMoveIntoTheLinesAroundThemAndPassOnTheParagraph() throws {
        var draft = try LyricsDraftImport.draft(from: "我\n\n你好\n再见")
        #expect(draft.moveSyllables([.init(line: 1, syllable: 0), .init(line: 1, syllable: 1)], toLineBy: -1) == 0)
        #expect(draft.lines.map(\.text) == ["我你好", "再见"])
        #expect(draft.lines.map(\.isParagraphStart) == [true, true])
        #expect(draft.moveSyllables([.init(line: 0, syllable: 2)], toLineBy: 1) == 1)
        #expect(draft.lines.map(\.text) == ["我你", "好再见"])
        #expect(draft.moveSyllables([.init(line: 0, syllable: 0)], toLineBy: -1) == nil)
        #expect(draft.moveSyllables([.init(line: 1, syllable: 0)], toLineBy: 1) == nil)
    }

    @Test func wordsThatComeToTouchStayApart() throws {
        var draft = try LyricsDraftImport.draft(from: "Hello world\nfoo bar")
        draft.moveSyllables([.init(line: 0, syllable: 1)], toLineBy: 1)
        #expect(draft.lines.map { $0.syllables.map(\.text) } == [["Hello "], ["world ", "foo ", "bar"]])
        draft.moveSyllablesToNewLine([.init(line: 1, syllable: 2)])
        draft.moveSyllables([.init(line: 2, syllable: 0)], toLineBy: -1)
        #expect(draft.lines.map { $0.syllables.map(\.text) } == [["Hello "], ["world ", "foo ", "bar"]])
        draft.removeSyllables([.init(line: 1, syllable: 1)])
        #expect(draft.lines[1].syllables.map(\.text) == ["world ", "bar"])
        var split = LyricsDraft(lines: [LyricsDraft.Line(syllables: LyricsDraftImport.syllables(in: "Hel|lo big world"))])
        split.removeSyllables([.init(line: 0, syllable: 1)])
        #expect(split.lines[0].syllables.map(\.text) == ["Hel ", "big ", "world"])
        split.removeSyllables((0..<3).map { .init(line: 0, syllable: $0) })
        #expect(split.lines.isEmpty)
    }

    @Test func linesMoveWithTheirBackgroundVocalsPastWholeLines() {
        func line(_ text: String, background: Bool = false) -> LyricsDraft.Line {
            LyricsDraft.Line(syllables: [.init(text: text)], isBackground: background)
        }
        var draft = LyricsDraft(lines: [line("A"), line("a", background: true), line("B"), line("C"), line("c", background: true)])
        let texts = { draft.lines.map(\.text) }
        #expect(draft.moveLine(at: 2, by: -1) == 0)
        #expect(texts() == ["B", "A", "a", "C", "c"])
        #expect(draft.moveLine(at: 1, by: 1) == 3)
        #expect(texts() == ["B", "C", "c", "A", "a"])
        #expect(draft.moveLine(at: 3, by: 1) == nil)
        #expect(draft.moveLine(at: 0, by: -1) == nil)
        #expect(draft.moveLine(at: 2, by: -1) == 1)
        #expect(texts() == ["B", "c", "C", "A", "a"])
        #expect(draft.moveLine(at: 1, by: 1) == 2)
        #expect(draft.moveLine(at: 2, by: 1) == 3)
        #expect(texts() == ["B", "C", "A", "c", "a"])
    }

    @Test func onlyARunOfSyllablesMergesAndLinesMergeWithTheirAnnotations() throws {
        var draft = try LyricsDraftImport.draft(from: "我爱你\nsee you")
        #expect(!LyricsDraft.isRun([.init(line: 0, syllable: 0), .init(line: 0, syllable: 2)]))
        #expect(draft.mergeSyllables([.init(line: 0, syllable: 0), .init(line: 0, syllable: 2)]) == nil)
        #expect(draft.mergeSyllables([.init(line: 0, syllable: 2), .init(line: 0, syllable: 1)]) == .init(line: 0, syllable: 1))
        #expect(draft.lines[0].syllables.map(\.text) == ["我", "爱你"])
        draft.lines[0].translation = "I love you"
        draft.lines[1].translation = "再见"
        draft.mergeLineWithNext(0)
        #expect(draft.lines.count == 1)
        #expect(draft.lines[0].syllables.map(\.text) == ["我", "爱你", "see ", "you"])
        #expect(draft.lines[0].translation == "I love you 再见")
    }
}

@Suite struct TTMLWriterTests {
    @Test func writtenTTMLReadsBackTheSame() throws {
        let original = try TTMLParser.parse(TTMLTests.sample)
        let written = TTMLWriter.write(original, duration: 30)
        let parsed = try TTMLParser.parse(written)
        #expect(parsed.lines.map(\.text) == original.lines.map(\.text))
        #expect(parsed.lines.map(\.singer) == original.lines.map(\.singer))
        #expect(parsed.lines.map(\.translation) == original.lines.map(\.translation))
        #expect(parsed.lines.map(\.isParagraphStart) == original.lines.map(\.isParagraphStart))
        #expect(parsed.lines[0].syllables.map(\.text) == original.lines[0].syllables.map(\.text))
        #expect(parsed.lines[0].syllables.map(\.start) == original.lines[0].syllables.map(\.start))
        #expect(parsed.lines[0].background?.text == original.lines[0].background?.text)
        #expect(parsed.lines[0].background?.syllables.map(\.start) == original.lines[0].background?.syllables.map(\.start))
        #expect(parsed.metadata["ncmMusicId"] == "123")
    }

    @Test func draftsExportWithSingersEscapingAndRepeatedMetadata() throws {
        var draft = try LyricsDraftImport.draft(from: "Rock & <roll>\n对唱\n合唱")
        draft.lines[1].singer = .secondary
        draft.lines[2].singer = .duet
        draft.lines[0].romanization = "rokku"
        let ttml = TTMLWriter.write(draft.document(), metadata: [("musicName", "Song \"A\""), ("artists", "X"), ("artists", "Y")])
        #expect(ttml.contains(#"<amll:meta key="artists" value="X"/><amll:meta key="artists" value="Y"/>"#))
        #expect(ttml.contains("&lt;roll&gt;"))
        let parsed = try TTMLParser.parse(ttml)
        #expect(parsed.lines.map(\.text) == ["Rock & <roll>", "对唱", "合唱"])
        #expect(parsed.lines.map(\.singer) == [.primary, .secondary, .duet])
        #expect(parsed.lines[0].romanization == "rokku")
        #expect(parsed.metadata["musicName"] == "Song \"A\"")
        #expect(parsed.lines[0].start < parsed.lines[1].start)
    }

    @Test func timestampsUseMinutesAndHours() {
        #expect(TTMLWriter.timestamp(83.4567) == "01:23.457")
        #expect(TTMLWriter.timestamp(3725) == "1:02:05.000")
    }
}
