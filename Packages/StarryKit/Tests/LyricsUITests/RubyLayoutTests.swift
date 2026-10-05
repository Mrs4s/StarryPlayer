import AppKit
import CoreText
import LyricsCore
import Testing
@testable import LyricsUI

@Suite @MainActor struct RubyLayoutTests {
    private let specs = LyricsSpecs.windowed.scaled()

    private func words(_ pieces: [String], start: Double = 0) -> [LyricWord] {
        var t = start
        return pieces.map { text in
            let syllables = Array(text).map { c -> LyricSyllable in
                defer { t += 1 }
                return LyricSyllable(start: t, end: t + 1, text: String(c))
            }
            return LyricWord(start: syllables[0].start, end: syllables[syllables.count - 1].end, text: text, syllables: syllables)
        }
    }

    private func line(_ pieces: [String]) -> LyricLine {
        let w = words(pieces)
        return LyricLine(id: 0, start: 0, end: w.last!.end, words: w)
    }

    private func romaji(_ text: String, _ start: Double, _ end: Double) -> LyricWord {
        LyricWord(start: start, end: end, text: text)
    }

    private func metrics(width: CGFloat) -> RubyLayout.Metrics {
        RubyLayout.Metrics(font: specs.font, rubyFont: specs.romanizationFont, width: width, leading: specs.fontLeading, alignment: .left,
                           minWordSpacing: specs.romanizationMinWordSpacing, lineHeightAdjustment: specs.romanizationLineHeightAdjustment)
    }

    private func fragment(_ row: LineTextLayout.Row, _ syllable: Int) -> LineTextLayout.Fragment? {
        row.fragments.first { $0.syllable == syllable }
    }

