import AppKit
import Foundation
import LyricsCore
import Testing
@testable import LyricsUI

@Suite struct LyricsSpecsTests {
    @Test func scalingMultipliesLengths() {
        var specs = LyricsSpecs.fullscreen
        specs.scale = 2
        let scaled = specs.scaled()
        #expect(scaled.fontSize == 56)
        #expect(scaled.lineSpacing == 50)
        #expect(scaled.syllableLift == 4)
        #expect(scaled.blur.maximum == 8)
        #expect(scaled.scale == 1)
    }

    @Test func blurRadiusGrowsWithDistance() {
        let specs = LyricsSpecs.windowed
        #expect(specs.blurRadius(distance: 1) == 2)
        #expect(specs.blurRadius(distance: 2) == 3)
        #expect(specs.blurRadius(distance: 3) == 4)
        #expect(specs.blurRadius(distance: 6) == 4)
        #expect(specs.blurRadius(distance: 0) == 3)
        #expect(specs.blurRadius(distance: -4) == 3)
        #expect(specs.blurRadius(distance: 1, beforeFirstLine: true) == 3)
        #expect(specs.blurRadius(distance: 3, beforeFirstLine: true) == 4)
        var upcoming = specs
        upcoming.blur.mode = .upcoming
        #expect(upcoming.blurRadius(distance: -1) == 0)
        #expect(upcoming.blurRadius(distance: 2) == 3)
        var off = specs
        off.blur.mode = .off
        #expect(off.blurRadius(distance: 3) == 0)
    }
}

@Suite struct LineTextLayoutTests {
    @Test func syllableFragmentsTileTheRow() {
        let words = [
            LyricWord(start: 0, end: 0.5, text: "夜"), LyricWord(start: 0.5, end: 1, text: "色"),
            LyricWord(start: 1, end: 1.5, text: "把"), LyricWord(start: 1.5, end: 2, text: "街"),
        ]
        let line = LyricLine(id: 0, start: 0, end: 2, words: words)
        let font = NSFont.systemFont(ofSize: 48, weight: .bold)
        let layout = LineTextLayout.layout(line: line, font: font, width: 600, leading: 52, alignment: .left, perSyllable: true)
        #expect(layout.rows.count == 1)
        let fragments = layout.rows[0].fragments
        #expect(fragments.map(\.syllable) == [0, 1, 2, 3])
        for (a, b) in zip(fragments, fragments.dropFirst()) {
            #expect(abs(a.rect.maxX - b.rect.minX) < 1)
            #expect(a.rect.width > 20)
        }
        #expect(layout.rows[0].height == 52)
        #expect(layout.size.height == 52)
    }

    @Test func wrappingProducesRowsAndKeepsSyllableOrder() {
        let text = "the quick brown fox jumps over the lazy dog again and again"
        var words: [LyricWord] = []
        var t = 0.0
        for w in text.split(separator: " ") {
            words.append(LyricWord(start: t, end: t + 0.3, text: String(w) + " "))
            t += 0.3
        }
        let line = LyricLine(id: 0, start: 0, end: t, words: words)
        let layout = LineTextLayout.layout(line: line, font: .systemFont(ofSize: 48, weight: .bold), width: 500, leading: nil, alignment: .left, perSyllable: true)
        #expect(layout.rows.count >= 2)
        let syllables = layout.rows.flatMap { $0.fragments.map(\.syllable) }
        #expect(syllables == syllables.sorted())
        #expect(Set(syllables).count == words.count)
        let image = LineTextLayout.renderRow(layout.rows[0], width: 500, color: CGColor.white, scale: 2, padding: 12)
        #expect(image != nil)
        #expect(image!.width == Int(ceil((500 + 24) * 2)))
    }

    @Test func rightAlignedRowsStartAtTheRightEdge() {
        let line = LyricLine.plain(id: 0, start: 0, end: 1, text: "short")
        let layout = LineTextLayout.layout(line: line, font: .systemFont(ofSize: 32, weight: .bold), width: 400, leading: nil, alignment: .right, perSyllable: false)
        let fragment = layout.rows[0].fragments[0]
        #expect(fragment.rect.maxX > 390)
        #expect(fragment.rect.minX > 200)
    }
}
