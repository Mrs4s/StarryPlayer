import AppKit
import Foundation
import LyricsCore
import QuartzCore
import Testing
@testable import LyricsUI

@Suite struct ProgressGeometryTests {
    private let font = NSFont.systemFont(ofSize: 48, weight: .bold)

    @Test func inkBoundsIgnoreTrailingSpaces() {
        let line = LyricLine(id: 0, start: 0, end: 2, words: [
            LyricWord(start: 0, end: 1, text: "Hello "),
            LyricWord(start: 1, end: 2, text: "world "),
        ])
        let layout = LineTextLayout.layout(line: line, font: font, width: 2000, leading: 52, alignment: .left, perSyllable: true)
        let fragments = layout.rows[0].fragments
        #expect(fragments.count == 2)
        // The advance rect of "Hello " includes the space, the ink does not.
        #expect(fragments[0].inkMaxX < fragments[0].rect.maxX - 5)
        #expect(fragments[1].rect.maxX - fragments[1].inkMaxX < 5)
    }

    @Test func progressTargetsLeadTowardsTheNextWord() {
        let words = ["夜", "色", "把", "街"].enumerated().map { i, c in
            LyricWord(start: Double(i) * 0.5, end: Double(i + 1) * 0.5, text: c)
        }
        let line = LyricLine(id: 0, start: 0, end: 2, words: words)
        let layout = LineTextLayout.layout(line: line, font: font, width: 600, leading: 52, alignment: .left, perSyllable: true)
        let row = layout.rows[0]
        let f: CGFloat = 30
        let steps = VoiceLayer.progressSteps(row: row, syllables: line.syllables, words: line.words,
                                            wordOfSyllable: [0, 1, 2, 3], lastSyllableOfWord: [0, 1, 2, 3], feather: f)
        #expect(steps.count == 4)
        for i in 0..<3 {
            let expected = row.fragments[i + 1].inkMinX - f * 0.5
            #expect(abs(steps[i].target - expected) < 0.01)
        }
        #expect(abs(steps[3].target - row.fragments[3].inkMaxX) < 0.01)
        for (a, b) in zip(steps, steps.dropFirst()) { #expect(b.target >= a.target) }
    }

    @Test func rowEdgeInterpolatesAndHolds() {
        let row = RowLayer()
        row.configure(rect: CGRect(x: 0, y: 0, width: 400, height: 52), overflow: CGSize(width: 20, height: 20), feather: 30, tint: CGColor.white,
                      steps: [.init(start: 0, end: 1, target: 10), .init(start: 2, end: 3, target: 50)], words: [])
        #expect(row.edge(at: -1) == -30)
        #expect(abs(row.edge(at: 0.5) - (-10)) < 1e-9)
        #expect(row.edge(at: 1.5) == 10)
        #expect(abs(row.edge(at: 2.5) - 30) < 1e-9)
        #expect(row.edge(at: 9) == 50)
        #expect(row.finalEdge == 50)
    }
}

/// Drives a window-hosted `LyricsView` and samples presentation layers, so motion can be
/// checked numerically (no screen capture needed).
@MainActor
private final class Harness {
    let window: NSWindow
    let view: LyricsView
    var seeks: [TimeInterval] = []

    init(size: CGSize = CGSize(width: 700, height: 800), document: LyricsDocument = Harness.document()) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        view = LyricsView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        view.specs = .windowed
        view.document = document
        view.layoutSubtreeIfNeeded()
        view.onSeek = { [weak self] t in self?.seeks.append(t) }
        CATransaction.flush()
    }

    /// 40 lines of two seconds, one timed word per character.
    static func document() -> LyricsDocument {
        let lines = (0..<40).map { i -> LyricLine in
            let start = Double(i) * 2
            let chars = Array("第\(i)行歌词的测试文本")
            let per = 2 / Double(chars.count)
            let words = chars.enumerated().map { j, c in
                LyricWord(start: start + Double(j) * per, end: start + Double(j + 1) * per, text: String(c))
            }
            return LyricLine(id: i, start: start, end: start + 2, words: words)
        }
        return LyricsDocument(format: .yrc, lines: lines)
    }

    static func romanizedDocument() -> LyricsDocument {
        var doc = document()
        for i in doc.lines.indices {
            let words = doc.lines[i].words.map { w in LyricWord(start: w.start, end: w.end, text: "ro\(w.text.unicodeScalars.first!.value % 7) ") }
            doc.lines[i].romanizationWords = words
            doc.lines[i].romanization = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        }
        return doc
    }

    func setTime(_ t: TimeInterval) {
        view.update(time: t, rate: 0)
        CATransaction.flush()
    }

    /// Drags the playback position to `t`; nil ends the drag.
    func scrub(_ t: TimeInterval?) {
        view.scrub(to: t)
        CATransaction.flush()
    }

    var lags: [CABasicAnimation] {
        lines.flatMap { l in (l.animationKeys() ?? []).filter { $0.hasPrefix("lag-") }.compactMap { l.animation(forKey: $0) as? CABasicAnimation } }
    }

    func advance(from start: TimeInterval, to end: TimeInterval, step: TimeInterval = 0.05) {
        var t = start
        while t < end - 1e-9 {
            t = min(end, t + step)
            setTime(t)
        }
    }

    /// 24 lines of two seconds. Line 5 (primary) runs until 13 s under line 6 (secondary
    /// voice, 12–14 s); line 8 has background vocals from 17 s to 18.5 s.
    static func duetDocument() -> LyricsDocument {
        func words(_ text: String, _ start: Double, _ end: Double) -> [LyricWord] {
            let chars = Array(text)
            let per = (end - start) / Double(chars.count)
            return chars.enumerated().map { j, c in LyricWord(start: start + Double(j) * per, end: start + Double(j + 1) * per, text: String(c)) }
        }
        let lines = (0..<24).map { i -> LyricLine in
            let start = Double(i) * 2
            var end = start + 2
            if i == 5 { end = 13 }
            var line = LyricLine(id: i, start: start, end: end, words: words("第\(i)行歌词的测试文本", start, end), singer: i == 6 ? .secondary : .primary)
            if i == 8 {
                let bg = LyricBackgroundVocals(start: 17, end: 18.5, words: words("（和声和声）", 17, 18.5))
                line.background = bg
                line.end = 18.5
                line.primaryEnd = 18
            }
            return line
        }
        return LyricsDocument(format: .yrc, lines: lines)
    }

