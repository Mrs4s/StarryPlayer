import AppKit
import CoreText
import LyricsCore

struct LineTextLayout {
    struct Cluster {
        var font: CTFont
        var glyphs: [CGGlyph]
        /// Relative to the row's baseline origin.
        var positions: [CGPoint]
    }

    struct Fragment {
        var syllable: Int
        /// Advance rect in row coordinates (origin top-left of the row, y down). Adjacent
        /// fragments tile the row, so crops of the row bitmap cover every glyph pixel once.
        var rect: CGRect
        /// Horizontal extent of the inked glyphs (`CTRunGetImageBounds`); nil for whitespace.
        /// Drives the progress edge, so spaces never widen a syllable.
        var ink: ClosedRange<CGFloat>?
        var clusters: [Cluster]

        var inkMinX: CGFloat { ink?.lowerBound ?? rect.minX }
        var inkMaxX: CGFloat { ink?.upperBound ?? rect.maxX }
    }

    struct Row {
        /// Top-left origin, y increasing downwards.
        var origin: CGPoint
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var height: CGFloat { ascent + descent }
        var fragments: [Fragment]
        var baselineY: CGFloat { origin.y + ascent }
    }

    var rows: [Row]
    var size: CGSize
    var font: NSFont

    static func layout(line: LyricLine, font: NSFont, width: CGFloat, leading: CGFloat?, alignment: NSTextAlignment, perSyllable: Bool) -> LineTextLayout {
        let (attributed, syllableForOffset) = attributedText(line.syllables, font: font)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        if let leading {
            paragraph.minimumLineHeight = leading
            paragraph.maximumLineHeight = leading
        }
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = max(width, 10)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: maxWidth, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var rows: [Row] = []
        var y: CGFloat = 0
        for (rowIndex, ctLine) in ctLines.enumerated() {
            let row = makeRow(ctLine, font: font, leading: leading, x: origins[rowIndex].x, y: y, syllableForOffset: syllableForOffset, perSyllable: perSyllable)
            rows.append(row)
            y += row.height
        }
        return LineTextLayout(rows: rows, size: CGSize(width: rows.map(\.width).max() ?? 0, height: y), font: font)
    }

