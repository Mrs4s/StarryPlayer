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
        let old = #"{"format":"starry-lyrics","version":1,"title":"","artists":[],"metadata":[],"draft":{"lines":[{"id":"00000000-0000-0000-0000-000000000001","syllables":[{"id":"00000000-0000-0000-0000-000000000002","text":"我","start":1,"end":1.5}],"translation":"","romanization":"","singer":"primary","isBackground":false,"isParagraphStart":false}],"metadata":{},"tracks":[]}}"#
        for version in [1, 2, 3, 4] {
            let json = old.replacingOccurrences(of: #""version":1"#, with: "\"version\":\(version)")
            let read = try LyricsProject(data: Data(json.utf8))
            #expect(read.draft.agents.isEmpty)
            #expect(read.draft.lines[0].agentIDs.isEmpty)
            #expect(read.draft.lines[0].syllables[0].agentIDs.isEmpty)
            #expect(read.draft.lines[0].text == "我")
            #expect(try LyricsProject(data: read.data()).version == LyricsProject.currentVersion)
        }
    }

    @Test func otherJSONAndProjectsFromLaterVersionsAreRefused() {
        #expect(throws: LyricsProject.ReadError.notAProject) { try LyricsProject(data: Data(#"{"lines": []}"#.utf8)) }
        #expect(throws: LyricsProject.ReadError.newerVersion(6)) {
            try LyricsProject(data: Data(#"{"format": "starry-lyrics", "version": 6}"#.utf8))
        }
        #expect(throws: (any Error).self) { try LyricsProject(data: Data("[00:01.00]歌词".utf8)) }
    }
}