    static func timedDocument(_ times: [(Double, Double)], secondary: Set<Int> = []) -> LyricsDocument {
        let lines = times.enumerated().map { i, time -> LyricLine in
            let chars = Array("第\(i)行歌词的测试文本")
            let per = (time.1 - time.0) / Double(chars.count)
            let words = chars.enumerated().map { j, c in LyricWord(start: time.0 + Double(j) * per, end: time.0 + Double(j + 1) * per, text: String(c)) }
            return LyricLine(id: i, start: time.0, end: time.1, words: words, singer: secondary.contains(i) ? .secondary : .primary)
        }
        return LyricsDocument(format: .yrc, lines: lines)
    }

    /// 20 lines of two seconds with translations and romanizations; lines 0–5 run 0–12 s,
    /// then a 14 s instrumental break (12.1–26 s) before line 6.
    static func breakDocument() -> LyricsDocument {
        let lines = (0..<20).map { i -> LyricLine in
            let start = i < 6 ? Double(i) * 2 : 26 + Double(i - 6) * 2
            let chars = Array("第\(i)行歌词的测试文本")
            let per = 2 / Double(chars.count)
            let words = chars.enumerated().map { j, c in
                LyricWord(start: start + Double(j) * per, end: start + Double(j + 1) * per, text: String(c))
            }
            return LyricLine(id: i, start: start, end: start + 2, words: words, translation: "Line \(i) translated", romanization: "di \(i) hang")
        }
        return LyricsDocument(format: .yrc, lines: lines)
    }

    var breaks: [InstrumentalBreakLayer] { contentLayer.sublayers?.compactMap { $0 as? InstrumentalBreakLayer } ?? [] }

    func visualTop(of gap: InstrumentalBreakLayer) -> CGFloat {
        let content = (contentLayer.presentation() ?? contentLayer).position.y
        let p = gap.presentation() ?? gap
        let ty = (p.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        return content + p.position.y + ty - gap.bounds.height / 2
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Ends every running animation at once, as if the view had been left alone: a test's
    /// starting point, not what it checks.
    func settle() {
        func strip(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.mask.map(strip)
            layer.sublayers?.forEach(strip)
        }
        strip(view.layer!)
        CATransaction.flush()
        spin(0.01)
    }

    /// Spins until the springs (`lag-*`) of the given lines have run out, at most `timeout`;
    /// without lines, those of every line and break (far lines start up to seconds later).
    /// Finished animations stay attached in this window, so their end times are what counts.
    func waitForLags(_ indices: Int..., timeout: TimeInterval = 2) {
        let layers = indices.isEmpty ? contentLayer.sublayers ?? [] : indices.compactMap { line($0) }
        let left = layers.flatMap { l -> [TimeInterval] in
            let now = l.convertTime(CACurrentMediaTime(), from: nil)
            return (l.animationKeys() ?? []).filter { $0.hasPrefix("lag-") }.compactMap { l.animation(forKey: $0) }
                .map { $0.beginTime == 0 ? $0.duration : $0.beginTime + $0.duration - now }
        }
        spin(min(timeout, max(0, left.max() ?? 0) + 0.05))
    }

    var contentLayer: CALayer { view.layer!.sublayers!.first! }
    var lines: [LineLayer] { contentLayer.sublayers?.compactMap { $0 as? LineLayer } ?? [] }
    func line(_ index: Int) -> LineLayer? { lines.first { $0.lineIndex == index } }

    func visualTops() -> [Int: CGFloat] {
        let content = (contentLayer.presentation() ?? contentLayer).position.y
        var out: [Int: CGFloat] = [:]
        for l in lines {
            let p = l.presentation() ?? l
            let ty = (p.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
            out[l.lineIndex] = content + p.position.y + ty - l.bounds.height / 2
        }
        return out
    }

    /// On-screen tops at the instant the springs start: model position plus the starting offset
    /// of every running lag. Unlike `visualTops()` this does not depend on how much time passed
    /// before the sample.
    func startTops() -> [Int: CGFloat] {
        let content = contentLayer.position.y
        var out: [Int: CGFloat] = [:]
        for l in lines {
            let lag = (l.animationKeys() ?? []).filter { $0.hasPrefix("lag-") }
                .compactMap { ((l.animation(forKey: $0) as? CABasicAnimation)?.fromValue as? NSNumber)?.doubleValue }
                .reduce(0, +)
            out[l.lineIndex] = content + l.position.y + CGFloat(lag) - l.bounds.height / 2
        }
        return out
    }

    func maxJump(_ a: [Int: CGFloat], _ b: [Int: CGFloat]) -> CGFloat {
        a.keys.compactMap { k in b[k].map { abs($0 - a[k]!) } }.max() ?? 0
    }

    var hasLagAnimations: Bool { lines.contains { LyricsAnimation.hasLags($0) } }

    func click(line index: Int) {
        guard let top = visualTops()[index] else { return }
        let point = NSPoint(x: 60, y: window.frame.height - (top + 20))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        CATransaction.flush()
    }

    func scroll(by dy: Int32) {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: cg)!)
        CATransaction.flush()
    }
}

@Suite(.serialized) @MainActor struct LyricsMotionTests {
    private var anchorTop: CGFloat { LyricsSpecs.windowed.selectedLineTop(viewHeight: 800) ?? 0 }

    @Test func interruptedLineChangesStackWithoutJumping() {
        let h = Harness()
        h.setTime(10.05)
        h.settle()
        h.setTime(12.05)
        h.spin(0.08)
        let before = h.visualTops()
        h.setTime(14.05)
        let after = h.visualTops()
        #expect(h.maxJump(before, after) < 5)
        h.waitForLags(7)
        #expect(abs((h.visualTops()[7] ?? 0) - anchorTop) < 1)
    }

