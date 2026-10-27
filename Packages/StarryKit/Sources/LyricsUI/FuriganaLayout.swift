import AppKit
import CoreText
import LyricsCore

/// Ruby over the text (`LyricSyllable.ruby`: furigana, pinyin): each annotated syllable's ruby is
/// centred on its ink, the syllable widened on both sides when its ruby is wider. Rows wrap
/// between words, and every row of the line keeps room for ruby above it. `RubyLayout` instead
/// sets romanization under the text.
struct FuriganaLayout {
    /// The ruby as a line: a word per annotated syllable, whose syllables are the ruby pieces.
    var line: LyricLine
    /// A row over every main row that carries ruby, in the voice's coordinates.
    var text: LineTextLayout

    struct Metrics {
        var font: NSFont
        var rubyFont: NSFont
        var width: CGFloat
        var leading: CGFloat?
        var alignment: NSTextAlignment
        /// Least space between the ruby of neighbouring syllables.
        var minSpacing: CGFloat
        /// Added to every ruby row's height; negative brings the ruby closer to its text.
        var lineHeightAdjustment: CGFloat
    }

    static func layout(line: LyricLine, metrics m: Metrics) -> (text: LineTextLayout, furigana: FuriganaLayout)? {
        let syllables = line.syllables
        var rubyWords: [LyricWord] = []
        var group: [Int?] = []  // the ruby word over each syllable
        for syllable in syllables {
            var pieces = syllable.ruby.compactMap { r -> LyricSyllable? in
                let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : LyricSyllable(start: r.start, end: r.end, text: text)
            }
            guard !pieces.isEmpty, !syllable.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                group.append(nil)
                continue
            }
            // Ending in a space keeps the ruby of neighbouring syllables from shaping together.
            pieces[pieces.count - 1].text += " "
            group.append(rubyWords.count)
            rubyWords.append(LyricWord(start: pieces[0].start, end: pieces.map(\.end).max() ?? pieces[0].end,
                                       text: pieces.map(\.text).joined(), syllables: pieces))
        }
        guard !rubyWords.isEmpty, !line.words.isEmpty else { return nil }
        let rubyLine = LyricLine(id: line.id, start: line.start, end: line.end, words: rubyWords)
        let main = RubyLayout.Measured(line: line, font: m.font)
        let ruby = RubyLayout.Measured(line: rubyLine, font: m.rubyFont)

        func width(_ ink: ClosedRange<CGFloat>) -> CGFloat { ink.upperBound - ink.lowerBound }
        func centre(_ ink: ClosedRange<CGFloat>) -> CGFloat { (ink.lowerBound + ink.upperBound) / 2 }
        let trimmed = syllables.indices.map { main.trimmed(syllable: $0) }
        var baseInk = [ClosedRange<CGFloat>](repeating: 0...0, count: syllables.count)
        var rubyInk = [ClosedRange<CGFloat>](repeating: 0...0, count: rubyWords.count)
        var extra = [CGFloat](repeating: 0, count: syllables.count)
        for (s, g) in group.enumerated() {
            guard let g else { continue }
            baseInk[s] = main.ink(trimmed[s])
            rubyInk[g] = ruby.ink(words: g...g)
            extra[s] = max(0, width(rubyInk[g]) + m.minSpacing - width(baseInk[s]))
        }

        let syllablesOfWord = line.words.indices.map { main.syllables(of: $0...$0) }
        let widening = syllablesOfWord.map { $0.reduce(0) { $0 + extra[$1] } }
        var plans: [[(word: Int, x: CGFloat)]] = [[]]
        var cursor: CGFloat = 0
        for w in line.words.indices {
            let visible = main.visibleWidth(words: w...w) + widening[w]
            if !plans[plans.count - 1].isEmpty, cursor + visible > m.width {
                plans.append([])
                cursor = 0
            }
            plans[plans.count - 1].append((w, cursor))
            cursor += main.advance(words: w...w) + widening[w]
        }

        var mainRows: [LineTextLayout.Row] = []
        var rubyRows: [LineTextLayout.Row?] = []
        var width: CGFloat = 0
        for plan in plans {
            guard let first = plan.first, let last = plan.last else { continue }
            let visible = last.x + main.visibleWidth(words: last.word...last.word) + widening[last.word]
            let rowX: CGFloat
            switch m.alignment {
            case .center: rowX = ((m.width - visible) / 2).rounded()
            case .right: rowX = m.width - visible
            default: rowX = 0
            }

            let rowStart = main.x(main.start(of: first.word))
            var shift: [Int: CGFloat] = [:]
            var widen: [Int: CGFloat] = [:]
            var pen: [Int: CGFloat] = [:]  // where an annotated syllable's glyphs start, from rowX
            for placed in plan {
                var before = placed.x - (main.x(main.start(of: placed.word)) - rowStart)
                for s in syllablesOfWord[placed.word] {
                    shift[s] = before + extra[s] / 2
                    if extra[s] > 0 { widen[s] = extra[s] / 2 }
                    if group[s] != nil { pen[s] = main.x(trimmed[s].lowerBound) - rowStart + before + extra[s] / 2 }
                    before += extra[s]
                }
            }
            let range = main.start(of: first.word)..<main.end(of: last.word)
            let row = LineTextLayout.makeRow(main.line(range), font: m.font, leading: m.leading, x: rowX, y: 0, syllableForOffset: main.syllableForOffset, perSyllable: true, shift: shift, widen: widen)
            mainRows.append(row)
            width = max(width, row.width)

            let annotated = plan.flatMap { syllablesOfWord[$0.word] }.compactMap { s in group[s].map { (syllable: s, group: $0) } }
            guard let firstGroup = annotated.first?.group, let lastGroup = annotated.last?.group else {
                rubyRows.append(nil)
                continue
            }
            let rubyRange = ruby.start(of: firstGroup)..<ruby.end(of: lastGroup)
            let rubyRowStart = ruby.x(rubyRange.lowerBound)
            var rubyShift: [Int: CGFloat] = [:]
            for (s, g) in annotated {
                let target = pen[s]! + centre(baseInk[s]) - centre(rubyInk[g])
                let dx = target - (ruby.x(ruby.start(of: g)) - rubyRowStart)
                for piece in ruby.syllables(of: g...g) { rubyShift[piece] = dx }
            }
            let rubyRow = LineTextLayout.makeRow(ruby.line(rubyRange), font: m.rubyFont, leading: nil, x: rowX, y: 0, syllableForOffset: ruby.syllableForOffset, perSyllable: true, shift: rubyShift, extraDescent: m.lineHeightAdjustment)
            rubyRows.append(rubyRow)
            width = max(width, rubyRow.width)
        }

        // Every row keeps the room of the tallest ruby row, its ruby sitting on the text below.
        let room = rubyRows.compactMap { $0?.height }.max() ?? 0
        var y: CGFloat = 0
        for i in mainRows.indices {
            if let height = rubyRows[i]?.height { rubyRows[i]?.origin.y = y + room - height }
            y += room
            mainRows[i].origin.y = y
            y += mainRows[i].height
        }
        return (LineTextLayout(rows: mainRows, size: CGSize(width: width, height: y), font: m.font),
                FuriganaLayout(line: rubyLine, text: LineTextLayout(rows: rubyRows.compactMap { $0 }, size: CGSize(width: width, height: y), font: m.rubyFont)))
    }
}
