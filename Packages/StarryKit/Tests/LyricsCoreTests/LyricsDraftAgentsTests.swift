import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricsDraftAgentsTests {
    private func draft() -> LyricsDraft {
        LyricsDraft(lines: [
            .init(syllables: [.init(text: "A", start: 1, end: 2), .init(text: "B", start: 2, end: 3)]),
            .init(syllables: [.init(text: "C", start: 4, end: 5)], singer: .secondary),
            .init(syllables: [.init(text: "D", start: 6, end: 7)], singer: .duet),
        ])
    }

    @Test func newRolesGetUnusedIDsAndKeepOtherNames() {
        var draft = draft()
        draft.lines[0].agentIDs = ["v1"]
        let alice = draft.addAgent(name: "  Alice ")
        #expect(alice.id == "v2")
        var renamed = alice
        renamed.names.append(.init("アリス", kind: .full, language: "ja"))
        renamed.setName("A", kind: .alias)
        renamed.setName("Alicia")
        #expect(renamed.names == [.init("Alicia"), .init("アリス", language: "ja"), .init("A", kind: .alias)])
    }

    @Test func reorderingAndRegroupingKeepTheAssignedDisplayPositions() {
        var draft = draft()
        let alice = draft.addAgent(name: "Alice").id
        let bob = draft.addAgent(name: "Bob").id
        draft.setAgents([alice], ofLine: 0)
        draft.setAgents([bob], ofLine: 1)
        draft.moveAgent(bob, to: 0)
        #expect(draft.lines[0].singer == .primary)
        #expect(draft.lines[1].singer == .secondary)
        var group = draft.agents[0]
        group.kind = .group
        draft.updateAgent(group)
        #expect(draft.lines[1].singer == .secondary)
        #expect(draft.lines[0].singer == .primary)
    }

    @Test func inlineChangesFollowTheLineAgainAndAWholeLineIsPromoted() {
        var draft = draft()
        let alice = draft.addAgent(name: "Alice").id
        let bob = draft.addAgent(name: "Bob").id
        draft.setAgents([alice], ofLine: 0)
        draft.setAgents([bob], at: [.init(line: 0, syllable: 1)])
        #expect(draft.lines[0].syllables.map(\.agentIDs) == [[], [bob]])
        #expect(draft.agentIDs(at: .init(line: 0, syllable: 0)) == [alice])
        #expect(draft.usage(of: bob).lines == 0)
        #expect(draft.usage(of: bob).syllables == 1)
        draft.setAgents([alice], at: [.init(line: 0, syllable: 1)])
        #expect(draft.lines[0].syllables.allSatisfy { $0.agentIDs.isEmpty })

        draft.setAgents([bob], at: [.init(line: 0, syllable: 0), .init(line: 0, syllable: 1)])
        #expect(draft.lines[0].agentIDs == [bob])
        #expect(draft.lines[0].singer == .primary)
        #expect(draft.lines[0].syllables.allSatisfy { $0.agentIDs.isEmpty })
    }

    @Test func removingARoleUnassignsOnlyWhatItSangAlone() {
        var draft = draft()
        let alice = draft.addAgent(name: "Alice").id
        let bob = draft.addAgent(name: "Bob").id
        let hero = draft.addAgent(kind: .character, name: "Hero")
        var played = hero
        played.actorID = bob
        draft.updateAgent(played)
        draft.setAgents([alice], ofLine: 0)
        draft.setAgents([bob], at: [.init(line: 0, syllable: 1)])
        draft.setAgents([bob], ofLine: 1)
        draft.setAgents([alice, bob], ofLine: 2)
        draft.removeAgent(bob)
        #expect(draft.agents.map(\.id) == [alice, hero.id])
        #expect(draft.agents[1].actorID == nil)
        #expect(draft.lines.map(\.agentIDs) == [[alice], [], [alice]])
        #expect(draft.lines.map(\.singer) == [.primary, .secondary, .duet])
        #expect(draft.lines[0].syllables.allSatisfy { $0.agentIDs.isEmpty })
    }

    @Test func legacySingersBecomeRolesWithTheSamePresentation() {
        var draft = draft()
        let assigned = draft.assignUnassignedLinesBySinger(names: [.primary: "主唱", .secondary: "对唱", .duet: "合唱"])
        #expect(assigned == 3)
        #expect(draft.agents.map(\.displayName) == ["主唱", "对唱", "合唱"])
        #expect(draft.agents.map(\.kind) == [.person, .person, .group])
        #expect(draft.lines.map(\.singer) == [.primary, .secondary, .duet])
        #expect(draft.assignUnassignedLinesBySinger(names: [:]) == 0)
    }
}