    @Test func clickAfterScrollingIsOneContinuousMotion() {
        let h = Harness()
        h.setTime(10.05)
        h.settle()
        h.scroll(by: -250)
        h.spin(0.1)
        let before = h.visualTops()
        h.click(line: 8)
        let after = h.visualTops()
        #expect(h.maxJump(before, after) < 5)
        #expect(h.seeks == [16])
        h.waitForLags(8)
        #expect(h.line(8)?.state == .selected)
        #expect(abs((h.visualTops()[8] ?? 0) - anchorTop) < 1)
    }

    @Test(arguments: [Int32(1000), -2400])
    func scrollTimeoutAnimatesBackToThePlayingLine(delta: Int32) throws {
        let h = Harness()
        h.setTime(20.05)
        h.settle()
        var scrolling = false
        var beforeReturn: [Int: CGFloat]?
        h.view.onUserScrollingChanged = { active in
            scrolling = active
            if !active { beforeReturn = h.visualTops() }
        }
        defer { h.view.onUserScrollingChanged = nil }
        h.scroll(by: delta)
        #expect(scrolling)
        h.advance(from: 20.05, to: 22.05)
        try #require(h.view.userScrollTimer).fire()
        CATransaction.flush()
        #expect(!scrolling)
        let before = try #require(beforeReturn)
        #expect(h.hasLagAnimations, "the playing line was offscreen, but returning should animate")
        let starts = h.startTops()
        #expect(Set(before.keys).isSubset(of: Set(starts.keys)), "keep the old viewport's lines during the return")
        #expect(h.maxJump(before, starts) < 1, "the return must start at the scrolled position")
        #expect(abs((h.visualTops()[11] ?? anchorTop) - anchorTop) > 30, "returned in one frame")
        let begins = h.lags.map(\.beginTime)
        #expect((begins.max() ?? 0) - (begins.min() ?? 0) < 0.01, "long returns must not stagger across every intervening line")
        h.waitForLags(11)
        #expect(abs((h.visualTops()[11] ?? 0) - anchorTop) < 1)
        #expect(h.line(11)?.state == .selected)
        #expect(h.line(12)?.blurTarget == 2)
        #expect(h.seeks.isEmpty, "returning must not seek playback")
    }

    @Test func aLineReachedAsItGivesWayStillMoves() {
        // Line 5 (10–10.1 s) is selected at 9.55 s as line 4 gives way, with 0.05 s left before
        // it gives way itself: the change must not be squeezed into those 0.05 s.
        let times = (0..<20).map { i -> (Double, Double) in
            switch i {
            case ..<5: (Double(i) * 2, Double(i) * 2 + 2)
            case 5: (10, 10.1)
            default: (10.1 + Double(i - 6) * 2, 12.1 + Double(i - 6) * 2)
            }
        }
        let h = Harness(document: Harness.timedDocument(times))
        h.setTime(8.05)
        h.settle()
        h.advance(from: 8.05, to: 9.5)
        let before = Set(h.lags.map { ObjectIdentifier($0) })
        h.setTime(9.55)
        #expect(h.line(5)?.state == .selected)
        let added = h.lags.filter { !before.contains(ObjectIdentifier($0)) }
        #expect(!added.isEmpty)
        for lag in added {
            #expect(lag.duration / Double(lag.speed) >= LyricsSpecs.windowed.minimumLineChangeDuration - 1e-6, "squeezed into \(lag.duration / Double(lag.speed)) s")
        }
    }

    @Test func playbackMovesOnToALineThatWasOffscreen() {
        // Three voices: lines 5–7 are lit together (6 and 7 join in place) and give way at
        // once to line 8, three lines further down — below the bottom of this short view. The
        // page must move there with springs rather than jump.
        let times: [(Double, Double)] = (0..<5).map { (Double($0) * 2, Double($0) * 2 + 2) } + [(10, 13), (12, 13), (12.2, 13)] + (0..<10).map { (13 + Double($0) * 2, 15 + Double($0) * 2) }
        let h = Harness(size: CGSize(width: 700, height: 250), document: Harness.timedDocument(times, secondary: [6]))
        h.setTime(10.05)
        h.advance(from: 10.05, to: 12.5)
        #expect([5, 6, 7].allSatisfy { h.line($0)?.state == .selected })
        h.settle()
        let before = h.visualTops()
        #expect((before[8] ?? 0) > h.view.bounds.height, "line 8 starts below the view")
        h.setTime(12.55)
        #expect(h.line(8)?.state == .selected)
        #expect(h.hasLagAnimations)
        #expect(h.maxJump(before, h.startTops()) < 1, "the move must start where the page was")
        h.waitForLags(8)
        #expect(abs((h.visualTops()[8] ?? 0) - (LyricsSpecs.windowed.selectedLineTop(viewHeight: 250) ?? 0)) < 1)
    }

    @Test func specsChangeReanchorsWithoutAnimation() {
        let h = Harness()
        h.setTime(20.05)
        h.settle()
        var specs = LyricsSpecs.windowed
        specs.scale = 0.8
        h.view.specs = specs
        CATransaction.flush()
        #expect(!h.hasLagAnimations)
        #expect(abs((h.visualTops()[10] ?? 0) - (specs.scaled().selectedLineTop(viewHeight: 800) ?? 0)) < 1)
    }

    @Test func farSeekJumpsWithoutFlyingLines() {
        let h = Harness()
        h.setTime(10.05)
        h.settle()
        h.setTime(60.05)
        #expect(!h.hasLagAnimations)
        #expect(abs((h.visualTops()[30] ?? 0) - anchorTop) < 1)
    }

    @Test func blurFollowsDistanceAndLeavesTheSelectedLine() {
        let h = Harness()
        h.setTime(20.05)
        h.spin(0.2) // the un-blurred line drops its filter after the 0.12 s transition
        #expect(h.line(10)?.state == .selected)
        #expect(h.line(10)?.filters == nil)
        #expect(h.line(11)?.blurTarget == 2)
        #expect(h.line(12)?.blurTarget == 3)
        #expect(h.line(13)?.blurTarget == 4)
        #expect(h.line(15)?.blurTarget == 4)
        #expect(h.line(9)?.blurTarget == 3)
        #expect(h.line(7)?.blurTarget == 3)
        #expect(h.line(11)?.showsBlur == true)
    }

