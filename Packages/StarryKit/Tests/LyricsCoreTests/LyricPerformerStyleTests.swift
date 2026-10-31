import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricPerformerStyleTests {
    static let palette = LyricColor.performerPalette
    static let agents: [LyricAgent] = [
        .init(id: "v1", names: [.init("Luna")], color: palette[1]),
        .init(id: "v2", names: [.init("Kai")]),
        .init(id: "v3"),
        .init(id: "all", kind: .group, names: [.init("ALL")], memberIDs: ["v3", "v1"]),
    ]

    static func syllable(_ text: String, _ agents: [String] = []) -> LyricSyllable {
        LyricSyllable(start: 0, end: 1, text: text, agentIDs: agents)
    }

    static func line(_ syllables: [LyricSyllable], agents: [String], background: LyricBackgroundVocals? = nil) -> LyricLine {
        LyricLine(id: 0, start: 0, end: 1, words: [LyricWord(start: 0, end: 1, text: syllables.map(\.text).joined(), syllables: syllables)],
                  background: background, agentIDs: agents)
    }

    static func style(_ lines: [LyricLine] = [line([syllable("A")], agents: ["v1"]), line([syllable("B")], agents: ["v2"])],
                      agents: [LyricAgent] = agents) -> LyricPerformerStyle? {
        LyricPerformerStyle(document: LyricsDocument(format: .ttml, lines: lines, agents: agents))
    }

    @Test func onlyDocumentsWithSeveralVocalistsAndAColorAreMarked() throws {
        #expect(Self.style() != nil)
        #expect(Self.style(agents: Self.agents.map { var agent = $0; agent.color = nil; return agent }) == nil)
        #expect(Self.style([Self.line([Self.syllable("A")], agents: ["v1"])]) == nil)
    }

    @Test func aHandoffSplitsTheLineAndUncoloredPerformersTakeUnusedPaletteColors() throws {
        let style = try #require(Self.style())
        let runs = style.runs(of: Self.line([Self.syllable("你"), Self.syllable("说"), Self.syllable("我", ["v2"]), Self.syllable("在", ["v2"])], agents: ["v1"]))
        #expect(runs == [
            LyricPerformerRun(syllables: 0..<2, colors: [Self.palette[1]], label: "Luna"),
            LyricPerformerRun(syllables: 2..<4, colors: [Self.palette[0]], label: "Kai"),
        ])
        #expect(style.runs(of: Self.line([Self.syllable("C")], agents: ["v3"])).first?.colors == [Self.palette[2]])
    }

    @Test func groupsShowMembersInDeclarationOrderUnderTheGroupName() throws {
        let style = try #require(Self.style())
        #expect(style.runs(of: Self.line([Self.syllable("All")], agents: ["all"])) == [
            LyricPerformerRun(syllables: 0..<1, colors: [Self.palette[1], Self.palette[2]], label: "ALL"),
        ])
        #expect(style.runs(of: Self.line([Self.syllable("Duo")], agents: ["v2", "v1"])) == [
            LyricPerformerRun(syllables: 0..<1, colors: [Self.palette[1], Self.palette[0]], label: "Luna · Kai"),
        ])
    }

    @Test func whitespaceStaysWithThePreviousRunAndUnknownPerformersAreUnmarked() throws {
        let style = try #require(Self.style())
        let runs = style.runs(of: Self.line([Self.syllable("One"), Self.syllable(" ", ["v2"]), Self.syllable("two", ["v2"])], agents: ["v1"]))
        #expect(runs.map(\.syllables) == [0..<2, 2..<3])
        #expect(style.runs(of: Self.line([Self.syllable("?")], agents: ["ghost"])) == [LyricPerformerRun(syllables: 0..<1, colors: [], label: nil)])
    }

    @Test func backgroundVocalsInheritTheLineUnlessAssigned() throws {
        let style = try #require(Self.style())
        let inherited = LyricBackgroundVocals(start: 0, end: 1, words: [LyricWord(start: 0, end: 1, text: "ah")])
        #expect(style.backgroundRuns(of: Self.line([Self.syllable("A")], agents: ["v1"], background: inherited)).map(\.colors) == [[Self.palette[1]]])
        var own = inherited
        own.agentIDs = ["v3"]
        #expect(style.backgroundRuns(of: Self.line([Self.syllable("A")], agents: ["v1"], background: own)) == [
            LyricPerformerRun(syllables: 0..<1, colors: [Self.palette[2]], label: nil),
        ])
        #expect(style.backgroundRuns(of: Self.line([Self.syllable("A")], agents: ["v1"])).isEmpty)
    }
}
