import Foundation
import Testing
@testable import LyricsCore

@Suite struct WordGroupingTests {
    private func syllables(_ parts: [String], step: Double = 0.3) -> [LyricSyllable] {
        parts.enumerated().map { i, t in LyricSyllable(start: Double(i) * step, end: Double(i + 1) * step, text: t) }
    }

    @Test func latinWordsSplitAtWhitespace() {
        let words = LyricWordGrouping.words(from: syllables(["Hel", "lo ", "dark", "ness, ", "my"]))
        #expect(words.map(\.text) == ["Hello ", "darkness, ", "my"])
        #expect(words.map(\.length) == [5, 9, 2])
        #expect(words.map(\.syllables.count) == [2, 2, 1])
        #expect(words[0].end == 0.6)
    }

    @Test func chineseUsesNaturalLanguageWords() {
        let words = LyricWordGrouping.words(from: syllables(Array("夜色把街道").map(String.init)))
        #expect(words.map(\.text) == ["夜色", "把", "街道"])
        #expect(words.map(\.length) == [2, 1, 2])
    }

    @Test func punctuationStaysWithThePreviousWord() {
        let words = LyricWordGrouping.words(from: syllables(Array("那些日子，").map(String.init)))
        #expect(words.map(\.text) == ["那些", "日子，"])
        #expect(words.last?.length == 2)
    }

    @Test func detectsChineseJapanese() {
        #expect(LyricWordGrouping.containsChineseJapanese("君の名は"))
        #expect(LyricWordGrouping.containsChineseJapanese("ㄅㄆ"))
        #expect(!LyricWordGrouping.containsChineseJapanese("Hello, 안녕"))
    }
}
