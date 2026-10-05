import AppKit
import QuartzCore

public final class BackdropView: NSView {
    public var palette: CoverPalette = .fallback {
        didSet { applyPalette() }
    }
    public var isAnimating = true {
        didSet { isAnimating ? startDrift() : stopDrift() }
    }

    private var blobs: [CAGradientLayer] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for _ in 0..<3 {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.opacity = 0.85
            layer?.addSublayer(blob)
            blobs.append(blob)
        }
        applyPalette()
        startDrift()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        let side = max(bounds.width, bounds.height) * 1.2
        for (index, blob) in blobs.enumerated() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            blob.position = anchor(for: index)
            CATransaction.commit()
        }
    }

    private func anchor(for index: Int) -> CGPoint {
        let points = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.6, y: 0.85)]
        let p = points[index % points.count]
        return CGPoint(x: bounds.width * p.x, y: bounds.height * p.y)
    }

    private func applyPalette() {
        let colours = (palette.accents + [palette.dominant, palette.dominant]).prefix(3)
        for (index, blob) in blobs.enumerated() {
            let c = colours[colours.index(colours.startIndex, offsetBy: index % colours.count)]
            let color = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            blob.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
        }
        layer?.backgroundColor = NSColor(red: palette.dominant.r * 0.35, green: palette.dominant.g * 0.35, blue: palette.dominant.b * 0.35, alpha: 1).cgColor
    }

    private func startDrift() {
        for (index, blob) in blobs.enumerated() {
            let drift = CABasicAnimation(keyPath: "position")
            let from = anchor(for: index)
            drift.fromValue = from
            drift.toValue = CGPoint(x: from.x + 120 * (index.isMultiple(of: 2) ? 1 : -1), y: from.y + 80)
            drift.duration = 14 + Double(index) * 3
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blob.add(drift, forKey: "drift")
        }
    }

    private func stopDrift() {
        blobs.forEach { $0.removeAnimation(forKey: "drift") }
    }
}
