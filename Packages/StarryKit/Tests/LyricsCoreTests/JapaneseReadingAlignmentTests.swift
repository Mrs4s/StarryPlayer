import Testing
@testable import LyricsCore

@Suite struct JapaneseReadingAlignmentTests {
    @Test(arguments: [
        (["麻", "酔"], "ますい", ["ま", "すい"]),
        (["呼", "吸"], "こきゅう", ["こ", "きゅう"]),
        (["食", "べ", "る"], "たべる", ["た", "べ", "る"]),
        (["歌", "声"], "うたごえ", ["うた", "ごえ"]),
        (["学", "校"], "がっこう", ["がっ", "こう"]),
        (["木", "漏", "れ", "日"], "こもれび", ["こ", "も", "れ", "び"])
    ])
    func readingsFollowLanguageEvidenceInsteadOfEqualShares(example: ([String], String, [String])) throws {
        let result = try #require(JapaneseReadingAlignment.align(reading: example.1, to: example.0))
        #expect(result.map(\.reading) == example.2)
        #expect(result.allSatisfy { !$0.isEstimated })
    }

    @Test func kanaAnchorsWorkWithoutAnyDictionaryAndRetainUnknownReadingStatus() throws {
        let result = try #require(JapaneseReadingAlignment.align(reading: "かんがえる", to: ["考", "え", "る"], characterReadings: [:]))
        #expect(result.map(\.reading) == ["かんが", "え", "る"])
        #expect(result.map(\.isEstimated) == [true, false, false])
        let small = try #require(JapaneseReadingAlignment.align(reading: "きゃく", to: ["きゃ", "く"], characterReadings: [:]))
        #expect(small.map(\.reading) == ["きゃ", "く"])
    }

    @Test func ambiguityIsReportedEvenWhenBothPathsUseKnownCharacterReadings() throws {
        let result = try #require(JapaneseReadingAlignment.align(reading: "あいう", to: ["甲", "乙"],
            characterReadings: ["甲": ["あ", "あい"], "乙": ["いう", "う"]]))
        #expect(result.map(\.reading) == ["あい", "う"])
        #expect(result.allSatisfy { $0.isEstimated })
        let irregular = try #require(JapaneseReadingAlignment.align(reading: "おとな", to: ["大", "人"], characterReadings: [:]))
        #expect(irregular.allSatisfy { $0.isEstimated })
    }

    @Test func contradictoryKanaAndNonJapaneseReadingsAreRejected() {
        #expect(JapaneseReadingAlignment.align(reading: "たべる", to: ["食", "れ", "る"]) == nil)
        #expect(JapaneseReadingAlignment.align(reading: "abc", to: ["甲", "乙"]) == nil)
    }
}
