import AppKit
import Foundation
import LyricsCore
import QuartzCore
import Testing
@testable import LyricsUI

@MainActor
private final class DesktopHarness {
    let window: NSWindow
    let view: DesktopLyricsView
    var time: TimeInterval = 0
    var rate: Double = 0

    init(width: CGFloat = 600, document: LyricsDocument = DesktopHarness.document(), style: DesktopLyricsView.Style = .init()) {
        _ = NSApplication.shared
        let height = DesktopLyricsView.Metrics(fontSize: style.fontSize).height(showsTranslation: true)
        let size = CGSize(width: width, height: height)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        view = DesktopLyricsView(frame: NSRect(origin: .zero, size: size))
        view.style = style
        view.timeSource = { [weak self] in (self?.time ?? 0, self?.rate ?? 0) }
        window.contentView = view
        view.content = .init(document: document, duration: 60, title: "歌名", artist: "歌手")
        CATransaction.flush()
    }

    static func line(_ id: Int, _ text: String, _ start: Double, _ end: Double, translation: String? = nil) -> LyricLine {
        let chars = Array(text)
        let per = (end - start) / Double(chars.count)
        return LyricLine(id: id, start: start, end: end, words: chars.enumerated().map { j, c in
            LyricWord(start: start + Double(j) * per, end: start + Double(j + 1) * per, text: String(c))
        }, translation: translation)
    }

    static func document() -> LyricsDocument {
        LyricsDocument(format: .yrc, lines: [
            line(0, "第一行歌词", 1, 3, translation: "The first line"),
            line(1, "这是一行很长很长的歌词会比桌面歌词的宽度还要长出很多很多很多", 3, 9, translation: "A very long line that runs past the edge of the desktop lyrics window"),
            line(2, "没有翻译", 9, 10),
        ])
    }

