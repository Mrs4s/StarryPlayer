import AppKit
import CoreText
import LyricsCore

/// Align romanization by timing groups and ink bounds, widening words as needed.
/// Wrap only between groups and keep each romanization row below its main row.
struct RubyLayout {
    var line: LyricLine
    /// One row under every main row that carries romanization, in the voice's coordinates.
    var text: LineTextLayout

    struct Metrics {
        var font: NSFont
        var rubyFont: NSFont
        var width: CGFloat
        var leading: CGFloat?
        var alignment: NSTextAlignment
        var minWordSpacing: CGFloat
        var lineHeightAdjustment: CGFloat
    }

    /// Main rows and romanization rows of `line`, or nil when no romanization word overlaps a
    /// word of the line (the caller then shows the romanization as a block).
    static func layout(line: LyricLine, romanization: [LyricWord], metrics m: Metrics) -> (text: LineTextLayout, ruby: RubyLayout)? {
        let groups = LyricRomanizationGrouping.groups(words: line.words, romanization: romanization)
        guard !groups.isEmpty, !line.words.isEmpty else { return nil }

        // The romanization line: grouped words in group order, every group ending in a space so
        // neighbouring groups never shape together.
        var rubyWords: [LyricWord] = []
        var rubyWordsOfGroup: [Range<Int>] = []
        for group in groups {
            let first = rubyWords.count
            rubyWords += group.romanization.map { romanization[$0] }
            if let last = rubyWords.indices.last, last >= first, !(rubyWords[last].text.last?.isWhitespace ?? false) {
                rubyWords[last].text += " "
                rubyWords[last].syllables[rubyWords[last].syllables.count - 1].text += " "
            }
            rubyWordsOfGroup.append(first..<rubyWords.count)
        }
        let rubyLine = LyricLine(id: line.id, start: rubyWords.map(\.start).min() ?? line.start, end: rubyWords.map(\.end).max() ?? line.end, words: rubyWords)

        let main = Measured(line: line, font: m.font)
        let ruby = Measured(line: rubyLine, font: m.rubyFont)

        // Layout units in text order: a group, or a word no romanization covers.
        struct Unit {
            var words: ClosedRange<Int>
            var group: Int?
            var ink: ClosedRange<CGFloat>
            var rubyInk: ClosedRange<CGFloat> = 0...0
        }
        var units: [Unit] = []
        var gi = 0, wi = 0
        while wi < line.words.count {
            if gi < groups.count, groups[gi].words.lowerBound == wi {
                let r = rubyWordsOfGroup[gi]
                units.append(Unit(words: groups[gi].words, group: gi, ink: main.ink(words: groups[gi].words), rubyInk: ruby.ink(words: r.lowerBound...(r.upperBound - 1))))
                wi = groups[gi].words.upperBound + 1
                gi += 1
            } else {
                units.append(Unit(words: wi...wi, group: nil, ink: main.ink(words: wi...wi)))
                wi += 1
            }
        }

        // Fill rows with whole units. `x` is the unit's pen position in the row before alignment,
        // `extra` how much its last word is widened, `rubyShift` where its romanization's pen
        // starts relative to `x` so the inked left edges meet.
        struct Placed {
            var unit: Int
            var x: CGFloat
            var extra: CGFloat
            var rubyShift: CGFloat
        }
        var plans: [[Placed]] = [[]]
        var cursor: CGFloat = 0
        for (ui, unit) in units.enumerated() {
            let visible = main.visibleWidth(words: unit.words)
            let rubyInkWidth = unit.rubyInk.upperBound - unit.rubyInk.lowerBound
            let inkWidth = unit.ink.upperBound - unit.ink.lowerBound
            let extra = unit.group == nil ? 0 : max(0, rubyInkWidth + m.minWordSpacing - inkWidth)
            if !plans[plans.count - 1].isEmpty, cursor + visible + extra > m.width {
                plans.append([])
                cursor = 0
            }
            plans[plans.count - 1].append(Placed(unit: ui, x: cursor, extra: extra, rubyShift: unit.ink.lowerBound - unit.rubyInk.lowerBound))
            cursor += main.advance(words: unit.words) + extra
        }

        var mainRows: [LineTextLayout.Row] = []
        var rubyRows: [LineTextLayout.Row] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        for plan in plans {
            guard let firstPlaced = plan.first, let lastPlaced = plan.last else { continue }
            let firstUnit = units[firstPlaced.unit], lastUnit = units[lastPlaced.unit]
            let visible = lastPlaced.x + main.visibleWidth(words: lastUnit.words) + lastPlaced.extra
            let rowX: CGFloat
            switch m.alignment {
            case .center: rowX = ((m.width - visible) / 2).rounded()
            case .right: rowX = m.width - visible
            default: rowX = 0
            }

            // Main row: every syllable of a unit moves by the widening before it in the row.
            let rowStart = main.x(main.start(of: firstUnit.words.lowerBound))
            var shift: [Int: CGFloat] = [:]
            var widen: [Int: CGFloat] = [:]
            for placed in plan {
                let unit = units[placed.unit]
                let dx = placed.x - (main.x(main.start(of: unit.words.lowerBound)) - rowStart)
                for s in main.syllables(of: unit.words) { shift[s] = dx }
                if placed.extra > 0, let last = main.syllables(of: unit.words).last { widen[last] = placed.extra }
            }
            let range = main.start(of: firstUnit.words.lowerBound)..<main.end(of: lastUnit.words.upperBound)
            let row = LineTextLayout.makeRow(main.line(range), font: m.font, leading: m.leading, x: rowX, y: y, syllableForOffset: main.syllableForOffset, perSyllable: true, shift: shift, widen: widen)
            mainRows.append(row)
            width = max(width, row.width)
            y += row.height

            let groupsInRow = plan.compactMap { units[$0.unit].group }
            guard let firstGroup = groupsInRow.first, let lastGroup = groupsInRow.last else { continue }
            let rubyRange = ruby.start(of: rubyWordsOfGroup[firstGroup].lowerBound)..<ruby.end(of: rubyWordsOfGroup[lastGroup].upperBound - 1)
            let rubyRowStart = ruby.x(rubyRange.lowerBound)
            var rubyShift: [Int: CGFloat] = [:]
            for placed in plan {
                guard let g = units[placed.unit].group else { continue }
                let words = rubyWordsOfGroup[g].lowerBound...(rubyWordsOfGroup[g].upperBound - 1)
                let dx = placed.x + placed.rubyShift - (ruby.x(ruby.start(of: words.lowerBound)) - rubyRowStart)
                for s in ruby.syllables(of: words) { rubyShift[s] = dx }
            }
            let rubyRow = LineTextLayout.makeRow(ruby.line(rubyRange), font: m.rubyFont, leading: nil, x: rowX, y: y, syllableForOffset: ruby.syllableForOffset, perSyllable: true, shift: rubyShift, extraDescent: m.lineHeightAdjustment)
            rubyRows.append(rubyRow)
            width = max(width, rubyRow.width)
            y += rubyRow.height
        }
        guard !rubyRows.isEmpty else { return nil }
        let mainHeight = mainRows.last.map { $0.origin.y + $0.height } ?? 0
        return (LineTextLayout(rows: mainRows, size: CGSize(width: width, height: mainHeight), font: m.font),
                RubyLayout(line: rubyLine, text: LineTextLayout(rows: rubyRows, size: CGSize(width: width, height: y), font: m.rubyFont)))
    }

