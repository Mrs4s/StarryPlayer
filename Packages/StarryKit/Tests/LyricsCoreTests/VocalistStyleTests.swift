import Foundation
import Testing
@testable import LyricsCore

@Suite struct VocalistStyleTests {
    static let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:v="urn:ttml:extensions:vocalist-style:1">
      <head><metadata>
        <ttm:agent type="person" xml:id="v1" v:color="#ff4f86"><ttm:name type="full">Luna</ttm:name></ttm:agent>
        <ttm:agent type="person" xml:id="v2" v:color="#3E7BFA"/>
        <ttm:agent type="person" xml:id="v3" v:color="red" v:members="v1"/>
        <ttm:agent type="group" xml:id="v1000" v:members="v1 v2 missing v1000 v2 g2"><ttm:name type="full">ALL</ttm:name></ttm:agent>
        <ttm:agent type="group" xml:id="g2"/>
      </metadata></head>
      <body><div>
        <p begin="1s" end="2s" ttm:agent="v1"><span begin="1s" end="1.5s">A</span><span begin="1.5s" end="2s" ttm:agent="v2">B</span></p>
        <p begin="3s" end="4s" ttm:agent="v1000"><span begin="3s" end="4s">C</span></p>
      </div></body>
    </tt>
    """

    static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: #" xmlns:ttv="urn:ttml:extensions:vocalist-style:1""#, with: "")
            .replacingOccurrences(of: #" ttv:[A-Za-z]+="[^"]*""#, with: "", options: .regularExpression)
    }

    static func unstyled(_ document: LyricsDocument) -> LyricsDocument {
        var document = document
        for index in document.agents.indices {
            document.agents[index].color = nil
            document.agents[index].memberIDs = []
        }
        return document
    }

    @Test func colorsAndMembersAreReadByNamespaceAndSanitized() throws {
        let document = try TTMLParser.parse(Self.ttml)
        #expect(document.agents.map(\.id) == ["v1", "v2", "v3", "v1000", "g2"])
        #expect(document.agents.map(\.color) == [LyricColor(hex: "#FF4F86"), LyricColor(hex: "#3E7BFA"), nil, nil, nil])
        #expect(document.agents.map(\.memberIDs) == [[], [], [], ["v1", "v2"], []])
        #expect(document.lines.map(\.singer) == [.primary, .duet])
    }

    @Test func thePrefixAloneIsNotTheExtension() throws {
        let other = Self.ttml.replacingOccurrences(of: "urn:ttml:extensions:vocalist-style:1", with: "urn:example:other")
        let document = try TTMLParser.parse(other)
        #expect(document.agents.allSatisfy { $0.color == nil && $0.memberIDs.isEmpty })
    }

    @Test(arguments: [TTMLWriter.Format.amll, .ttml2])
    func stylesRoundTripWithoutChangingUnstyledTTML(format: TTMLWriter.Format) throws {
        let document = try TTMLParser.parse(Self.ttml)
        let written = TTMLWriter.write(document, format: format)
        #expect(try TTMLParser.parse(written).agents == document.agents)
        #expect(Self.stripped(written) == TTMLWriter.write(Self.unstyled(document), format: format))
    }

    @Test func membersFollowRewrittenIDs() throws {
        let document = LyricsDocument(format: .ttml, lines: [
            .init(id: 0, start: 1, end: 2, words: [LyricWord(start: 1, end: 2, text: "A")], agentIDs: ["all"]),
        ], agents: [
            .init(id: "1 singer", color: LyricColor(hex: "#112233")),
            .init(id: "all", kind: .group, memberIDs: ["1 singer"]),
        ])
        let parsed = try TTMLParser.parse(TTMLWriter.write(document))
        #expect(parsed.agents.map(\.id) == ["agent1", "all"])
        #expect(parsed.agents.map(\.memberIDs) == [[], ["agent1"]])
        #expect(parsed.agents[0].color == LyricColor(hex: "#112233"))
    }

    @Test func colorsAcceptOnlySixDigitHex() {
        #expect(LyricColor(hex: "#a1B2c3")?.hex == "#A1B2C3")
        for text in ["A1B2C3", "#ABC", "#A1B2C3FF", "#+1B2C3", "#GGGGGG", ""] { #expect(LyricColor(hex: text) == nil) }
    }

    @Test func newRolesTakeUnusedPaletteColorsAndGroupsDropRemovedMembers() {
        let palette = LyricColor.performerPalette
        var draft = LyricsDraft(agents: [.init(id: "v1", color: palette[0])])
        let second = draft.addAgent(name: "B")
        #expect(second.color == palette[1])
        var group = draft.addAgent(kind: .group, name: "All")
        #expect(group.color == palette[2])
        group.memberIDs = ["v1", second.id, group.id, "v1"]
        draft.updateAgent(group)
        #expect(draft.agents.last?.memberIDs == ["v1", second.id])
        draft.removeAgent("v1")
        #expect(draft.agents.last?.memberIDs == [second.id])
        var person = draft.agents.last!
        person.kind = .person
        draft.updateAgent(person)
        #expect(draft.agents.last?.memberIDs == [])
    }

    @Test func projectsKeepStyleAndEarlierProjectsStillOpen() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "A", start: 1, end: 2)], agentIDs: ["v1"])],
                                agents: [.init(id: "v1", color: LyricColor(hex: "#112233")), .init(id: "all", kind: .group, memberIDs: ["v1"])])
        let data = try LyricsProject(draft: draft).data()
        #expect(try LyricsProject(data: data).draft == draft)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var draftObject = try #require(object["draft"] as? [String: Any])
        let agents = try #require(draftObject["agents"] as? [[String: Any]])
        draftObject["agents"] = agents.map { $0.filter { $0.key != "color" && $0.key != "memberIDs" } }
        object["draft"] = draftObject
        object["version"] = 5
        let earlier = try LyricsProject(data: JSONSerialization.data(withJSONObject: object))
        #expect(earlier.draft.agents.map(\.color) == [nil, nil])
        #expect(earlier.draft.agents.map(\.memberIDs) == [[], []])
    }
}
