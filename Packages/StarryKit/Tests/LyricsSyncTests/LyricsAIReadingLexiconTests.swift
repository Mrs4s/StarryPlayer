import Testing
@testable import LyricsSync

@Suite struct LyricsAIReadingLexiconTests {
    @Test func dictionarySuppliesAlternativesBeyondTheLyricSupplement() {
        let market = LyricsAIReadingLexicon.candidates(for: "市場", defaultReading: "しじょう")
        #expect(market.contains("しじょう"))
        #expect(market.contains("いちば"))
        let living = LyricsAIReadingLexicon.candidates(for: "生物", defaultReading: "せいぶつ")
        #expect(living.contains("せいぶつ"))
        #expect(living.contains("なまもの"))
        let maple = LyricsAIReadingLexicon.candidates(for: "紅葉", defaultReading: "こうよう")
        #expect(maple.contains("もみじ"))
    }

    @Test func completeWordsExcludeAdjectiveStemsAndPrioritizeCompatiblePartsOfSpeech() {
        let readings = LyricsAIReadingLexicon.candidates(for: "上手", defaultReading: "ジョウズ")
        #expect(readings.first == "じょうず")
        #expect(readings.contains("かみて"))
        #expect(readings.contains("うわて"))
        #expect(!readings.contains("うま"))
        #expect(!readings.contains("うえで"))
        let inflected = LyricsAIReadingLexicon.candidates(for: "行っ", defaultReading: "いっ")
        #expect(inflected.contains("いっ"))
        #expect(inflected.contains("おこなっ"))
    }
}
