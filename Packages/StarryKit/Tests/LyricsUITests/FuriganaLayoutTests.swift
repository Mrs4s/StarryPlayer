import AppKit
import CoreText
import LyricsCore
import Testing
@testable import LyricsUI

@Suite @MainActor struct FuriganaLayoutTests {
    private let specs = LyricsSpecs.windowed.scaled()

    private func line(_ entries: [(String, [String])]) -> LyricLine {
        let syllables = entries.enumerated().map { i, entry in
            LyricSyllable(start: Double(i), end: Double(i + 1), text: entry.0, ruby: LyricRuby.spread(entry.1, start: Double(i), end: Double(i + 1)))
        }
        return LyricLine(id: 0, start: 0, end: Double(entries.count), words: LyricWordGrouping.words(from: syllables))
    }

    private func metrics(width: CGFloat, alignment: NSTextAlignment = .left) -> FuriganaLayout.Metrics {
        FuriganaLayout.Metrics(font: specs.font, rubyFont: specs.rubyFont, width: width, leading: specs.fontLeading, alignment: alignment,
                               minSpacing: specs.rubyMinSpacing, lineHeightAdjustment: specs.rubyLineHeightAdjustment)
    }

    private func ink(_ row: LineTextLayout.Row, _ syllables: ClosedRange<Int>) -> ClosedRange<CGFloat>? {
        let fragments = row.fragments.filter { syllables.contains($0.syllable) }
        guard let lo = fragments.map(\.inkMinX).min(), let hi = fragments.map(\.inkMaxX).max() else { return nil }
        return lo...hi
    }

    private func centre(_ r: ClosedRange<CGFloat>) -> CGFloat { (r.lowerBound + r.upperBound) / 2 }

    @Test func rubySitsCentredOnItsSyllableAboveTheText() throws {
        let l = line([("君", ["き", "み"]), ("の", []), ("名", ["な"]), ("前", ["ま", "え"])])
        let r = try #require(FuriganaLayout.layout(line: l, metrics: metrics(width: 900)))
        #expect(r.text.rows.count == 1 && r.furigana.text.rows.count == 1)
        let main = r.text.rows[0], ruby = r.furigana.text.rows[0]
        #expect(abs(ruby.origin.y + ruby.height - main.origin.y) < 0.01)
        #expect(abs(r.text.size.height - (main.origin.y + main.height)) < 0.01)
        #expect(r.furigana.line.syllables.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["き", "み", "な", "ま", "え"])
        #expect(r.furigana.line.syllables.map(\.start) == [0, 0.5, 2, 3, 3.5])
        for (base, pieces) in [(0, 0...1), (2, 2...2), (3, 3...4)] {
            let baseInk = try #require(ink(main, base...base)), rubyInk = try #require(ink(ruby, pieces))
            #expect(abs(centre(baseInk) - centre(rubyInk)) < 0.5)
        }
    }

    @Test func wideRubyWidensItsSyllableOnBothSides() throws {
        let plain = LineTextLayout.layout(line: line([("へ", []), ("囃", []), ("子", [])]), font: specs.font, width: 900, leading: specs.fontLeading, alignment: .left, perSyllable: true)
        let r = try #require(FuriganaLayout.layout(line: line([("へ", []), ("囃", ["は", "や", "し"]), ("子", ["し"])]), metrics: metrics(width: 900)))
        let main = r.text.rows[0], ruby = r.furigana.text.rows[0]
        let before = try #require(ink(plain.rows[0], 1...1)), after = try #require(ink(main, 1...1))
        let shift = after.lowerBound - before.lowerBound
        #expect(shift > 5)
        let ko = try #require(ink(main, 2...2)), plainKo = try #require(ink(plain.rows[0], 2...2))
        #expect(abs(ko.lowerBound - plainKo.lowerBound - 2 * shift) < 0.5)
        let hayashi = try #require(ink(ruby, 0...2)), shi = try #require(ink(ruby, 3...3))
        #expect(abs(centre(hayashi) - centre(after)) < 0.5)
        #expect(hayashi.upperBound + specs.rubyMinSpacing <= shi.lowerBound + 0.5)
        let he = try #require(ink(main, 0...0))
        #expect(hayashi.lowerBound >= he.upperBound)
    }

    @Test func rowsWrapBetweenWordsAndEveryRowKeepsRoomForRuby() throws {
        let entries: [(String, [String])] = [("瞳", ["ひとみ"]), ("の", []), ("奥", ["おく"]), ("に", []), ("隠", ["かく"]), ("し", []), ("た", []),
                                             ("秘", ["ひ"]), ("密", ["みつ"]), ("を", []), ("誰", ["だれ"]), ("に", []), ("も", []), ("見", ["み"]),
                                             ("せ", []), ("な", []), ("い", []), ("ま", []), ("ま", [])]
        let r = try #require(FuriganaLayout.layout(line: line(entries), metrics: metrics(width: 500)))
        #expect(r.text.rows.count > 1)
        let room = try #require(r.furigana.text.rows.map(\.height).max())
        var top: CGFloat = 0
        for row in r.text.rows {
            #expect(abs(row.origin.y - (top + room)) < 0.01)
            #expect(row.width <= 500 + 0.5)
            top = row.origin.y + row.height
        }
        #expect(abs(r.text.size.height - top) < 0.01)
        #expect(r.text.rows.flatMap { $0.fragments.map(\.syllable) }.sorted() == Array(entries.indices))
    }

    @Test func rightAlignedRowsEndAtTheEdge() throws {
        let r = try #require(FuriganaLayout.layout(line: line([("君", ["きみ"]), ("は", [])]), metrics: metrics(width: 900, alignment: .right)))
        let main = r.text.rows[0]
        #expect(abs(main.fragments.map(\.rect.maxX).max()! - 900) < 1)
        #expect(r.furigana.text.rows[0].fragments.allSatisfy { $0.inkMaxX <= 900 })
    }

    @Test func rubyRowsSweepByTheirOwnTimingAndNeverLift() throws {
        let l = line([("所", ["しょ"]), ("詮", ["せ", "ん"]), ("は", [])])
        let built = try #require(FuriganaLayout.layout(line: l, metrics: metrics(width: 900)))
        let layout = VoiceLayout(voice: l, text: built.text, translation: nil, furigana: built.furigana)
        let layer = LineLayer(lineIndex: 0, line: l, main: layout, background: nil, alignment: .left)
        layer.build(width: 900, specs: specs, tint: .white, scale: 2, translationTint: .white)
        layer.apply(state: .selected, specs: specs, scrolling: false, animated: false)
        #expect(layer.main.rows.count == 2)
        #expect(abs(layer.contentHeight - layout.textHeight) < 0.01)
        let rubyRow = try #require(layer.main.rows.first { !$0.liftsSyllables })
        let mainRow = try #require(layer.main.rows.first { $0.liftsSyllables })
        #expect(rubyRow.frame.maxY <= mainRow.frame.minY + 0.01)
        // Halfway through 詮: せ is sung, ん just starts; 詮 is half sung.
        layer.updateSyllables(time: 1.5, specs: specs)
        let se = try #require(ink(built.furigana.text.rows[0], 1...1)), n = try #require(ink(built.furigana.text.rows[0], 2...2))
        #expect(rubyRow.edge + rubyRow.feather > se.upperBound - 1)
        #expect(rubyRow.edge < n.upperBound)
        #expect(rubyRow.syllables.allSatisfy { !$0.isLifted })
        #expect(mainRow.syllables.filter { $0.start <= 1.5 && $0.glyphLayers.isEmpty }.allSatisfy { $0.isLifted })
    }
}
