import Foundation
import Testing
@testable import LyricsCore

/// `LyricsSelection` against its selection rules, with a fixed 0.6 s line-change lead so the
/// thresholds are easy to read: finish when `last.end − 0.5 < t + 0.25`, switch when
/// `last.end − 0.5 < t` and `next.start ≤ t + 0.6`, append when `next.start < t` while the last
/// line is still sung.
@Suite struct LyricsSelectionTests {
    private func entry(_ index: Int, _ start: Double, _ end: Double) -> LyricsTimelineEntry {
        LyricsTimelineEntry(kind: .line(index), start: start, end: end)
    }

    private func selection(_ entries: [LyricsTimelineEntry]) -> LyricsSelection {
        LyricsSelection(entries: entries, configuration: .init { _ in 0.6 })
    }

    @Test func backToBackLinesFinishThenSwitchHalfASecondEarly() {
        var s = selection([entry(0, 0, 2), entry(1, 2, 4)])
        #expect(s.jump(to: 0) == [.jump(0, selected: true)])
        #expect(s.update(at: 1.0) == [])
        #expect(s.update(at: 1.3) == [.finish(0)])
        #expect(s.update(at: 1.45) == [.finish(0)])
        #expect(s.update(at: 1.55) == [.finish(0), .select(1, gap: 0)])
        #expect(s.selected == [1])
    }

    @Test func overlappingLinesAreLitTogetherUntilTheOlderEnds() {
        var s = selection([entry(0, 0, 4), entry(1, 2, 5), entry(2, 5, 7)])
        _ = s.jump(to: 0)
        #expect(s.update(at: 1.5) == [])
        #expect(s.update(at: 2.05) == [.append(1)])
        #expect(s.selected == [0, 1])
        #expect(s.update(at: 3.3) == [])
        #expect(s.update(at: 3.45) == [.deselect(0)])
        #expect(s.selected == [1])
        #expect(s.update(at: 4.45) == [.finish(1)])
        #expect(s.update(at: 4.55) == [.finish(1), .select(2, gap: 0)])
    }

    @Test func trailingBackgroundVocalsHoldTheLine() {
        // A's main vocals end at 2.5, its background vocals at 4; B starts at 3. A stays lit
        // through its background vocals: B joins it, and A leaves only once they end — not a
        // lead earlier, as a plain overlapping line would.
        let doc = LyricsDocument(format: .ttml, lines: [
            LyricLine(id: 0, start: 0, end: 4, words: [LyricWord(start: 0, end: 2.5, text: "a")],
                      background: LyricBackgroundVocals(start: 1, end: 4, words: [LyricWord(start: 1, end: 4, text: "(a)")]),
                      primaryEnd: 2.5),
            LyricLine(id: 1, start: 3, end: 5, words: [LyricWord(start: 3, end: 5, text: "b")]),
        ])
        let entries = LyricsSelection.entries(for: doc, gaps: [])
        #expect(entries[0].backgroundEnd == 4)
        #expect(entries[1].backgroundEnd == nil)
        var s = selection(entries)
        _ = s.jump(to: 0)
        #expect(s.update(at: 2.2) == [])
        #expect(s.update(at: 2.45) == [])
        #expect(s.selected == [0])
        #expect(s.update(at: 3.05) == [.append(1)])
        #expect(s.selected == [0, 1])
        #expect(s.update(at: 3.45) == [])
        #expect(s.update(at: 3.95) == [])
        #expect(s.update(at: 4.05) == [.deselect(0)])
        #expect(s.selected == [1])
    }

    @Test func trailingBackgroundVocalsAreNotCutShortBySwitching() {
        // A's main vocals end at 2.5, its background vocals at 3.25; B starts at 3.5. Without
        // the background vocals A would give way at 2.75 (0.5 s before its end); with them it
        // holds until they end, and the finish (which only completes the main vocals) comes
        // 0.25 s before that.
        var s = selection([LyricsTimelineEntry(kind: .line(0), start: 0, end: 3.25, backgroundEnd: 3.25), entry(1, 3.5, 5)])
        _ = s.jump(to: 0)
        #expect(s.update(at: 2.6) == [])
        #expect(s.update(at: 2.9) == [])
        #expect(s.selected == [0])
        #expect(s.update(at: 3.1) == [.finish(0)])
        // At 3.3 the finish check (0.25 s ahead) already sees B start, so no finish is sent.
        #expect(s.update(at: 3.3) == [.select(1, gap: 0.25)])
        #expect(s.selected == [1])
    }

    @Test func backgroundVocalsEndingWithinTheMarginHoldTheLineToo() {
        // A's background vocals end at 2.75, its main vocals at 3; B starts at 3.25. The switch
        // may come 0.5 s before A's end but not before its background vocals are done.
        var s = selection([LyricsTimelineEntry(kind: .line(0), start: 0, end: 3, backgroundEnd: 2.75), entry(1, 3.25, 5)])
        _ = s.jump(to: 0)
        #expect(s.update(at: 2.4) == [])
        #expect(s.update(at: 2.6) == [.finish(0)])
        #expect(s.update(at: 2.7) == [.finish(0)])
        #expect(s.selected == [0])
        #expect(s.update(at: 2.8) == [.finish(0), .select(1, gap: 0.25)])
        #expect(s.selected == [1])
    }