    @Test func theLastLineStaysPutAsItEnds() {
        let h = Harness()
        h.setTime(77.55)
        h.setTime(77.6)
        h.settle()
        #expect(h.line(39)?.state == .selected)
        let position = h.contentLayer.position.y
        // Played through in small steps (a seek would restart the selection and hide it).
        var t = 77.6
        while t < 80.2 {
            t += 0.05
            h.setTime(t)
            #expect(h.contentLayer.position.y == position, "page moved at \(t)")
            #expect(h.line(39)?.state == .selected, "line 39 lost the selection at \(t)")
        }
        #expect(!h.hasLagAnimations)
    }

    @Test func settledLinesOutsideTheBufferAreDropped() {
        let h = Harness()
        h.setTime(0.05)
        // Played through to line 25 in small steps. Every change gives every line a spring, so
        // nothing is dropped while they run.
        h.advance(from: 0.05, to: 50.05)
        #expect(h.line(25)?.state == .selected)
        #expect(h.line(0) != nil)
        let before = h.lines.count
        h.waitForLags(timeout: 4)
        h.setTime(50.1)
        #expect(h.lines.count < before)
        #expect(h.line(0) == nil)
        #expect(h.line(25)?.state == .selected)
        let height = h.view.bounds.height
        let tops = h.visualTops()
        for l in h.lines {
            let top = tops[l.lineIndex] ?? 0
            #expect(top + l.bounds.height >= -height * 0.6 - 1, "line \(l.lineIndex) is above the buffer")
            #expect(top <= height * 1.6 + 1, "line \(l.lineIndex) is below the buffer")
        }
    }

    @Test func clockIgnoresOffsetAndSmallRewinds() {
        let h = Harness()
        h.view.timeOffset = 0.5
        h.view.update(time: 20, rate: 1)
        let t0 = CACurrentMediaTime()
        h.view.update(time: 19.97, rate: 1)   // a slightly stale sample
        let now = CACurrentMediaTime()
        #expect(abs(h.view.lyricTime(at: now) - (20.5 + (now - t0))) < 0.015)

        h.view.timeOffset = 0
        h.setTime(20)
        #expect(h.line(10)?.state == .selected)
        h.setTime(19.8)                        // < 0.5 s back: ignored
        #expect(h.line(10)?.state == .selected)
        h.setTime(17)                          // a real seek back
        #expect(h.line(8)?.state == .selected)
    }
}

@Suite(.serialized) @MainActor struct LyricsScrubTests {
    private var anchorTop: CGFloat { LyricsSpecs.windowed.selectedLineTop(viewHeight: 800) ?? 0 }

    private func isLinear(_ anim: CABasicAnimation) -> Bool {
        guard !(anim is CASpringAnimation), let f = anim.timingFunction else { return false }
        var a: [Float] = [0, 0], b: [Float] = [0, 0]
        f.getControlPoint(at: 1, values: &a)
        f.getControlPoint(at: 2, values: &b)
        return a == [0, 0] && b == [1, 1]
    }

    @Test func newLineMovesThePageInOneLinearStep() {
        let h = Harness()
        h.setTime(10.05)
        h.settle()
        h.scrub(10.3)
        #expect(h.view.isScrubbing)
        #expect(!h.hasLagAnimations)
        #expect(h.line(5)?.state == .selected)
        h.scrub(12.1)
        #expect(h.line(6)?.state == .selected)
        #expect(h.line(5)?.state == .past)
        let lags = h.lags
        #expect(!lags.isEmpty)
        #expect(lags.allSatisfy { isLinear($0) && abs($0.duration - LyricsAnimation.scrubDuration) < 1e-9 })
        #expect(Set(lags.map { ($0.fromValue as! NSNumber).doubleValue.rounded() }).count == 1)
        #expect((lags.map(\.beginTime).max() ?? 0) - (lags.map(\.beginTime).min() ?? 0) < 0.001)
        h.spin(LyricsAnimation.scrubDuration + 0.1)
        #expect(abs((h.visualTops()[6] ?? 0) - anchorTop) < 1)
    }

    @Test func steadyDragNeverJumps() {
        let h = Harness()
        h.setTime(10.05)
        h.settle()
        h.scrub(10.1)
        var worst: CGFloat = 0
        var t = 10.1
        while t < 22 {
            t += 0.3
            let before = h.visualTops()
            h.scrub(t)
            worst = max(worst, h.maxJump(before, h.visualTops()))
            h.spin(0.016)
        }
        #expect(worst < 3)
        #expect(h.line(11)?.state == .selected)
        h.spin(LyricsAnimation.scrubDuration + 0.1)
        #expect(abs((h.visualTops()[11] ?? 0) - anchorTop) < 1)
    }

    @Test func draggingBackReselectsEvenWithinHalfASecond() {
        let h = Harness()
        h.setTime(20.05)
        h.settle()
        h.scrub(20.1)
        h.scrub(19.7)
        #expect(h.line(9)?.state == .selected)
        #expect(h.line(10)?.state == .upcoming)
        h.spin(LyricsAnimation.scrubDuration + 0.1)
        #expect(abs((h.visualTops()[9] ?? 0) - anchorTop) < 1)
    }

    @Test func blurClearsWhileDraggingAndComesBackAfter() {
        let h = Harness()
        h.setTime(20.05)
        h.settle()
        #expect(h.line(12)?.blurTarget == 3)
        h.scrub(20.2)
        #expect(h.lines.allSatisfy { $0.blurTarget == 0 })
        h.scrub(24.1)
        #expect(h.line(12)?.state == .selected)
        #expect(h.lines.allSatisfy { $0.blurTarget == 0 })
        h.scrub(nil)
        #expect(!h.view.isScrubbing)
        #expect(h.line(13)?.blurTarget == 2)
        #expect(h.line(11)?.blurTarget == 3)
    }

    @Test func playerClockWaitsForTheDragAndResumesWithoutAJump() {
        let h = Harness()
        h.setTime(10.05)
        h.settle()
        h.scrub(10.2)
        h.setTime(30)                          // the player's clock while dragging: ignored
        #expect(h.line(5)?.state == .selected)
        h.scrub(16.1)
        #expect(h.line(8)?.state == .selected)
        h.spin(LyricsAnimation.scrubDuration + 0.1)
        h.scrub(nil)
        h.view.update(time: 16.15, rate: 1)    // the player reports from the new position
        CATransaction.flush()
        h.spin(0.05)
        #expect(!h.hasLagAnimations)
        #expect(h.line(8)?.state == .selected)
        #expect(abs((h.visualTops()[8] ?? 0) - anchorTop) < 1)
    }