    /// The syllables' text with `font`, and the syllable index of every UTF-16 unit.
    static func attributedText(_ syllables: [LyricSyllable], font: NSFont) -> (NSMutableAttributedString, [Int]) {
        let text = syllables.map(\.text).joined()
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font])
        var syllableForOffset: [Int] = []
        syllableForOffset.reserveCapacity(attributed.length)
        for (index, syllable) in syllables.enumerated() {
            syllableForOffset.append(contentsOf: repeatElement(index, count: syllable.text.utf16.count))
        }
        return (attributed, syllableForOffset)
    }

    static func makeRow(_ ctLine: CTLine, font: NSFont, leading: CGFloat?, x rowX: CGFloat, y: CGFloat, syllableForOffset: [Int], perSyllable: Bool,
                        shift: [Int: CGFloat] = [:], widen: [Int: CGFloat] = [:], extraDescent: CGFloat = 0) -> Row {
        var ascent: CGFloat = 0, descent: CGFloat = 0, lineLeading: CGFloat = 0
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &lineLeading))
        ascent = max(ascent, font.ascender)
        descent = max(descent, -font.descender)
        var rowHeight: CGFloat
        if let leading {
            let extra = (leading - (ascent + descent)) / 2
            ascent += extra
            descent += extra
            rowHeight = leading
        } else {
            rowHeight = ascent + descent
        }
        descent += extraDescent
        rowHeight += extraDescent
        var fragments: [Fragment] = []
        var current: (syllable: Int, minX: CGFloat, maxX: CGFloat, ink: ClosedRange<CGFloat>?, clusters: [Cluster])? = nil

        func flush() {
            guard let c = current else { return }
            let rect = CGRect(x: c.minX, y: 0, width: max(c.maxX - c.minX, 1), height: rowHeight)
            fragments.append(Fragment(syllable: c.syllable, rect: rect, ink: c.ink, clusters: c.clusters))
            current = nil
        }

        func union(_ a: ClosedRange<CGFloat>?, _ b: ClosedRange<CGFloat>?) -> ClosedRange<CGFloat>? {
            guard let a else { return b }
            guard let b else { return a }
            return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
        }

        func syllable(at index: CFIndex) -> Int {
            perSyllable ? (index < syllableForOffset.count ? syllableForOffset[index] : 0) : 0
        }

        let runs = (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attributes[kCTFontAttributeName as String] as! CTFont)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)

            var i = 0
            while i < count {
                let s = syllable(at: indices[i])
                var j = i
                while j < count, syllable(at: indices[j]) == s { j += 1 }
                let slice = i..<j
                let dx = rowX + (shift[s] ?? 0)
                let clusterGlyphs = Array(glyphs[slice])
                let clusterPositions = slice.map { CGPoint(x: positions[$0].x + dx, y: 0) }
                let minX = clusterPositions.map(\.x).min() ?? 0
                let maxX = slice.map { positions[$0].x + dx + advances[$0].width }.max() ?? minX
                let cluster = Cluster(font: runFont, glyphs: clusterGlyphs, positions: clusterPositions)
                let image = CTRunGetImageBounds(run, nil, CFRange(location: i, length: j - i))
                let ink: ClosedRange<CGFloat>? = image.isNull || image.width <= 0 ? nil : (image.minX + dx)...(image.maxX + dx)
                if var c = current, c.syllable == s {
                    c.minX = min(c.minX, minX)
                    c.maxX = max(c.maxX, maxX)
                    c.ink = union(c.ink, ink)
                    c.clusters.append(cluster)
                    current = c
                } else {
                    flush()
                    current = (s, minX, maxX, ink, [cluster])
                }
                i = j
            }
        }
        flush()
        let visibleWidth = typographicWidth - CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine))
        if var last = fragments.last {
            let lastShift = shift[last.syllable] ?? 0
            last.rect.size.width = max(1, min(last.rect.width, rowX + lastShift + visibleWidth - last.rect.minX))
            fragments[fragments.count - 1] = last
        }
        for (i, fragment) in fragments.enumerated() {
            if let extra = widen[fragment.syllable], extra > 0 { fragments[i].rect.size.width += extra }
        }
        let rowWidth = fragments.map(\.rect.maxX).max() ?? 0
        return Row(origin: CGPoint(x: 0, y: y), width: rowWidth, ascent: ascent, descent: descent, fragments: fragments)
    }

    /// Renders one row into a bitmap (row coordinates, y down), with `color` fill and optional
    /// horizontal / vertical padding so glow and overhanging glyphs are not clipped. `colorSpace`
    /// should be the window's: Core Animation keeps a converted copy of an image in any other
    /// space (always of a device RGB one), which doubles the memory of every line. With
    /// `outline`, the row's outline is drawn instead of its glyphs (`padding` should cover
    /// `outline.extent`).
    static func renderRow(_ row: Row, width: CGFloat, color: CGColor, scale: CGFloat, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, padding: CGFloat = 0, outline: TextOutline? = nil) -> CGImage? {
        let pixelWidth = Int(ceil((width + padding * 2) * scale))
        let pixelHeight = Int(ceil((row.height + padding * 2) * scale))
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 16384, pixelHeight < 4096 else { return nil }
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setFillColor(color)
        // Core Graphics is y-up; place the baseline above the bitmap's bottom.
        let baseline = row.descent + padding
        let draw = {
            for fragment in row.fragments {
                for cluster in fragment.clusters {
                    let positions = cluster.positions.map { CGPoint(x: $0.x + padding, y: baseline) }
                    CTFontDrawGlyphs(cluster.font, cluster.glyphs, positions, cluster.glyphs.count, ctx)
                }
            }
        }
        if let outline { outline.draw(in: ctx, scale: scale, draw) } else { draw() }
        return ctx.makeImage()
    }

    /// Draws `line`'s glyphs with the context's text drawing mode and colours, its origin at
    /// `origin` (`CTLineDraw` takes its colours from the string instead).
    static func drawGlyphs(of line: CTLine, at origin: CGPoint, in ctx: CGContext) {
        // Glyph positions are in text space: the text position would move them again.
        ctx.textPosition = .zero
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName as String] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTFontDrawGlyphs(font, glyphs, positions.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }, count, ctx)
        }
    }
}

struct TextOutline: Equatable {
    var color: CGColor
    var width: CGFloat
    var shadowColor: CGColor
    var shadowRadius: CGFloat

    var extent: CGFloat { ceil(width + shadowRadius * 1.5 + 1) }

    // Shadows ignore the context's scale, so scale their geometry explicitly.
    func draw(in ctx: CGContext, scale: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -width / 2 * scale), blur: shadowRadius * scale, color: shadowColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setTextDrawingMode(.fillStroke)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width * 2)
        ctx.setLineJoin(.round)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

struct TextBlockLayout {
    var text: String
    var rows: [LineTextLayout.Row]
    var size: CGSize

    static func layout(text: String, font: NSFont, width: CGFloat, alignment: NSTextAlignment) -> TextBlockLayout {
        let line = LyricLine.plain(id: 0, start: 0, end: 0, text: text)
        let layout = LineTextLayout.layout(line: line, font: font, width: width, leading: nil, alignment: alignment, perSyllable: false)
        return TextBlockLayout(text: text, rows: layout.rows, size: layout.size)
    }
}
