import Foundation
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsFormatExportTests {
    private func session(_ text: String) throws -> LyricsEditorSession {
        let track = Track(id: TrackRef(source: .local, id: "formats"), title: "Song", artists: [ArtistRef(id: "a", name: "Singer")], duration: 60)
        let session = LyricsEditorSession(track: track)
        session.replace(with: try LyricsDraftImport.draft(from: text))
        return session
    }

    @Test func timingRequirementsDependOnTheExportFormat() throws {
        let text = try session("Hello world")
        #expect(try text.exportLyrics(format: .txt)?.text == "Hello world\n")
        #expect(!text.needsTiming(for: .txt))
        #expect(text.needsTiming(for: .srt))
        let subtitle = try session("1\n00:00:01,000 --> 00:00:03,000\n你好")
        #expect(!subtitle.needsTiming(for: .srt))
        #expect(!subtitle.needsTiming(for: .lrcLine))
        #expect(subtitle.needsTiming(for: .lrcEnhanced))
    }

    @Test func rlExportsAStillUnreleasedHeldSyllableWithoutChangingTheSession() throws {
        let session = try session("[2|00:01:00]あ[00:05:00]")
        let draft = session.draft
        let revision = session.revision
        #expect(!session.needsTiming(for: .rl))
        let output = try #require(try session.exportLyrics(format: .rl))
        let reopened = try LyricsDraftImport.draft(from: output.text)
        #expect(reopened.lines[0].syllables[0].checkpoints == [0, 4])
        #expect(reopened.lines[0].syllables[0].end == nil)
        #expect(session.draft == draft)
        #expect(session.revision == revision)
        #expect(session.hasUnsavedChanges)
    }
}