    @Test func firstPositionFarAwaySeeksLikeAClick() {
        let h = Harness()
        h.setTime(10.05)
        h.settle()
        h.scrub(60.05)
        #expect(h.line(30)?.state == .selected)
        #expect(!h.hasLagAnimations)
        #expect(abs((h.visualTops()[30] ?? 0) - anchorTop) < 1)
    }
}

@Suite(.serialized) @MainActor struct LyricsSelectionViewTests {
    private var anchorTop: CGFloat { LyricsSpecs.windowed.selectedLineTop(viewHeight: 800) ?? 0 }

    @Test func overlappingLinesAreLitTogetherAndThePageFollowsTheOlder() {
        let h = Harness(document: Harness.duetDocument())
        h.setTime(10.05)
        h.settle()
        #expect(h.line(5)?.state == .selected)
        h.advance(from: 10.05, to: 12.1)
        #expect(h.line(5)?.state == .selected)
        #expect(h.line(6)?.state == .selected)
        #expect(h.line(7)?.state == .upcoming)
        #expect(h.line(6)?.blurTarget == 0)
        #expect(h.line(7)?.blurTarget == 2)
        h.waitForLags(5, timeout: 1.5)
        #expect(abs((h.visualTops()[5] ?? 0) - anchorTop) < 1)
        h.advance(from: 12.1, to: 12.9)
        #expect(h.line(5)?.state == .past)
        #expect(h.line(6)?.state == .selected)
        h.waitForLags(6)
        #expect(abs((h.visualTops()[6] ?? 0) - anchorTop) < 1)
    }

    @Test func duetLinesAreNarrowerAndKeepTheirSide() {
        let h = Harness(document: Harness.duetDocument())
        h.setTime(12.05)
        h.spin(0.2)
        let left = h.line(5)!, right = h.line(6)!
        #expect(left.bounds.width < h.view.bounds.width * 0.86)
        #expect(left.anchorPoint.x == 0 && right.anchorPoint.x == 1)
        #expect(right.position.x > left.position.x + left.bounds.width)
    }

    @Test func backgroundVocalsOpenUnderTheirLineWhileSelected() {
        let h = Harness(document: Harness.duetDocument())
        h.setTime(15.4)
        h.settle()
        let line = h.line(8)!
        let collapsed = line.contentHeight
        #expect(!line.isExpanded)
        #expect(line.background?.opacity == 0)
        var worst: CGFloat = 0
        var t = 15.4
        while t < 16.1 {
            t += 0.05
            let before = h.visualTops()
            h.setTime(t)
            worst = max(worst, h.maxJump(before, h.visualTops()))
            h.spin(0.016)
        }
        #expect(worst < 3)
        #expect(line.state == .selected)
        #expect(line.isExpanded)
        #expect(line.background?.opacity == 1)
        #expect(line.contentHeight > collapsed + LyricsSpecs.windowed.backgroundVocalsTopSpacing)
        #expect(!line.backgroundAbove)
        #expect(line.background!.frame.minY >= line.main.frame.maxY)
        h.waitForLags(8, 9)
        let tops = h.visualTops()
        let gap = (tops[9] ?? 0) - ((tops[8] ?? 0) + line.contentHeight)
        #expect(abs(gap - LyricsSpecs.windowed.lineSpacing) < 1)
        h.advance(from: 16.1, to: 18.2)
        #expect(line.state == .selected)
        #expect(line.isExpanded)
        #expect(h.line(9)?.state == .selected)
        h.advance(from: 18.2, to: 18.7)
        #expect(line.state == .past)
        #expect(!line.isExpanded)
        #expect(line.background?.opacity == 0)
    }
}

@Suite(.serialized) @MainActor struct LyricsStateTransitionTests {
    private var anchorTop: CGFloat { LyricsSpecs.windowed.selectedLineTop(viewHeight: 800) ?? 0 }

    private func space(_ h: Harness, _ a: Int, _ b: Int) -> CGFloat {
        let tops = h.visualTops()
        return (tops[b] ?? 0) - ((tops[a] ?? 0) + (h.line(a)?.bounds.height ?? 0))
    }

    @Test func instrumentalBreakOpensOnlyWhileSelected() {
        let s = LyricsSpecs.windowed
        let h = Harness(document: Harness.breakDocument())
        h.setTime(8.05)
        h.settle()
        #expect(abs(space(h, 5, 6) - s.lineSpacing) < 1)
        var worst: CGFloat = 0
        var t = 8.05
        while t < 13.5 {
            t += 0.05
            let before = h.visualTops()
            h.setTime(t)
            worst = max(worst, h.maxJump(before, h.visualTops()))
            h.spin(0.016)
        }
        #expect(worst < 3)
        let gap = h.breaks.first!
        #expect(gap.isSelected)
        #expect(h.line(5)?.state == .past)
        h.waitForLags(timeout: 1.5)
        #expect(abs(space(h, 5, 6) - (2 * s.lineSpacing + s.instrumentalBreakViewHeight)) < 1)
        #expect(abs(h.visualTop(of: gap) - anchorTop) < 1)
        #expect(gap.dots.allSatisfy { $0.opacity == InstrumentalBreakLayer.unlitOpacity || $0.opacity == 1 })
        h.advance(from: t, to: 20, step: 0.1)
        #expect(gap.dots[0].opacity == 1)
        h.advance(from: 20, to: 24.5, step: 0.1)
        #expect(gap.fadeOutCued)
        #expect(gap.isSelected)
        h.advance(from: 24.5, to: 26.1, step: 0.1)
        #expect(!gap.isSelected)
        #expect(h.line(6)?.state == .selected)
        h.waitForLags(5, 6, timeout: 1.5)
        #expect(abs(space(h, 5, 6) - s.lineSpacing) < 1)
        #expect(abs((h.visualTops()[6] ?? 0) - anchorTop) < 1)
    }

