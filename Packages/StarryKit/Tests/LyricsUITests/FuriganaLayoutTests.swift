import AppKit
import CoreText
import LyricsCore
import Testing
@testable import LyricsUI

@Suite @MainActor struct FuriganaLayoutTests {
    private let specs = LyricsSpecs.windowed.scaled()

    private func line(_ entries: [(String, [String])], grouped: Bool = true) -> LyricLine {
        let syllables = entries.enumerated().map { i, entry in
            LyricSyllable(start: Double(i), end: Double(i + 1), text: entry.0, ruby: LyricRuby.spread(entry.1, start: Double(i), end: Double(i + 1)))
        }
        let words = grouped ? LyricWordGrouping.words(from: syllables) : syllables.map {
            LyricWord(start: $0.start, end: $0.end, text: $0.text, syllables: [$0])
        }
        return LyricLine(id: 0, start: 0, end: Double(entries.count), words: words)
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

    private func build(_ l: LyricLine, width: CGFloat = 900) throws -> (LineLayer, LineTextLayout, FuriganaLayout) {
        let built = try #require(FuriganaLayout.layout(line: l, metrics: metrics(width: width)))
        let layout = VoiceLayout(voice: l, text: built.text, translation: nil, furigana: built.furigana)
        let layer = LineLayer(lineIndex: 0, line: l, main: layout, background: nil, alignment: .left)
        layer.build(width: width, specs: specs, tint: .white, scale: 2, translationTint: .white)
        layer.apply(state: .selected, specs: specs, scrolling: false, animated: false)
        return (layer, built.text, built.furigana)
    }

    @Test(arguments: [CGFloat(900), 140])
    func rubyHighlightFollowsItsBaseInsteadOfItsOwnTiming(width: CGFloat) throws {
        var l = line([("揺", ["ゆ"]), ("ら", []), ("め", []), ("く", []), ("囃", ["は", "や", "し"]), ("消", ["き"])], grouped: false)
        for w in l.words.indices {
            for s in l.words[w].syllables.indices {
                for r in l.words[w].syllables[s].ruby.indices {
                    l.words[w].syllables[s].ruby[r].start = 0
                    l.words[w].syllables[s].ruby[r].end = 0.05
                }
            }
        }
        let (layer, main, ruby) = try build(l, width: width)
        for time in [-0.1, 0.5, 4.5, 5.5, 6, 0.5] {
            layer.updateSyllables(time: time, specs: specs)
            for baseIndex in [0, 4, 5] {
                let row = try #require(layer.rows.first { $0.liftsSyllables && $0.syllables.contains { $0.syllableIndex == baseIndex } })
                let base = try #require(row.syllables.first { $0.syllableIndex == baseIndex })
                let annotation = try #require(base.ruby)
                let baseLayout = try #require(main.rows.first { $0.fragments.contains { $0.syllable == baseIndex } })
                let baseInk = try #require(ink(baseLayout, baseIndex...baseIndex))
                let indices = annotation.syllables.map(\.syllableIndex)
                let rubyLayout = try #require(ruby.text.rows.first { $0.fragments.contains { indices.contains($0.syllable) } })
                let rubyInk = try #require(ink(rubyLayout, indices.min()!...indices.max()!))
                for fraction in [CGFloat(0), 0.5, 1] {
                    let x = baseInk.lowerBound + fraction * (baseInk.upperBound - baseInk.lowerBound)
                    let rx = rubyInk.lowerBound + fraction * (rubyInk.upperBound - rubyInk.lowerBound)
                    let baseAlpha = min(max((row.edge + row.feather - x) / row.feather, 0), 1)
                    let rubyAlpha = min(max((annotation.edge + annotation.feather - rx) / annotation.feather, 0), 1)
                    #expect(abs(baseAlpha - rubyAlpha) < 1e-6)
                }
            }
        }
    }

    @Test func rubyLiftsWithItsBaseAndResetsWhenSeekingBackwards() throws {
        let (layer, _, _) = try build(line([("瞬", ["しゅん"]), ("間", ["かん"])], grouped: false))
        let bases = layer.rows.filter(\.liftsSyllables).flatMap(\.syllables)
        for time in [-0.1, 0.5, 1.5, -0.1] {
            layer.updateSyllables(time: time, specs: specs)
            for base in bases {
                let annotation = try #require(base.ruby)
                #expect(annotation.transform.m42 == (time >= base.start ? -specs.syllableLift : 0))
            }
        }
    }

    @Test func rubySharesEmphasisedGlyphMotion() throws {
        let syllables = line([("瞬", ["しゅん"]), ("間", ["かん"])]).syllables
        let l = LyricLine(id: 0, start: 0, end: 2, words: [LyricWord(start: 0, end: 2, text: "瞬間", syllables: syllables)])
        let (layer, _, _) = try build(l)
        let glyphs = layer.rows.filter(\.liftsSyllables).flatMap(\.words).flatMap(\.glyphs)
        #expect(glyphs.count == 2)
        for time in [0.3, 1.5, 2.5, -0.1] {
            layer.updateSyllables(time: time, specs: specs)
            for glyph in glyphs {
                let ruby = try #require(glyph.ruby)
                #expect(abs((glyph.position.x - glyph.rest.x) - (ruby.layer.position.x - ruby.rest.x)) < 1e-6)
                #expect(abs((glyph.position.y - glyph.rest.y) - (ruby.layer.position.y - ruby.rest.y)) < 1e-6)
                #expect(CATransform3DEqualToTransform(glyph.transform, ruby.layer.transform))
            }
        }
    }

    @Test func wrappedRubyFinishesWithItsMainRowAndResumesTheClock() throws {
        let (layer, _, _) = try build(line([("揺", ["ゆ"]), ("ら", []), ("泡", ["あ", "わ"]), ("消", ["き"])], grouped: false), width: 140)
        #expect(layer.rows.filter(\.liftsSyllables).count > 1)
        layer.updateSyllables(time: 0.25, specs: specs)
        let now = CACurrentMediaTime()
        layer.finishMainProgress(specs: specs)
        var checked = 0
        for row in layer.rows where row.liftsSyllables {
            let run = try #require(row.progressLayer.animation(forKey: "finish") as? CABasicAnimation)
            for base in row.syllables {
                guard let ruby = base.ruby else { continue }
                checked += 1
                let rubyRun = try #require(ruby.progressLayer.animation(forKey: "finish") as? CABasicAnimation)
                let begin = run.beginTime == 0 ? now : run.beginTime
                let rubyBegin = rubyRun.beginTime == 0 ? now : rubyRun.beginTime
                #expect(rubyBegin >= begin - 0.01)
                #expect(rubyBegin + rubyRun.duration <= begin + run.duration + 0.01)
                let speed = ((run.toValue as! CGFloat) - (run.fromValue as! CGFloat)) / run.duration
                let rubySpeed = ((rubyRun.toValue as! CGFloat) - (rubyRun.fromValue as! CGFloat)) / rubyRun.duration
                #expect(abs(rubySpeed - speed * ruby.feather / row.feather) < 1e-5)
                #expect(ruby.edge == ruby.finalEdge)
            }
        }
        #expect(checked == 3)
        layer.main.resume()
        layer.updateSyllables(time: 0.1, specs: specs)
        #expect(layer.rows.allSatisfy { $0.progressLayer.animation(forKey: "finish") == nil })
        #expect(layer.rows.allSatisfy { abs($0.edge - $0.edge(at: 0.1)) < 1e-6 })
    }
}
