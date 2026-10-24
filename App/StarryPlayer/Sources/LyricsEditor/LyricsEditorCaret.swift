import AppKit
import QuartzCore

/// A table-level outline keeps caret animation independent of row reuse and text layout.
@MainActor
final class LyricsEditorCaret {
    let layer = CALayer()
    private(set) var frame: NSRect?

    init() {
        layer.name = "lyrics.selection"
        layer.borderWidth = 1.75
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.zPosition = 1_000
        layer.isHidden = true
    }

    func update(frame: NSRect?, color: NSColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.borderColor = color.cgColor
        guard let frame else {
            reset()
            return
        }
        // Timing, hover, and theme updates must not restart an in-flight movement.
        guard self.frame != frame else { return }
        let moving = animated && self.frame != nil && !layer.isHidden
        let visible = layer.presentation() ?? layer
        let position = visible.position
        let bounds = visible.bounds
        self.frame = frame
        layer.isHidden = false
        layer.frame = frame
        layer.removeAllAnimations()
        if moving {
            if position != layer.position {
                layer.add(Self.spring("position", from: NSValue(point: position), to: NSValue(point: layer.position)), forKey: "move")
            }
            if bounds != layer.bounds {
                layer.add(Self.spring("bounds", from: NSValue(rect: bounds), to: NSValue(rect: layer.bounds)), forKey: "resize")
            }
        }
    }

    func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.isHidden = true
        frame = nil
        CATransaction.commit()
    }

    private static func spring(_ keyPath: String, from: NSValue, to: NSValue) -> CASpringAnimation {
        // Match Motion.selection: response 0.36 s, damping fraction 0.8.
        let frequency = 2 * Double.pi / 0.36
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = frequency * frequency
        animation.damping = 2 * 0.8 * frequency
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }
}