    @Test func shortPausesKeepThePreviousLineLit() {
        var s = selection([entry(0, 0, 2), entry(1, 5, 7)])
        _ = s.jump(to: 0)
        #expect(s.update(at: 3) == [])
        #expect(s.selected == [0])
        #expect(s.update(at: 4.1) == [])
        #expect(s.update(at: 4.3) == [.finish(0)])
        #expect(s.update(at: 4.45) == [.finish(0), .select(1, gap: 3)])
    }

    @Test func instrumentalBreaksAreSelectedLikeLines() {
        var s = selection([
            entry(0, 0, 2),
            LyricsTimelineEntry(kind: .instrumental(0), start: 2.1, end: 12),
            entry(1, 12, 14),
        ])
        _ = s.jump(to: 0)
        let events = s.update(at: 1.55)
        #expect(events.first == .finish(0))
        guard case .select(1, let gap)? = events.last else {
            Issue.record("the break is not selected: \(events)")
            return
        }
        #expect(abs((gap ?? 0) - 0.1) < 1e-9)
        #expect(s.selected == [1])
        #expect(s.update(at: 11.4) == [.finish(1)])
        #expect(s.update(at: 11.55) == [.finish(1), .select(2, gap: 0)])
    }

    @Test func jumpsSelectTheLineThatStartedLast() {
        var s = selection([entry(0, 1, 2), entry(1, 2, 4), entry(2, 4, 6)])
        #expect(s.jump(to: 0.2) == [.jump(0, selected: false)])
        #expect(s.update(at: 0.3) == [])
        #expect(s.update(at: 0.45) == [.select(0, gap: nil)])
        #expect(s.jump(to: 2.3) == [.jump(1, selected: true)])
        #expect(s.next == 2)
        // Within 0.1 s of a line start counts as that line.
        #expect(s.jump(to: 3.95) == [.jump(2, selected: true)])
    }

    @Test func pastTheLastLineNothingRepeats() {
        var s = selection([entry(0, 0, 4), entry(1, 2, 5)])
        _ = s.jump(to: 0)
        #expect(s.update(at: 2.1) == [.append(1)])
        #expect(s.update(at: 3.5) == [.deselect(0)])
        #expect(s.update(at: 4.8) == [.finish(1)])
        #expect(s.selected == [1])
    }

    @Test func theLastLineSelectedEarlyDoesNotHandBackToTheLineBefore() {
        // The last line is selected 0.5 s before the line before it ends; the cursor, re-found
        // on the next frame, must not fall back on that earlier line (it would be re-selected
        // once the last line neared its end: a jump back and forth).
        var s = selection([entry(0, 0, 10), entry(1, 10, 15)])
        _ = s.jump(to: 0)
        #expect(s.update(at: 9.55) == [.finish(0), .select(1, gap: 0)])
        #expect(s.update(at: 9.6) == [])
        #expect(s.next == 1)
        #expect(s.update(at: 14.6) == [.finish(1)])
        #expect(s.update(at: 14.7) == [.finish(1)])
        #expect(s.selected == [1])
    }

    @Test func aLineGivingWayAsItIsReachedIsPassedInOneFrame() {
        // Line 1 is too short to be lit before it would give way (end − 0.5 < its selection at
        // 1.55): it is selected and left within the same frame, which moves the page once.
        var s = selection([entry(0, 0, 2), entry(1, 2, 2), entry(2, 2, 4), entry(3, 4, 6)])
        _ = s.jump(to: 0)
        #expect(s.update(at: 1.45) == [.finish(0)])
        #expect(s.update(at: 1.55) == [.finish(0), .select(1, gap: 0), .finish(1), .select(2, gap: 0)])
        #expect(s.selected == [2])
        #expect(s.next == 3)
        #expect(s.update(at: 1.6) == [])
    }

    @Test func aLineWithBadTimingDoesNotCaptureSeeks() {
        var s = selection([entry(0, 1, 2), entry(1, 2, 4), entry(2, 4, 6), entry(3, 0, 8)])
        #expect(s.jump(to: 2.5) == [.jump(1, selected: true)])
        #expect(s.jump(to: 0.5) == [.jump(3, selected: true)])
    }

    @Test func timelineInterleavesBreaks() throws {
        let doc = LyricsDocument(format: .lrc, lines: [
            .plain(id: 0, start: 10, end: 12, text: "a"),
            .plain(id: 1, start: 12, end: 13, text: " "),
            .plain(id: 2, start: 25, end: 27, text: "b"),
        ])
        let gaps = doc.instrumentalGaps()
        let entries = LyricsSelection.entries(for: doc, gaps: gaps)
        #expect(entries.map(\.kind) == [.instrumental(0), .line(0), .instrumental(1), .line(2)])
        #expect(abs(entries[2].start - 12.1) < 1e-9)
    }
}
