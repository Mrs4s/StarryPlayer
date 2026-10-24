import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricsProjectTests {
    @Test func aProjectKeepsWhatTTMLCannot() throws {
        let track = LyricsDraft.Track(name: "和声")
        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "我", start: 1, end: 1.5), .init(text: "爱 ")], translation: "I love", romanization: "wo ai",
                  singer: .secondary, isParagraphStart: true, start: 1, end: 3, track: track.id),
            .init(syllables: [.init(text: "(ah)")], isBackground: true),
        ], metadata: ["isrc": "X"], tracks: [track])
        let project = LyricsProject(draft: draft, metadata: [.init(key: "artists", value: "A"), .init(key: "artists", value: "B")],
                                    title: "歌", artists: ["A", "B"])
        let read = try LyricsProject(data: project.data())
        #expect(read == project)
    }

    @Test func otherJSONAndProjectsFromLaterVersionsAreRefused() {
        #expect(throws: LyricsProject.ReadError.notAProject) { try LyricsProject(data: Data(#"{"lines": []}"#.utf8)) }
        #expect(throws: LyricsProject.ReadError.newerVersion(2)) {
            try LyricsProject(data: Data(#"{"format": "starry-lyrics", "version": 2}"#.utf8))
        }
        #expect(throws: (any Error).self) { try LyricsProject(data: Data("[00:01.00]歌词".utf8)) }
    }
}
