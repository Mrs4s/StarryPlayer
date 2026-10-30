import Foundation
import Testing
@testable import LyricsCore

struct SharedRubyTests {
    static let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttx="urn:ttml:extensions:shared-ruby:1"><body><div>
      <p begin="00:10.000" end="00:11.500"><span begin="00:10.000" end="00:10.500" ttx:rubyGroup="1" ttx:rubyText="des|ti|ny" ttx:rubyTimes="00:10.000,00:10.300 00:10.300,00:10.600 00:10.600,00:11.200">運</span><span begin="00:10.500" end="00:11.200" ttx:rubyGroup="1">命</span><span begin="00:11.200" end="00:11.500">を</span></p>
    </div></body></tt>
    """

    @Test func sharedRubyCoversItsRunAndEverySyllableKeepsItsTiming() throws {
        let line = try #require(try TTMLParser.parse(Self.ttml).lines.first)
        #expect(line.text == "運命を")
        let syllables = line.syllables
        #expect(syllables.map(\.start) == [10, 10.5, 11.2])
        #expect(syllables[0].groupRuby == [LyricRuby(start: 10, end: 10.3, text: "des"), LyricRuby(start: 10.3, end: 10.6, text: "ti"), LyricRuby(start: 10.6, end: 11.2, text: "ny")])
        #expect(syllables.map(\.joinsRubyGroup) == [false, true, false])
        #expect(syllables.allSatisfy { $0.ruby.isEmpty })
        #expect(LyricRubyGroup.groups(in: syllables).map(\.syllables) == [0...1])
        #expect(line.hasRuby)
    }

    @Test func sharedRubyNamespaceDoesNotDependOnItsPrefix() throws {
        let renamed = Self.ttml.replacingOccurrences(of: "xmlns:ttx=", with: "xmlns:shared=")
            .replacingOccurrences(of: "ttx:", with: "shared:")
        let expected = try TTMLParser.parse(Self.ttml)
        #expect(try TTMLParser.parse(renamed).lines.map(\.syllables) == expected.lines.map(\.syllables))
    }

    @Test func unreadableSharedRubyIsIgnoredWhole() throws {
        let reused = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttx="urn:ttml:extensions:shared-ruby:1"><body><div><p begin="1s" end="4s"><span begin="1s" end="2s" ttx:rubyGroup="a" ttx:rubyText="x">A</span><span begin="2s" end="3s">B</span><span begin="3s" end="4s" ttx:rubyGroup="a">C</span></p></div></body></tt>
        """
        for ttml in [
            Self.ttml.replacingOccurrences(of: "des|ti|ny", with: "des|tiny"),
            Self.ttml.replacingOccurrences(of: "des|ti|ny", with: "des||ny"),
            Self.ttml.replacingOccurrences(of: "00:10.300,00:10.600", with: "00:10.600,00:10.300"),
            Self.ttml.replacingOccurrences(of: "urn:ttml:extensions:shared-ruby:1", with: "urn:example:other"),
            reused,
        ] {
            let line = try #require(try TTMLParser.parse(ttml).lines.first)
            #expect(!line.hasRuby)
            #expect(line.syllables.allSatisfy { !$0.joinsRubyGroup })
        }
    }

    @Test func untimedSharedRubySpreadsOverItsRun() throws {
        let ttml = Self.ttml.replacingOccurrences(of: #" ttx:rubyTimes="[^"]*""#, with: "", options: .regularExpression)
        let ruby = try #require(try TTMLParser.parse(ttml).lines.first).syllables[0].groupRuby
        #expect(ruby.map(\.text) == ["des", "ti", "ny"])
        #expect(ruby.first?.start == 10 && abs((ruby.last?.end ?? 0) - 11.2) < 1e-9)
    }

    @Test(arguments: [TTMLWriter.Format.amll, .ttml2])
    func writtenSharedRubyReadsBackTheSame(format: TTMLWriter.Format) throws {
        let document = try TTMLParser.parse(Self.ttml)
        let written = TTMLWriter.write(document, format: format)
        #expect(try TTMLParser.parse(written).lines.map(\.syllables) == document.lines.map(\.syllables))
    }

    @Test(arguments: [TTMLWriter.Format.amll, .ttml2])
    func sharedRubyKeepsTheWordBreaksOfItsReadingAndEscapesSeparators(format: TTMLWriter.Format) throws {
        var syllables = [("永遠", 1.0, 2.0), ("の", 2.0, 2.5), ("愛", 2.5, 3.0)].map { LyricSyllable(start: $0.1, end: $0.2, text: $0.0) }
        syllables[0].groupRuby = LyricRuby.spread(["eternal ", #"lo|ve\"#], start: 1, end: 3)
        syllables[1].joinsRubyGroup = true
        syllables[2].joinsRubyGroup = true
        let line = LyricLine(id: 0, start: 1, end: 3, words: LyricWordGrouping.words(from: syllables))
        let written = TTMLWriter.write(LyricsDocument(format: .ttml, lines: [line]), format: format)
        let parsed = try #require(try TTMLParser.parse(written).lines.first)
        #expect(parsed.syllables[0].groupRuby.map(\.text) == ["eternal ", #"lo|ve\"#])
        #expect(parsed.syllables.map(\.joinsRubyGroup) == [false, true, true])
    }

    @Test func aRunOfOneIsPlainRuby() {
        var syllables = [LyricSyllable(start: 0, end: 1, text: "今日"), LyricSyllable(start: 1, end: 2, text: "は")]
        syllables[0].groupRuby = [LyricRuby(start: 0, end: 1, text: "きょう")]
        let normalized = LyricRubyGroup.normalized(syllables)
        #expect(normalized[0].ruby == [LyricRuby(start: 0, end: 1, text: "きょう")] && normalized[0].groupRuby.isEmpty)
        #expect(LyricRubyGroup.normalized([LyricSyllable(start: 0, end: 1, text: "は", joinsRubyGroup: true)])[0].joinsRubyGroup == false)
    }

    // MARK: Draft

    private func positions(_ syllables: Int...) -> [LyricsDraft.Position] { syllables.map { .init(line: 0, syllable: $0) } }

    private func eternalLove() -> LyricsDraft {
        var draft = LyricsDraft(lines: [.init(syllables: [
            .init(text: "永遠", start: 1, end: 2), .init(text: "の", start: 2, end: 2.5), .init(text: "愛", start: 2.5, end: 3), .init(text: "を", start: 3, end: 4),
        ])])
        draft.setGroupRuby(" eternal |love ", over: positions(0, 1, 2))
        return draft
    }

    @Test func draftsShareRubyOverARunAndMakeLyricsOfIt() throws {
        let draft = eternalLove()
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 1)) == 0...2)
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 3)) == nil)
        #expect(draft.lines[0].syllables[0].groupRuby?.map(\.text) == ["eternal ", "love"])
        #expect(draft.editableRuby(at: .init(line: 0, syllable: 2)) == "eternal |love")
        let syllables = draft.document().lines[0].syllables
        #expect(syllables.map(\.joinsRubyGroup) == [false, true, true, false])
        #expect(syllables[0].groupRuby.first?.start == 1 && syllables[0].groupRuby.last?.end == 3)
        let back = LyricsDraft(document: draft.document())
        #expect(back.lines[0].syllables.map { $0.groupRuby?.map(\.text) } == [["eternal ", "love"], nil, nil, nil])
        #expect(back.lines[0].syllables.map(\.joinsRubyGroup) == [false, true, true, false])
        let project = try LyricsProject(data: LyricsProject(draft: draft).data())
        #expect(project.draft == draft)
    }

    @Test func splittingAndMergingInsideTheRunKeepItsRuby() {
        var draft = eternalLove()
        #expect(!draft.canMergeSyllables(positions(2, 3)))
        draft.mergeWithNext(at: .init(line: 0, syllable: 2))
        #expect(draft.lines[0].syllables.count == 4)
        draft.splitSyllable(at: .init(line: 0, syllable: 0))
        #expect(draft.lines[0].syllables.map(\.text) == ["永", "遠", "の", "愛", "を"])
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 0)) == 0...3)
        #expect(draft.mergeSyllables(positions(0, 1, 2, 3)) != nil)
        #expect(draft.lines[0].syllables[0].text == "永遠の愛")
        #expect(draft.lines[0].syllables[0].ruby?.map(\.text) == ["eternal ", "love"])
        #expect(draft.lines[0].syllables[0].groupRuby == nil)
    }

    @Test func editsThatBreakTheRunRemoveItsRuby() {
        var draft = eternalLove()
        draft.setText("永遠|の|哀|を", ofLine: 0)
        #expect(draft.lines[0].syllables.allSatisfy { $0.groupRuby == nil && $0.ruby == nil && !$0.joinsRubyGroup })

        draft = eternalLove()
        draft.setText("永遠|の|愛|に", ofLine: 0)
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 0)) == 0...2)

        draft = eternalLove()
        draft.removeSyllables(positions(1))
        #expect(draft.lines[0].syllables.allSatisfy { $0.groupRuby == nil && !$0.joinsRubyGroup })

        draft = eternalLove()
        let line = draft.moveSyllablesToNewLine(positions(0, 1, 2))
        #expect(line == 1 && draft.lines.map(\.text) == ["を", "永遠の愛"])
        #expect(draft.rubyGroup(at: .init(line: 1, syllable: 0)) == 0...2)

        draft = eternalLove()
        draft.setRuby("あい", at: .init(line: 0, syllable: 2))
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 0)) == nil)
        #expect(draft.lines[0].syllables[2].ruby?.map(\.text) == ["あい"])

        draft = eternalLove()
        draft.clearRuby(at: positions(1))
        #expect(!(0..<4).contains { draft.hasRuby(at: .init(line: 0, syllable: $0)) })
    }

    @Test func aNewRunReplacesTheRunsItOverlaps() {
        var draft = eternalLove()
        draft.setGroupRuby("あいを", over: positions(2, 3))
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 0)) == nil)
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 3)) == 2...3)
        #expect(draft.lines[0].syllables[0].ruby == nil)
        draft.setGroupRuby("", over: positions(2, 3))
        #expect(!(0..<4).contains { draft.hasRuby(at: .init(line: 0, syllable: $0)) })
    }

    // MARK: AI ruby

    private func today() -> LyricsDraft {
        LyricsDraft(lines: [.init(syllables: [.init(text: "今", start: 1, end: 1.3), .init(text: "日", start: 1.3, end: 1.6), .init(text: "は", start: 1.6, end: 2)])])
    }

    private func response(_ draft: LyricsDraft, _ syllables: [[String: Any]]) throws -> String {
        let row: [String: Any] = ["id": draft.lines[0].id.uuidString, "source": draft.lines[0].text, "syllables": syllables]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["lines": [row]]), as: UTF8.self)
    }

    @Test func aiRubySharedByARunGoesOverTheRun() throws {
        var draft = today()
        let json = try response(draft, [["text": "今", "ruby": "きょう"], ["text": "日", "ruby": "", "joinsPrevious": true], ["text": "は", "ruby": ""]])
        let entries = try LyricsTranslation.parse(json, for: draft, fields: [.ruby])
        #expect(entries.map(\.rubyJoins) == [[false, true, false]])
        let changes = try LyricsTranslation.apply(json, to: &draft, fields: [.ruby])
        #expect(changes.rubies == 2)
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 1)) == 0...1)
        #expect(draft.editableRuby(at: .init(line: 0, syllable: 0)) == "きょう")
        let again = try response(draft, [["text": "今", "ruby": "いま"], ["text": "日", "ruby": "ひ"], ["text": "は", "ruby": ""]])
        #expect(try LyricsTranslation.apply(again, to: &draft, fields: [.ruby]).rubies == 0)
        #expect(try LyricsTranslation.apply(again, to: &draft, fields: [.ruby], overwrite: true).rubies == 2)
        #expect(draft.rubyGroup(at: .init(line: 0, syllable: 0)) == nil)
        #expect(draft.lines[0].syllables.map { $0.ruby?.map(\.text) } == [["いま"], ["ひ"], nil])
    }

    @Test func aiRubyJoiningNothingIsRejected() throws {
        let draft = today()
        for syllables: [[String: Any]] in [
            [["text": "今", "ruby": "", "joinsPrevious": true], ["text": "日", "ruby": ""], ["text": "は", "ruby": ""]],
            [["text": "今", "ruby": "きょう"], ["text": "日", "ruby": "う", "joinsPrevious": true], ["text": "は", "ruby": ""]],
            [["text": "今", "ruby": ""], ["text": "日", "ruby": "", "joinsPrevious": true], ["text": "は", "ruby": ""]],
        ] {
            #expect(throws: LyricsTranslation.ValidationError.brokenRubyGroup(1)) {
                try LyricsTranslation.parse(response(draft, syllables), for: draft, fields: [.ruby])
            }
        }
    }

    @Test func exportsThatCannotKeepSharedRubySayTheyDropIt() throws {
        let draft = eternalLove()
        #expect(try LyricsExport.write(draft, format: .krl).losses.contains(.sharedRuby))
        #expect(try LyricsExport.write(draft, format: .lrcWord).losses.contains(.ruby))
        #expect(try LyricsExport.write(draft, format: .ttml).losses.isEmpty)
    }
}
