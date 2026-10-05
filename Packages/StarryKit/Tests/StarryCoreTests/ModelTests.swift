import Foundation
import Testing
@testable import StarryCore

@Suite struct ModelTests {
    @Test func artworkSizesOnlyThroughItsTemplate() throws {
        let template = Artwork(url: URL(string: "https://img.example/a.jpg"), seed: "a", sizedTemplate: "https://img.example/a.jpg?w={width}&h={height}")
        #expect(template.sized(width: 300, height: 200)?.absoluteString == "https://img.example/a.jpg?w=300&h=200")
        let plain = Artwork(url: URL(string: "https://img.example/c.jpg"), seed: "a")
        #expect(plain.sized(300) == plain.url)
        #expect(Artwork(seed: "a").sized(300) == nil)
        let saved = try JSONDecoder().decode(Artwork.self, from: Data(#"{"url": "https://img.example/b.jpg", "seed": "b"}"#.utf8))
        #expect(saved.sizedTemplate == nil && saved.sized(64) == saved.url)
    }

    @Test func trackKeepsItsTTMLKeys() throws {
        let track = Track(id: TrackRef(source: .example, id: "1"), title: "t", duration: 1, ttml: [TTMLKey(folder: "am-lyrics", id: "42")])
        #expect(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)) == track)
        var old = track
        old.ttml = nil
        let json = try JSONEncoder().encode(old)
        #expect(!String(decoding: json, as: UTF8.self).contains("ttml"))
        #expect(try JSONDecoder().decode(Track.self, from: json).ttml == nil)
    }

    @Test func formatting() {
        #expect(TimeFormatting.clock(252) == "4:12")
        #expect(TimeFormatting.clock(3725) == "1:02:05")
        #expect(TimeFormatting.compactCount(2_153_000) == "215.3万")
        #expect(TimeFormatting.compactCount(398) == "398")
    }
}
