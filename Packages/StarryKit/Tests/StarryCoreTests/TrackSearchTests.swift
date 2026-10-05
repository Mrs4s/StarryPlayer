import Foundation
import Testing
@testable import StarryCore

@Suite struct TrackSearchTests {
    private static func track(_ id: String, _ title: String, alias: String? = nil, artists: [String] = [], album: String? = nil) -> Track {
        Track(
            id: TrackRef(source: .example, id: id),
            title: title,
            alias: alias,
            artists: artists.enumerated().map { ArtistRef(id: "\($0.offset)", name: $0.element) },
            album: album.map { AlbumRef(id: "a", name: $0) },
            duration: 200
        )
    }

    private let tracks = [
        track("1", "晴天", artists: ["周杰伦"], album: "叶惠美"),
        track("2", "Love Story", alias: "爱的故事", artists: ["Taylor Swift"], album: "Fearless"),
        track("3", "Café", artists: ["Ｏｒｂｉｔ Club"]),
        track("4", "海浪之间", artists: ["鸣潮先约电台", "jixwang"], album: "五浔深处"),
    ]

    @Test func blankQueryIsNoFilter() {
        let index = TrackSearchIndex(tracks)
        #expect(index.matches("") == nil)
        #expect(index.matches("  ") == nil)
    }

    @Test func matchesEachField() {
        let index = TrackSearchIndex(tracks)
        #expect(index.matches("晴") == [0])
        #expect(index.matches("周杰伦") == [0])
        #expect(index.matches("惠美") == [0])
        #expect(index.matches("故事") == [1])
        #expect(index.matches("fearless") == [1])
        #expect(index.matches("jixwang") == [3])
        #expect(index.matches("zzz") == [])
    }

    @Test func foldsCaseWidthAndDiacritics() {
        let index = TrackSearchIndex(tracks)
        #expect(index.matches("LOVE") == [1])
        #expect(index.matches("cafe") == [2])
        #expect(index.matches("orbit") == [2])
        #expect(index.matches("ＬＯＶＥ") == [1])
        #expect(index.matches(" swift ") == [1])
    }

    @Test func aMatchStaysInsideOneField() {
        let index = TrackSearchIndex(tracks)
        // Title `晴天` followed by artist `周杰伦`: not one string.
        #expect(index.matches("天周") == [])
        #expect(index.matches("电台 / jix") == [3])
    }

    @Test func editsKeepPositions() {
        var index = TrackSearchIndex(tracks.prefix(2))
        index.append(TrackSearchIndex(tracks.suffix(2)))
        #expect(index.count == 4)
        #expect(index.matches("海浪") == [3])
        index.remove(at: 0)
        #expect(index.matches("海浪") == [2])
        index.insert(tracks[0], at: 0)
        #expect(index.matches("晴天") == [0])
        #expect(index.matches("海浪") == [3])
    }

    @Test func fastOnALongList() {
        let many = (0..<20_000).map { Self.track("\($0)", "Song \($0) 第\($0)首", artists: ["Artist \($0 % 97)"], album: "Album \($0 % 311)") }
        let index = TrackSearchIndex(many)
        let start = Date()
        for query in ["s", "so", "son", "song 1", "第", "artist 5", "album 31"] { _ = index.matches(query) }
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(index.matches("song 19999")?.count == 1)
    }
}
