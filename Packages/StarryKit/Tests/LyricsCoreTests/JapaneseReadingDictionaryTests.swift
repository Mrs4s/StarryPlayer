import Foundation
import Testing
@testable import LyricsCore

@Suite struct JapaneseReadingDictionaryTests {
    private var fixture: Data {
        Data(base64Encoded: "U1RKUkVBRAACAAAAcyc1AaUoNQECAAAABAAAAGQAAABxAAAAAAAAAAAAAAAAAAAAAwABAAQAAAABAAAAAwADAAMAAAAAgAAAAQcAAAABwK/9AgkAAAABQdAHAgsAAAAAgAAAAuWRvBLnjosJBQn/CQk=")!
    }

    @Test func oneIndexSeparatesWordMetadataAndSingleCharacterReadings() throws {
        let index = try #require(JapaneseReadingDictionary(data: fixture))
        #expect(index.wordReadings(for: "王") == [.init(reading: "おう", partOfSpeech: 1, cost: -593),
                                                  .init(reading: "おー", partOfSpeech: 257, cost: 2000)])
        #expect(index.characterReadings(for: "王") == ["おう", "おお"])
        #expect(index.characterReadings(for: "呼") == ["こ"])
        #expect(index.wordReadings(for: "呼").isEmpty)
        #expect(index.wordReadings(for: "").isEmpty)
        #expect(index.wordReadings(for: "玉").isEmpty)
        #expect(index.characterReadings(for: "王様").isEmpty)
    }

    @Test func truncatedUnsupportedAndInconsistentHeadersAreRejected() {
        let good = fixture
        for size in 0..<good.count { #expect(JapaneseReadingDictionary(data: Data(good.prefix(size))) == nil) }
        for offset in [0, 8, 20, 24, 28, 32, 36] {
            var damaged = good
            damaged[offset] ^= 0xFF
            #expect(JapaneseReadingDictionary(data: damaged) == nil)
        }
        for offset in [12, 16] {
            var damaged = good
            damaged.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 0])
            #expect(JapaneseReadingDictionary(data: damaged) == nil)
        }
        var trailing = good; trailing.append(0)
        #expect(JapaneseReadingDictionary(data: trailing) == nil)
    }

    @Test func invalidOffsetsPurposeBitsMetadataAndKanaFailWithoutPartialResults() throws {
        for offset in [40, 44, 50, 64, 68, 69, 72, 103] {
            var damaged = fixture
            damaged[offset] = 0xFE
            let index = try #require(JapaneseReadingDictionary(data: damaged))
            #expect(index.characterReadings(for: "呼").isEmpty)
        }
        var noPurpose = fixture; noPurpose[69] = 0
        #expect(try #require(JapaneseReadingDictionary(data: noPurpose)).characterReadings(for: "呼").isEmpty)
    }

    @Test func bundledCharacterCandidatesDoNotLeakIntoWholeWordSelection() throws {
        let index = try #require(JapaneseReadingDictionary.shared)
        #expect(index.wordReadings(for: "名").map(\.reading) == ["な", "めい"])
        #expect(index.characterReadings(for: "名") == ["な", "みょう", "めい"])
        #expect(index.wordReadings(for: "呼").isEmpty)
        #expect(index.characterReadings(for: "呼") == ["こ", "よ"])
    }
}