    private func advance(_ text: String, _ font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil, nil, nil))
    }

    @Test func groupHeadsStartAtTheirWordsAndWideRomanizationPushesTheTextApart() throws {
        let l = line(["完璧", "で"])
        let r = try #require(RubyLayout.layout(line: l, romanization: [romaji("kanpeki ", 0, 2), romaji("de", 2, 3)], metrics: metrics(width: 900)))
        #expect(r.text.rows.count == 1)
        #expect(r.ruby.text.rows.count == 1)
        let main = r.text.rows[0], ruby = r.ruby.text.rows[0]
        let kanpeki = advance("kanpeki", specs.romanizationFont)
        let kanji = advance("完璧", specs.font)
        #expect(kanpeki + specs.romanizationMinWordSpacing > kanji)
        let de = try #require(fragment(main, 2)), kan = try #require(fragment(main, 0)), bi = try #require(fragment(main, 1))
        let kanpekiRow = try #require(fragment(ruby, 0)), deRow = try #require(fragment(ruby, 1))
        #expect(abs(kanpekiRow.inkMinX - kan.inkMinX) < 0.5)
        #expect(abs(deRow.inkMinX - de.inkMinX) < 0.5)
        let plain = LineTextLayout.layout(line: l, font: specs.font, width: 900, leading: specs.fontLeading, alignment: .left, perSyllable: true)
        let plainBi = try #require(fragment(plain.rows[0], 1)), plainDe = try #require(fragment(plain.rows[0], 2))
        let extra = de.inkMinX - plainDe.inkMinX
        #expect(extra > 1)
        #expect(abs(plainBi.inkMaxX + extra - (kanpekiRow.inkMaxX + specs.romanizationMinWordSpacing)) < 0.5)
        // `璧` (the group's last word) is widened up to `で`, so the gap is sung with it.
        #expect(abs(bi.rect.maxX - de.rect.minX) < 0.5)
        #expect(abs(ruby.origin.y - (main.origin.y + main.height)) < 0.01)
        let font = specs.romanizationFont
        #expect(abs(ruby.height - (font.ascender - font.descender + specs.romanizationLineHeightAdjustment)) < 1)
        #expect(abs(r.ruby.text.size.height - (ruby.origin.y + ruby.height)) < 0.01)
    }

    @Test func narrowRomanizationLeavesTheTextAlone() throws {
        let l = line(["抜けてる", "とこ"])
        let plain = LineTextLayout.layout(line: l, font: specs.font, width: 900, leading: specs.fontLeading, alignment: .left, perSyllable: true)
        let r = try #require(RubyLayout.layout(line: l, romanization: [romaji("nuketeru ", 0, 4), romaji("toko", 4, 6)], metrics: metrics(width: 900)))
        for s in 0..<6 {
            #expect(abs((fragment(r.text.rows[0], s)?.rect.minX ?? -1) - (fragment(plain.rows[0], s)?.rect.minX ?? -2)) < 0.5)
        }
        let toko = try #require(fragment(r.ruby.text.rows[0], 1)), to = try #require(fragment(r.text.rows[0], 4))
        #expect(abs(toko.inkMinX - to.inkMinX) < 0.5)
    }

    @Test func kanaSideBearingsDoNotIndentTheText() throws {
        // `ま` has a wide left side bearing, "m" hardly any: the inked edges line up, not the pens.
        let l = line(["まある", "い", "から"])
        let r = try #require(RubyLayout.layout(line: l, romanization: [romaji("ma ", 0, 1), romaji("a ", 1, 2), romaji("ru ", 2, 3), romaji("i ", 3, 4), romaji("ka ", 4, 5), romaji("ra", 5, 6)], metrics: metrics(width: 900)))
        let ma = try #require(fragment(r.text.rows[0], 0)), maRuby = try #require(fragment(r.ruby.text.rows[0], 0))
        #expect(ma.inkMinX - ma.rect.minX > 1)
        #expect(abs(maRuby.inkMinX - ma.inkMinX) < 0.5)
        let ka = try #require(fragment(r.text.rows[0], 4)), kaRuby = try #require(fragment(r.ruby.text.rows[0], 4))
        #expect(abs(kaRuby.inkMinX - ka.inkMinX) < 0.5)
    }

    @Test func followersKeepTheirNaturalSpacing() throws {
        let r = try #require(RubyLayout.layout(line: line(["とこさえ"]), romanization: [romaji("toko ", 0, 2), romaji("sae", 2, 4)], metrics: metrics(width: 900)))
        let row = r.ruby.text.rows[0]
        let toko = try #require(fragment(row, 0)), sae = try #require(fragment(row, 1))
        #expect(abs(sae.rect.minX - toko.rect.minX - advance("toko ", specs.romanizationFont)) < 0.5)
        #expect(r.ruby.line.words.map(\.text) == ["toko ", "sae "])
    }

    @Test func rowsBreakBetweenGroupsNeverInside() throws {
        let together = try #require(RubyLayout.layout(line: line(["抜け", "てる"]), romanization: [romaji("nuketeru", 0, 4)], metrics: metrics(width: 120)))
        #expect(together.text.rows.count == 1)
        let apart = try #require(RubyLayout.layout(line: line(["完璧", "で"]), romanization: [romaji("kanpeki ", 0, 2), romaji("de", 2, 3)], metrics: metrics(width: 140)))
        #expect(apart.text.rows.count == 2)
        #expect(apart.ruby.text.rows.count == 2)
        let tops = [apart.text.rows[0], apart.ruby.text.rows[0], apart.text.rows[1], apart.ruby.text.rows[1]].map(\.origin.y)
        #expect(tops == tops.sorted())
        #expect(abs(apart.text.rows[1].origin.y - (apart.ruby.text.rows[0].origin.y + apart.ruby.text.rows[0].height)) < 0.01)
        let de = try #require(fragment(apart.ruby.text.rows[1], 1)), deKana = try #require(fragment(apart.text.rows[1], 2))
        #expect(abs(de.inkMinX - deKana.inkMinX) < 0.5)
    }

    @Test func noOverlapFallsBackToTheBlock() {
        #expect(RubyLayout.layout(line: line(["君"]), romanization: [romaji("kimi", 5, 6)], metrics: metrics(width: 900)) == nil)
    }

    @Test func romanizationRowsProgressAndGlowButNeverLift() throws {
        let l = line(["完璧", "で"])
        // "kanpeki" is held two seconds but has 7 letters: emphasised; "de" is not.
        let roma = [romaji("kanpeki ", 0, 2), romaji("de", 2, 3)]
        let built = try #require(RubyLayout.layout(line: l, romanization: roma, metrics: metrics(width: 900)))
        let layout = VoiceLayout(voice: l, text: built.text, translation: nil, ruby: built.ruby)
        let layer = LineLayer(lineIndex: 0, line: l, main: layout, background: nil, alignment: .left)
        layer.build(width: 900, specs: specs, tint: .white, scale: 2, translationTint: .white)
        layer.apply(state: .selected, specs: specs, scrolling: false, animated: false)
        #expect(layer.main.rows.count == 2)
        #expect(abs(layer.contentHeight - layout.textHeight) < 0.01)
        let rubyRow = try #require(layer.main.rows.first { !$0.liftsSyllables })
        #expect(rubyRow.words.first?.isEmphasized == true)
        // At 2.5 s `で` and "de" (neither emphasised) have started: only `で` lifts. Emphasised
        // words carry the lift in their glyph animation instead.
        layer.updateSyllables(time: 2.5, specs: specs)
        let mainRow = try #require(layer.main.rows.first { $0.liftsSyllables })
        let mainLifted = mainRow.syllables.filter { $0.glyphLayers.isEmpty && $0.start <= 2.5 }.map(\.isLifted)
        let rubyLifted = rubyRow.syllables.filter { $0.glyphLayers.isEmpty }.map(\.isLifted)
        #expect(mainLifted == [true])
        #expect(rubyLifted == [false])
        #expect(rubyRow.edge > -rubyRow.feather)
    }
}
