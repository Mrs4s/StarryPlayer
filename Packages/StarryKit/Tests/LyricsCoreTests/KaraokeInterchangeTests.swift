import Foundation
import Testing
@testable import LyricsCore

@Suite struct KaraokeInterchangeTests {
    static let ass = #"""
    [Script Info]
    ; Generator: StrangeUtaGame
    ; SUG-PreRollMs: 200
    Title: Test
    [Events]
    Format: Name, Start, End, Text
    Dialogue: Alice,0:00:00.80,0:00:03.20,{\kf20\b1}未|<み{\K30}#|らい{\k50}来{\k50}{\sing_Bob}{\ko50}へ
    """#

    static let nicokara = """
    【sv1】[00:01:00]未[00:01:20]来[00:02:00]へ[00:03:00]
    【sv2】[00:04:00]未来[00:05:00]
    @Title=Test
    @Ruby1=未来,み[00:00:20]らい,[00:01:00],[00:02:00]
    @Ruby2=未来,あした,[00:04:00],[00:05:00]
    @Emoji=【sv1】,transparent.png,NoDecor
    """

    static let krl = """
    config {"style": {"font": "Noto {Sans}", "quoted": "\\\"}"}, "groups": []}
    【@Alice】[00:01:00]{未来|[00:01:20]み[00:01:40]らい[00:01:80]>[00:01:10]mi[00:01:55]rai[00:01:90]}[00:02:00]
    【@Alice+Bob】{へ|>[00:03:00]e[00:04:00]}[00:04:00]
    """

    @Test func assReadsCompoundKaraokeRubyPausesSingerChangesAndSUGPreRoll() throws {
        #expect(LyricsFormatDetector.detect(Self.ass) == .ass)
        let document = try ASSParser.parse(Self.ass)
        let line = try #require(document.lines.first)
        #expect(line.text == "未来へ")
        #expect(line.syllables.map(\.start) == [1, 1.5, 2.5])
        #expect(line.syllables.map(\.end) == [1.5, 2, 3])
        #expect(line.syllables[0].ruby.map(\.text) == ["み", "らい"])
        #expect(line.syllables[0].ruby.map(\.start) == [1, 1.2])
        #expect(document.agents.map(\.displayName) == ["Alice", "Bob"])
        #expect(line.agentIDs == ["v1"])
        #expect(line.syllables.last?.agentIDs == ["v2"])
        #expect(document.metadata["musicName"] == "Test")
    }

    @Test func plainSSAHasLineTimingAndDrawingsAreNotLyrics() throws {
        let text = #"""
        [Script Info]
        [Events]
        Format: Marked, Start, End, Text
        Dialogue: Marked=0,0:00:01.00,0:00:03.00,{\p1}m 0 0 l 20 20{\p0}Hello\Nworld\h!
        """#
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.lines[0].text == "Hello\nworld\u{00A0}!")
        #expect(draft.lines[0].start == 1 && draft.lines[0].end == 3)
        #expect(draft.timedCount == 0)
        #expect(LyricsDraftImport.kind(of: text) == .lineTimedFormat(.ass))
    }

    @Test func nicokaraRubyIsScopedByPositionAndMergesOnlyItsBaseGroup() throws {
        #expect(LyricsFormatDetector.detect(Self.nicokara) == .nicokara)
        let draft = try LyricsDraftImport.draft(from: Self.nicokara)
        #expect(draft.lines.map(\.text) == ["未来へ", "未来"])
        #expect(draft.lines[0].syllables.map(\.text) == ["未来", "へ"])
        #expect(draft.lines[0].syllables[0].ruby?.map(\.text) == ["み", "らい"])
        #expect(draft.lines[1].syllables[0].ruby?.map(\.text) == ["あした"])
        let original = draft.document()
        let output = try LyricsExport.write(draft, format: .nicokaraRuby)
        #expect(output.text.contains("@Ruby1=未来,"))
        #expect(output.text.contains("@Emoji=【sv1】,transparent.png,NoDecor"))
        let parsed = try NicokaraParser.parse(output.text)
        #expect(parsed.lines.map(\.text) == original.lines.map(\.text))
        #expect(parsed.lines[0].syllables[0].ruby == original.lines[0].syllables[0].ruby)
        #expect(parsed.lines[1].syllables[0].ruby.map(\.text) == ["あした"])
    }

    @Test func aNicokaraRubyRangeMayOmitItsLowerBound() throws {
        let text = "[00:01:00]者[00:02:00]\n[00:30:00]者[00:31:00]\n@Ruby=者,しゃ,,[00:27:01]"
        let parsed = try NicokaraParser.parse(text)
        #expect(parsed.lines[0].hasRuby)
        #expect(!parsed.lines[1].hasRuby)
    }

    @Test func krlPreservesIndependentRubyAndRomanizationTimingAndCoPerformers() throws {
        #expect(LyricsFormatDetector.detect(Self.krl) == .krl)
        let draft = try LyricsDraftImport.draft(from: Self.krl)
        #expect(draft.lines.map(\.text) == ["未来", "へ"])
        #expect(draft.lines[0].syllables[0].start == 1)
        #expect(draft.lines[0].syllables[0].end == 2)
        #expect(draft.lines[0].romanization == "mirai")
        #expect(draft.lines[1].agentIDs.count == 2)
        let original = draft.document()
        #expect(abs(original.lines[0].syllables[0].ruby[0].start - 1.2) < 1e-9)
        #expect(abs(original.lines[0].romanizationWords![0].syllables[1].start - 1.55) < 1e-9)
        let project = try LyricsProject(data: LyricsProject(draft: draft).data())
        #expect(project.version == 4 && project.draft == draft)
        let written = try LyricsExport.write(project.draft, format: .krl)
        let parsed = try KRLParser.parse(written.text)
        #expect(parsed.lines.map(\.text) == original.lines.map(\.text))
        #expect(abs(parsed.lines[0].syllables[0].start - 1) < 0.011)
        #expect(abs(parsed.lines[0].syllables[0].end - 2) < 0.011)
        #expect(abs(parsed.lines[0].romanizationWords![0].syllables[1].start - 1.55) < 0.011)
        #expect(parsed.lines[1].singer == .duet)
    }

    @Test func timedRomanizationSurvivesTTMLAndFollowsGlobalRetiming() throws {
        var draft = try LyricsDraftImport.draft(from: Self.krl)
        draft.shift(by: 2)
        let original = draft.document()
        let parsed = try TTMLParser.parse(TTMLWriter.write(original))
        #expect(abs(parsed.lines[0].romanizationWords![0].start - 3.1) < 1e-9)
        #expect(abs(parsed.lines[0].romanizationWords![0].syllables[1].start - 3.55) < 1e-9)
        draft.lines[0].romanization = "edited"
        #expect(draft.lines[0].romanizationTiming == nil)
    }

    @Test func rlKeepsUntimedBeatsReleaseFlagsRestsAndLinkedRubyInTheProject() throws {
        let text = "[2]あ[10]\n[2|00:01:00]い[00:01:20][10|00:02:00][1|00:02:00]▨[10|00:03:00]\n{未来|[2|00:04:00]み[00:04:50]らい＋[0]}[10|00:05:00]"
        #expect(LyricsFormatDetector.detect(text) == .rl)
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.lines[0].syllables[0].checkpoints == [nil, nil])
        #expect(draft.lines[0].syllables[0].hasRelease)
        #expect(draft.lines[0].syllables[0].start == nil)
        #expect(draft.lines[1].syllables[1].isRest)
        #expect(draft.lines[1].text == "い")
        #expect(draft.lines[2].syllables[0].text == "未来")
        #expect(draft.lines[2].syllables[0].ruby?.map(\.text) == ["み", "らい"])
        #expect(try LyricsProject(data: LyricsProject(draft: draft).data()).draft == draft)
        let output = try LyricsExport.write(draft, format: .rl)
        #expect(output.text.contains("[2]あ[10]"))
        #expect(output.text.contains("▨"))
        let reparsed = try LyricsDraftImport.draft(from: output.text)
        #expect(reparsed.lines.map(\.text) == draft.lines.map(\.text))
        #expect(reparsed.lines[0].syllables[0].checkpoints == [nil, nil])
        #expect(reparsed.lines[1].syllables[1].isRest)
        #expect(reparsed.lines[2].syllables[0].checkpoints == [0, 0.5])
        #expect(try !LyricsExport.write(draft, format: .ttml).losses.isEmpty)
    }

    @Test func untimedRLIsEditableButDoesNotInventSyncedPlayback() throws {
        let text = "{漢字|[2]かんじ＋[0]}[10]"
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.timedCount == 0)
        #expect(draft.lines[0].text == "漢字")
        #expect(throws: LyricsParseError.empty) { try RLParser.parse(text) }
    }

    @Test(arguments: ["[1]abc[", "[1]abc[00:01", "[1]abc\n["])
    func incompleteRLBeatTagsAreRejected(_ text: String) {
        #expect(throws: (any Error).self) { try LyricsDraftImport.draft(from: text) }
        #expect(throws: (any Error).self) { try RLParser.parse(text) }
    }

    @Test(arguments: [
        "[2|00:01:00]あ[00:05:00]",
        "[2|00:01:00]あ[00:05:00][10]",
        "{未来|[2|00:01:00]み[00:05:00]らい}",
    ])
    func rlExportKeepsBeatsBeyondTheInferredEndWithoutInventingARelease(_ text: String) throws {
        let draft = try LyricsDraftImport.draft(from: text)
        let original = try #require(draft.lines.first?.syllables.first)
        #expect(original.end == nil)
        let output = try LyricsExport.write(draft, format: .rl)
        let reopened = try LyricsDraftImport.draft(from: output.text)
        let syllable = try #require(reopened.lines.first?.syllables.first)
        #expect(syllable.text == original.text)
        #expect(syllable.start == original.start)
        #expect(syllable.end == nil)
        #expect(syllable.checkpoints == original.checkpoints)
        #expect(syllable.hasRelease == original.hasRelease)
        #expect(syllable.ruby?.map(\.text) == original.ruby?.map(\.text))
        #expect(!output.losses.contains(.editingState))
    }

    @Test func rlExportReportsLossesWithoutValidatingInferredReleaseTimes() throws {
        var draft = try LyricsDraftImport.draft(from: "[2|00:01:00]あ[00:05:00]")
        draft.lines[0].translation = "Translation"
        draft.lines[0].romanization = "a"
        draft.lines[0].agentIDs = ["a"]
        draft.agents = [.init(id: "a")]
        draft.metadata["title"] = "Song"
        draft.lines.append(.init(syllables: [.init(text: "oh", start: 2, end: 3)], isBackground: true))
        let output = try LyricsExport.write(draft, format: .rl)
        #expect(Set(output.losses) == [.translation, .romanization, .agents, .backgroundGrouping, .metadata])
        #expect(output.text.contains("[00:05:00]"))
    }

    @Test func rlExportStillRejectsAnAuthoredReleaseBeforeTheLastBeat() throws {
        var draft = try LyricsDraftImport.draft(from: "[2|00:01:00]あ[00:05:00]")
        draft.lines[0].syllables[0].end = 2
        #expect(throws: (any Error).self) { try LyricsExport.write(draft, format: .rl) }
    }

    @Test func assExportPreservesPartialRubySpansWithoutDuplicatingTheBase() throws {
        let syllable = LyricSyllable(start: 1, end: 2, text: "未", ruby: [.init(start: 1.2, end: 1.8, text: "み")])
        let document = LyricsDocument(format: .ttml, lines: [.init(id: 0, start: 1, end: 2, words: [.init(start: 1, end: 2, text: "未", syllables: [syllable])])])
        let output = try LyricsExport.write(document, format: .ass)
        let parsed = try ASSParser.parse(output.text)
        #expect(parsed.lines[0].text == "未")
        #expect(parsed.lines[0].syllables[0].start == 1)
        #expect(parsed.lines[0].syllables[0].end == 2)
        let ruby = parsed.lines[0].syllables[0].ruby.filter { !$0.text.isEmpty }
        #expect(ruby == [.init(start: 1.2, end: 1.8, text: "み")])
    }

    @Test func literalKRLRoleTagsAndEscapedBackslashesStayInTheText() throws {
        let text = #"【@Alice】[00:01:00]\【@literal】A\\B[00:02:00]"#
        let draft = try LyricsDraftImport.draft(from: text)
        #expect(draft.lines[0].text == #"【@literal】A\B"#)
        let output = try LyricsExport.write(draft, format: .krl)
        #expect(try KRLParser.parse(output.text).lines[0].text == draft.lines[0].text)
    }

    @Test func untimedKRLStillKeepsItsPronunciationAndRomanizationText() throws {
        let draft = try LyricsDraftImport.draft(from: "{未来|みらい>mirai}")
        #expect(draft.timedCount == 0)
        #expect(draft.lines[0].syllables[0].ruby?.first?.text == "みらい")
        #expect(draft.lines[0].romanization == "mirai")
        #expect(throws: LyricsParseError.empty) { try KRLParser.parse("{未来|みらい>mirai}") }
        let exported = try LyricsExport.write(draft, format: .krl)
        #expect(try KRLParser.parse(exported.text).lines[0].romanization == "mirai")
    }

    @Test func subtitleStructureWinsOverInlineSyntaxInTheLyrics() throws {
        let text = "1\n00:00:01,000 --> 00:00:03,000\n{foo|bar} [2]"
        #expect(LyricsFormatDetector.detect(text) == .srt)
        #expect(try LyricsDraftImport.draft(from: text).lines[0].text == "{foo|bar} [2]")
    }

    @Test func editingUnchangedTextKeepsItsCheckpointsRestsAndRoles() throws {
        var draft = try LyricsDraftImport.draft(from: "[2|00:01:00]あ[00:01:20][10|00:02:00][1|00:02:00]▨[10|00:03:00]")
        draft.lines[0].syllables[0].agentIDs = ["singer"]
        let original = draft.lines[0].syllables
        draft.setText(LyricsDraft.editableText(of: draft.lines[0]), ofLine: 0)
        #expect(draft.lines[0].syllables == original)
        draft.shift(by: 2)
        #expect(try LyricsExport.write(draft, format: .rl).text.contains("[2|00:03:00]あ[00:03:20]"))
    }

    @Test func mergingLinesKeepsBothTimedRomanizationTracks() throws {
        var draft = try LyricsDraftImport.draft(from: "{未|[00:01:00]み>[00:01:00]mi}[00:02:00]\n{来|[00:03:00]らい>[00:03:00]rai}[00:04:00]")
        draft.mergeLineWithNext(0)
        #expect(draft.lines.count == 1)
        #expect(draft.lines[0].romanization == "mi rai")
        let romanization = try #require(draft.document().lines[0].romanizationWords)
        #expect(romanization.flatMap(\.syllables).map(\.start) == [1, 3])
        #expect(romanization.flatMap(\.syllables).map(\.end) == [2, 4])
    }

    @Test func aMissingFinalRomanizationReleaseDoesNotDropTheLastReading() throws {
        let draft = try LyricsDraftImport.draft(from: "{未|[00:01:00]み>[00:01:00]mi[00:01:20]rai}")
        #expect(draft.lines[0].romanization == "mirai")
        #expect(draft.lines[0].romanizationTiming?.last?.end == nil)
        #expect(draft.hasAuthoringTiming)
        let document = draft.document()
        #expect(document.lines[0].romanizationWords?.flatMap(\.syllables).map(\.text) == ["mi", "rai"])
        #expect(document.lines[0].romanizationWords?.flatMap(\.syllables).first?.end == 1.2)
        #expect(try LyricsProject(data: LyricsProject(draft: draft).data()).draft == draft)
    }

    @Test(arguments: [LyricsExportFormat.ass, .nicokara, .nicokaraRuby, .rl, .kasugamuki, .krl])
    func allAdvancedOutputsCanBeReadBack(_ format: LyricsExportFormat) throws {
        let document = try KRLParser.parse(Self.krl)
        let output = try LyricsExport.write(document, format: format)
        let parsed = try LyricsParsing.parse(output.text, format: LyricsFormatDetector.detect(output.text))
        #expect(parsed.lines.map(\.text) == ["未来", "へ"])
        #expect(parsed.lines[0].syllables[0].start >= 0.99 && parsed.lines[0].syllables[0].start <= 1.01)
        #expect(parsed.lines[0].syllables.map(\.end).max() == 2)
    }

    @Test(arguments: ["config {\"style\": {\"font\": \"bad\"}", "{漢|[2|00:01:00]かん", "【@A】{漢|[00:99:00]かん}", "【@A】{漢|[00:03:00]かん[00:02:00]}"])
    func malformedAdvancedFormatsAreReportedInsteadOfBeingTokenizedAsPlainText(_ text: String) {
        #expect(throws: (any Error).self) { try LyricsDraftImport.draft(from: text) }
    }
}
