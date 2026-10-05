import AppKit
import QuartzCore
import SwiftUI

/// Core Animation portrait ripples. Stop on hidden pages and under Reduce Motion;
/// centre the view at `diameter × RippleRings.extent`.
struct RippleRings: NSViewRepresentable {
    var color: Color
    var diameter: CGFloat
    var rippling: Bool
    var pulse: Bool

    static let reach: CGFloat = 1.3
    static let extent: CGFloat = 1.34

    func makeNSView(context: Context) -> RippleRingsView { RippleRingsView() }

    func updateNSView(_ view: RippleRingsView, context: Context) {
        view.diameter = diameter
        view.setColor(NSColor(color))
        view.setRippling(rippling)
        if pulse { view.pulseOnce() }
    }
}

final class RippleRingsView: NSView {
    var diameter: CGFloat = 200 {
        didSet { if diameter != oldValue { needsLayout = true } }
    }

    private let train = CALayer()
    private let rings: [CAShapeLayer] = (0..<3).map { _ in CAShapeLayer() }
    private let echo = CAShapeLayer()
    private var rippling = false
    private var pulsed = false
    private static let rippleKey = "ripple"
    private static let period: CFTimeInterval = 3.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        train.opacity = 0
        layer?.addSublayer(train)
        for ring in rings + [echo] {
            ring.fillColor = nil
            ring.opacity = 0
            (ring === echo ? layer : train)?.addSublayer(ring)
        }
        for ring in rings { ring.lineWidth = 1.2 }
        echo.lineWidth = 1.6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        train.frame = bounds
        let box = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let path = CGPath(ellipseIn: box.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        for ring in rings + [echo] {
            ring.bounds = box
            ring.position = center
            ring.path = path
        }
        CATransaction.commit()
    }

    func setColor(_ color: NSColor) {
        let cg = color.cgColor
        guard echo.strokeColor != cg else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ring in rings + [echo] { ring.strokeColor = cg }
        CATransaction.commit()
    }

    func setRippling(_ on: Bool) {
        guard on != rippling else { return }
        rippling = on
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = train.presentation()?.opacity ?? train.opacity
        fade.duration = on ? 0.2 : 0.6
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.rippling else { return }
            for ring in self.rings { ring.removeAnimation(forKey: Self.rippleKey) }
        }
        train.opacity = on ? 1 : 0
        train.add(fade, forKey: "fade")
        if on {
            let now = CACurrentMediaTime()
            for (i, ring) in rings.enumerated() {
                let ripple = Self.ring(from: 1, to: RippleRings.reach, peak: 0.5, duration: Self.period)
                ripple.repeatCount = .infinity
                ripple.beginTime = ring.convertTime(now, from: nil) + Double(i) * Self.period / Double(rings.count)
                ripple.fillMode = .backwards
                ripple.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                ring.add(ripple, forKey: Self.rippleKey)
            }
        }
        CATransaction.commit()
    }

    func pulseOnce() {
        guard !pulsed else { return }
        pulsed = true
        let ripple = Self.ring(from: 0.97, to: RippleRings.reach, peak: 0.75, duration: 1.4)
        ripple.beginTime = echo.convertTime(CACurrentMediaTime(), from: nil) + 0.22
        ripple.fillMode = .backwards
        echo.add(ripple, forKey: Self.rippleKey)
    }

    private static func ring(from: CGFloat, to: CGFloat, peak: Float, duration: CFTimeInterval) -> CAAnimationGroup {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = from
        scale.toValue = to
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.35, 1)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, peak, 0]
        opacity.keyTimes = [0, 0.1, 1]
        opacity.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = duration
        return group
    }
}
