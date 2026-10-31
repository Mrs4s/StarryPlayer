import AppKit
import CoreText
import LyricsCore

/// Centres ruby over a syllable or shared run, keeping each shared run on one row.
struct FuriganaLayout {
    /// The ruby as a line: a word per annotated syllable or run, whose syllables are the ruby pieces.
    var line: LyricLine
    var baseSyllables: [ClosedRange<Int>]
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
        var gaps: [Int: CGFloat] = [:]
    }

    static func layout(line: LyricLine, metrics m: Metrics) -> (text: LineTextLayout, furigana: FuriganaLayout)? {
        let syllables = line.syllables
        var rubyWords: [LyricWord] = []
        var baseSyllables: [ClosedRange<Int>] = []
        var group = [Int?](repeating: nil, count: syllables.count)  // the ruby word over each syllable
        for annotation in LyricRubyGroup.annotations(in: syllables) {
            var pieces = annotation.ruby.compactMap { r -> LyricSyllable? in
                let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let spaced = annotation.syllables.count > 1 && r.text.last?.isWhitespace == true
                return LyricSyllable(start: r.start, end: r.end, text: spaced ? text + " " : text)
            }
            let bases = annotation.syllables.filter { !syllables[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !pieces.isEmpty, let lo = bases.first, let hi = bases.last else { continue }
            // Ending in a space keeps the ruby of neighbouring syllables from shaping together.
            if !(pieces[pieces.count - 1].text.last?.isWhitespace ?? false) { pieces[pieces.count - 1].text += " " }
            for s in annotation.syllables { group[s] = rubyWords.count }
            baseSyllables.append(lo...hi)
            rubyWords.append(LyricWord(start: pieces[0].start, end: pieces.map(\.end).max() ?? pieces[0].end,
                                       text: pieces.map(\.text).joined(), syllables: pieces))
        }
        guard !rubyWords.isEmpty, !line.words.isEmpty else { return nil }
        let rubyLine = LyricLine(id: line.id, start: line.start, end: line.end, words: rubyWords)
        let main = RubyLayout.Measured(line: line, font: m.font, gaps: m.gaps)
        let ruby = RubyLayout.Measured(line: rubyLine, font: m.rubyFont)

        func width(_ ink: ClosedRange<CGFloat>) -> CGFloat { ink.upperBound - ink.lowerBound }
        func centre(_ ink: ClosedRange<CGFloat>) -> CGFloat { (ink.lowerBound + ink.upperBound) / 2 }
        let trimmed = syllables.indices.map { main.trimmed(syllable: $0) }
        let baseRange = baseSyllables.map { trimmed[$0.lowerBound].lowerBound..<trimmed[$0.upperBound].upperBound }
        let baseInk = baseRange.map { main.ink($0) }
        let rubyInk = rubyWords.indices.map { ruby.ink(words: $0...$0) }
        var before = [CGFloat](repeating: 0, count: syllables.count)
        var after = [CGFloat](repeating: 0, count: syllables.count)
        for (g, bases) in baseSyllables.enumerated() {
            let extra = max(0, width(rubyInk[g]) + m.minSpacing - width(baseInk[g]))
            before[bases.lowerBound] += extra / 2
            after[bases.upperBound] += extra / 2
        }

        let wordOfSyllable = line.words.indices.flatMap { w in repeatElement(w, count: line.words[w].syllables.count) }
        var units: [ClosedRange<Int>] = []
        var joined = [Bool](repeating: false, count: line.words.count)  // the word continues a run from the one before
        for bases in baseSyllables where wordOfSyllable[bases.lowerBound] < wordOfSyllable[bases.upperBound] {
            for w in (wordOfSyllable[bases.lowerBound] + 1)...wordOfSyllable[bases.upperBound] { joined[w] = true }
        }
        for w in line.words.indices {
            if joined[w], let last = units.last { units[units.count - 1] = last.lowerBound...w } else { units.append(w...w) }
        }
        let syllablesOfUnit = units.map { main.syllables(of: $0) }
        let widening = syllablesOfUnit.map { $0.reduce(0) { $0 + before[$1] + after[$1] } }
        var plans: [[(unit: Int, x: CGFloat)]] = [[]]
        var cursor: CGFloat = 0
        for (u, words) in units.enumerated() {
            let visible = main.visibleWidth(words: words) + widening[u]
            if !plans[plans.count - 1].isEmpty, cursor + visible > m.width {
                plans.append([])
                cursor = 0
            }
            plans[plans.count - 1].append((u, cursor))
            cursor += main.advance(words: words) + widening[u]
        }

        var mainRows: [LineTextLayout.Row] = []
        var rubyRows: [LineTextLayout.Row?] = []
        var width: CGFloat = 0
        for plan in plans {
            guard let first = plan.first, let last = plan.last else { continue }
            let visible = last.x + main.visibleWidth(words: units[last.unit]) + widening[last.unit]
            let rowX: CGFloat
            switch m.alignment {
            case .center: rowX = ((m.width - visible) / 2).rounded()
            case .right: rowX = m.width - visible
            default: rowX = 0
            }

            let rowStart = main.x(main.start(of: units[first.unit].lowerBound))
            var shift: [Int: CGFloat] = [:]
            var widen: [Int: CGFloat] = [:]
            var pen: [Int: CGFloat] = [:]  // where each run's glyphs start, from rowX
            for placed in plan {
                var moved = placed.x - (main.x(main.start(of: units[placed.unit].lowerBound)) - rowStart)
                for s in syllablesOfUnit[placed.unit] {
                    moved += before[s]
                    shift[s] = moved
                    if after[s] > 0 { widen[s] = after[s] }
                    if let g = group[s], baseSyllables[g].lowerBound == s { pen[g] = main.x(baseRange[g].lowerBound) - rowStart + moved }
                    moved += after[s]
                }
            }
            let range = main.start(of: units[first.unit].lowerBound)..<main.end(of: units[last.unit].upperBound)
            let row = LineTextLayout.makeRow(main.line(range), font: m.font, leading: m.leading, x: rowX, y: 0, syllableForOffset: main.syllableForOffset, perSyllable: true, shift: shift, widen: widen)
            mainRows.append(row)
            width = max(width, row.width)

            let annotated = plan.flatMap { syllablesOfUnit[$0.unit] }.compactMap { s in group[s].flatMap { baseSyllables[$0].lowerBound == s ? $0 : nil } }
            guard let firstGroup = annotated.first, let lastGroup = annotated.last else {
                rubyRows.append(nil)
                continue
            }
            let rubyRange = ruby.start(of: firstGroup)..<ruby.end(of: lastGroup)
            let rubyRowStart = ruby.x(rubyRange.lowerBound)
            var rubyShift: [Int: CGFloat] = [:]
            for g in annotated {
                let target = pen[g]! + centre(baseInk[g]) - centre(rubyInk[g])
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
                FuriganaLayout(line: rubyLine, baseSyllables: baseSyllables, text: LineTextLayout(rows: rubyRows.compactMap { $0 }, size: CGSize(width: width, height: y), font: m.rubyFont)))
    }
}