    @Test func introBreakPushesTheFirstLineDown() {
        var lines = Harness.breakDocument().lines
        for i in lines.indices {
            lines[i].start += 20
            lines[i].end += 20
            lines[i].words = lines[i].words.map { var w = $0; w.start += 20; w.end += 20; return w }
        }
        let h = Harness(document: LyricsDocument(format: .yrc, lines: lines))
        h.setTime(2)
        h.settle()
        let gap = h.breaks.first!
        #expect(gap.isSelected)
        let s = LyricsSpecs.windowed
        #expect(abs((h.visualTops()[0] ?? 0) - h.visualTop(of: gap) - (s.instrumentalBreakViewHeight + s.lineSpacing)) < 1)
    }

    @Test func translationToggleAnimatesInPlace() {
        let s = LyricsSpecs.windowed
        let h = Harness(document: Harness.breakDocument())
        h.setTime(4.05)
        h.settle()
        let line = h.line(2)!
        let withTranslation = line.contentHeight
        #expect(line.main.secondaryBlock(.translation) != nil)
        #expect(line.main.secondaryBlock(.romanization) == nil)

        var specs = LyricsSpecs.windowed
        specs.showTranslation = false
        var before = h.visualTops()
        h.view.specs = specs
        CATransaction.flush()
        // Same layers, moved with springs from where they were (`startTops`: the springs of the
        // far lines cover a pixel or two in the milliseconds before a presentation sample).
        #expect(h.line(2) === line)
        #expect(h.maxJump(before, h.startTops()) < 2)
        #expect(h.hasLagAnimations)
        #expect(line.main.secondaryBlock(.translation) == nil)
        #expect(line.contentHeight < withTranslation)
        h.waitForLags(2, 3, timeout: 1.5)
        #expect(abs((h.visualTops()[2] ?? 0) - anchorTop) < 1)
        #expect(abs(space(h, 2, 3) - s.lineSpacing) < 1)

        specs.showRomanization = true
        before = h.visualTops()
        h.view.specs = specs
        CATransaction.flush()
        #expect(h.maxJump(before, h.startTops()) < 2)
        let block = line.main.secondaryBlock(.romanization)
        #expect(block?.animation(forKey: "reveal") != nil)
        #expect(block?.animation(forKey: "opacity") != nil)
        h.waitForLags(2, 3, timeout: 1.5)
        #expect(abs(space(h, 2, 3) - s.lineSpacing) < 1)

        specs.showTranslation = true
        h.view.specs = specs
        CATransaction.flush()
        let translation = line.main.secondaryBlock(.translation)!
        #expect(line.main.secondaryBlock(.romanization) === block)
        #expect(block!.frame.minY >= translation.frame.maxY - 0.5)
        #expect(line.contentHeight > withTranslation)
    }

    @Test func alignedRomanizationToggleRebuildsRowsInPlace() {
        let h = Harness(document: Harness.romanizedDocument())
        h.setTime(4.05)
        h.settle()
        let line = h.line(2)!
        let plainHeight = line.contentHeight
        let plainRows = line.main.rows.count
        #expect(line.main.layout.ruby == nil)

        var specs = LyricsSpecs.windowed
        specs.showRomanization = true
        var before = h.visualTops()
        h.view.specs = specs
        CATransaction.flush()
        #expect(h.line(2) === line)
        #expect(h.maxJump(before, h.startTops()) < 0.5)
        #expect(line.main.layout.ruby != nil)
        #expect(line.main.secondaryBlock(.romanization) == nil)
        #expect(line.main.rows.count == plainRows * 2)
        #expect(line.main.rows.filter { !$0.liftsSyllables }.count == plainRows)
        #expect(line.contentHeight > plainHeight)
        h.spin(1.5)
        #expect(line.main.sublayers?.filter { $0 is RowLayer }.count == line.main.rows.count)
        #expect(abs((h.visualTops()[2] ?? 0) - anchorTop) < 1)
        #expect(abs(space(h, 2, 3) - LyricsSpecs.windowed.lineSpacing) < 1)

        specs.showRomanization = false
        before = h.visualTops()
        h.view.specs = specs
        CATransaction.flush()
        #expect(h.maxJump(before, h.startTops()) < 0.5)
        #expect(line.main.layout.ruby == nil)
        #expect(line.main.rows.count == plainRows)
        #expect(abs(line.contentHeight - plainHeight) < 0.01)
    }
}

@Suite(.serialized) @MainActor struct SelectedLinePositionTests {
    @Test func topRelativePutsTheFirstBaselineAtAFractionOfTheHeight() {
        let s = LyricsSpecs.windowed
        #expect(abs((s.selectedLineTop(viewHeight: 1000) ?? 0) - (200 - s.font.ascender)) < 0.01)
        let h = Harness(document: Self.lateDocument())
        h.setTime(1)
        h.spin(0.2)
        #expect(h.line(0)?.state == .upcoming)
        #expect(abs((h.visualTops()[0] ?? 0) - ((s.selectedLineTop(viewHeight: 800) ?? 0) + s.firstLineStartingPosition)) < 1)
    }

    @Test func centreLinesTheSelectedLineUpWithTheRect() {
        let h = Harness()
        var specs = LyricsSpecs.windowed
        specs.selectedLinePosition = .center(rect: CGRect(x: 0, y: 300, width: 0, height: 0))
        h.view.specs = specs
        h.setTime(20.05)
        h.settle()
        let line = h.line(10)!
        #expect(abs((h.visualTops()[10] ?? 0) + line.bounds.height / 2 - 300) < 1)
        specs.selectedLinePosition = .center(rect: CGRect(x: 0, y: 360, width: 0, height: 0))
        h.view.specs = specs
        CATransaction.flush()
        #expect(h.line(10) === line)
        #expect(!h.hasLagAnimations)
        #expect(abs((h.visualTops()[10] ?? 0) + line.bounds.height / 2 - 360) < 1)
        specs.selectedLinePosition = .center
        h.view.specs = specs
        CATransaction.flush()
        #expect(abs((h.visualTops()[10] ?? 0) + line.bounds.height / 2 - 400) < 1)
    }

    private static func lateDocument() -> LyricsDocument {
        var lines = Harness.document().lines
        for i in lines.indices {
            lines[i].start += 3
            lines[i].end += 3
            lines[i].words = lines[i].words.map { var w = $0; w.start += 3; w.end += 3; return w }
        }
        return LyricsDocument(format: .yrc, lines: lines)
    }

