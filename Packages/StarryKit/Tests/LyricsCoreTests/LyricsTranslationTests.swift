import Foundation
import Testing
@testable import LyricsCore

struct LyricsTranslationTests {
    private func draft() -> LyricsDraft {
        let track = LyricsDraft.Track(name: "主唱")
        return LyricsDraft(lines: [
            .init(syllables: [.init(text: "Hello ", start: 1, end: 2), .init(text: "\"world\" 🌟", start: 2, end: 3)],
                  translation: "旧译文", romanization: "hello world", singer: .secondary, isParagraphStart: true, track: track.id),
            .init(syllables: [.init(text: "Hello ", start: 1.5, end: 2), .init(text: "\"world\" 🌟", start: 2, end: 3)], isBackground: true),
            .init(syllables: []),
            .init(syllables: [.init(text: "星空", start: 5, end: 7)], translation: "  \t", isParagraphStart: true),
        ], metadata: ["title": "Test"], tracks: [track])
    }

    private func rows(_ draft: LyricsDraft) -> [[String: Any]] {
        draft.lines.filter(LyricsTranslation.isTranslatable).enumerated().map { index, line in
            ["id": line.id.uuidString, "source": line.text, "translation": "译文 \(index + 1)"]
        }
    }

    private func response(_ rows: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["lines": rows]), as: UTF8.self)
    }

    @Test func promptPreservesEverySourceAndVocalContextAndIncludesPreferences() throws {
        let draft = draft()
        let prompt = try LyricsTranslation.prompt(for: draft, language: "English", style: .lyrical,
                                                  instructions: "保留人名", title: "Test song", artist: "Artist")
        #expect(prompt.contains("English"))
        #expect(prompt.contains(LyricsTranslation.Style.lyrical.guidance))
        #expect(prompt.contains("保留人名"))
        #expect(prompt.contains("Test song"))
        #expect(prompt.contains("Artist"))
        let start = try #require(prompt.firstIndex(of: "{"))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(prompt[start...].utf8)) as? [String: Any])
        let rows = try #require(payload["lines"] as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(rows.compactMap { $0["source"] as? String } == draft.lines.filter(LyricsTranslation.isTranslatable).map(\.text))
        #expect(rows[1]["isBackground"] as? Bool == true)
        #expect(rows[2]["isParagraphStart"] as? Bool == true)
        #expect(rows.allSatisfy { $0["translation"] as? String == "" })
        #expect(throws: LyricsTranslation.ValidationError.emptyTranslation(1)) {
            try LyricsTranslation.parse(String(prompt[start...]), for: draft)
        }
        #expect(throws: LyricsTranslation.ValidationError.noLanguage) {
            try LyricsTranslation.prompt(for: draft, language: " \n ")
        }
        #expect(throws: LyricsTranslation.ValidationError.noLyrics) {
            try LyricsTranslation.prompt(for: LyricsDraft(lines: [.init(syllables: [.init(text: " ")])]))
        }
    }

    @Test func matchesRepeatedLyricsByIDAndAcceptsMarkdownFencesAndReorderedResponses() throws {
        let draft = draft()
        var rows = rows(draft)
        rows[0]["translation"] = "  你好，世界  "
        let json = try response(rows.reversed())
        for text in [json, "\u{FEFF}\n```json\r\n\(json)\r\n```\n", "```\n\(json)\n```"] {
            let entries = try LyricsTranslation.parse(text, for: draft)
            #expect(entries.map(\.id) == draft.lines.filter(LyricsTranslation.isTranslatable).map(\.id))
            #expect(entries.map(\.lineNumber) == [1, 2, 4])
            #expect(entries.map(\.translation) == ["你好，世界", "译文 2", "译文 3"])
        }
        var reordered = draft
        reordered.lines.swapAt(0, 3)
        let entries = try LyricsTranslation.parse(json, for: reordered)
        #expect(entries.first?.id == draft.lines[3].id)
        #expect(entries.first?.translation == "译文 3")
    }

    @Test func rejectsMissingDuplicateUnknownChangedBlankAndMultilineRows() throws {
        let draft = draft()
        let original = rows(draft)
        var bad = original
        bad.removeLast()
        #expect(throws: LyricsTranslation.ValidationError.missingLines(1)) { try LyricsTranslation.parse(response(bad), for: draft) }
        bad = original + [original[0]]
        #expect(throws: LyricsTranslation.ValidationError.duplicateLine(1)) { try LyricsTranslation.parse(response(bad), for: draft) }
        bad = original
        bad[0]["id"] = UUID().uuidString
        #expect(throws: LyricsTranslation.ValidationError.unknownLine) { try LyricsTranslation.parse(response(bad), for: draft) }
        bad = original
        bad[1]["source"] = "changed"
        #expect(throws: LyricsTranslation.ValidationError.changedSource(2)) { try LyricsTranslation.parse(response(bad), for: draft) }
        bad = original
        bad[2]["translation"] = " \n "
        #expect(throws: LyricsTranslation.ValidationError.emptyTranslation(4)) { try LyricsTranslation.parse(response(bad), for: draft) }
        bad[2]["translation"] = "one\ntwo"
        #expect(throws: LyricsTranslation.ValidationError.multilineTranslation(4)) { try LyricsTranslation.parse(response(bad), for: draft) }
        for text in ["", "translation", "{\"lines\": [", "Here is the result:\n\(try response(original))", "{\"lines\": null}"] {
            #expect(throws: LyricsTranslation.ValidationError.invalidFormat) { try LyricsTranslation.parse(text, for: draft) }
        }
    }

    @Test func appliesOnlyTranslationsAndCanPreserveOrReplaceExistingOnes() throws {
        var draft = draft()
        let original = draft
        let json = try response(rows(draft))
        let changes = try LyricsTranslation.apply(json, to: &draft)
        #expect(changes.translations == 2 && changes.romanizations == 0 && changes.rubies == 0)
        #expect(changes.lines == [original.lines[1].id, original.lines[3].id])
        var expected = original
        expected.lines[1].translation = "译文 2"
        expected.lines[3].translation = "译文 3"
        #expect(draft == expected)
        #expect(try LyricsTranslation.apply(json, to: &draft).isEmpty)
        #expect(try LyricsTranslation.apply(json, to: &draft, overwrite: true).translations == 1)
        expected.lines[0].translation = "译文 1"
        #expect(draft == expected)
    }

    private func japanese() -> LyricsDraft {
        LyricsDraft(lines: [
            .init(syllables: [.init(text: "所", start: 1, end: 1.4), .init(text: "詮", start: 1.4, end: 1.8, ruby: [.init(text: "せん")]),
                              .init(text: "は", start: 1.8, end: 2), .init(text: "夢 ", start: 2, end: 2.5), .init(text: "だ")]),
            .init(syllables: [.init(text: "Hello ", start: 3, end: 3.5), .init(text: "world", start: 3.5, end: 4)], romanization: "kept"),
        ])
    }

    private func readings(_ draft: LyricsDraft, ruby: [[String]], romanization: [String]) throws -> String {
        let rows: [[String: Any]] = draft.lines.enumerated().map { index, line in
            var row: [String: Any] = ["id": line.id.uuidString, "source": line.text, "romanization": romanization[index]]
            if !ruby[index].isEmpty {
                row["syllables"] = zip(line.syllables, ruby[index]).map { ["text": $0.text.trimmingCharacters(in: .whitespaces), "ruby": $1] }
            }
            return row
        }
        return try response(rows)
    }

    @Test func promptsForRomanizationAndRubyWithoutTranslating() throws {
        let draft = japanese()
        let prompt = try LyricsTranslation.prompt(for: draft, fields: [.romanization, .ruby], language: "", rubyScript: "片假名")
        let start = try #require(prompt.firstIndex(of: "{"))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(prompt[start...].utf8)) as? [String: Any])
        let rows = try #require(payload["lines"] as? [[String: Any]])
        #expect(rows.allSatisfy { $0["translation"] == nil && $0["romanization"] as? String == "" })
        let syllables = try #require(rows[0]["syllables"] as? [[String: Any]])
        #expect(syllables.compactMap { $0["text"] as? String } == ["所", "詮", "は", "夢", "だ"])
        #expect(rows[1]["syllables"] == nil)
        #expect(throws: LyricsTranslation.ValidationError.noFields) { try LyricsTranslation.prompt(for: draft, fields: []) }
        #expect(throws: LyricsTranslation.ValidationError.noLanguage) { try LyricsTranslation.prompt(for: draft, fields: [.translation, .ruby], language: " ") }
    }

    @Test func appliesRomanizationAndRubyToBlanksOnly() throws {
        var draft = japanese()
        let original = draft
        let json = try readings(draft, ruby: [["しょ", "ぜん", "わ", "ゆめ", "だ"], []], romanization: ["shosen wa yume da", "  "])
        let entries = try LyricsTranslation.parse(json, for: draft, fields: [.romanization, .ruby])
        #expect(entries.map(\.translation) == [nil, nil])
        #expect(entries.map(\.ruby) == [["しょ", "ぜん", "わ", "ゆめ", "だ"], nil])
        let changes = LyricsTranslation.apply(entries, to: &draft)
        #expect(changes.romanizations == 1 && changes.rubies == 2 && changes.translations == 0)
        #expect(changes.lines == [original.lines[0].id])
        #expect(draft.lines[0].romanization == "shosen wa yume da")
        #expect(draft.lines[0].syllables.map { $0.ruby?.map(\.text) } == [["しょ"], ["せん"], nil, ["ゆめ"], nil])
        #expect(draft.lines[1] == original.lines[1])
        let replaced = try LyricsTranslation.apply(json, to: &draft, fields: [.romanization, .ruby], overwrite: true)
        #expect(replaced.rubies == 1 && replaced.romanizations == 0)
        #expect(draft.lines[0].syllables[1].ruby == [.init(text: "ぜん")])
        #expect(try LyricsTranslation.parse(json, for: draft, fields: [.ruby]).map(\.romanization) == [nil, nil])
    }

    @Test func rejectsChangedSyllablesAndMultilineReadings() throws {
        let draft = japanese()
        let fields: LyricsTranslation.Fields = [.romanization, .ruby]
        var json = try readings(draft, ruby: [["しょ", "せん", "", "ゆめ"], []], romanization: ["", ""])
        #expect(throws: LyricsTranslation.ValidationError.changedSyllables(1)) { try LyricsTranslation.parse(json, for: draft, fields: fields) }
        json = try readings(draft, ruby: [[], []], romanization: ["", ""])
        #expect(throws: LyricsTranslation.ValidationError.changedSyllables(1)) { try LyricsTranslation.parse(json, for: draft, fields: fields) }
        json = try readings(draft, ruby: [["しょ", "せ\nん", "", "", ""], []], romanization: ["", ""])
        #expect(throws: LyricsTranslation.ValidationError.multilineRuby(1)) { try LyricsTranslation.parse(json, for: draft, fields: fields) }
        json = try readings(draft, ruby: [["", "", "", "", ""], []], romanization: ["", "hello\nworld"])
        #expect(throws: LyricsTranslation.ValidationError.multilineRomanization(2)) { try LyricsTranslation.parse(json, for: draft, fields: fields) }
        json = try readings(draft, ruby: [["", "", "", "", ""], []], romanization: ["", ""])
        #expect(throws: LyricsTranslation.ValidationError.emptyTranslation(1)) { try LyricsTranslation.parse(json, for: draft, fields: [.translation, .ruby]) }
        #expect(throws: LyricsTranslation.ValidationError.noFields) { try LyricsTranslation.parse(json, for: draft, fields: []) }
    }

    @Test func aLateValidationFailureCannotPartiallyApplyAndTimingEditsAreAllowed() throws {
        var draft = draft()
        var bad = rows(draft)
        bad[2]["translation"] = ""
        let original = draft
        #expect(throws: LyricsTranslation.ValidationError.emptyTranslation(4)) {
            try LyricsTranslation.apply(response(bad), to: &draft, overwrite: true)
        }
        #expect(draft == original)
        let json = try response(rows(draft))
        draft.lines[0].syllables[0].start = 0.5
        #expect(try LyricsTranslation.apply(json, to: &draft, overwrite: true).translations == 3)
        #expect(draft.lines[0].syllables[0].start == 0.5)
        draft.lines[3].syllables[0].text = "edited"
        let edited = draft
        #expect(throws: LyricsTranslation.ValidationError.changedSource(4)) {
            try LyricsTranslation.apply(json, to: &draft, overwrite: true)
        }
        #expect(draft == edited)
    }
}
