import Foundation
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorRomanizationTests {
    private func session() -> LyricsEditorSession {
        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "星", start: 1, end: 2), .init(text: "空", start: 2, end: 3)], translation: "星空", singer: .secondary),
            .init(syllables: [.init(text: "コーヒー", start: 1, end: 3)], romanization: "my reading", isBackground: true),
            .init(syllables: [.init(text: "Hello", start: 4, end: 5)]),
        ], metadata: ["title": "Test"])
        return LyricsEditorSession(track: Track(id: TrackRef(source: .local, id: "romanization-test"), title: "Test", artists: [], duration: 20), draft: draft)
    }

    @Test func fillsMissingReadingsAsOneUndoableEditAndExportsThem() async throws {
        let session = session()
        session.select(.init(line: 0, syllable: 0))
        session.extendSelection(to: .init(line: 0, syllable: 1))
        let before = session.draft
        let caret = session.caret
        let selection = session.selection
        let revision = session.revision
        await session.generateJapaneseRomanization()
        var expected = before
        expected.lines[0].romanization = "hoshizora"
        #expect(session.draft == expected)
        #expect(session.revision == revision + 1)
        #expect(session.hasUnsavedChanges)
        #expect(session.caret == caret)
        #expect(session.selection == selection)
        #expect(!session.isGeneratingRomanization)
        #expect(session.document.lines[0].romanization == "hoshizora")
        let exported = try LyricsParsing.parse(session.ttml(), format: .ttml)
        #expect(exported.lines[0].romanization == "hoshizora")
        #expect(exported.lines[0].background?.romanization == "my reading")
        #expect(exported.lines[0].syllables.map(\.start) == [1, 2])
        session.undo()
        #expect(session.draft == before)
        #expect(!session.canUndo)
        session.redo()
        #expect(session.draft == expected)
        let completedRevision = session.revision
        await session.generateJapaneseRomanization()
        #expect(session.revision == completedRevision)
    }

    @Test func singleLineCanRegenerateBackgroundVocalsWithoutChangingOtherLines() async {
        let session = session()
        let before = session.draft
        await session.generateJapaneseRomanization(for: before.lines[1].id, overwrite: true)
        var expected = before
        expected.lines[1].romanization = "kōhī"
        #expect(session.draft == expected)
        session.undo()
        #expect(session.draft == before)
        await session.generateJapaneseRomanization(overwrite: true)
        expected.lines[0].romanization = "hoshizora"
        #expect(session.draft == expected)
    }

    @Test func whitespaceCountsAsMissingAndUnusableLinesRemainUntouched() async {
        let session = session()
        session.edit {
            $0.lines[0].romanization = " \t "
            $0.lines.append(.init(syllables: [.init(text: "𠮷𠮷𠮷")], romanization: "keep me"))
        }
        await session.generateJapaneseRomanization()
        #expect(session.draft.lines[0].romanization == "hoshizora")
        #expect(session.draft.lines[1].romanization == "my reading")
        await session.generateJapaneseRomanization(overwrite: true)
        #expect(session.draft.lines[0].romanization == "hoshizora")
        #expect(session.draft.lines[2].romanization.isEmpty)
        #expect(session.draft.lines[3].romanization == "keep me")
        let revision = session.revision
        await session.generateJapaneseRomanization(for: UUID(), overwrite: true)
        #expect(session.revision == revision)
        #expect(!session.isGeneratingRomanization)
    }
}
