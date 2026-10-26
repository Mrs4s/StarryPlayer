import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricsProjectTests {
    @Test func aProjectKeepsWhatTTMLCannot() throws {
        let track = LyricsDraft.Track(name: "和声")
        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "我", start: 1, end: 1.5), .init(text: "爱 ", ruby: [.init(text: "ài", span: 0...1)])], translation: "I love", romanization: "wo ai",
                  singer: .secondary, isParagraphStart: true, start: 1, end: 3, track: track.id),
            .init(syllables: [.init(text: "(ah)")], isBackground: true),
        ], metadata: ["isrc": "X"], tracks: [track])
        let project = LyricsProject(draft: draft, metadata: [.init(key: "artists", value: "A"), .init(key: "artists", value: "B")],
                                    title: "歌", artists: ["A", "B"])
        let read = try LyricsProject(data: project.data())
        #expect(read == project)
    }

    @Test func projectsFromBeforeRubyStillOpen() throws {
        let project = LyricsProject(draft: LyricsDraft(lines: [.init(syllables: [.init(text: "我", start: 1, end: 1.5)])]))
        let data = try project.data()
        #expect(!String(decoding: data, as: UTF8.self).contains("ruby"))
        let v1 = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""version" : 2"#, with: #""version" : 1"#)
        #expect(v1.contains(#""version" : 1"#))
        #expect(try LyricsProject(data: Data(v1.utf8)).draft == project.draft)
    }

    @Test func otherJSONAndProjectsFromLaterVersionsAreRefused() {
        #expect(throws: LyricsProject.ReadError.notAProject) { try LyricsProject(data: Data(#"{"lines": []}"#.utf8)) }
        #expect(throws: LyricsProject.ReadError.newerVersion(3)) {
            try LyricsProject(data: Data(#"{"format": "starry-lyrics", "version": 3}"#.utf8))
        }
        #expect(throws: (any Error).self) { try LyricsProject(data: Data("[00:01.00]歌词".utf8)) }
    }
}
