import AppKit
import QuartzCore
import StarryCore
import SwiftUI

/// Core Animation playback bars avoid the per-frame main-thread work of repeating symbol effects.
struct PlayingBars: NSViewRepresentable {
    var color: Color
    var animating: Bool

    func makeNSView(context: Context) -> PlayingBarsView { PlayingBarsView() }

    func updateNSView(_ view: PlayingBarsView, context: Context) {
        view.setColor(NSColor(color))
        view.setAnimating(animating)
    }
}

final class PlayingBarsView: NSView {
    private let bars: [CALayer] = (0..<3).map { _ in CALayer() }
    private var animating = false
    private static let rest: [CGFloat] = [0.45, 0.9, 0.62]
    private static let periods: [Double] = [0.42, 0.58, 0.49]
    private static let key = "bounce"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let width: CGFloat = 2.5, gap: CGFloat = 2
        var x = (bounds.width - (width * 3 + gap * 2)) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: x + width / 2, y: 0)
            bar.transform = CATransform3DMakeScale(1, Self.rest[i], 1)
            x += width + gap
        }
        CATransaction.commit()
    }

    func setColor(_ color: NSColor) {
        let cg = color.cgColor
        guard bars[0].backgroundColor != cg else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = cg }
        CATransaction.commit()
    }

    func setAnimating(_ on: Bool) {
        guard on != animating else { return }
        animating = on
        for (i, bar) in bars.enumerated() {
            guard on else { bar.removeAnimation(forKey: Self.key); continue }
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.22
            bounce.toValue = 1
            bounce.duration = Self.periods[i]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            bounce.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) - Double(i) * 0.19
            bar.add(bounce, forKey: Self.key)
        }
    }
}

private struct PageActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False for a page the router keeps alive behind the current one, and for every page while
    /// Now Playing covers them. Continuous animations must stop there: a hidden page may stay
    /// alive for a long time.
    var isPageActive: Bool {
        get { self[PageActiveKey.self] }
        set { self[PageActiveKey.self] = newValue }
    }
}

extension PlayerController {
    /// nil unless the queue came from `origin` of `source` (and `id`, when given); then whether
    /// it is playing (true) or paused. Drives the playing markers on rows and tiles.
    func playState(from origin: PlaybackOrigin, of source: SourceID?, id: String? = nil) -> Bool? {
        guard current != nil, let context, context.originType == origin, context.source == source, id == nil || context.originID == id else { return nil }
        return isPlaying
    }
}