    /// A line's text measured as one unbroken Core Text line, with UTF-16 ranges of its words.
    private struct Measured {
        let text: NSString
        let syllableForOffset: [Int]
        let typesetter: CTTypesetter
        let full: CTLine
        /// UTF-16 start of each word, plus the text length at the end.
        let wordStarts: [Int]
        let syllableStarts: [Int]

        init(line: LyricLine, font: NSFont) {
            let (attributed, syllableForOffset) = LineTextLayout.attributedText(line.syllables, font: font)
            text = attributed.string as NSString
            self.syllableForOffset = syllableForOffset
            typesetter = CTTypesetterCreateWithAttributedString(attributed)
            full = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))
            var starts = [0], syllables = [0]
            for word in line.words {
                starts.append(starts[starts.count - 1] + word.syllables.reduce(0) { $0 + $1.text.utf16.count })
                syllables.append(syllables[syllables.count - 1] + word.syllables.count)
            }
            wordStarts = starts
            syllableStarts = syllables
        }

        func start(of word: Int) -> Int { wordStarts[word] }
        func end(of word: Int) -> Int { wordStarts[word + 1] }
        func syllables(of words: ClosedRange<Int>) -> Range<Int> { syllableStarts[words.lowerBound]..<syllableStarts[words.upperBound + 1] }

        func x(_ offset: Int) -> CGFloat { CTLineGetOffsetForStringIndex(full, offset, nil) }

        func trimmedEnd(of words: ClosedRange<Int>) -> Int {
            var end = self.end(of: words.upperBound)
            let start = self.start(of: words.lowerBound)
            while end > start, let scalar = Unicode.Scalar(text.character(at: end - 1)), scalar.properties.isWhitespace { end -= 1 }
            return end
        }

        func visibleWidth(words: ClosedRange<Int>) -> CGFloat { x(trimmedEnd(of: words)) - x(start(of: words.lowerBound)) }

        func ink(words: ClosedRange<Int>) -> ClosedRange<CGFloat> {
            let start = self.start(of: words.lowerBound), end = trimmedEnd(of: words)
            guard end > start else { return 0...0 }
            let bounds = CTLineGetImageBounds(line(start..<end), nil)
            guard !bounds.isNull, bounds.width > 0 else { return 0...(x(end) - x(start)) }
            return bounds.minX...bounds.maxX
        }
        func advance(words: ClosedRange<Int>) -> CGFloat { x(end(of: words.upperBound)) - x(start(of: words.lowerBound)) }

        func line(_ range: Range<Int>) -> CTLine {
            CTTypesetterCreateLine(typesetter, CFRange(location: range.lowerBound, length: range.count))
        }
    }
}
