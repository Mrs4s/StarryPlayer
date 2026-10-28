import Foundation
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorRolesTests {
    private func session(_ text: String = "我爱你\n再见\n晚安") throws -> LyricsEditorSession {
        let track = Track(id: TrackRef(source: .local, id: "song"), title: "Song", artists: [ArtistRef(id: "a", name: "A")], duration: 200)
        let session = LyricsEditorSession(track: track)
        session.replace(with: try LyricsDraftImport.draft(from: text))
        session.markSaved()
        return session
    }

    @Test func roleEditsAreUndoableAndMarkTheSessionUnsaved() throws {
        let session = try session()
        let line = session.draft.lines[1].id
        let alice = session.addAgent(kind: .person)
        #expect(session.hasUnsavedChanges)
        session.setAgents([alice], ofLines: [line])
        #expect(session.draft.lines[1].agentIDs == [alice])

        session.undo()
        #expect(session.draft.lines[1].agentIDs.isEmpty)
        #expect(session.draft.agents.map(\.id) == [alice])
        session.undo()
        #expect(session.draft.agents.isEmpty)
        session.redo()
        session.redo()
        #expect(session.draft.lines[1].agentIDs == [alice])

        session.removeAgent(alice)
        #expect(session.draft.lines[1].agentIDs.isEmpty)
        session.undo()
        #expect(session.draft.agents.map(\.id) == [alice])
        #expect(session.draft.lines[1].agentIDs == [alice])
    }

    @Test func selectedSyllablesCanBeSungByAnotherRole() throws {
        let session = try session()
        let alice = session.addAgent(kind: .person)
        let bob = session.addAgent(kind: .person)
        session.setAgents([alice], ofLines: [session.draft.lines[0].id])
        session.select(.init(line: 0, syllable: 1))
        session.extendSelection(to: .init(line: 0, syllable: 2))
        session.setAgents([bob], at: session.selectedPositions)
        #expect(session.draft.lines[0].syllables.map(\.agentIDs) == [[], [bob], [bob]])
        #expect(session.draft.lines[0].agentIDs == [alice])
        session.setAgents([], at: session.selectedPositions)
        #expect(session.draft.lines[0].syllables.allSatisfy { $0.agentIDs.isEmpty })
    }
}