    func set(_ t: TimeInterval, rate: Double) {
        time = t
        self.rate = rate
        view.sync()
        CATransaction.flush()
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

@MainActor
@Suite struct DesktopLyricsViewTests {
    @Test func showsTheSongBeforeTheFirstLineThenTheLineWithItsTranslation() {
        let h = DesktopHarness()
        h.set(0, rate: 0)
        #expect(h.view.displayedText == "歌名 - 歌手")
        #expect(h.view.translationSlot == nil)
        h.set(1.5, rate: 0)
        #expect(h.view.displayedText == "第一行歌词")
        #expect(h.view.displayedTranslation == "The first line")
        #expect(h.view.mainSlot?.isTimed == true)
        #expect(h.view.translationSlot?.isTimed == false)
    }

    @Test func rowsAreCentredAndKeepTheirPlaceThroughASong() throws {
        let h = DesktopHarness()
        h.set(1.5, rate: 0)
        let main = try #require(h.view.mainSlot)
        let translation = try #require(h.view.translationSlot)
        #expect(abs(main.frame.midX - h.view.bounds.midX) <= 0.5)
        #expect(abs(translation.frame.midX - h.view.bounds.midX) <= 0.5)
        #expect(translation.frame.minY >= main.frame.maxY)
        h.set(9.5, rate: 0)
        #expect(h.view.displayedText == "没有翻译")
        #expect(h.view.translationSlot == nil)
        #expect(h.view.mainSlot?.frame.minY == main.frame.minY)
    }

    @Test func aSongWithoutTranslationsGetsOneRowInTheMiddle() throws {
        let plain = LyricsDocument(format: .yrc, lines: [DesktopHarness.line(0, "第一行歌词", 1, 3)])
        let h = DesktopHarness(document: plain)
        h.set(1.5, rate: 0)
        let main = try #require(h.view.mainSlot)
        #expect(abs(main.frame.midY - h.view.bounds.midY) <= 0.5)

        var style = DesktopLyricsView.Style()
        style.showsTranslation = false
        let off = DesktopHarness(style: style)
        off.set(1.5, rate: 0)
        #expect(off.view.translationSlot == nil)
        let untranslated = try #require(off.view.mainSlot)
        #expect(abs(untranslated.frame.midY - off.view.bounds.midY) <= 0.5)
    }

    @Test func theUnsungColourUpdatesAndDisablingTimingLightsTheWholeLine() throws {
        var style = DesktopLyricsView.Style()
        style.litColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        style.unlitColor = .white
        let h = DesktopHarness(style: style)
        h.set(2, rate: 0)
        let slot = try #require(h.view.mainSlot)
        #expect(slot.unsung.backgroundColor == NSColor.white.cgColor)
        #expect(slot.unsung.opacity == 1)

        style.unlitColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        h.view.style = style
        CATransaction.flush()
        #expect(h.view.mainSlot?.unsung.backgroundColor == style.unlitColor.cgColor)

        style.perSyllable = false
        h.view.style = style
        h.set(2, rate: 0)
        let whole = try #require(h.view.mainSlot)
        #expect(whole.isTimed == false)
        #expect(whole.unsung.backgroundColor == style.litColor.cgColor)
    }

    @Test func theOutlineSitsUnderTheTextOnWholePointsAndScrollsWithIt() throws {
        let h = DesktopHarness(width: 300)
        h.set(4, rate: 0)
        let slot = try #require(h.view.mainSlot)
        #expect(slot.outline.superlayer === slot)
        #expect(slot.sublayers?.firstIndex(of: slot.outline) ?? 1 < slot.sublayers?.firstIndex(of: slot.line) ?? 0)
        #expect(slot.outlineInset > 0 && slot.outlineInset == slot.outlineInset.rounded())
        #expect(slot.textWidth > slot.visibleWidth)
        #expect(slot.mask != nil)
        h.set(8.7, rate: 0)
        #expect(slot.line.position.x < -MenuBarSlotLayer.imagePadding - 10)
        #expect(abs(slot.outline.position.x - (slot.line.position.x - slot.outlineInset)) < 1e-6)
        #expect(abs(slot.outline.position.y - (slot.line.position.y - slot.outlineInset)) < 1e-6)
        h.set(5, rate: 1)
        #expect(slot.line.animation(forKey: "position") != nil)
        #expect(slot.outline.animation(forKey: "position") != nil)
    }

    /// Where an image layer's opaque pixels are, in its superlayer's coordinates (y down). Over
    /// half opaque: the song's artist (0.55) counts, the outline's shadow (0.45 at most) does not.
    private func ink(of layer: CALayer) throws -> CGRect {
        let image = try #require(layer.contents.map { $0 as! CGImage })
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var box = CGRect.null
        // The buffer's first row is the image's top.
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 { box = box.union(CGRect(x: x, y: y, width: 1, height: 1)) }
        }
        let scale = CGFloat(width) / layer.bounds.width
        return CGRect(x: layer.position.x + box.minX / scale, y: layer.position.y + box.minY / scale, width: box.width / scale, height: box.height / scale)
    }

    @Test func theOutlineLinesUpWithTheTextOfTheSongAndOfALine() throws {
        let h = DesktopHarness()
        for t in [0.0, 1.5] {
            h.set(t, rate: 0)
            let slot = try #require(h.view.mainSlot)
            let text = try ink(of: try #require(slot.line.mask)).offsetBy(dx: slot.line.position.x, dy: slot.line.position.y)
            let outline = try ink(of: slot.outline)
            #expect(abs(outline.midX - text.midX) < 1, "t=\(t)")
            #expect(abs(outline.midY - text.midY) < 1.5, "t=\(t)")
            #expect(outline.insetBy(dx: 0.5, dy: 0.5).contains(text), "t=\(t)")
        }
    }

    @Test func playingRunsOnTheRenderServerAndPausingDims() throws {
        let h = DesktopHarness()
        h.set(1.2, rate: 1)
        let slot = try #require(h.view.mainSlot)
        #expect(slot.progress.animation(forKey: "position.x") != nil)
        #expect(h.view.changeTimer.isScheduled)
        #expect(h.view.isPaused == false)
        h.set(1.4, rate: 0)
        #expect(slot.progress.animation(forKey: "position.x") == nil)
        #expect(h.view.changeTimer.isScheduled == false)
        #expect(h.view.isPaused)
    }

    @Test func nextLineArrivesByTimer() {
        let h = DesktopHarness()
        h.set(2.6, rate: 1)
        #expect(h.view.displayedText == "第一行歌词")
        h.time = 3.2
        h.spin(0.45) // line 1 is due at 2.9
        #expect(h.view.displayedText.hasPrefix("这是一行"))
        #expect(h.view.displayedTranslation.hasPrefix("A very long line"))
    }

    @Test func aSuspendedViewHoldsStillUntilItIsSeenAgain() throws {
        let h = DesktopHarness()
        h.set(1.2, rate: 1)
        let slot = try #require(h.view.mainSlot)
        h.view.isSuspended = true
        CATransaction.flush()
        #expect(slot.progress.animation(forKey: "position.x") == nil)
        #expect(h.view.changeTimer.isScheduled == false)
        h.set(1.5, rate: 1)
        #expect(slot.progress.animation(forKey: "position.x") == nil)
        #expect(h.view.changeTimer.isScheduled == false)
        h.view.isSuspended = false
        CATransaction.flush()
        #expect(h.view.mainSlot?.progress.animation(forKey: "position.x") != nil)
        #expect(h.view.changeTimer.isScheduled)
    }

    @Test func theCardFitsTheText() throws {
        var style = DesktopLyricsView.Style()
        style.showsCard = true
        let h = DesktopHarness(style: style)
        h.set(1.5, rate: 0)
        let main = try #require(h.view.mainSlot)
        let translation = try #require(h.view.translationSlot)
        #expect(h.view.cardLayer.opacity == 1)
        #expect(h.view.cardLayer.frame.contains(main.frame.union(translation.frame)))
        #expect(h.view.cardLayer.frame.width < h.view.bounds.width)

        style.showsCard = false
        h.view.style = style
        h.set(1.5, rate: 0)
        #expect(h.view.cardLayer.opacity == 0)
    }
}

@Suite struct DesktopLyricsPlacementTests {
    private let main = DesktopLyricsPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 985))
    private let side = DesktopLyricsPlacement.Screen(frame: CGRect(x: 1920, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 1920, y: 0, width: 1440, height: 875))
    private let size = CGSize(width: 900, height: 120)

