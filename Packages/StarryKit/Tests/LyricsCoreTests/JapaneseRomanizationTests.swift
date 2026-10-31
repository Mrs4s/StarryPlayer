import Foundation
import Testing
@testable import LyricsCore

struct JapaneseRomanizationTests {
    @Test func japaneseDetectionUsesPrimaryLyricsAndReadings() {
        var line = LyricLine.plain(id: 0, start: 0, end: 3, text: "这一路上走走停停", translation: "君の名前を呼ぶ")
        line.background = .init(start: 0, end: 3, words: [.init(start: 0, end: 3, text: "きっと")])
        #expect(!LyricsDocument(format: .lrc, lines: [line]).hasJapanese)
        line.words = [.init(start: 0, end: 3, text: "東京", syllables: [.init(start: 0, end: 3, text: "東京", ruby: [.init(start: 0, end: 3, text: "とうきょう")])])]
        #expect(LyricsDocument(format: .ttml, lines: [line]).hasJapanese)
    }

    @Test func readsKanjiCompoundsInJapanese() {
        #expect(JapaneseRomanization.romanize("星空") == "hoshizora")
        #expect(JapaneseRomanization.romanize("東京") == "toukyou")
        #expect(JapaneseRomanization.romanize("君の名前を呼ぶ") == "kimi no namae o yobu")
    }

    @Test func readsKanaAndCommonParticles() {
        #expect(JapaneseRomanization.romanize("きっと ずっと しゃしん マッチ") == "kitto zutto shashin matchi")
        #expect(JapaneseRomanization.romanize("コーヒー") == "kōhī")
        #expect(JapaneseRomanization.romanize("ｷﾐﾉｺｴ") == "kiminokoe")
        #expect(JapaneseRomanization.romanize("今日はいい天気です") == "kyou wa ii tenki desu")
        #expect(JapaneseRomanization.romanize("東京へ行こう") == "toukyou e ikou")
        #expect(JapaneseRomanization.romanize("こんばんは") == "konbanwa")
    }

    @Test func preservesMixedTextPunctuationAndSupplementaryCharacters() {
        #expect(JapaneseRomanization.romanize("Hello 君が好き I love you") == "Hello kimi ga suki I love you")
        #expect(JapaneseRomanization.romanize("😀「こんにちは、世界！」🌟") == "😀「konnichiwa、sekai！」🌟")
        #expect(JapaneseRomanization.romanize("星空・東京") == "hoshizora・toukyou")
        #expect(JapaneseRomanization.romanize("  星空  コーヒー  ") == "hoshizora  kōhī")
    }

    @Test func skipsNonJapaneseAndDoesNotInventReadingsForUnknownKanji() {
        for text in ["", " \n\t", "Hello, world!", "123 🎵", "안녕하세요", "「」・。！？"] {
            #expect(!JapaneseRomanization.containsJapaneseScript(text))
            #expect(JapaneseRomanization.romanize(text) == nil)
        }
        // A rare extension-B character also exercises UTF-16 indexing on a failed reading.
        #expect(JapaneseRomanization.romanize("𠮷𠮷𠮷") == nil)
    }
}
