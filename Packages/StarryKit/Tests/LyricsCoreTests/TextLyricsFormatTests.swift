import Foundation
import Testing
@testable import LyricsCore

@Suite struct TextLyricsFormatTests {
    @Test(arguments: [
        "[00:01.000]<00:01.000>你<00:02.000>好<00:03.000>",
        "[00:01.000]你[00:02.000]好[00:03.000]",
        "[00:01:00]<00:01:00>你<00:02:00>好<00:03:00>",
        "[00:01:00]你[00:02:00]好[00:03:00]",
    ])
    func wordLRCUsesTagsAsTimingRatherThanText(_ text: String) throws {
        let document = try LRCParser.parse(text)
        #expect(document.lines.map(\.text) == ["你好"])
        #expect(document.lines[0].syllables.map(\.start) == [1, 2])
        #expect(document.lines[0].syllables.map(\.end) == [2, 3])
        #expect(document.lines[0].end == 3)
        #expect(LyricsDraftImport.kind(of: text) == .syllableTimed(.lrc))
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.lines[0].text == "你好")
        #expect(draft.lines[0].syllables.map(\.start) == [1, 2])
        #expect(draft.lines[0].syllables.map(\.end) == [2, 3])
    }

    @Test func repeatedLineTagsDoNotBecomeWordsAndEnhancedRepeatsShiftTimes() throws {
        let plain = "[00:01.000][00:05.000]Again\n[00:08.000]End"
        #expect(LyricsDraftImport.kind(of: plain) == .lineTimed)
        #expect(try LRCParser.parse(plain).lines.map(\.text) == ["Again", "Again", "End"])
        let enhanced = try LRCParser.parse("[00:01.000][00:05.000]<00:01.000>你<00:02.000>好<00:03.000>")
        #expect(enhanced.lines.map(\.start) == [1, 5])
        #expect(enhanced.lines.map(\.end) == [3, 7])
        #expect(enhanced.lines[1].syllables.map(\.start) == [5, 6])
    }

    @Test(arguments: [".", ":"])
    func neteaseCreditsDoNotTurnLineTimedLRCIntoKaraoke(_ separator: String) throws {
        let text = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"KAORU"}]}
        {"t":570,"c":[{"tx":"作曲: "},{"tx":"Gom"},{"tx":"/"},{"tx":"KAORU"}]}
        [00:03\(separator)00][00:20\(separator)00]何十年 何百年だって
        [00:07\(separator)50]色褪せない思い出にしよう
        """
        let translation = """
        {"t":0,"c":[{"tx":"翻译: "},{"tx":"Translator"}]}
        [00:03\(separator)00][00:20\(separator)00]无论是十年 还是百年
        [00:07\(separator)50]都要将它化作永不褪色的回忆
        """
        #expect(LyricsFormatDetector.detect(text) == .lrc)
        #expect(LyricsDraftImport.kind(of: text) == .lineTimed)
        let document = try LyricsParsing.parse(text, format: .lrc, translation: translation)
        #expect(document.format == .lrc)
        #expect(document.lines.map(\.text) == ["何十年 何百年だって", "色褪せない思い出にしよう", "何十年 何百年だって"])
        #expect(document.lines.map(\.start) == [3, 7.5, 20])
        #expect(!document.hasSyllables)
        #expect(document.lines.map(\.translation) == ["无论是十年 还是百年", "都要将它化作永不褪色的回忆", "无论是十年 还是百年"])
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.lines.map(\.text) == document.lines.map(\.text))
        #expect(draft.lines.map(\.start) == [3, 7.5, 20])
        #expect(draft.timedCount == 0)
    }

    @Test(arguments: [LyricsExportFormat.lrcEnhanced, .lrcWord, .kra])
    func sameStartWordTimedVoicesStaySeparateAfterExportAndImport(_ format: LyricsExportFormat) throws {
        var document = try LRCParser.parse("[00:01.000]你[00:02.000]好[00:03.000]\n[00:01.000]我[00:02.000]们[00:04.000]")
        let background = document.lines.removeLast()
        document.lines[0].background = .init(start: background.start, end: background.end, words: background.words)
        document.lines[0].end = background.end
        let output = try LyricsExport.write(document, format: format)
        #expect(output.losses.contains(.backgroundGrouping))
        let draft = try LyricsDraftImport.draft(from: output.text)
        #expect(draft.lines.map(\.text) == ["你好", "我们"])
        #expect(draft.lines.map { $0.syllables.map(\.start) } == [[1, 2], [1, 2]])
        #expect(draft.lines.map { $0.syllables.map(\.end) } == [[2, 3], [2, 4]])
        #expect(draft.lines.allSatisfy { $0.translation.isEmpty && $0.romanization.isEmpty })
    }

    @Test func mixedLineAndWordTimedLRCDoesNotPairSameStartVoices() throws {
        let text = "[00:01.000]你[00:02.000]\n[00:01.000]我\n[00:05.000]后来\n[00:05.000]再见"
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.lines.map(\.text) == ["你", "我", "后来", "再见"])
        #expect(draft.lines.allSatisfy { $0.translation.isEmpty && $0.romanization.isEmpty })
    }

    @Test func releasesKeepInternalSilenceAndUntimedTailsRemainEditable() throws {
        let document = try LRCParser.parse("[00:01.000]a[00:02.000][00:04.000]b[00:05.000]")
        #expect(document.lines[0].syllables.map(\.start) == [1, 4])
        #expect(document.lines[0].syllables.map(\.end) == [2, 5])
        let draft = try LyricsDraftImport.draft(from: "[00:01.000]<00:01.000>hold")
        #expect(draft.lines[0].syllables.count == 1)
        #expect(draft.lines[0].syllables[0].start == 1)
        #expect(draft.lines[0].syllables[0].end == nil)
        #expect(draft.lines[0].end == nil)
    }

    @Test func metadataAndOffsetsSurviveEditingWithoutBeingAppliedTwice() throws {
        let text = "[ti:Song]\n[ar:Singer]\n[offset:100]\n[00:01.000]<00:01.000>你<00:02.000>好<00:03.000>"
        let document = try LRCParser.parse(text)
        #expect(document.lines[0].start == 0.9)
        #expect(document.lines[0].syllables.map(\.start) == [0.9, 1.9])
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.metadata["ti"] == "Song")
        #expect(draft.metadata["ar"] == "Singer")
        #expect(draft.metadata["offset"] == nil)
        let written = try LyricsExport.write(draft.document(), format: .lrcEnhanced).text
        #expect(!written.contains("[offset:"))
        #expect(try LRCParser.parse(written).lines[0].start == 0.9)
        #expect(try LyricsDraftImport.draft(from: "[offset:-250]\n[00:01.000]Line").lines[0].start == 1.25)
    }

    @Test func descendingInlineTimesAreAnErrorAndProseIsNotLRC() throws {
        #expect(throws: (any Error).self) { try LyricsDraftImport.draft(from: "[00:03.000]a[00:01.000]b") }
        #expect(LRCParser.parseTimestamp("00:60.00") == nil)
        #expect(LRCParser.parseTimestamp("00:nan") == nil)
        #expect(LRCParser.parseTimestamp("00:-1") == nil)
        #expect(LyricsDraftImport.kind(of: "Literal <00:01.000> text") == .plainText)
    }

    @Test func srtPreservesExplicitEndsOverlapMarkupAndHourTimes() throws {
        let source = "\u{FEFF}2\r\n01:00:01,250 --> 01:00:03,500\r\n<i>你好</i> &amp; &lt;world&gt;\r\n\r\n1\r\n01:00:00,000 --> 01:00:02,000 X1:0\r\nOther\r\n"
        #expect(LyricsFormatDetector.detect(source) == .srt)
        let document = try SRTParser.parse(source)
        #expect(document.lines.map(\.text) == ["Other", "你好 & <world>"])
        #expect(document.lines.map(\.start) == [3600, 3601.25])
        #expect(document.lines.map(\.end) == [3602, 3603.5])
        #expect(!document.hasSyllables)
        let draft = try LyricsDraftImport.draft(from: source)
        #expect(LyricsDraftImport.kind(of: source) == .lineTimedFormat(.srt))
        #expect(draft.lines[1].start == 3601.25 && draft.lines[1].end == 3603.5)
        #expect(draft.timedCount == 0)
        let written = try LyricsExport.write(document, format: .srt).text
        #expect(written.contains("01:00:01,250 --> 01:00:03,500"))
        let reparsed = try SRTParser.parse(written)
        #expect(reparsed.lines == document.lines)
    }

    @Test(arguments: ["1\n00:00:03,000 --> 00:00:01,000\nBad", "1\n00:61:00,000 --> 01:02:00,000\nBad", "1\n00:00:01,000 --> invalid\nBad"])
    func malformedSubtitlesAreNotImportedAsPlainLyrics(_ text: String) {
        #expect(LyricsFormatDetector.detect(text) == .srt)
        #expect(throws: (any Error).self) { try LyricsDraftImport.draft(from: text) }
    }

    @Test(arguments: [LyricsExportFormat.lrcEnhanced, .lrcWord, .kra])
    func wordExportsKeepGapsAndReleaseTimes(_ format: LyricsExportFormat) throws {
        let original = try LRCParser.parse("[00:01.000]你[00:02.000][00:04.000]好[00:05.000]")
        let output = try LyricsExport.write(original, format: format)
        let parsed = try LRCParser.parse(output.text)
        #expect(parsed.lines.map(\.text) == ["你好"])
        #expect(parsed.lines[0].syllables == original.lines[0].syllables)
        #expect(output.losses.isEmpty)
    }

    @Test func lossyExportsReportRichFieldsAndFlattenBackgroundWithoutChangingTheDocument() throws {
        let original = try TTMLParser.parse(TTMLTests.sample)
        let output = try LyricsExport.write(original, format: .srt)
        #expect(output.losses.contains(.agents))
        #expect(output.losses.contains(.translation))
        #expect(output.losses.contains(.syllableTiming))
        #expect(output.losses.contains(.backgroundGrouping))
        let cues = try SRTParser.parse(output.text)
        #expect(cues.lines.map(\.text) == ["Hello world", "(ooh yeah)", "Second voice", "Plain line"])
        #expect(cues.lines[0].end == 3.5)
        #expect(cues.lines[1].end == 3.9)
        #expect(original.lines[0].background != nil)
        #expect(try LyricsExport.write(original, format: .ttml).losses.isEmpty)
    }

    @Test(arguments: [LyricsExportFormat.lrcLine, .txt2ass])
    func lineExportsEndBeforeAnInstrumentalGap(_ format: LyricsExportFormat) throws {
        let document = LyricsDocument(format: .ttml, lines: [.plain(id: 0, start: 1, end: 3, text: "A"), .plain(id: 1, start: 20, end: 22, text: "B")], metadata: ["musicName": "Song"])
        let output = try LyricsExport.write(document, format: format)
        let parsed = try LRCParser.parse(output.text)
        #expect(parsed.lines[0].end == 3)
        #expect(parsed.instrumentalGaps().count == 1)
        #expect(parsed.metadata["ti"] == (format == .txt2ass ? nil : "Song"))
    }

    @Test func enhancedRomanizationRetainsItsOwnTimingWhenAttached() throws {
        let document = try LyricsParsing.parse("[00:01.000]你[00:02.000]好[00:03.000]", format: .lrc, romanization: "[00:01.000]<00:01.000>ni <00:02.000>hao<00:03.000>")
        #expect(document.lines[0].romanizationWords?.flatMap(\.syllables).map(\.start) == [1, 2])
    }

    @Test(arguments: ["[00:01.000]<00:01.200>hello<00:01.700>", "[1200,500](1200,500,0)hello"])
    func oneTimedRomanizationUnitKeepsItsOwnSpan(_ romanization: String) throws {
        let document = try LyricsParsing.parse("[00:01.000]你[00:02.000]好[00:03.000]", format: .lrc, romanization: romanization)
        #expect(document.lines[0].romanizationWords?.first?.start == 1.2)
        #expect(document.lines[0].romanizationWords?.first?.end == 1.7)
    }

    @Test func subtitleEditingPreservesLiteralBarsAndLineBreaks() throws {
        let draft = try LyricsDraftImport.draft(from: "1\n00:00:01,000 --> 00:00:04,000\nHello|world\n你好")
        #expect(draft.lines[0].text == "Hello|world\n你好")
        let output = try LyricsExport.write(draft.document(), format: .srt)
        #expect(try SRTParser.parse(output.text).lines[0].text == "Hello|world\n你好")
    }

    @Test func anUnreleasedLastSyllableGetsADisplayTail() throws {
        let parsed = try LRCParser.parse("[00:01.000]<00:01.000>first <00:20.000>last")
        #expect(parsed.lines[0].syllables.last?.start == 20)
        #expect(parsed.lines[0].syllables.last?.end == 25)
    }

    @Test func plainTextExportKeepsTheAuthorOrderRatherThanSortingByInferredTimes() throws {
        let document = LyricsDocument(format: .ttml, lines: [.plain(id: 0, start: 20, end: 22, text: "A"), .plain(id: 1, start: 1, end: 3, text: "B")])
        #expect(try LyricsExport.write(document, format: .txt).text == "A\nB\n")
        let untimed = try LyricsDraftImport.draft(from: "No times")
        #expect(try !LyricsExport.write(untimed, format: .txt).losses.contains(.timing))
        let lineTimed = try LyricsDraftImport.draft(from: "[00:01.000]你好\n[00:03.000]")
        #expect(try !LyricsExport.write(lineTimed, format: .srt).losses.contains(.syllableTiming))
    }
}
