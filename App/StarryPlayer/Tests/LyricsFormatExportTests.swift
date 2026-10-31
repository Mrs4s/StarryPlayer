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

    @Test func exportReportComparesWhatEachFormatKeepsWithoutTouchingTheSession() throws {
        let session = try session("我爱你")
        session.tap(at: 1)
        session.tap(at: 2)
        session.tap(at: 3)
        session.release(at: 4)
        session.edit { $0.lines[0].translation = "I love you" }
        let caret = session.caret
        let flash = session.flashText
        let revision = session.revision

        let report = LyricsExportReport(session: session)
        #expect(report.status(of: .translation, in: .format(.ttml)) == .kept)
        #expect(report.status(of: .syllableTiming, in: .format(.lrcLine)) == .lost)
        #expect(report.status(of: .translation, in: .format(.srt)) == .lost)
        #expect(report.status(of: .timing, in: .format(.txt)) == .lost)
        #expect(report.status(of: .translation, in: .project) == .kept)
        #expect(session.caret == caret)
        #expect(session.flashText == flash)
        #expect(session.revision == revision)
    }

    @Test func exportReportOnlyRevealsInvalidTimingWhenRequested() throws {
        let session = try session("我爱你")
        session.tap(at: 1)
        session.tap(at: 2)
        session.tap(at: 3)
        session.release(at: 4)
        session.edit { $0.lines[0].syllables[0].end = 2.5 }
        let caret = session.caret
        let flash = session.flashText

        let report = LyricsExportReport(session: session)
        let issue = try #require(report.blockingIssue(for: .format(.ttml)))
        #expect(issue == .timingOverlap(.init(line: 0, syllable: 1)))
        #expect(report.blockingIssue(for: .format(.txt)) == nil)
        #expect(report.blockingIssue(for: .project) == nil)
        #expect(session.caret == caret)
        #expect(session.flashText == flash)

        session.reveal(issue)
        #expect(session.caret == .init(line: 0, syllable: 1))
    }
}
