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

    @Test func colorChangesCoalesceAndUndoSeparatelyForEachRole() throws {
        let session = try session()
        let alice = session.addAgent(kind: .person)
        let bob = session.addAgent(kind: .person)
        let palette = LyricColor.performerPalette
        for hex in ["#112233", "#223344", "#334455"] { session.setColor(LyricColor(hex: hex), ofAgent: alice) }
        #expect(session.draft.agents[0].color == LyricColor(hex: "#334455"))
        session.undo()
        #expect(session.draft.agents[0].color == palette[0])
        session.setColor(nil, ofAgent: bob)
        session.setColor(nil, ofAgent: alice)
        #expect(session.draft.agents.map(\.color) == [nil, nil])
        session.undo()
        #expect(session.draft.agents.map(\.color) == [palette[0], nil])
    }

    @Test func groupMembersToggleAndLeaveWithTheirRole() throws {
        let session = try session()
        let alice = session.addAgent(kind: .person)
        let group = session.addAgent(kind: .group)
        session.toggleMember(alice, ofGroup: group)
        session.toggleMember(group, ofGroup: group)
        #expect(session.draft.agents[1].memberIDs == [alice])
        session.removeAgent(alice)
        #expect(session.draft.agents[0].memberIDs.isEmpty)
        session.undo()
        #expect(session.draft.agents[1].memberIDs == [alice])
        session.toggleMember(alice, ofGroup: group)
        #expect(session.draft.agents[1].memberIDs.isEmpty)
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

    @Test func selectingAllCoSingersIsOneUndoStepAndKeepsDisplayPosition() throws {
        let session = try session()
        let alice = session.addAgent(kind: .person)
        let bob = session.addAgent(kind: .person)
        let group = session.addAgent(kind: .group)
        let line = session.draft.lines[0].id
        session.setDisplayPosition(.secondary, ofLines: [line])
        session.setAgents([alice], ofLines: [line])
        session.setAgents([bob], at: [.init(line: 0, syllable: 1)])

        session.selectAllAgents(ofLine: line)
        #expect(session.draft.lines[0].agentIDs == [alice, bob, group])
        #expect(session.draft.lines[0].singer == .secondary)
        #expect(session.draft.lines[0].syllables[1].agentIDs == [bob])
        session.undo()
        #expect(session.draft.lines[0].agentIDs == [alice])
        session.redo()
        #expect(session.draft.lines[0].agentIDs == [alice, bob, group])

        session.setAgents([], ofLines: [line])
        #expect(session.draft.lines[0].agentIDs.isEmpty)
        #expect(session.draft.lines[0].singer == .secondary)
        #expect(session.draft.lines[0].syllables[1].agentIDs == [bob])
    }

    @Test func displayPositionAndPerformersHaveIndependentUndoSteps() throws {
        let session = try session()
        let alice = session.addAgent(kind: .person)
        let bob = session.addAgent(kind: .person)
        let line = session.draft.lines[0].id
        session.setAgents([alice, bob], ofLines: [line])
        #expect(session.draft.lines[0].singer == .primary)
        session.setDisplayPosition(.duet, ofLines: [line])
        #expect(session.draft.lines[0].agentIDs == [alice, bob])
        session.moveAgent(bob, by: -1)
        #expect(session.draft.lines[0].singer == .duet)
        session.undo()
        session.undo()
        #expect(session.draft.lines[0].singer == .primary)
        #expect(session.draft.lines[0].agentIDs == [alice, bob])
        session.undo()
        #expect(session.draft.lines[0].agentIDs.isEmpty)
    }
}
