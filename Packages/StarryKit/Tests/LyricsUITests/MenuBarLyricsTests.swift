import AppKit
import Foundation
import LyricsCore
import QuartzCore
import Testing
@testable import LyricsUI

@Suite struct MenuBarTrackTests {
    @Test func edgeTrackMatchesTheRowEdgeShiftedByTheHeadstart() {
        let steps: [RowLayer.Step] = [.init(start: 1, end: 2, target: 10), .init(start: 3, end: 4, target: 50)]
        let track = MenuBarTrack.edge(steps: steps, startEdge: -8, headstart: 0.1)
        let row = RowLayer()
        row.configure(rect: CGRect(x: 0, y: 0, width: 100, height: 20), overflow: .zero, feather: 8, tint: CGColor.white, steps: steps, words: [])
        for t in stride(from: 0.0, through: 5, by: 0.05) {
            #expect(abs(track.value(at: t) - row.edge(at: t + 0.1)) < 1e-9)
        }
    }

    @Test func overlappingSyllablesKeepKeysInOrder() {
        let steps: [RowLayer.Step] = [.init(start: 1, end: 2.5, target: 10), .init(start: 2, end: 3, target: 20)]
        let track = MenuBarTrack.edge(steps: steps, startEdge: 0, headstart: 0)
        for (a, b) in zip(track.keys, track.keys.dropFirst()) { #expect(b.time >= a.time) }
        #expect(track.value(at: 9) == 20)
    }

    @Test func clampingAddsKeysWhereTheBoundsBite() {
        let track = MenuBarTrack(keys: [.init(time: 0, value: 0), .init(time: 2, value: 100), .init(time: 3, value: 100), .init(time: 4, value: 40)])
        let clamped = track.clamped(offset: 30, range: 0...50)
        for t in stride(from: -1.0, through: 5, by: 0.01) {
            let expected = min(max(track.value(at: t) - 30, 0), 50)
            #expect(abs(clamped.value(at: t) - expected) < 1e-9)
        }
        let scaled = track.clamped(offset: 20, factor: 1 / 10, range: 0...1)
        #expect(abs(scaled.value(at: 0.5) - 0.5) < 1e-9)
        #expect(scaled.value(at: 1) == 1)
    }
}

@MainActor
private final class MenuBarHarness {
    let window: NSWindow
    let view: MenuBarLyricsView
    var time: TimeInterval = 0
    var rate: Double = 0
    /// Set by `play(from:)`: the clock runs with real time from `time` at this host time.
    var runningSince: CFTimeInterval?
    var widths: [CGFloat] = []

    init(maxTextWidth: CGFloat = 300) {
        _ = NSApplication.shared
        let size = CGSize(width: 400, height: 24)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        view = MenuBarLyricsView(frame: NSRect(origin: .zero, size: size))
        view.maxTextWidth = maxTextWidth
        view.timeSource = { [weak self] in
            guard let self else { return (0, 0) }
            guard let since = runningSince else { return (time, rate) }
            return (time + (CACurrentMediaTime() - since) * rate, rate)
        }
        view.onPreferredWidthChange = { [weak self] in self?.widths.append($0) }
        window.contentView = view
        view.content = .init(document: Self.document(), duration: 60, title: "歌名", artist: "歌手")
        CATransaction.flush()
    }

    static func document() -> LyricsDocument {
        func line(_ id: Int, _ text: String, _ start: Double, _ end: Double) -> LyricLine {
            let chars = Array(text)
            let per = (end - start) / Double(chars.count)
            return LyricLine(id: id, start: start, end: end, words: chars.enumerated().map { j, c in
                LyricWord(start: start + Double(j) * per, end: start + Double(j + 1) * per, text: String(c))
            })
        }
        return LyricsDocument(format: .yrc, lines: [
            line(0, "第一行歌词", 1, 3),
            line(1, "这是一行很长很长的歌词会比菜单栏的宽度还要长很多", 3, 9),
            line(2, "短", 9, 10),
        ])
    }

