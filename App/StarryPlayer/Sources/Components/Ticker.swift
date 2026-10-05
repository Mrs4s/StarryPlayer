import AppKit
import SwiftUI

enum TickerMotion {
    case rise(direction: Int)
    case push(Spring)
}

/// Animates text changes with Core Animation to avoid per-frame shell updates.
/// Provide one content container; pass changing dependencies through `value`.
struct Ticker<Value: Equatable, Trigger: Equatable, Content: View>: View {
    var value: Value
    var trigger: Trigger
    var motion: TickerMotion
    var clipsSides = true
    var interactive = true
    @ViewBuilder var content: (Value) -> Content
    @Environment(AppModel.self) private var model

    var body: some View {
        content(value)
            .hidden()
            .overlay {
                TickerSurface(value: value, trigger: trigger, motion: motion, clipsSides: clipsSides, interactive: interactive, model: model, content: content)
            }
    }
}

private struct TickerSurface<Value: Equatable, Trigger: Equatable, Content: View>: NSViewRepresentable {
    var value: Value
    var trigger: Trigger
    var motion: TickerMotion
    var clipsSides: Bool
    var interactive: Bool
    var model: AppModel
    var content: (Value) -> Content

    final class Coordinator {
        var value: Value?
        var font: Font?
        var theme: Theme?
        var trigger: Trigger?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TickerView { TickerView() }

    func updateNSView(_ view: TickerView, context: Context) {
        let environment = context.environment
        let shown = context.coordinator
        view.clipsSides = clipsSides
        view.isInteractive = interactive
        let entering = shown.trigger.map { $0 != trigger } ?? false
        shown.trigger = trigger
        guard entering || shown.value != value || shown.font != environment.font || shown.theme != environment.theme else { return }
        shown.value = value
        shown.font = environment.font
        shown.theme = environment.theme
        let root = AnyView(content(value)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .font(environment.font)
            .environment(\.theme, environment.theme)
            .environment(model))
        view.show(root, motion: entering ? motion : nil, reduceMotion: environment.accessibilityReduceMotion, glass: environment.barGlass)
    }
}

final class TickerView: NSView {
    private var host = TickerView.makeHost()
    private var spare: NSHostingView<AnyView>?
    private var blurred: [NSHostingView<AnyView>] = []
    private let clip = CALayer()
    var clipsSides = true {
        didSet { if clipsSides != oldValue { needsLayout = true } }
    }
    var isInteractive = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(host)
        clip.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makeHost() -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        return host
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    /// A point wider than the line: its frame comes rounded to pixels, and a title fitted to its
    /// own width would truncate in one a fraction narrower.
    private var hostFrame: CGRect { CGRect(x: 0, y: 0, width: bounds.width + 1, height: bounds.height) }
    private var blurredFrame: CGRect { hostFrame.insetBy(dx: -Self.blurMargin, dy: -Self.blurMargin) }
    private static let blurRadii: [CGFloat] = [1.5, 3, 6]
    private static let blurMargin: CGFloat = 18

    override func layout() {
        super.layout()
        host.frame = hostFrame
        spare?.frame = hostFrame
        for copy in blurred { copy.frame = blurredFrame }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer?.mask !== clip { layer?.mask = clip }
        clip.frame = clipsSides ? bounds : bounds.insetBy(dx: -1000, dy: 0)
        CATransaction.commit()
    }

    /// Restart the entrance animation. Backwards fill prevents the final text position
    /// from flashing before the render server commits the animation.
    func show(_ content: AnyView, motion: TickerMotion?, reduceMotion: Bool, glass: Bool) {
        switch motion {
        case nil:
            host.rootView = content
        case .rise(let direction):
            host.rootView = content
            rise(by: reduceMotion ? 0 : (direction < 0 ? -14 : 14), blurring: glass ? content : nil, glass: glass)
        case .push(let spring):
            push(content, by: reduceMotion ? 0 : bounds.height, on: spring)
        }
    }

    /// Positive offsets are below the line.
    private func down(_ offset: CGFloat) -> CGFloat {
        layer?.contentsAreFlipped() == false ? -offset : offset
    }

