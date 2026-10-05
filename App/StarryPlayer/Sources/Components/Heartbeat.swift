import AppKit
import QuartzCore
import SwiftUI

struct LikedCover: View {
    var size: CGFloat
    var playing: Bool
    /// Changes with every like and unlike.
    var pulse: Int
    @Environment(AppModel.self) private var model
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let tint = Color(hex: "#F0566E")

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#FF9E8C"), Color(hex: "#F4586F"), Color(hex: "#DC3A5E")], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.3), .white.opacity(0)], center: UnitPoint(x: 0.18, y: 0.08), startRadius: 0, endRadius: size * 0.85)
            Heartbeat(pointSize: size * 0.38, beating: playing && pageActive && !reduceMotion, pulse: pulse, animated: !reduceMotion) { [player = model.player] in
                player.energies().x
            }
            .frame(width: size * 0.72, height: size * 0.72)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Core Animation heart driven by playback bass. Stop on hidden pages and under Reduce Motion.
struct Heartbeat: NSViewRepresentable {
    var pointSize: CGFloat
    var beating: Bool
    var pulse: Int
    var animated: Bool
    /// The low band's level, 0…1.
    var level: @MainActor () -> Float

    func makeNSView(context: Context) -> HeartbeatView { HeartbeatView() }

    func updateNSView(_ view: HeartbeatView, context: Context) {
        view.pointSize = pointSize
        view.level = level
        view.setBeating(beating)
        view.pulse(pulse, animated: animated)
    }
}

final class HeartbeatView: NSView {
    var pointSize: CGFloat = 76 {
        didSet { if pointSize != oldValue { updateImage() } }
    }
    var level: (@MainActor () -> Float)?

    /// Swells with the music; holds `heart`, which takes the pulse beats, so the two scale
    /// together without fighting over one transform.
    private let swell = CALayer()
    private let heart = CALayer()
    private var link: CADisplayLink?
    private var lastPulse: Int?
    /// Running average of the low band (about half a second) and the current swell, 0…1.
    private var average: Float = 0
    private var amount: Float = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        heart.shadowColor = NSColor.white.cgColor
        heart.shadowOpacity = 0.3
        heart.shadowRadius = 12
        heart.shadowOffset = .zero
        swell.addSublayer(heart)
        layer?.addSublayer(swell)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateImage()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swell.bounds = bounds
        swell.position = CGPoint(x: bounds.midX, y: bounds.midY)
        heart.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private func updateImage() {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heart.contents = image.layerContents(forContentsScale: scale)
        heart.contentsScale = scale
        heart.bounds = CGRect(origin: .zero, size: image.size)
        CATransaction.commit()
        needsLayout = true
    }

    func pulse(_ token: Int, animated: Bool) {
        defer { lastPulse = token }
        guard animated, token != lastPulse else { return }
        lubDub(delay: lastPulse == nil ? 0.32 : 0)
    }

    private func lubDub(delay: CFTimeInterval) {
        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1, 1.17, 0.98, 1.1, 1]
        beat.keyTimes = [0, 0.16, 0.34, 0.5, 1]
        beat.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1),
        ]
        beat.duration = 0.8
        beat.beginTime = heart.convertTime(CACurrentMediaTime(), from: nil) + delay
        beat.fillMode = .backwards
        heart.add(beat, forKey: "pulse")
    }

    func setBeating(_ on: Bool) {
        guard on != (link != nil) else { return }
        if on {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            link?.invalidate()
            link = nil
            average = 0
            amount = 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            swell.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let (average, amount) = Self.step(level: level?() ?? 0, average: average, amount: amount)
        self.average = average
        self.amount = amount
        let scale = 1 + CGFloat(amount)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swell.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    static func step(level: Float, average: Float, amount: Float) -> (average: Float, amount: Float) {
        let average = average == 0 ? level : average * 0.93 + level * 0.07
        let onset = max(0, level - average - 0.02)
        return (average, min(max(onset * 1.6, amount * 0.8), 0.08))
    }
}
