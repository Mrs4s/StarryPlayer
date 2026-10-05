import AppKit
import Foundation
import LyricsCore
import Testing
@testable import LyricsUI

@MainActor
@Suite struct MenuBarLyricsTitleTests {
    /// A clock the test sets; `running` makes it follow real time from `time`.
    private final class Clock {
        var time: TimeInterval = 0
        var rate: Double = 0
        var since: CFTimeInterval?
        var reads = 0
        var now: (TimeInterval, Double) {
            reads += 1
            guard let since else { return (time, rate) }
            return (time + (CACurrentMediaTime() - since) * rate, rate)
        }
    }

    private static func document() -> LyricsDocument {
        LyricsDocument(format: .lrc, lines: [
            .plain(id: 0, start: 1, end: 3, text: "第一行"),
            .plain(id: 1, start: 3, end: 5, text: "这一句非常非常非常非常非常非常非常非常长的歌词放不下"),
            .plain(id: 2, start: 5, end: 6, text: "第三行"),
        ])
    }

    private func make(_ clock: Clock, maxWidth: CGFloat = 300) -> (MenuBarLyricsTitle, () -> Int) {
        let title = MenuBarLyricsTitle()
        var changes = 0
        title.maxTextWidth = maxWidth
        title.timeSource = { clock.now }
        title.onChange = { changes += 1 }
        title.content = .init(document: Self.document(), duration: 60, title: "歌名", artist: "歌手")
        return (title, { changes })
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test func showsTheSongThenTheLineDue() {
        let clock = Clock()
        let (title, _) = make(clock)
        #expect(title.text == "歌名 - 歌手")
        #expect(title.title == "歌名 - 歌手")
        clock.time = 2
        title.sync()
        #expect(title.text == "第一行")
        #expect(title.title == "第一行")
    }

    @Test func theTimerBringsTheNextLineWithoutWatchingTheClock() {
        let clock = Clock()
        let (title, changes) = make(clock)
        clock.time = 2.6
        clock.rate = 1
        clock.since = CACurrentMediaTime()
        title.sync()
        #expect(title.text == "第一行")
        let before = changes()
        let reads = clock.reads
        spin(0.4) // line 1 is due at 2.9
        #expect(title.text.hasPrefix("这一句"))
        #expect(changes() == before + 1)
        #expect(clock.reads == reads + 1)
    }

    @Test func pausedNothingIsScheduled() {
        let clock = Clock()
        let (title, _) = make(clock)
        clock.time = 2.75
        title.sync()
        spin(0.3)
        #expect(title.text == "第一行")
    }

    @Test func aStalledClockNeverShowsTheLineEarly() {
        let clock = Clock()
        let (title, _) = make(clock)
        clock.time = 2.7
        clock.rate = 1 // "playing", but the time does not move
        title.sync()
        spin(0.3)
        #expect(title.text == "第一行")
        clock.time = 2.95
        spin(LyricsChangeTimer.longestStallWait + 0.05)
        #expect(title.text.hasPrefix("这一句"))
    }

    @Test func aClockStandingStillBacksOff() {
        let timer = LyricsChangeTimer()
        var fired = 0
        timer.schedule(3, from: 2.9, rate: 1) { fired += 1 }
        #expect(abs((timer.lastDelay ?? 0) - 0.1) < 1e-9)
        timer.schedule(3, from: 2.9, rate: 1) { fired += 1 }
        #expect(abs((timer.lastDelay ?? 0) - 0.2) < 1e-9)
        timer.schedule(3, from: 2.9, rate: 1) { fired += 1 }
        timer.schedule(3, from: 2.9, rate: 1) { fired += 1 }
        #expect(timer.lastDelay == LyricsChangeTimer.longestStallWait)
        timer.schedule(3, from: 2.95, rate: 1) { fired += 1 }
        #expect(abs((timer.lastDelay ?? 0) - 0.05) < 1e-9)
        timer.cancel()
        #expect(!timer.isScheduled)
    }

    @Test func longLinesAreCutShortToTheWidth() {
        let clock = Clock()
        let (title, _) = make(clock, maxWidth: 120)
        clock.time = 4
        title.sync()
        #expect(title.text.hasPrefix("这一句非常"))
        #expect(title.title.hasSuffix("…"))
        #expect(title.title.count < title.text.count)
        let shown = NSAttributedString(string: title.title, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(shown), nil, nil, nil)
        #expect(width <= 120)
        #expect(width > 100)
        let short = NSAttributedString(string: "短", attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        #expect(MenuBarLyricsTitle.fitted(short, width: 120) == short)
    }

    @Test func noSongIsAnEmptyTitle() {
        let clock = Clock()
        let (title, _) = make(clock)
        title.content = .init()
        #expect(title.title.isEmpty)
        #expect(title.text.isEmpty)
    }
}