    /// Cross-fade blurred copies; a Core Image filter can trigger per-frame shell rendering with
    /// Liquid Glass.
    private func rise(by offset: CGFloat, blurring content: AnyView?, glass: Bool) {
        guard let hostLayer = host.layer else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideBlurred), object: nil)
        // The content moves under the mask, which stays on the line (a sublayer transform would
        // move the mask too).
        let rise = Self.spring("transform.translation.y", from: down(offset), to: 0, Spring(response: 0.42, dampingRatio: glass ? 0.74 : 0.86))
        rise.duration = 0.5
        hostLayer.add(rise, forKey: "tickerMove")
        guard let content else {
            hideBlurred()
            hostLayer.add(Self.basic("opacity", from: 0, to: 1, duration: 0.24), forKey: "tickerFade")
            return
        }
        while blurred.count < Self.blurRadii.count {
            let copy = Self.makeHost()
            addSubview(copy, positioned: .above, relativeTo: blurred.last ?? host)
            blurred.append(copy)
        }
        let fades = Self.focusFades
        hostLayer.add(fades[0], forKey: "tickerFade")
        for (index, copy) in blurred.enumerated() {
            copy.rootView = AnyView(content
                .padding(Self.blurMargin)
                .blur(radius: Self.blurRadii[index])
                .allowsHitTesting(false)
                .accessibilityHidden(true))
            copy.frame = blurredFrame
            copy.isHidden = false
            copy.alphaValue = 0
            copy.layer?.add(rise, forKey: "tickerMove")
            copy.layer?.add(fades[index + 1], forKey: "tickerFade")
        }
        perform(#selector(hideBlurred), with: nil, afterDelay: fades[0].duration, inModes: [.common])
    }

    private static let focusFades: [CAKeyframeAnimation] = {
        let duration = 0.34, steps = 34
        let levels = [0] + blurRadii
        var times: [NSNumber] = []
        var values = Array(repeating: [CGFloat](), count: levels.count)
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let o = min(x * duration / 0.24, 1)
            let radius = levels.last! * (1 - x * x * (3 - 2 * x))
            let lower = max(levels.lastIndex { $0 <= radius } ?? 0, 0)
            let upper = min(lower + 1, levels.count - 1)
            let w = upper == lower ? 0 : (radius - levels[lower]) / (levels[upper] - levels[lower])
            times.append(NSNumber(value: x))
            for level in levels.indices {
                let value: CGFloat
                if level == upper, upper != lower {
                    value = o * w
                } else if level == lower {
                    value = o * w < 1 ? o * (1 - w) / (1 - o * w) : 0
                } else {
                    value = 0
                }
                values[level].append(value)
            }
        }
        return values.map { values in
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = values
            animation.keyTimes = times
            animation.duration = duration
            animation.fillMode = .backwards
            return animation
        }
    }()

    @objc private func hideBlurred() {
        for copy in blurred { copy.isHidden = true }
    }

    private func push(_ content: AnyView, by distance: CGFloat, on spring: Spring) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideSpare), object: nil)
        let leaving = host
        let coming = spare ?? Self.makeHost()
        if coming.superview == nil { addSubview(coming) }
        spare = leaving
        host = coming
        coming.rootView = content
        coming.frame = hostFrame
        coming.isHidden = false
        coming.alphaValue = 1
        leaving.alphaValue = 0
        guard let comingLayer = coming.layer, let leavingLayer = leaving.layer else { return }
        let move = Self.spring("transform.translation.y", from: down(distance), to: 0, spring)
        comingLayer.add(move, forKey: "tickerMove")
        comingLayer.add(Self.spring("opacity", from: 0, to: 1, spring), forKey: "tickerFade")
        leavingLayer.add(Self.spring("transform.translation.y", from: 0, to: down(-distance), spring), forKey: "tickerMove")
        leavingLayer.add(Self.spring("opacity", from: 1, to: 0, spring), forKey: "tickerFade")
        perform(#selector(hideSpare), with: nil, afterDelay: move.duration, inModes: [.common])
    }

    @objc private func hideSpare() {
        spare?.isHidden = true
    }

    private static func spring(_ keyPath: String, from: CGFloat, to: CGFloat, _ spring: Spring) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = spring.mass
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.fillMode = .backwards
        return animation
    }

    private static func basic(_ keyPath: String, from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.fillMode = .backwards
        return animation
    }
}