    @Test func centreKeepsTheFirstLineCentredBeforeItStarts() {
        let h = Harness(document: Self.lateDocument())
        var specs = LyricsSpecs.windowed
        specs.selectedLinePosition = .center(rect: CGRect(x: 0, y: 300, width: 0, height: 0))
        h.view.specs = specs
        h.setTime(1)
        h.spin(0.2)
        let first = h.line(0)!
        #expect(first.state == .upcoming)
        #expect(abs((h.visualTops()[0] ?? 0) + first.bounds.height / 2 - 300) < 1)
    }
}

@Suite @MainActor struct InstrumentalBreakTimelineTests {
    @Test func dotsFadeInLightAndBreatheOverTheBreak() {
        let layer = InstrumentalBreakLayer(gap: InstrumentalGap(afterLine: 3, start: 20, end: 34), specs: .windowed, tint: CGColor.white)
        let unlit = InstrumentalBreakLayer.unlitOpacity
        #expect(abs(layer.breathDuration - 12.2 / 3 / 2) < 1e-9)
        #expect(abs(layer.dotFadeInDuration - 11.2 / 3) < 1e-9)
        #expect(layer.dots.allSatisfy { $0.opacity == 0 })
        #expect(layer.dots[0].anchorPoint.x > 1 && layer.dots[2].anchorPoint.x < 0)

        layer.setSelected(true, animated: false)
        layer.appear(at: 19.5, now: 0)
        #expect(layer.dots.allSatisfy { $0.opacity == unlit })
        #expect(abs(layer.dots[0].transform.m11 - 1.2) < 1e-6)
        layer.update(at: 21.5, now: 0.5)
        #expect(layer.dots[0].opacity == unlit)
        layer.update(at: 22.1, now: 1.1)
        #expect(layer.dots[0].opacity == 1)
        #expect(layer.dots[1].opacity == unlit)
        #expect(abs(layer.dots[0].transform.m11 - 0.9) < 1e-6)
        layer.update(at: 29, now: 9)
        #expect(layer.dots.allSatisfy { $0.opacity == 1 })
        #expect(!layer.fadeOutCued)
        layer.update(at: 32.3, now: 12)
        #expect(layer.fadeOutCued)
        #expect(layer.dots.allSatisfy { $0.opacity == 0 && abs($0.transform.m11 - 0.2) < 1e-6 })
        layer.update(at: 21.2, now: 13)
        #expect(!layer.fadeOutCued)
        #expect(layer.dots[0].opacity == 1)
        #expect(layer.dots[1].opacity == unlit)
        layer.setSelected(false, animated: false)
        #expect(layer.dots.allSatisfy { $0.opacity == 0 })
    }

    private func run(_ layer: InstrumentalBreakLayer, to t: TimeInterval) {
        layer.setSelected(true, animated: false)
        layer.appear(at: 19.5, now: 0)
        var time = 19.5
        while time < t {
            time = min(time + 0.05, t)
            layer.update(at: time, now: time - 19.5)
        }
    }

    /// The breaths come in an even number, so the dots rest at 0.9 when the fade-out starts; it
    /// swells them back to 1.2 before the shrink and the fade, all three additive — the delayed
    /// shrink does not replace the swell.
    @Test func fadeOutSwellsBeforeItShrinks() {
        let layer = InstrumentalBreakLayer(gap: InstrumentalGap(afterLine: 3, start: 20, end: 34), specs: .windowed, tint: CGColor.white)
        run(layer, to: 32.15)
        #expect(!layer.fadeOutCued)
        #expect(layer.dots.allSatisfy { abs($0.transform.m11 - 0.9) < 1e-6 && $0.opacity == 1 })
        layer.dots.forEach { $0.removeAllAnimations() }
        let now = CACurrentMediaTime()
        layer.update(at: 32.25, now: 12.75)
        #expect(layer.fadeOutCued)
        for dot in layer.dots {
            let anims = (dot.animationKeys() ?? []).compactMap { dot.animation(forKey: $0) as? CABasicAnimation }
            #expect(anims.count == 3)
            #expect(anims.allSatisfy { $0.isAdditive && $0.fillMode == .both })
            let transforms = anims.filter { $0.keyPath == "transform" }.sorted { $0.beginTime < $1.beginTime }
            let from = transforms.map { ($0.fromValue as! NSValue).caTransform3DValue.m11 }
            #expect(transforms.count == 2)
            #expect(abs(from[0] - 0.75) < 1e-6 && transforms[0].duration == 1 && abs(transforms[0].beginTime - now) < 0.05)
            #expect(abs(from[1] - 6) < 1e-6 && transforms[1].duration == 0.5 && abs(transforms[1].beginTime - now - 1) < 0.05)
            let fade = anims.first { $0.keyPath == "opacity" }
            #expect((fade?.fromValue as? Float) == 1 && fade?.duration == 0.3 && abs((fade?.beginTime ?? 0) - now - 1) < 0.05)
            #expect(abs(dot.transform.m11 - 0.2) < 1e-6 && dot.opacity == 0)
        }
    }
}

@Suite @MainActor struct EmphasisTimelineTests {
    private func makeLine() -> LineLayer {
        let specs = LyricsSpecs.windowed.scaled()
        let line = LyricLine(id: 0, start: 0, end: 2, words: [
            LyricWord(start: 0, end: 0.5, text: "Oh "),
            LyricWord(start: 0.5, end: 2, text: "forever"),
        ])
        let layout = LineTextLayout.layout(line: line, font: specs.font, width: 900, leading: specs.fontLeading, alignment: .left, perSyllable: true)
        let layer = LineLayer(lineIndex: 0, line: line, textLayout: layout, translationLayout: nil, alignment: .left)
        layer.build(width: 900, specs: specs, tint: .white, scale: 2, translationTint: .white)
        layer.apply(state: .selected, specs: specs, scrolling: false, animated: false)
        return layer
    }

