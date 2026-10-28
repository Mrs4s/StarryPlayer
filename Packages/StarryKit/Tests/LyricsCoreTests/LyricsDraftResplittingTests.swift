import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricsDraftResplittingTests {
    @Test func importedChunksUseCharacterAndWordRules() {
        var line = LyricsDraft.Line(syllables: [
            .init(text: "你好", start: 1, end: 2), .init(text: "，  Hel"), .init(text: "lo\n"),
            .init(text: "き"), .init(text: "ゃ"), .init(text: "ー！")
        ])
        line.resplitSyllables()
        #expect(line.syllables.map(\.text) == ["你", "好，  ", "Hello\n", "きゃー！"])
    }

    @Test func unchangedRubyAndWholeMergedReadingsSurviveButSplitRubyIsNotInvented() {
        let unchanged = LyricsDraft.Syllable(text: "愛", ruby: [.init(text: "あい", span: 0...1)])
        var line = LyricsDraft.Line(syllables: [unchanged,
            .init(text: "未来", ruby: [.init(text: "みらい")]),
            .init(text: "き", ruby: [.init(text: "き")]), .init(text: "ゃ", ruby: [.init(text: "ゃ")])
        ])
        line.resplitSyllables()
        #expect(line.syllables.map(\.text) == ["愛", "未", "来", "きゃ"])
        #expect(line.syllables[0] == unchanged)
        #expect(line.syllables[1].ruby == nil)
        #expect(line.syllables[2].ruby == nil)
        #expect(line.syllables[3].ruby?.map(\.text) == ["き", "ゃ"])
    }

    @Test func performerBoundariesAndExplicitRhythmBlocksArePreserved() {
        let rest = LyricsDraft.Syllable(text: "▨", start: 2, end: 3, isRest: true)
        let beats = LyricsDraft.Syllable(text: "未来", checkpoints: [0, nil], hasRelease: true)
        var line = LyricsDraft.Line(syllables: [
            .init(text: "Hel", agentIDs: ["a"]), .init(text: "lo ", agentIDs: ["b"]),
            .init(text: "你好", agentIDs: ["b"]), rest, beats
        ])
        line.resplitSyllables()
        #expect(line.syllables.map(\.text) == ["Hel", "lo ", "你", "好", "▨", "未来"])
        #expect(line.syllables.map(\.agentIDs) == [["a"], ["b"], ["b"], ["b"], [], []])
        #expect(line.syllables[4] == rest)
        #expect(line.syllables[5] == beats)
    }

    @Test(arguments: [" 你好\t 世界 \n", "a( b )", "a()", "君|の名は", "\"Hello\"  world", "👩‍🚀你好 e\u{301}", " \t"])
    func whitespacePunctuationAndLiteralBarsRoundTrip(text: String) {
        var line = LyricsDraft.Line(syllables: [.init(text: text)])
        line.resplitSyllables()
        #expect(line.text == text)
    }
}
