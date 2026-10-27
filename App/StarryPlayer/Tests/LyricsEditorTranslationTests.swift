import Foundation
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorTranslationTests {
    private func session() -> LyricsEditorSession {
        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "Hello ", start: 1, end: 2), .init(text: "world", start: 2, end: 3)],
                  translation: "旧译文", romanization: "hello world", singer: .secondary, isParagraphStart: true),
            .init(syllables: [.init(text: "Hello", start: 1.5, end: 3)], isBackground: true),
        ])
        return LyricsEditorSession(track: Track(id: TrackRef(source: .local, id: "translation-test"), title: "Test", artists: [], duration: 20), draft: draft)
    }

    private func response(_ session: LyricsEditorSession) throws -> String {
        let rows = session.draft.lines.map { ["id": $0.id.uuidString, "source": $0.text, "translation": "译：\($0.text)"] }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["lines": rows]), as: UTF8.self)
    }

    @Test func translationIsOneUndoableEditPreservingSelectionAndExportingBackgroundVocals() throws {
        let session = session()
        session.select(.init(line: 0, syllable: 0))
        session.extendSelection(to: .init(line: 0, syllable: 1))
        let before = session.draft
        let selection = session.selection
        let caret = session.caret
        let revision = session.revision
        let json = try response(session)
        #expect(try session.applyTranslation(json, overwrite: true).translations == 2)
        var expected = before
        expected.lines[0].translation = "译：Hello world"
        expected.lines[1].translation = "译：Hello"
        #expect(session.draft == expected)
        #expect(session.revision == revision + 1)
        #expect(session.hasUnsavedChanges)
        #expect(session.selection == selection)
        #expect(session.caret == caret)
        let exported = try LyricsParsing.parse(session.ttml(), format: .ttml)
        #expect(exported.lines[0].translation == "译：Hello world")
        #expect(exported.lines[0].background?.translation == "译：Hello")
        #expect(exported.lines[0].romanization == "hello world")
        #expect(exported.lines[0].syllables.map(\.start) == [1, 2])
        session.undo()
        #expect(session.draft == before)
        #expect(!session.canUndo)
        session.redo()
        #expect(session.draft == expected)
        let completedRevision = session.revision
        #expect(try session.applyTranslation(json, overwrite: true).isEmpty)
        #expect(session.revision == completedRevision)
    }

    @Test func invalidOrStaleResultsDoNotChangeTheDraftOrUndoHistory() throws {
        let session = session()
        let json = try response(session)
        session.edit { $0.lines[1].syllables[0].text = "Changed" }
        let before = session.draft
        let revision = session.revision
        #expect(throws: LyricsTranslation.ValidationError.changedSource(2)) { try session.applyTranslation(json, overwrite: true) }
        #expect(throws: LyricsTranslation.ValidationError.invalidFormat) { try session.applyTranslation("bad") }
        #expect(session.draft == before)
        #expect(session.revision == revision)
        session.undo()
        #expect(!session.canUndo)
        #expect(try session.applyTranslation(json).translations == 1)
        #expect(session.draft.lines[0].translation == "旧译文")
    }
}