    @Test func glyphWaveAndGlowFollowTheWordTimeline() {
        let specs = LyricsSpecs.windowed.scaled()
        let layer = makeLine()
        let word = layer.rows[0].words[1]
        #expect(word.emphasisFactor == 0.5)
        #expect(word.glyphs.count == 7)
        #expect(layer.rows[0].words[0].glyphs.isEmpty)

        func phases(at elapsed: Double) -> [GlyphLayer.Phase] {
            layer.updateSyllables(time: 0.5 + elapsed, specs: specs)
            return word.glyphs.map(\.phase)
        }
        #expect(phases(at: 0.05) == Array(repeating: .rest, count: 7))
        #expect(abs(word.shadowOpacity - 0.2) < 1e-6)
        #expect(phases(at: 0.2) == [.up, .up, .rest, .rest, .rest, .rest, .rest])
        #expect(phases(at: 0.58) == [.down, .up, .up, .up, .up, .up, .rest])
        #expect(phases(at: 1.49) == Array(repeating: .down, count: 7))
        _ = phases(at: 1.6)
        #expect(word.shadowOpacity == 0)
        #expect(phases(at: -0.1) == Array(repeating: .rest, count: 7))
        #expect(word.glyphs.allSatisfy { $0.position == $0.rest })
        // Emphasised syllables do not lift on their own; plain ones do.
        layer.updateSyllables(time: 1.0, specs: specs)
        #expect(layer.rows[0].words[0].syllables[0].isLifted)
        #expect(!word.syllables[0].isLifted)
    }

    @Test func upPoseGrowsFromTheBaselineAndSpreadsFromTheCentre() {
        let specs = LyricsSpecs.windowed.scaled()
        let layer = makeLine()
        let word = layer.rows[0].words[1]
        layer.updateSyllables(time: 0.5 + 1.0, specs: specs)   // all glyphs up or down; force a known pose:
        layer.updateSyllables(time: 0.4, specs: specs)          // reset
        layer.updateSyllables(time: 0.5 + 0.2, specs: specs)    // glyphs 1–2 up
        let first = word.glyphs[0]
        #expect(first.phase == .up)
        let s = 1 + 0.14 * 0.5
        #expect(first.position.x < first.rest.x)
        #expect(abs((first.rest.y - first.position.y) - ((s - 1) * layer.textLayout.rows[0].height / 4 + specs.syllableLift)) < 1e-6)
        #expect(abs((first.value(forKeyPath: "transform.scale") as! CGFloat) - s) < 1e-6)
        #expect(first.anchorPoint.x == 0.5 && first.anchorPoint.y > 0.5)
    }
}

@Suite @MainActor struct LineFinishTests {
    /// The finish comes up to 0.75 s before the line ends. A wrapped line must then sweep its
    /// rows one after another rather than light an edge in every row at once: each run starts
    /// when the previous one ends, and the runs share the finish duration by distance left.
    @Test func wrappedRowsFinishInReadingOrder() throws {
        let specs = LyricsSpecs.windowed.scaled()
        let chars = Array("タイムストッパーメイドのお出ましだ")
        let words = chars.enumerated().map { i, c in LyricWord(start: Double(i) * 0.1, end: Double(i + 1) * 0.1, text: String(c)) }
        let line = LyricLine(id: 0, start: 0, end: Double(chars.count) * 0.1, words: words)
        let width: CGFloat = 500
        let layout = LineTextLayout.layout(line: line, font: specs.font, width: width, leading: specs.fontLeading, alignment: .left, perSyllable: true)
        let layer = LineLayer(lineIndex: 0, line: line, textLayout: layout, translationLayout: nil, alignment: .left)
        layer.build(width: width, specs: specs, tint: .white, scale: 2, translationTint: .white)
        layer.apply(state: .selected, specs: specs, scrolling: false, animated: false)
        let rows = layer.main.rows
        try #require(rows.count >= 2)

        // Part of the first row is sung, the rest of the line is not.
        layer.updateSyllables(time: 0.35, specs: specs)
        let left = rows.map(\.remainingDistance)
        #expect(left.allSatisfy { $0 > 0 })
        let now = CACurrentMediaTime()
        layer.finishMainProgress(specs: specs)

        let runs = try rows.map { try #require($0.progressLayer.animation(forKey: "finish") as? CABasicAnimation) }
        let duration = specs.lineFinishProgressAnimationDuration
        #expect(abs(runs.map(\.duration).reduce(0, +) - duration) < 1e-6)
        var start: TimeInterval = 0
        for (run, distance) in zip(runs, left) {
            #expect(abs(run.duration - duration * Double(distance / left.reduce(0, +))) < 1e-6)
            if start > 0 {
                #expect(abs(run.beginTime - now - start) < 0.05)
                #expect(run.fillMode == .backwards)
            }
            start += run.duration
        }
        #expect(rows.allSatisfy { $0.edge == $0.finalEdge })
    }

    /// Line-synced lyrics have no progress edge: a plain line stays fully sung — before its
    /// start, through its finish and after it is deselected — so nothing sweeps across it and
    /// only the line's colours mark it as current.
    @Test func plainLineNeverSweeps() throws {
        let specs = LyricsSpecs.windowed.scaled()
        let line = LyricLine.plain(id: 0, start: 10, end: 14, text: "A line without any word timing that wraps onto a second row")
        let width: CGFloat = 500
        let layout = LineTextLayout.layout(line: line, font: specs.font, width: width, leading: specs.fontLeading, alignment: .left, perSyllable: false)
        let layer = LineLayer(lineIndex: 0, line: line, textLayout: layout, translationLayout: nil, alignment: .left)
        layer.build(width: width, specs: specs, tint: .white, scale: 2, translationTint: .white)
        let rows = layer.main.rows
        try #require(rows.count >= 2)
        #expect(rows.allSatisfy { $0.edge == $0.finalEdge && $0.finalEdge > 0 })

        layer.apply(state: .selected, specs: specs, scrolling: false, animated: false)
        for t in [9.0, 10, 10.1, 13] {
            layer.updateSyllables(time: t, specs: specs)
            #expect(rows.allSatisfy { $0.edge == $0.finalEdge })
        }
        layer.finishMainProgress(specs: specs)
        #expect(rows.allSatisfy { $0.progressLayer.animation(forKey: "finish") == nil })
        layer.apply(state: .upcoming, specs: specs, scrolling: false, animated: false)
        #expect(rows.allSatisfy { $0.edge == $0.finalEdge })
    }
}
