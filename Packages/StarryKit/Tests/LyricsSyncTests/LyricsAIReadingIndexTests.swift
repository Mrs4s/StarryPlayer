import Foundation
import Testing
@testable import LyricsSync

@Suite struct LyricsAIReadingIndexTests {
    private var fixture: Data {
        Data(base64Encoded: "U1RKUkVBRAABAAAAcyc1AQEAAAACAAAAPgAAAEUAAAAAAAAAAAAAAAMAAgADAAAAAQCv/QIFAAAAAQHQBwLnjosJBQn/")!
    }

    @Test func binaryFixturePreservesReadingsMasksNegativeCostsAndLongMarks() throws {
        let index = try #require(LyricsAIReadingIndex(data: fixture))
        #expect(index.entries(for: "王") == [.init(reading: "おう", partOfSpeech: 1, cost: -593), .init(reading: "おー", partOfSpeech: 257, cost: 2000)])
        #expect(index.entries(for: "").isEmpty)
        #expect(index.entries(for: "玉").isEmpty)
        #expect(index.entries(for: "王様").isEmpty)
    }

    @Test func truncatedUnsupportedAndInconsistentHeadersAreRejected() {
        let good = fixture
        for size in 0..<good.count { #expect(LyricsAIReadingIndex(data: Data(good.prefix(size))) == nil) }
        for offset in [0, 8, 24, 28] {
            var damaged = good
            damaged[offset] ^= 0xFF
            #expect(LyricsAIReadingIndex(data: damaged) == nil)
        }
        var trailing = good
        trailing.append(0)
        #expect(LyricsAIReadingIndex(data: trailing) == nil)
    }

    @Test func invalidRecordOffsetsCountsAndKanaReturnNoEntries() throws {
        for offset in [32, 42, 44, 52, 65] {
            var damaged = fixture
            damaged[offset] = 0xFE
            let index = try #require(LyricsAIReadingIndex(data: damaged))
            #expect(index.entries(for: "王").isEmpty)
        }
    }
}
