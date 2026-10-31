import AppKit
import CoreText
import LyricsCore

enum PerformerMarks {
    struct Bar: Equatable {
        /// In the text layout's coordinates (y down).
        var frame: CGRect
        var colors: [LyricColor]
        var run: Int
        var row: Int
    }

    static func gaps(runs: [LyricPerformerRun], syllables: [LyricSyllable], font: NSFont, specs: LyricsSpecs) -> [Int: CGFloat] {
        let gap = font.pointSize * specs.performerGap
        var result: [Int: CGFloat] = [:]
        for run in runs.dropFirst() where !run.colors.isEmpty {
            let before = run.syllables.lowerBound - 1
            guard syllables.indices.contains(before) else { continue }
            result[before] = syllables[before].text.last?.isWhitespace == true ? gap * 0.5 : gap
        }
        return result
    }

    static func bars(text: LineTextLayout, runs: [LyricPerformerRun], specs: LyricsSpecs) -> [Bar] {
        let em = text.font.pointSize
        let width = max(2, em * specs.performerBarWidth)
        let side = max((em * specs.performerGap - width) / 2, 2)
        func run(of syllable: Int) -> Int? { runs.firstIndex { $0.syllables.contains(syllable) } }
        var result: [Bar] = []
        var previousRun: Int?
        for (ri, row) in text.rows.enumerated() {
            var previousInk: CGFloat?
            for fragment in row.fragments {
                let r = run(of: fragment.syllable)
                defer {
                    if fragment.ink != nil { previousInk = fragment.inkMaxX }
                    previousRun = r
                }
                guard let r, r != previousRun, !runs[r].colors.isEmpty else { continue }
                let x: CGFloat
                if let previousInk {
                    x = (previousInk + fragment.inkMinX - width) / 2
                } else {
                    x = fragment.inkMinX - side - width
                }
                let frame = CGRect(x: x, y: row.baselineY - em * 0.84, width: width, height: em * 0.94)
                result.append(Bar(frame: frame, colors: runs[r].colors, run: r, row: ri))
            }
        }
        return result
    }

    /// Ink rectangles rather than row bounds: a reading elsewhere on the row must not move a name.
    static func rubyBounds(text: LineTextLayout) -> [(syllable: Int, frame: CGRect)] {
        text.rows.flatMap { row in
            row.fragments.compactMap { fragment -> (syllable: Int, frame: CGRect)? in
                guard fragment.ink != nil else { return nil }
                var ink = CGRect.null
                for cluster in fragment.clusters {
                    var bounds = [CGRect](repeating: .zero, count: cluster.glyphs.count)
                    CTFontGetBoundingRectsForGlyphs(cluster.font, .horizontal, cluster.glyphs, &bounds, cluster.glyphs.count)
                    for (rect, position) in zip(bounds, cluster.positions) where !rect.isEmpty {
                        ink = ink.union(CGRect(x: position.x + rect.minX, y: row.baselineY - rect.maxY,
                                              width: rect.width, height: rect.height))
                    }
                }
                return ink.isNull ? nil : (fragment.syllable, ink)
            }
        }
    }

    static func displayColor(_ color: LyricColor, tint: NSColor) -> CGColor {
        let rgb = [color.red, color.green, color.blue].map { Double($0) / 255 }
        let (lightness, a, b) = oklab(rgb)
        let hue = atan2(b, a)
        let chroma = min(hypot(a, b), 0.12)
        let tintIsLight = (tint.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.5
        let target = tintIsLight ? min(max(lightness, 0.80), 0.88) : min(max(lightness, 0.38), 0.50)
        let out = srgb(target, chroma * cos(hue), chroma * sin(hue))
        return CGColor(srgbRed: out[0], green: out[1], blue: out[2], alpha: 1)
    }

    static func nameImage(label: String, colors: [CGColor], tint: NSColor, fontSize: CGFloat, scale: CGFloat, colorSpace: CGColorSpace) -> (image: CGImage, size: CGSize)? {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let radius = fontSize * 0.32, step = radius * 1.35
        let dots = colors.isEmpty ? 0 : radius * 2 + step * CGFloat(colors.count - 1)
        let padding = fontSize * 0.6, spacing = colors.isEmpty ? 0 : fontSize * 0.45
        let size = CGSize(width: ceil(padding * 2 + dots + spacing + textWidth), height: ceil(fontSize * 1.6))
        let pixelWidth = Int(ceil(size.width * scale)), pixelHeight = Int(ceil(size.height * scale))
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 8192,
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let tint = tint.usingColorSpace(.sRGB) ?? .white
        ctx.setFillColor(tint.withAlphaComponent(0.14).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil))
        ctx.fillPath()
        for (index, color) in colors.enumerated() {
            let center = CGPoint(x: padding + radius + CGFloat(index) * step, y: size.height / 2)
            let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: dot)
            if colors.count > 1 {
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: dot)
            }
        }
        ctx.setFillColor(tint.withAlphaComponent(0.9).cgColor)
        let baseline = (size.height - ascent - descent) / 2 + descent
        LineTextLayout.drawGlyphs(of: line, at: CGPoint(x: padding + dots + spacing, y: baseline), in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return (image, size)
    }

    private static func oklab(_ rgb: [Double]) -> (Double, Double, Double) {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let l = cbrt(0.4122214708 * linear[0] + 0.5363325363 * linear[1] + 0.0514459929 * linear[2])
        let m = cbrt(0.2119034982 * linear[0] + 0.6806995451 * linear[1] + 0.1073969566 * linear[2])
        let s = cbrt(0.0883024619 * linear[0] + 0.2817188376 * linear[1] + 0.6299787005 * linear[2])
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func srgb(_ lightness: Double, _ a: Double, _ b: Double) -> [Double] {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let linear = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
        return linear.map { value in
            let c = min(max(value, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
    }
}
