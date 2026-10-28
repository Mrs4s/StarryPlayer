import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricAgentTests {
    static let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata" xmlns:tts="http://www.w3.org/ns/ttml#styling">
      <head><metadata>
        <m:agent xml:id="chorus" type="group"><m:name type="full">合唱</m:name></m:agent>
        <m:agent xml:id="alice" type="person"><m:name type="full" xml:lang="en">Alice &amp; Co.</m:name><m:name type="alias">A</m:name></m:agent>
        <m:agent xml:id="bob" type="person"><m:name type="full">Bob</m:name></m:agent>
        <m:agent xml:id="hero" type="character" xml:lang="ja"><m:name type="full">勇者</m:name><m:actor agent="alice"/></m:agent>
        <m:agent xml:id="unused" type="organization"/>
      </metadata></head>
      <body m:agent="alice"><div>
        <p begin="1s" end="4s"><span begin="1s" end="2s">One</span> <span begin="2s" end="3s" m:agent="bob hero bob">two</span><span m:role="x-bg" m:agent="chorus"><span begin="3s" end="4s">(ah)</span></span></p>
        <p begin="5s" end="6s" m:agent="hero"><span begin="5s" end="6s" tts:ruby="container" m:agent="bob"><span tts:ruby="base">空</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="5s" end="6s">そら</span></span></span></p>
        <p begin="7s" end="8s" m:agent="chorus">All</p>
      </div></body>
    </tt>
    """

    @Test func ttmlPreservesIdentitiesNamesActorsAndInheritedAssignments() throws {
        let document = try TTMLParser.parse(Self.ttml)
        #expect(document.agents.map(\.id) == ["chorus", "alice", "bob", "hero", "unused"])
        #expect(document.agents[1].names == [.init("Alice & Co.", language: "en"), .init("A", kind: .alias)])
        #expect(document.agents[1].displayName == "Alice & Co.")
        #expect(document.agents[3].kind == .character)
        #expect(document.agents[3].actorID == "alice")
        #expect(document.agents[3].names[0].language == "ja")
        #expect(document.lines.map(\.agentIDs) == [["alice"], ["hero"], ["chorus"]])
        #expect(document.lines.map(\.singer) == [.primary, .secondary, .duet])
        #expect(document.lines[0].syllables.map(\.agentIDs) == [[], ["bob", "hero"]])
        #expect(document.lines[0].background?.agentIDs == ["chorus"])
        #expect(document.lines[0].background?.syllables.first?.agentIDs == [])
        #expect(document.lines[1].syllables.first?.agentIDs == ["bob"])
        #expect(document.lines[1].syllables.first?.ruby.first?.text == "そら")

        let reparsed = try TTMLParser.parse(TTMLWriter.write(document))
        #expect(reparsed.agents == document.agents)
        #expect(reparsed.lines.map(\.agentIDs) == document.lines.map(\.agentIDs))
        #expect(reparsed.lines.flatMap(\.syllables) == document.lines.flatMap(\.syllables))
        #expect(reparsed.lines[0].background == document.lines[0].background)
    }

    @Test func editorAndProjectKeepRolesIncludingASingleRubySyllable() throws {
        let original = try TTMLParser.parse(Self.ttml)
        let draft = LyricsDraft(document: original)
        #expect(draft.agents == original.agents)
        #expect(draft.lines.map(\.agentIDs) == [["alice"], ["chorus"], ["hero"], ["chorus"]])
        #expect(draft.lines[2].syllables[0].ruby?.first?.text == "そら")
        #expect(draft.lines[2].syllables[0].agentIDs == ["bob"])
        let saved = try LyricsProject(data: LyricsProject(draft: draft).data())
        #expect(saved.version == LyricsProject.currentVersion)
        #expect(saved.draft == draft)
        let reparsed = try TTMLParser.parse(TTMLWriter.write(saved.draft.document()))
        #expect(reparsed.agents == original.agents)
        #expect(reparsed.lines.map(\.agentIDs) == original.lines.map(\.agentIDs))
        #expect(reparsed.lines.flatMap(\.syllables).map(\.agentIDs) == original.lines.flatMap(\.syllables).map(\.agentIDs))
        #expect(reparsed.lines[0].background?.agentIDs == ["chorus"])
    }

    @Test func legacySingersStillExportConventionalAMLLAgents() throws {
        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "A", start: 1, end: 2)]),
            .init(syllables: [.init(text: "B", start: 3, end: 4)], singer: .secondary),
            .init(syllables: [.init(text: "C", start: 5, end: 6)], singer: .duet),
        ])
        let parsed = try TTMLParser.parse(TTMLWriter.write(draft.document()))
        #expect(parsed.agents.map(\.id) == ["v1", "v2", "v1000"])
        #expect(parsed.lines.map(\.singer) == [.primary, .secondary, .duet])
        #expect(parsed.lines.map(\.agentIDs) == [["v1"], ["v2"], ["v1000"]])
    }

    @Test func coPerformersAreIDReferencesAndUnassignedLinesStayUnassigned() throws {
        let document = LyricsDocument(format: .ttml, lines: [
            .init(id: 0, start: 1, end: 2, words: [LyricWord(start: 1, end: 2, text: "Together")], agentIDs: ["alice", "bob"]),
            .plain(id: 1, start: 3, end: 4, text: "Unassigned"),
        ], agents: [.init(id: "alice"), .init(id: "bob")])
        #expect(document.hasMultipleVocalists)
        let parsed = try TTMLParser.parse(TTMLWriter.write(document))
        #expect(parsed.agents == document.agents)
        #expect(parsed.lines.map(\.agentIDs) == [["alice", "bob"], []])
        #expect(parsed.lines.map(\.singer) == [.duet, .primary])
    }

    @Test func foreignIDsAndMissingDeclarationsProduceConsistentXMLReferences() throws {
        let document = LyricsDocument(format: .ttml, lines: [
            .init(id: 0, start: 1, end: 2, words: [LyricWord(start: 1, end: 2, text: "A")], agentIDs: ["1 singer", "missing", "1 singer"]),
            .plain(id: 1, start: 3, end: 4, text: "B"),
        ], agents: [
            .init(id: "agent1", names: [.init("Reserved")]),
            .init(id: "1 singer", kind: .character, names: [.init("A < B")], actorID: "actor:1"),
            .init(id: "v1", names: [.init("Named singer")]),
        ])
        let written = TTMLWriter.write(document)
        let parsed = try TTMLParser.parse(written)
        #expect(parsed.agents.map(\.id) == ["agent1", "agent2", "v1", "agent3", "missing"])
        #expect(parsed.agents[1].actorID == "agent3")
        #expect(parsed.agents[1].displayName == "A < B")
        #expect(parsed.lines.map(\.agentIDs) == [["agent2", "missing"], []])
        #expect(!written.contains("xml:id=\"1 singer\""))
    }

    @Test func editingBoundariesDoesNotChangeThePerformer() throws {
        var draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "AB", start: 1, end: 2)], agentIDs: ["alice"]),
            .init(syllables: [.init(text: "C", start: 3, end: 4)], agentIDs: ["bob"]),
        ], agents: [.init(id: "alice"), .init(id: "bob")])
        draft.splitSyllable(at: .init(line: 0, syllable: 0))
        _ = draft.moveSyllables([.init(line: 0, syllable: 1)], toLineBy: 1)
        #expect(draft.lines[1].syllables[0].agentIDs == ["alice"])
        let beforeMerge = draft
        #expect(draft.mergeSyllables([.init(line: 1, syllable: 0), .init(line: 1, syllable: 1)]) == nil)
        #expect(draft == beforeMerge)
        draft.mergeLineWithNext(0)
        let result = try TTMLParser.parse(TTMLWriter.write(draft.document()))
        #expect(result.lines[0].agentIDs == ["alice"])
        #expect(result.lines[0].syllables.last?.agentIDs == ["bob"])
    }

    @Test func theLegacySingerControlReassignsNamedRolesInsteadOfExportingStaleIDs() throws {
        var draft = LyricsDraft(document: try TTMLParser.parse(Self.ttml))
        draft.lines[0].setSinger(.secondary, agents: draft.agents)
        #expect(draft.lines[0].agentIDs == ["bob"])
        #expect(draft.lines[0].syllables.allSatisfy { $0.agentIDs.isEmpty })
        let parsed = try TTMLParser.parse(TTMLWriter.write(draft.document()))
        #expect(parsed.lines[0].agentIDs == ["bob"])
        #expect(parsed.lines[0].singer == .secondary)
    }
}