    func set(_ t: TimeInterval, rate: Double) {
        time = t
        self.rate = rate
        view.sync()
        CATransaction.flush()
    }

    /// Plays from `t` on a clock that follows real time.
    func play(from t: TimeInterval) {
        time = t
        rate = 1
        runningSince = CACurrentMediaTime()
        view.sync()
        CATransaction.flush()
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

@MainActor
@Suite struct MenuBarLyricsViewTests {
    @Test func displayCallbacksSeeTheMatchingTextAndWidth() {
        let h = MenuBarHarness()
        // The controller reads both properties from either callback. In particular, the
        // first nonempty title must never be published with the previous empty width (0).
        h.view.content = .init()
        var textChanges = 0
        h.view.onDisplayedTextChange = { text in
            textChanges += 1
            let expected = text.isEmpty ? 0 : ceil(h.view.currentSlot!.visibleWidth) + h.view.horizontalPadding * 2
            #expect(h.view.preferredWidth == expected)
        }
        h.view.onPreferredWidthChange = { width in
            #expect(h.view.displayedText == h.view.currentSlot?.text)
            #expect(h.view.preferredWidth == width)
        }
        defer {
            h.view.onDisplayedTextChange = nil
            h.view.onPreferredWidthChange = nil
        }
        h.view.content = .init(title: "First song", artist: "Artist")
        h.view.content = .init(title: "A much longer second song", artist: "Artist")
        h.view.content = .init()
        #expect(textChanges == 3)
    }

    @Test func appKitLayoutCallbacksDeferRebuildingTheText() async throws {
        let h = MenuBarHarness()
        let before = try #require(h.view.currentSlot)
        h.view.setFrameSize(NSSize(width: 400, height: 30))
        h.view.viewDidChangeBackingProperties()
        h.view.viewDidChangeBackingProperties()
        // AppKit may be resizing a status item's window. Don't draw or request another
        // window resize from inside its frame/backing-properties callbacks.
        #expect(h.view.currentSlot === before)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(h.view.currentSlot !== before)
        #expect(h.view.slotCount == 1)
        #expect(h.view.currentSlot?.frame.height == 30)
    }

    @Test func showsTheSongBeforeTheFirstLineThenTheLine() {
        let h = MenuBarHarness()
        h.set(0, rate: 0)
        #expect(h.view.displayedText == "歌名 - 歌手")
        #expect(h.view.preferredWidth > h.view.horizontalPadding * 2)
        h.set(1.5, rate: 0)
        #expect(h.view.displayedText == "第一行歌词")
        #expect(h.view.currentSlot?.isTimed == true)
    }

    @Test func pausedEdgeSitsWhereTheClockSays() throws {
        let h = MenuBarHarness()
        h.set(2, rate: 0)
        let slot = try #require(h.view.currentSlot)
        #expect(slot.progress.animation(forKey: "position.x") == nil)
        let expected = slot.edgeTrack.value(at: 2) + slot.feather + MenuBarSlotLayer.imagePadding
        #expect(abs(slot.progress.position.x - expected) < 1e-6)
        #expect(slot.edgeTrack.value(at: 2) > 0 && slot.edgeTrack.value(at: 2) < slot.textWidth)
    }

    @Test func playingEdgeRunsOnTheRenderServerInStepWithTheClock() throws {
        let h = MenuBarHarness()
        h.set(1.2, rate: 1)
        let slot = try #require(h.view.currentSlot)
        #expect(slot.progress.animation(forKey: "position.x") != nil)
        let start = CACurrentMediaTime()
        h.spin(0.5)
        let elapsed = CACurrentMediaTime() - start
        let shown = (slot.progress.presentation() ?? slot.progress).position.x
        let expected = slot.edgeTrack.value(at: 1.2 + elapsed) + slot.feather + MenuBarSlotLayer.imagePadding
        #expect(abs(shown - expected) < 2)
        h.set(1.2 + elapsed, rate: 0)
        #expect(slot.progress.animation(forKey: "position.x") == nil)
    }

    @Test func nextLineArrivesByTimerWithoutAnotherSync() {
        let h = MenuBarHarness()
        h.set(2.6, rate: 1)
        #expect(h.view.displayedText == "第一行歌词")
        h.time = 3.2 // the clock the timer will read
        h.spin(0.45) // line 1 is due at 2.9
        #expect(h.view.displayedText.hasPrefix("这是一行"))
    }

    @Test func linesChangeAtOnceWithoutAnimation() throws {
        let h = MenuBarHarness()
        h.play(from: 2.7)
        let first = try #require(h.view.currentSlot)
        h.spin(0.35) // line 1 takes over at 2.9, by the timer
        let second = try #require(h.view.currentSlot)
        #expect(second !== first)
        #expect(first.superlayer == nil)
        #expect(h.view.slotCount == 1)
        #expect(second.animationKeys() == nil)
        #expect(second.opacity == 1)
        h.runningSince = nil
        h.set(1.5, rate: 1)
        #expect(h.view.displayedText == "第一行歌词")
        #expect(h.view.slotCount == 1)
        #expect(h.view.currentSlot?.animationKeys() == nil)
    }

    @Test func longLinesScrollToTheirEndAndFadeWhereCut() throws {
        let h = MenuBarHarness(maxTextWidth: 120)
        h.set(4, rate: 0)
        let slot = try #require(h.view.currentSlot)
        #expect(slot.textWidth > 120)
        #expect(slot.visibleWidth == 120)
        #expect(slot.mask != nil)
        // Early on: not scrolled, only the right side fades (its cover is hidden).
        #expect(slot.line.position.x == -MenuBarSlotLayer.imagePadding)
        #expect(slot.leftCover.opacity == 1)
        #expect(slot.rightCover.opacity == 0)
        h.set(8.7, rate: 0)
        #expect(h.view.currentSlot === slot)
        let overflow = slot.textWidth - slot.visibleWidth
        #expect(abs(slot.line.position.x - (-MenuBarSlotLayer.imagePadding - overflow)) < 0.5)
        #expect(slot.leftCover.opacity == 0)
        #expect(slot.rightCover.opacity == 1)
    }

    @Test func widthFollowsEachLineAtOnce() {
        let h = MenuBarHarness(maxTextWidth: 120)
        h.set(1.5, rate: 0)
        let short = h.view.preferredWidth
        h.set(4, rate: 0)
        #expect(h.view.preferredWidth == 120 + h.view.horizontalPadding * 2)
        #expect(h.view.preferredWidth > short)
        h.set(9.5, rate: 0)
        #expect(h.view.preferredWidth < short)
        #expect(h.view.slotCount == 1)
        #expect(h.widths.last == h.view.preferredWidth)
    }

    @Test func lyricsArrivingDuringTheIntroDoNotReplayTheSong() throws {
        let h = MenuBarHarness()
        h.view.content = .init(document: nil, duration: 0, title: "歌名", artist: "歌手")
        h.set(0.3, rate: 1)
        h.spin(0.5)
        let song = try #require(h.view.currentSlot)
        h.view.content = .init(document: MenuBarHarness.document(), duration: 60, title: "歌名", artist: "歌手")
        CATransaction.flush()
        let replaced = try #require(h.view.currentSlot)
        #expect(replaced !== song)
        #expect(replaced.animationKeys() == nil)
        #expect(h.view.slotCount == 1)
    }

    @Test func withoutLyricsOrPerSyllableTheLineIsLitWhole() throws {
        let h = MenuBarHarness()
        h.view.perSyllable = false
        h.set(2, rate: 1)
        let slot = try #require(h.view.currentSlot)
        #expect(slot.isTimed == false)
        #expect(slot.unsung.opacity == 1)
        h.view.content = .init(document: nil, duration: 60, title: "另一首", artist: "")
        CATransaction.flush()
        #expect(h.view.displayedText == "另一首")
    }
}