    @Test func startsInTheMiddleAboveTheDock() {
        let frame = DesktopLyricsPlacement.frame(anchor: nil, size: size, screens: [main, side])
        #expect(frame.midX == main.visibleFrame.midX)
        #expect(frame.minY == main.visibleFrame.minY + DesktopLyricsPlacement.bottomMargin)
        #expect(frame.size == size)
    }

    @Test func keepsItsSpotAndItsTopEdgeWhenItChangesSize() {
        let anchor = DesktopLyricsPlacement.Anchor(centerX: 700, top: 600)
        let frame = DesktopLyricsPlacement.frame(anchor: anchor, size: size, screens: [main])
        #expect(frame == CGRect(x: 250, y: 480, width: 900, height: 120))
        let taller = DesktopLyricsPlacement.frame(anchor: anchor, size: CGSize(width: 1000, height: 160), screens: [main])
        #expect(taller.maxY == 600)
        #expect(taller.midX == 700)
        #expect(DesktopLyricsPlacement.Anchor(frame: frame) == anchor)
    }

    @Test func staysWholeOnScreenClearOfTheMenuBarAndTheDock() {
        let high = DesktopLyricsPlacement.frame(anchor: .init(centerX: 100, top: 1078), size: size, screens: [main])
        #expect(high.maxY == main.visibleFrame.maxY)
        #expect(high.minX == 0)
        let low = DesktopLyricsPlacement.frame(anchor: .init(centerX: 960, top: 100), size: size, screens: [main])
        #expect(low.minY == main.visibleFrame.minY)
    }

    @Test func comesBackToTheFirstScreenWhenItsScreenIsGone() {
        let anchor = DesktopLyricsPlacement.Anchor(centerX: 2700, top: 500)
        let frame = DesktopLyricsPlacement.frame(anchor: anchor, size: size, screens: [main])
        #expect(frame == DesktopLyricsPlacement.frame(anchor: nil, size: size, screens: [main]))
        let restored = DesktopLyricsPlacement.frame(anchor: anchor, size: size, screens: [main, side])
        #expect(side.visibleFrame.contains(restored))
        #expect(restored.midX == 2700)
    }

    @Test func aWindowWiderThanTheScreenIsCutToIt() {
        let frame = DesktopLyricsPlacement.frame(anchor: .init(centerX: 2640, top: 500), size: CGSize(width: 1600, height: 120), screens: [main, side])
        #expect(frame.width == side.visibleFrame.width)
        #expect(side.visibleFrame.contains(frame))
    }
}
