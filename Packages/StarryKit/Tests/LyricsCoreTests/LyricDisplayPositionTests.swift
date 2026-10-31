import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricDisplayPositionTests {
    @Test func aSoloSingerIsStillSoloInEveryDisplayPosition() {
        for position in [LyricSinger.primary, .secondary, .duet] {
            let document = LyricsDraft(lines: [.init(syllables: [.init(text: "A", start: 1, end: 2)], singer: position, agentIDs: ["alice"])],
                                       agents: [.init(id: "alice", color: LyricColor(hex: "#112233"))]).document()
            #expect(!document.hasMultipleVocalists)
            #expect(LyricPerformerStyle(document: document) == nil)
        }
    }

    @Test(arguments: [TTMLWriter.Format.amll, .ttml2])
    func positionsAndRealPerformersSurviveExportAndProjectReload(format: TTMLWriter.Format) throws {
        let agents: [LyricAgent] = [
            .init(id: "v1", names: [.init("Alice")], color: LyricColor(hex: "#112233")),
            .init(id: "v2", names: [.init("Bob")]),
            .init(id: "v1000", kind: .group, memberIDs: ["v1", "v2"]),
        ]
        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "A", start: 1, end: 2, agentIDs: ["v2"])], singer: .secondary, agentIDs: ["v1"]),
            .init(syllables: [.init(text: "B", start: 3, end: 4)], agentIDs: ["v1", "v2"]),
            .init(syllables: [.init(text: "C", start: 5, end: 6)], singer: .secondary, agentIDs: ["v1000"]),
            .init(syllables: [.init(text: "D", start: 7, end: 8)], singer: .duet, agentIDs: ["v2"]),
            .init(syllables: [.init(text: "E", start: 9, end: 10)], singer: .secondary),
        ], agents: agents)
        let reloaded = try LyricsProject(data: LyricsProject(draft: draft).data()).draft
        #expect(reloaded == draft)
        let document = reloaded.document()
        let xml = TTMLWriter.write(document, format: format)
        let parsed = try TTMLParser.parse(xml)
        #expect(parsed.agents == agents)
        #expect(parsed.lines.map(\.singer) == draft.lines.map(\.singer))
        #expect(parsed.lines.map(\.agentIDs) == draft.lines.map(\.agentIDs))
        #expect(parsed.lines.flatMap(\.syllables).map(\.agentIDs) == document.lines.flatMap(\.syllables).map(\.agentIDs))

        let legacy = try TTMLParser.parse(xml.replacingOccurrences(of: LyricSinger.positionNamespace, with: "urn:example:other"))
        #expect(legacy.lines.map(\.singer) == draft.lines.map(\.singer))
    }

    @Test func independentPositionsPreserveBackgroundAndRubyPerformers() throws {
        let original = try TTMLParser.parse(LyricAgentTests.ttml)
        var document = original
        document.lines[0].singer = .secondary
        document.lines[1].singer = .duet
        document.lines[2].singer = .primary
        let parsed = try TTMLParser.parse(TTMLWriter.write(document))
        #expect(parsed.agents == original.agents)
        #expect(parsed.lines.map(\.singer) == [.secondary, .duet, .primary])
        #expect(parsed.lines.map(\.agentIDs) == original.lines.map(\.agentIDs))
        #expect(parsed.lines[0].background == original.lines[0].background)
        #expect(parsed.lines.flatMap(\.syllables) == original.lines.flatMap(\.syllables))
    }

    @Test func positionExtensionsUseTheirNamespace() throws {
        var document = try TTMLParser.parse(LyricAgentTests.ttml)
        document.lines[0].singer = .secondary
        let xml = TTMLWriter.write(document)
        let aliased = xml.replacingOccurrences(of: "xmlns:ttd=", with: "xmlns:display=")
            .replacingOccurrences(of: " ttd:", with: " display:")
        #expect(try TTMLParser.parse(aliased).lines.map(\.singer) == document.lines.map(\.singer))
        let foreign = xml.replacingOccurrences(of: LyricSinger.positionNamespace, with: "urn:example:other")
        #expect(try TTMLParser.parse(foreign).agents.count > document.agents.count)
    }
}
