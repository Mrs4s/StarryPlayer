import AppKit
import SwiftUI

/// The app's mark: a coral play glyph and two white sparkles on a night-blue sky, flat fills only.
/// The app icon is rendered from this view too, so keep it self-contained.
struct AppMark: View {
    var size: CGFloat

    static let coral = Color(.sRGB, red: 254 / 255, green: 121 / 255, blue: 113 / 255)
    static let night = Color(.sRGB, red: 34 / 255, green: 28 / 255, blue: 78 / 255)

    /// Drawn on an 824 pt body (the macOS icon grid), then scaled to `size`.
    static let body: CGFloat = 824

    private static let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (130, 150, 12, 0.5), (100, 600, 10, 0.4), (240, 720, 9, 0.35), (720, 560, 10, 0.4), (420, 110, 8, 0.35),
    ]

    var body: some View {
        ZStack {
            Self.night
            ForEach(Self.stars.indices, id: \.self) { i in
                let (x, y, diameter, opacity) = Self.stars[i]
                Circle().fill(.white.opacity(opacity)).frame(width: diameter, height: diameter).position(x: x, y: y)
            }
            RoundedPlay(radius: 70).fill(Self.coral).frame(width: 400, height: 450).offset(x: 40, y: 30)
            Sparkle().fill(.white).frame(width: 170, height: 205).offset(x: 205, y: -205)
            Sparkle().fill(.white).frame(width: 64, height: 78).offset(x: 295, y: -60)
        }
        .frame(width: Self.body, height: Self.body)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .scaleEffect(size / Self.body)
        .frame(width: size, height: size)
    }

    static func menuBarGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedPlay(radius: 2).path(in: CGRect(x: 1.5, y: 3.5, width: 11, height: 13)).cgPath)
            context.addPath(Sparkle().path(in: CGRect(x: 12, y: 0.5, width: 6, height: 7.4)).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Starry Player"
        return image
    }
}

struct Sparkle: Shape {
    var pinch: CGFloat = 0.1

    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let w = r.width / 2, h = r.height / 2
        let tips = [CGPoint(x: c.x, y: c.y - h), CGPoint(x: c.x + w, y: c.y), CGPoint(x: c.x, y: c.y + h), CGPoint(x: c.x - w, y: c.y)]
        let controls = [CGPoint(x: c.x + w * pinch, y: c.y - h * pinch), CGPoint(x: c.x + w * pinch, y: c.y + h * pinch),
                        CGPoint(x: c.x - w * pinch, y: c.y + h * pinch), CGPoint(x: c.x - w * pinch, y: c.y - h * pinch)]
        var p = Path()
        p.move(to: tips[0])
        for i in 0..<4 { p.addQuadCurve(to: tips[(i + 1) % 4], control: controls[i]) }
        p.closeSubpath()
        return p
    }
}

struct RoundedPlay: Shape {
    var radius: CGFloat

    func path(in r: CGRect) -> Path {
        let a = CGPoint(x: r.minX, y: r.minY), b = CGPoint(x: r.maxX, y: r.midY), c = CGPoint(x: r.minX, y: r.maxY)
        var p = Path()
        p.move(to: CGPoint(x: a.x, y: r.midY))
        p.addArc(tangent1End: a, tangent2End: b, radius: radius)
        p.addArc(tangent1End: b, tangent2End: c, radius: radius)
        p.addArc(tangent1End: c, tangent2End: a, radius: radius)
        p.closeSubpath()
        return p
    }
}
