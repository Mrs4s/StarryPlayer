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
        #expect(try LyricsTranslation.apply(json, to: &draft) == 2)
        var expected = original
        expected.lines[1].translation = "译文 2"
        expected.lines[3].translation = "译文 3"
        #expect(draft == expected)
        #expect(try LyricsTranslation.apply(json, to: &draft) == 0)
        #expect(try LyricsTranslation.apply(json, to: &draft, overwrite: true) == 1)
        expected.lines[0].translation = "译文 1"
        #expect(draft == expected)
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
        #expect(try LyricsTranslation.apply(json, to: &draft, overwrite: true) == 3)
        #expect(draft.lines[0].syllables[0].start == 0.5)
        draft.lines[3].syllables[0].text = "edited"
        let edited = draft
        #expect(throws: LyricsTranslation.ValidationError.changedSource(4)) {
            try LyricsTranslation.apply(json, to: &draft, overwrite: true)
        }
        #expect(draft == edited)
    }
}
