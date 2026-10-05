import Foundation
import Testing
@testable import LyricsCore

@Suite struct CompactLyricsTimelineTests {
    private func document(_ lines: [(Double, Double, String)]) -> LyricsDocument {
        LyricsDocument(format: .lrc, lines: lines.enumerated().map { index, line in
            .plain(id: index, start: line.0, end: line.1, text: line.2)
        })
    }

    @Test func linesAppearALittleEarlyAndHoldThroughShortPauses() {
        let timeline = CompactLyricsTimeline(document: document([(10, 13, "a"), (15, 18, "b")]), lead: 0.2)
        #expect(timeline.item(at: 0) == .idle)
        #expect(timeline.item(at: 9.79) == .idle)
        #expect(timeline.item(at: 9.8) == .line(0))
        // A 2 s pause is not a break: the sung line stays.
        #expect(timeline.item(at: 14) == .line(0))
        #expect(timeline.item(at: 14.8) == .line(1))
        #expect(timeline.item(at: 100) == .line(1))
        #expect(timeline.nextChange(after: 0) == 9.8)
        #expect(timeline.nextChange(after: 9.8) == 14.8)
        #expect(timeline.nextChange(after: 20) == nil)
    }

    @Test func instrumentalBreaksAndTheOutroShowTheSong() {
        let timeline = CompactLyricsTimeline(document: document([(1, 4, "a"), (20, 22, "b")]), duration: 60, lead: 0.2)
        #expect(timeline.item(at: 3) == .line(0))
        #expect(timeline.item(at: 4.05) == .line(0))
        #expect(timeline.item(at: 4.1) == .idle)
        #expect(timeline.item(at: 19.8) == .line(1))
        #expect(timeline.item(at: 22.1) == .idle)
        let open = CompactLyricsTimeline(document: document([(1, 4, "a"), (20, 22, "b")]), lead: 0.2)
        #expect(open.item(at: 50) == .line(1))
    }

    @Test func blankLinesAreSkippedAndLaterLinesWinTies() {
        let timeline = CompactLyricsTimeline(document: document([(1, 3, "a"), (3, 3.5, " "), (5, 7, "b"), (5, 7, "c")]), lead: 0)
        #expect(timeline.item(at: 3.2) == .line(0))
        #expect(timeline.item(at: 5) == .line(3))
        #expect(timeline.changes.map(\.item) == [.line(0), .line(3)])
    }

    @Test func overlappingLinesHandOverAtTheLaterStart() {
        let timeline = CompactLyricsTimeline(document: document([(1, 6, "a"), (4, 8, "b"), (7, 9, "c")]), lead: 0)
        #expect(timeline.item(at: 3.9) == .line(0))
        #expect(timeline.item(at: 4) == .line(1))
        #expect(timeline.item(at: 7.5) == .line(2))
    }

    @Test func emptyLyricsStayIdle() {
        let timeline = CompactLyricsTimeline(document: document([]), duration: 100)
        #expect(timeline.changes.isEmpty)
        #expect(timeline.item(at: 10) == .idle)
        #expect(timeline.nextChange(after: 0) == nil)
    }
}
