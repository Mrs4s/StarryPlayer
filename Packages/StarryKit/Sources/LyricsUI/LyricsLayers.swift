import AppKit
import LyricsCore
import QuartzCore

/// Layer whose properties never animate implicitly; every animation on the lyrics page is either
/// driven per frame or added explicitly.
class NoAnimationLayer: CALayer {
    override init() {
        super.init()
        contentsScale = 2
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    override func action(forKey event: String) -> CAAction? { nil }
}

final class NoAnimationGradientLayer: CAGradientLayer {
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }
    override func action(forKey event: String) -> CAAction? { nil }
}

extension LyricsSpecs.Spring {
    static func critical(response: Double) -> LyricsSpecs.Spring {
        LyricsSpecs.Spring(dampingRatio: 1, response: max(response, 0.05))
    }

    var settlingDuration: TimeInterval {
        let anim = CASpringAnimation()
        anim.mass = mass
        anim.stiffness = stiffness
        anim.damping = damping
        return anim.settlingDuration
    }
}

enum LyricsAnimation {
    /// Blur changes: 0.12 s, control points (0.33, 0, 0.2, 0.1).
    static let blurDuration: CFTimeInterval = 0.12
    static var blurCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.33, 0, 0.2, 0.1) }
    static let highlightInDuration: CFTimeInterval = 0.2
    static var highlightInCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0, 0, 0.55, 1) }
    static let highlightOutDuration: CFTimeInterval = 0.3
    static var highlightOutCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 0.1) }
    static let stateDuration: CFTimeInterval = 0.4
    static let secondaryRevealDuration: CFTimeInterval = 0.3
    static let secondaryConcealDuration: CFTimeInterval = 0.14
    static let secondaryCrossFadeDuration: CFTimeInterval = 0.15
    static var secondaryFadeCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.33, 0, 0.67, 1) }
    static let scrubDuration: CFTimeInterval = 0.25

    /// Main-thread only (layers are driven from `LyricsView`).
    nonisolated(unsafe) private static var lagSerial = 0

    static func spring(_ keyPath: String, from: Any?, to: Any, _ spring: LyricsSpecs.Spring) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.mass = spring.mass
        anim.stiffness = spring.stiffness
        anim.damping = spring.damping
        anim.initialVelocity = 0
        anim.fromValue = from
        anim.toValue = to
        anim.duration = anim.settlingDuration
        return anim
    }

    static func animate(_ layer: CALayer, _ keyPath: String, to value: Any, spring: LyricsSpecs.Spring, key: String) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        layer.add(Self.spring(keyPath, from: from, to: value, spring), forKey: key)
        layer.setValue(value, forKeyPath: keyPath)
    }

    static func animate(_ layer: CALayer, _ keyPath: String, to value: Any, duration: CFTimeInterval, curve: CAMediaTimingFunction, delay: CFTimeInterval = 0, key: String) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        anim.toValue = value
        anim.duration = duration
        anim.timingFunction = curve
        if delay > 0 {
            anim.beginTime = CACurrentMediaTime() + delay
            anim.fillMode = .backwards
        }
        layer.add(anim, forKey: key)
        layer.setValue(value, forKeyPath: keyPath)
    }

    static func animate(_ layer: CALayer, _ keyPath: String, to value: Any, spring: LyricsSpecs.Spring, delay: CFTimeInterval, key: String) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        let anim = Self.spring(keyPath, from: from, to: value, spring)
        if delay > 0 {
            anim.beginTime = CACurrentMediaTime() + delay
            anim.fillMode = .backwards
        }
        layer.add(anim, forKey: key)
        layer.setValue(value, forKeyPath: keyPath)
    }

    static func addLag(to layer: CALayer, offset: CGFloat, spring: LyricsSpecs.Spring, delay: TimeInterval, speed: Float = 1) {
        let anim = Self.spring("transform.translation.y", from: offset, to: 0, spring)
        anim.isAdditive = true
        anim.speed = speed
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .backwards
        lagSerial += 1
        layer.add(anim, forKey: "lag-\(lagSerial)")
        noteLag(on: layer, until: anim.beginTime + anim.duration / Double(speed))
    }

    static func addLinearLag(to layer: CALayer, offset: CGFloat, duration: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "transform.translation.y")
        anim.fromValue = offset
        anim.toValue = 0
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.isAdditive = true
        lagSerial += 1
        layer.add(anim, forKey: "lag-\(lagSerial)")
        noteLag(on: layer, until: CACurrentMediaTime() + duration)
    }

    private static func noteLag(on layer: CALayer, until end: CFTimeInterval) {
        guard let line = layer as? LineLayer else { return }
        line.lagsEnd = max(line.lagsEnd, end)
    }

    /// Set the model immediately, then animate the additive difference under a unique key.
    /// Use backwards fill for delays; transforms compose as old × new⁻¹.
    static func addAdditive(_ layer: CALayer, opacity new: Float, from old: Float? = nil, duration: CFTimeInterval, curve: CAMediaTimingFunction, delay: CFTimeInterval = 0) {
        let old = old ?? layer.opacity
        layer.opacity = new
        guard old != new else { return }
        addAdditive(layer, "opacity", from: old - new, to: Float(0), duration: duration, curve: curve, delay: delay)
    }

    static func addAdditive(_ layer: CALayer, transform new: CATransform3D, from old: CATransform3D? = nil, duration: CFTimeInterval, curve: CAMediaTimingFunction, delay: CFTimeInterval = 0) {
        let old = old ?? layer.transform
        layer.transform = new
        guard !CATransform3DEqualToTransform(old, new) else { return }
        let offset = CATransform3DConcat(old, CATransform3DInvert(new))
        addAdditive(layer, "transform", from: NSValue(caTransform3D: offset), to: NSValue(caTransform3D: CATransform3DIdentity), duration: duration, curve: curve, delay: delay)
    }

    private static func addAdditive(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, duration: CFTimeInterval, curve: CAMediaTimingFunction, delay: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = curve
        anim.isAdditive = true
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .both
        lagSerial += 1
        layer.add(anim, forKey: "\(keyPath)-\(lagSerial)")
    }

    static func removeLags(from layer: CALayer) {
        for key in layer.animationKeys() ?? [] where key.hasPrefix("lag-") { layer.removeAnimation(forKey: key) }
        (layer as? LineLayer)?.lagsEnd = 0
    }

    static func hasLags(_ layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).contains { $0.hasPrefix("lag-") }
    }
}

/// One glyph of an emphasised word: a crop of the row bitmap anchored at its baseline centre, so
/// the emphasis swell grows upwards.
final class GlyphLayer: NoAnimationLayer {
    enum Phase { case rest, up, down }
    /// Resting position (in the syllable layer, which does not move for emphasised words).
    var rest: CGPoint = .zero
    var wordX: CGFloat = 0
    var phase: Phase = .rest
}

final class SyllableLayer: NoAnimationLayer {
    let syllableIndex: Int
    let start: TimeInterval
    let end: TimeInterval
    /// Advance rect of the syllable in row coordinates (without bitmap padding).
    var contentRect: CGRect = .zero
    private(set) var isLifted = false

    init(syllableIndex: Int, syllable: LyricSyllable) {
        self.syllableIndex = syllableIndex
        self.start = syllable.start
        self.end = syllable.end
        super.init()
    }

    override init(layer: Any) {
        let other = layer as! SyllableLayer
        syllableIndex = other.syllableIndex
        start = other.start
        end = other.end
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    /// Points the layer at its crop of the shared row bitmap; `frame` is in row coordinates.
    func setContent(image: CGImage, imageOrigin: CGPoint, imageSize: CGSize, scale: CGFloat) {
        contents = image
        contentsScale = scale
        contentsGravity = .resize
        contentsRect = CGRect(x: (frame.minX - imageOrigin.x) / imageSize.width, y: (frame.minY - imageOrigin.y) / imageSize.height,
                              width: bounds.width / imageSize.width, height: bounds.height / imageSize.height)
    }

    /// Glyph crops of an emphasised word's syllable; empty otherwise.
    private(set) var glyphLayers: [GlyphLayer] = []

    /// Replaces the syllable's own crop by one crop per glyph. `edges` are the glyph boundaries
    /// and `baselineY` the baseline, in row coordinates (`frame` must still be in row coordinates).
    func splitIntoGlyphs(edges: [CGFloat], baselineY: CGFloat, image: CGImage, imageOrigin: CGPoint, imageSize: CGSize, scale: CGFloat) {
        guard edges.count >= 2 else { return }
        contents = nil
        let anchorY = bounds.height > 0 ? (baselineY - frame.minY) / bounds.height : 1
        for (a, b) in zip(edges, edges.dropFirst()) where b > a {
            let glyph = GlyphLayer()
            glyph.anchorPoint = CGPoint(x: 0.5, y: anchorY)
            glyph.frame = CGRect(x: a - frame.minX, y: 0, width: b - a, height: bounds.height)
            glyph.rest = glyph.position
            glyph.wordX = max(a, contentRect.minX)
            glyph.contents = image
            glyph.contentsScale = scale
            glyph.contentsGravity = .resize
            glyph.contentsRect = CGRect(x: (a - imageOrigin.x) / imageSize.width, y: (frame.minY - imageOrigin.y) / imageSize.height,
                                        width: (b - a) / imageSize.width, height: bounds.height / imageSize.height)
            addSublayer(glyph)
            glyphLayers.append(glyph)
        }
    }

    func setLifted(_ lifted: Bool, lift: CGFloat, spring: LyricsSpecs.Spring?) {
        guard lifted != isLifted else { return }
        isLifted = lifted
        let y: CGFloat = lifted ? -lift : 0
        if let spring {
            LyricsAnimation.animate(self, "transform.translation.y", to: y, spring: spring, key: "lift")
        } else {
            removeAnimation(forKey: "lift")
            transform = CATransform3DMakeTranslation(0, y, 0)
        }
    }
}

/// Syllables of one word inside one row. Emphasised words (`LyricWord.emphasisFactor`) run the
/// emphasis once the word begins (from `VoiceLayer.updateSyllables`): the word's own shadow glows,
/// and a wave runs through its glyphs — each rises and swells, then settles back lifted. Because
/// the layer lives in the row's glyph mask, the halo takes the row's sung / unsung colours.
final class WordLayer: NoAnimationLayer {
    private enum Glow { case off, on, fading }

    let wordIndex: Int
    let emphasisFactor: Double
    let start: TimeInterval
    let end: TimeInterval
    var syllables: [SyllableLayer] = []
    private var glow: Glow = .off
    /// Word content (advance rect without padding) in row coordinates, and the row height.
    private var contentMinX: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var rowHeight: CGFloat = 0

    init(wordIndex: Int, word: LyricWord) {
        self.wordIndex = wordIndex
        self.emphasisFactor = word.emphasisFactor
        self.start = word.start
        self.end = word.end
        super.init()
    }

    override init(layer: Any) {
        let other = layer as! WordLayer
        wordIndex = other.wordIndex
        emphasisFactor = other.emphasisFactor
        start = other.start
        end = other.end
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    var glyphs: [GlyphLayer] { syllables.flatMap(\.glyphLayers) }
    var isEmphasized: Bool { emphasisFactor > 0 }

    func configureEmphasis(glowRadius: CGFloat, rowHeight: CGFloat, scale: CGFloat) {
        guard isEmphasized else { return }
        let content = syllables.map(\.contentRect).reduce(CGRect.null) { $0.union($1) }
        contentMinX = content.isNull ? 0 : content.minX
        contentWidth = content.isNull ? 0 : content.width
        self.rowHeight = rowHeight
        shadowColor = CGColor.white
        shadowRadius = glowRadius
        shadowOffset = .zero
        shadowOpacity = 0
        shouldRasterize = true
        rasterizationScale = scale
    }

    func updateEmphasis(time t: TimeInterval, specs: LyricsSpecs) {
        guard isEmphasized else { return }
        let elapsed = t - start
        guard elapsed >= 0 else {
            resetEmphasis()
            return
        }
        let duration = max(end - start, 0.001)
        let spring = LyricsSpecs.Spring.critical(response: min(duration, 3))
        if specs.glowEnabled {
            if elapsed < duration, glow == .off {
                glow = .on
                let target = Float(specs.glowRange.lowerBound + emphasisFactor * (specs.glowRange.upperBound - specs.glowRange.lowerBound))
                LyricsAnimation.animate(self, "shadowOpacity", to: target, spring: spring, key: "glow")
            } else if elapsed >= duration, glow == .on {
                glow = .fading
                LyricsAnimation.animate(self, "shadowOpacity", to: Float(0), spring: specs.syllableLiftSpring, key: "glow")
            }
        }
        guard specs.emphasisEnabled else { return }
        let glyphs = glyphs
        let n = Double(max(glyphs.count, 1))
        let stagger = min(0.4 * duration / n, 0.4)
        for (i, glyph) in glyphs.enumerated() {
            let k = Double(i + 1)
            let phase: GlyphLayer.Phase = elapsed >= 2 * duration / n + k * stagger ? .down : (elapsed >= k * stagger ? .up : .rest)
            if phase != glyph.phase { move(glyph, to: phase, specs: specs, spring: spring) }
        }
    }

    private func move(_ glyph: GlyphLayer, to phase: GlyphLayer.Phase, specs: LyricsSpecs, spring: LyricsSpecs.Spring?) {
        glyph.phase = phase
        let lift = specs.syllableLiftEnabled ? specs.syllableLift : 0
        let s = specs.emphasizingScaleRange.lowerBound + emphasisFactor * (specs.emphasizingScaleRange.upperBound - specs.emphasizingScaleRange.lowerBound)
        let offset: CGPoint
        let scale: CGFloat
        switch phase {
        case .rest:
            offset = .zero
            scale = 1
        case .up:
            let x = glyph.wordX - contentMinX
            offset = CGPoint(x: (s - 1) * (x - contentWidth / 2) / 2, y: -(s - 1) * rowHeight / 4 - lift)
            scale = s
        case .down:
            offset = CGPoint(x: 0, y: -lift)
            scale = 1
        }
        let position = CGPoint(x: glyph.rest.x + offset.x, y: glyph.rest.y + offset.y)
        if let spring {
            LyricsAnimation.animate(glyph, "position", to: NSValue(point: position), spring: spring, key: "emphasisPosition")
            LyricsAnimation.animate(glyph, "transform.scale", to: scale, spring: spring, key: "emphasisScale")
        } else {
            glyph.removeAnimation(forKey: "emphasisPosition")
            glyph.removeAnimation(forKey: "emphasisScale")
            glyph.position = position
            glyph.transform = CATransform3DMakeScale(scale, scale, 1)
        }
    }

    /// Leaving the selected state after the word began: the glyphs finish their run, so every glyph
    /// ends in its lifted rest; the glow fades.
    func settleEmphasis(specs: LyricsSpecs) {
        guard isEmphasized, glow != .off || glyphs.contains(where: { $0.phase != .rest }) else { return }
        let spring = LyricsSpecs.Spring.critical(response: min(max(end - start, 0.1), 3))
        if specs.emphasisEnabled {
            for glyph in glyphs where glyph.phase != .down { move(glyph, to: .down, specs: specs, spring: spring) }
        }
        if glow == .on {
            glow = .fading
            LyricsAnimation.animate(self, "shadowOpacity", to: Float(0), spring: specs.syllableLiftSpring, key: "glow")
        }
    }

    func resetEmphasis() {
        guard isEmphasized else { return }
        for glyph in glyphs where glyph.phase != .rest { move(glyph, to: .rest, specs: LyricsSpecs(), spring: nil) }
        if glow != .off {
            glow = .off
            removeAnimation(forKey: "glow")
            shadowOpacity = 0
        }
    }
}

final class RowLayer: NoAnimationLayer {
    struct Step {
        var start: TimeInterval
        var end: TimeInterval
        var target: CGFloat
    }

    let unsungLayer = NoAnimationLayer()
    let progressLayer = NoAnimationLayer()
    private let fillLayer = NoAnimationLayer()
    private let edgeLayer = NoAnimationGradientLayer()
    let glyphs = NoAnimationLayer()
    private(set) var words: [WordLayer] = []
    private(set) var syllables: [SyllableLayer] = []
    private(set) var steps: [Step] = []
    private(set) var feather: CGFloat = 30
    private(set) var edge: CGFloat = 0
    private(set) var isTimed = true
    /// Syllables lift once they start; romanization rows do not.
    var liftsSyllables = true

    override init() {
        super.init()
        edgeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        edgeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        progressLayer.addSublayer(fillLayer)
        progressLayer.addSublayer(edgeLayer)
        progressLayer.anchorPoint = CGPoint(x: 1, y: 0)
        addSublayer(unsungLayer)
        addSublayer(progressLayer)
        glyphs.anchorPoint = .zero
        mask = glyphs
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    var finalEdge: CGFloat { steps.last?.target ?? -feather }
    var startEdge: CGFloat { isTimed ? -feather : finalEdge }

    func configure(rect: CGRect, overflow: CGSize, feather: CGFloat, tint: CGColor, steps: [Step], timed: Bool = true, words: [WordLayer]) {
        frame = rect
        self.feather = feather
        self.steps = steps
        isTimed = timed
        let area = bounds.insetBy(dx: -overflow.width, dy: -overflow.height)
        unsungLayer.frame = area
        unsungLayer.backgroundColor = tint
        let length = area.width + feather
        progressLayer.bounds = CGRect(x: 0, y: 0, width: length, height: area.height)
        fillLayer.frame = CGRect(x: 0, y: 0, width: length - feather, height: area.height)
        fillLayer.backgroundColor = tint
        edgeLayer.frame = CGRect(x: length - feather, y: 0, width: feather, height: area.height)
        edgeLayer.colors = [tint, tint.copy(alpha: 0) ?? CGColor.clear]
        glyphs.bounds = area
        glyphs.position = area.origin
        glyphs.sublayers?.forEach { $0.removeFromSuperlayer() }
        self.words = words
        syllables = words.flatMap(\.syllables)
        words.forEach { glyphs.addSublayer($0) }
        setEdge(startEdge)
    }

    /// Places the progress layer so the row is sung up to `s` (right edge at `s + feather`).
    func setEdge(_ s: CGFloat) {
        guard s != edge || progressLayer.animation(forKey: "finish") != nil else { return }
        progressLayer.removeAnimation(forKey: "finish")
        edge = s
        progressLayer.position = CGPoint(x: s + feather, y: unsungLayer.frame.minY)
    }

    func edge(at t: TimeInterval) -> CGFloat {
        var previous = startEdge
        for step in steps {
            if t < step.start { return previous }
            if t < step.end {
                let p = (t - step.start) / max(step.end - step.start, 0.001)
                return previous + (step.target - previous) * CGFloat(p)
            }
            previous = step.target
        }
        return previous
    }

    var remainingDistance: CGFloat {
        max(finalEdge - ((progressLayer.presentation() ?? progressLayer).position.x - feather), 0)
    }

    func finish(duration: TimeInterval, delay: TimeInterval = 0) {
        let target = finalEdge
        guard edge != target else { return }
        guard duration > 0 else { return setEdge(target) }
        edge = target
        LyricsAnimation.animate(progressLayer, "position.x", to: target + feather, duration: duration,
                                curve: CAMediaTimingFunction(name: .linear), delay: delay, key: "finish")
    }
}

final class InstrumentalBreakLayer: NoAnimationLayer {
    let gap: InstrumentalGap
    private(set) var isSelected = false
    private(set) var dots: [NoAnimationLayer] = []
    private var dotLength: CGFloat = 12
    private var dotMargin: CGFloat = 8
    private(set) var breathDuration: TimeInterval = 0
    private(set) var dotFadeInDuration: TimeInterval = 0
    private var totalDotsCompleted = 0
    private var totalBreathsCompleted = 0
    private var appearedAt: CFTimeInterval?
    private(set) var fadeOutCued = false

    static let lightingDelay: TimeInterval = 1
    static let fadeOutLead: TimeInterval = 1.8
    static let unlitOpacity: Float = 0.1
    static let appearDuration: CFTimeInterval = 0.8
    static let appearStagger: CFTimeInterval = 0.06
    static let breathDelay: CFTimeInterval = 0.2
    static let inhaleScale: CGFloat = 1.2
    static let exhaleScale: CGFloat = 0.9
    static let swellDuration: CFTimeInterval = 1
    static var swellCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1) }
    static let vanishDelay: CFTimeInterval = 1
    static let vanishScale: CGFloat = 0.2
    static let shrinkDuration: CFTimeInterval = 0.5
    static let vanishFadeDuration: CFTimeInterval = 0.3
    static let deselectDuration: CFTimeInterval = 0.12

    init(gap: InstrumentalGap, specs: LyricsSpecs, tint: CGColor) {
        self.gap = gap
        super.init()
        dotLength = specs.instrumentalBreakDotLength
        dotMargin = specs.instrumentalBreakDotMargin
        let count = max(1, specs.instrumentalBreakCountdownDotCount)
        for i in 0..<count {
            let dot = NoAnimationLayer()
            var anchor: CGFloat = 0.5
            if i == 0 { anchor += 1.3 } else if i == count - 1 { anchor -= 1.3 }
            dot.anchorPoint = CGPoint(x: anchor, y: 0.5)
            dot.bounds = CGRect(x: 0, y: 0, width: dotLength, height: dotLength)
            dot.cornerRadius = dotLength / 2
            dot.backgroundColor = tint
            dot.opacity = 0
            addSublayer(dot)
            dots.append(dot)
        }
        reset()
    }

    override init(layer: Any) {
        let other = layer as! InstrumentalBreakLayer
        gap = other.gap
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func layout(size: CGSize, alignment: NSTextAlignment) {
        bounds = CGRect(origin: .zero, size: size)
        let n = CGFloat(dots.count)
        let total = n * dotLength + (n - 1) * dotMargin
        var x: CGFloat
        switch alignment {
        case .center: x = (size.width - total) / 2
        case .right: x = size.width - total
        default: x = 0
        }
        for dot in dots {
            dot.position = CGPoint(x: x + dot.anchorPoint.x * dotLength, y: size.height / 2)
            x += dotLength + dotMargin
        }
    }

    func reset() {
        resetTimeline()
        for dot in dots {
            dot.removeAllAnimations()
            dot.opacity = 0
            dot.transform = CATransform3DIdentity
        }
    }

    private func resetTimeline() {
        let span = max(gap.end - Self.fadeOutLead - gap.start, 0.1)
        breathDuration = span / max(floor(span * 0.25), 1) * 0.5
        dotFadeInDuration = max(gap.end - Self.fadeOutLead - (gap.start + Self.lightingDelay), 0.1) / Double(dots.count)
        totalDotsCompleted = 0
        totalBreathsCompleted = 0
        appearedAt = nil
        fadeOutCued = false
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        isSelected = selected
        guard !selected else { return }
        let before = dots.map { ($0.opacity, $0.transform) }
        reset()
        guard animated else { return }
        for (dot, (opacity, transform)) in zip(dots, before) {
            LyricsAnimation.addAdditive(dot, opacity: 0, from: opacity, duration: Self.deselectDuration, curve: LyricsAnimation.blurCurve)
            LyricsAnimation.addAdditive(dot, transform: CATransform3DIdentity, from: transform, duration: Self.deselectDuration, curve: LyricsAnimation.blurCurve)
        }
    }

    func appear(at t: TimeInterval, now: CFTimeInterval = CACurrentMediaTime()) {
        guard appearedAt == nil else { return }
        appearedAt = now
        var lit = 0
        if t >= gap.start + Self.lightingDelay {
            lit = min(Int((t - gap.start - Self.lightingDelay) / dotFadeInDuration) + 1, dots.count)
        }
        let linear = CAMediaTimingFunction(name: .linear)
        for (i, dot) in dots.enumerated() {
            LyricsAnimation.addAdditive(dot, opacity: i < lit ? 1 : Self.unlitOpacity, duration: Self.appearDuration, curve: linear, delay: Self.appearStagger * Double(i))
        }
        breathe(1)
        totalBreathsCompleted += 1
    }

    func update(at t: TimeInterval, now: CFTimeInterval = CACurrentMediaTime()) {
        let n = dots.count
        let k = max(0, min(Int((t - (gap.start + Self.lightingDelay)) / dotFadeInDuration) + 1, n))
        if k < totalDotsCompleted {
            reset()
            appear(at: t, now: now)
            return
        }
        let fadeOutAt = gap.end - Self.fadeOutLead
        let fadedIn = appearedAt.map { now >= $0 + Self.appearDuration + Self.appearStagger * Double(n - 1) } ?? false
        if fadedIn, gap.start + Self.lightingDelay < t, t < fadeOutAt {
            if k != totalDotsCompleted, isSelected {
                let i = k - 1
                for j in totalDotsCompleted..<i { dots[j].opacity = 1 }
                totalDotsCompleted = k
                LyricsAnimation.addAdditive(dots[i], opacity: 1, duration: max(dotFadeInDuration - 0.1, 0.05), curve: CAMediaTimingFunction(name: .linear))
            }
            let breath = Int((t - gap.start) / breathDuration) + 1
            if totalBreathsCompleted < breath {
                breathe(breath)
                totalBreathsCompleted += 1
            }
        }
        if t < gap.end, t > fadeOutAt, !fadeOutCued { fadeOut() }
    }

    private func breathe(_ index: Int) {
        let scale = index % 2 == 1 ? Self.inhaleScale : Self.exhaleScale
        let target = CATransform3DMakeScale(scale, scale, 1)
        for dot in dots {
            LyricsAnimation.addAdditive(dot, transform: target, duration: max(breathDuration - 0.4, 0.05), curve: CAMediaTimingFunction(name: .easeOut), delay: Self.breathDelay)
        }
    }

    private func fadeOut() {
        fadeOutCued = true
        let easeIn = CAMediaTimingFunction(name: .easeIn)
        let swell = CATransform3DMakeScale(Self.inhaleScale, Self.inhaleScale, 1)
        let vanish = CATransform3DMakeScale(Self.vanishScale, Self.vanishScale, 1)
        for dot in dots {
            LyricsAnimation.addAdditive(dot, transform: swell, duration: Self.swellDuration, curve: Self.swellCurve)
            LyricsAnimation.addAdditive(dot, opacity: 0, duration: Self.vanishFadeDuration, curve: easeIn, delay: Self.vanishDelay)
            LyricsAnimation.addAdditive(dot, transform: vanish, duration: Self.shrinkDuration, curve: easeIn, delay: Self.vanishDelay)
        }
    }
}

struct VoiceLayout {
    var voice: LyricLine
    var text: LineTextLayout
    var translation: TextBlockLayout?
    var romanization: TextBlockLayout? = nil
    var ruby: RubyLayout? = nil

    var textHeight: CGFloat { max(text.size.height, ruby?.text.size.height ?? 0) }

    enum Secondary: CaseIterable { case translation, romanization }

    func block(_ kind: Secondary) -> TextBlockLayout? {
        switch kind {
        case .translation: translation
        case .romanization: romanization
        }
    }

    func top(of kind: Secondary, specs: LyricsSpecs) -> CGFloat {
        let top = textHeight + specs.translationSpacing
        return kind == .translation ? top : top + (translation?.size.height ?? 0)
    }

    func height(specs: LyricsSpecs) -> CGFloat {
        guard translation != nil || romanization != nil else { return textHeight }
        return textHeight + specs.translationSpacing + (translation?.size.height ?? 0) + (romanization?.size.height ?? 0) + specs.translationBottomPadding
    }
}

final class VoiceLayer: NoAnimationLayer {
    private(set) var layout: VoiceLayout
    private(set) var rows: [RowLayer] = []
    private let secondaryLayer = NoAnimationLayer()
    private var blocks: [VoiceLayout.Secondary: NoAnimationLayer] = [:]
    private(set) var contentHeight: CGFloat = 0
    var placedTop: CGFloat?
    /// Set once the progress was completed ahead of the line change (`finishProgress`): the edge
    /// stops following the clock, lifts and emphasis do not.
    private(set) var ignoresProgress = false
    private let glyphPadding: CGFloat = 12
    private var width: CGFloat = 0
    private var renderScale: CGFloat = 2
    private var renderColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var secondaryTint: CGColor = .white
    private var rowTint: CGColor = .white
    private var rowColors: (unsung: Float, sung: Float)?
    private var snapsNextUpdate = false

    init(layout: VoiceLayout) {
        self.layout = layout
        super.init()
        addSublayer(secondaryLayer)
    }

    override init(layer: Any) {
        layout = (layer as! VoiceLayer).layout
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    var line: LyricLine { layout.voice }
    var textLayout: LineTextLayout { layout.text }
    var syllables: [SyllableLayer] { rows.flatMap(\.syllables) }

    func build(width: CGFloat, specs: LyricsSpecs, tint: NSColor, scale: CGFloat, colorSpace: CGColorSpace, translationTint: NSColor) {
        rows.forEach { $0.removeFromSuperlayer() }
        ignoresProgress = false
        self.width = width
        renderScale = scale
        renderColorSpace = colorSpace
        secondaryTint = translationTint.cgColor
        rowTint = tint.cgColor
        rows = makeRows(specs: specs)
        rows.forEach { insertSublayer($0, below: secondaryLayer) }

        blocks.values.forEach { $0.removeFromSuperlayer() }
        blocks = [:]
        for kind in VoiceLayout.Secondary.allCases {
            guard let block = layout.block(kind) else { continue }
            let l = makeBlock(block, top: layout.top(of: kind, specs: specs))
            secondaryLayer.addSublayer(l)
            blocks[kind] = l
        }
        resize(specs: specs)
    }

    private func makeRows(specs: LyricsSpecs) -> [RowLayer] {
        var result = rowLayers(textLayout, line: line, lifts: true, specs: specs)
        if let ruby = layout.ruby { result += rowLayers(ruby.text, line: ruby.line, lifts: false, specs: specs) }
        return result
    }

    private func rowLayers(_ text: LineTextLayout, line: LyricLine, lifts: Bool, specs: LyricsSpecs) -> [RowLayer] {
        let scale = renderScale
        let lineSyllables = line.syllables
        let padding = glyphPadding
        var wordOfSyllable: [Int] = []
        var lastSyllableOfWord: [Int] = []
        for (w, word) in line.words.enumerated() {
            wordOfSyllable.append(contentsOf: repeatElement(w, count: word.syllables.count))
            lastSyllableOfWord.append(wordOfSyllable.count - 1)
        }
        let timed = line.hasSyllableTiming && specs.perSyllableEnabled
        let feather = specs.lineProgressionGradientFeather
        let font = textLayout.font
        let lineHeight = font.ascender - font.descender + font.leading
        let glow = specs.glowEnabled ? specs.glowRadius : 0

        var result: [RowLayer] = []
        for row in text.rows {
            let rowHeight = row.height
            let imageOrigin = CGPoint(x: -padding, y: -padding)
            let imageSize = CGSize(width: max(width, row.width) + padding * 2, height: rowHeight + padding * 2)
            guard let image = LineTextLayout.renderRow(row, width: max(width, row.width), color: CGColor.white, scale: scale, colorSpace: renderColorSpace, padding: padding) else { continue }
            let vPad = max(padding, abs(lineHeight * specs.emphasizingScaleRange.upperBound + 2 * glow - rowHeight) / 2 + specs.syllableLift)
            let overflow = CGSize(width: padding + 2 * glow, height: vPad)

            // Word / syllable layers cropped from the row bitmap (row coordinates).
            var words: [WordLayer] = []
            var wordFrames: [CGRect] = []
            for (fi, fragment) in row.fragments.enumerated() {
                let wordIndex = fragment.syllable < wordOfSyllable.count ? wordOfSyllable[fragment.syllable] : 0
                var rect = fragment.rect
                if fi == 0 { rect.origin.x -= padding; rect.size.width += padding }
                if fi == row.fragments.count - 1 { rect.size.width += padding }
                rect.origin.y = -padding
                rect.size.height = rowHeight + padding * 2
                if words.last?.wordIndex != wordIndex {
                    words.append(WordLayer(wordIndex: wordIndex, word: line.words[min(wordIndex, line.words.count - 1)]))
                    wordFrames.append(rect)
                } else {
                    wordFrames[wordFrames.count - 1] = wordFrames[wordFrames.count - 1].union(rect)
                }
                let syllable = fragment.syllable < lineSyllables.count ? lineSyllables[fragment.syllable] : LyricSyllable(start: line.start, end: line.end, text: "")
                let layer = SyllableLayer(syllableIndex: fragment.syllable, syllable: syllable)
                layer.frame = rect
                layer.contentRect = fragment.rect
                layer.setContent(image: image, imageOrigin: imageOrigin, imageSize: imageSize, scale: scale)
                if timed, specs.emphasisEnabled, words[words.count - 1].isEmphasized {
                    let starts = fragment.clusters.flatMap { $0.positions.map(\.x) }.sorted()
                    let edges = [rect.minX] + starts.dropFirst().filter { $0 > rect.minX && $0 < rect.maxX } + [rect.maxX]
                    layer.splitIntoGlyphs(edges: edges, baselineY: row.ascent, image: image, imageOrigin: imageOrigin, imageSize: imageSize, scale: scale)
                }
                words[words.count - 1].syllables.append(layer)
            }
            for (word, frame) in zip(words, wordFrames) {
                word.frame = frame
                for s in word.syllables {
                    s.frame = s.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
                    word.addSublayer(s)
                }
                if timed { word.configureEmphasis(glowRadius: glow, rowHeight: rowHeight, scale: scale) }
            }

            let steps = timed
                ? Self.progressSteps(row: row, syllables: lineSyllables, words: line.words, wordOfSyllable: wordOfSyllable, lastSyllableOfWord: lastSyllableOfWord, feather: feather)
                : [RowLayer.Step(start: line.start, end: line.start, target: row.fragments.map(\.inkMaxX).max() ?? 0)]
            let rowLayer = RowLayer()
            rowLayer.liftsSyllables = lifts
            rowLayer.configure(rect: CGRect(x: 0, y: row.origin.y, width: width, height: rowHeight), overflow: overflow, feather: feather, tint: rowTint, steps: steps, timed: timed, words: words)
            result.append(rowLayer)
        }
        return result
    }

    /// The text layout changed (aligned romanization switched on or off): new rows take over the
    /// colours and progress and cross-fade with the old ones — 0.15 s, the new rows 0.1 s later,
    /// like a translation block whose text changes.
    private func replaceRows(specs: LyricsSpecs, animated: Bool) {
        let old = rows
        rows = makeRows(specs: specs)
        let liftSung = ignoresProgress && specs.syllableLiftEnabled && line.hasSyllableTiming && specs.perSyllableEnabled
        for row in rows {
            insertSublayer(row, below: secondaryLayer)
            if let rowColors {
                row.unsungLayer.opacity = rowColors.unsung
                row.progressLayer.opacity = rowColors.sung
            }
            guard ignoresProgress else { continue }
            row.setEdge(row.finalEdge)
            if liftSung, row.liftsSyllables {
                for s in row.syllables where s.glyphLayers.isEmpty { s.setLifted(true, lift: specs.syllableLift, spring: nil) }
            }
        }
        snapsNextUpdate = true
        guard animated else {
            old.forEach { $0.removeFromSuperlayer() }
            return
        }
        let curve = LyricsAnimation.secondaryFadeCurve
        let duration = LyricsAnimation.secondaryCrossFadeDuration
        for row in old { LyricsAnimation.animate(row, "opacity", to: Float(0), duration: duration, curve: curve, key: "opacity") }
        // Removed on a timer rather than a transaction completion, which needs the render server
        // (it never fires for a window that is not on screen).
        perform(#selector(removeRetiredRows(_:)), with: old as NSArray, afterDelay: duration + 0.05, inModes: [.common])
        for row in rows {
            row.opacity = 0
            LyricsAnimation.animate(row, "opacity", to: Float(1), duration: duration, curve: curve, delay: 0.1, key: "opacity")
        }
    }

    @objc private func removeRetiredRows(_ retired: NSArray) {
        for case let row as CALayer in retired { row.removeFromSuperlayer() }
    }

    func secondaryBlock(_ kind: VoiceLayout.Secondary) -> CALayer? { blocks[kind] }

    private func resize(specs: LyricsSpecs) {
        contentHeight = layout.height(specs: specs)
        secondaryLayer.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        bounds = CGRect(x: 0, y: 0, width: width, height: contentHeight)
    }

    private func makeBlock(_ block: TextBlockLayout, top: CGFloat) -> NoAnimationLayer {
        let container = NoAnimationLayer()
        container.frame = CGRect(x: 0, y: top, width: width, height: block.size.height)
        let padding: CGFloat = 6
        var y: CGFloat = 0
        for r in block.rows {
            defer { y += r.height }
            guard let img = LineTextLayout.renderRow(r, width: max(width, r.width), color: secondaryTint, scale: renderScale, colorSpace: renderColorSpace, padding: padding) else { continue }
            let l = NoAnimationLayer()
            l.contents = img
            l.contentsScale = renderScale
            l.contentsGravity = .resize
            l.frame = CGRect(x: -padding, y: y - padding, width: max(width, r.width) + padding * 2, height: r.height + padding * 2)
            container.addSublayer(l)
        }
        return container
    }

    func updateSecondary(to new: VoiceLayout, specs: LyricsSpecs, animated: Bool, spring: LyricsSpecs.Spring) {
        let old = layout
        layout = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if (old.ruby == nil) != (new.ruby == nil) { replaceRows(specs: specs, animated: animated) }
        for kind in VoiceLayout.Secondary.allCases {
            let top = new.top(of: kind, specs: specs)
            switch (blocks[kind], new.block(kind)) {
            case (nil, nil):
                continue
            case (nil, let block?):
                let l = makeBlock(block, top: top)
                secondaryLayer.addSublayer(l)
                blocks[kind] = l
                if animated { reveal(l, specs: specs) }
            case (let l?, nil):
                blocks[kind] = nil
                if animated { conceal(l, specs: specs) } else { l.removeFromSuperlayer() }
            case (let l?, let block?):
                if old.block(kind)?.text != block.text {
                    let replacement = makeBlock(block, top: top)
                    secondaryLayer.addSublayer(replacement)
                    blocks[kind] = replacement
                    if animated {
                        crossFade(from: l, to: replacement)
                    } else {
                        l.removeFromSuperlayer()
                    }
                } else {
                    let oldTop = l.frame.minY
                    l.frame.origin.y = top
                    if animated, abs(oldTop - top) > 0.5 {
                        LyricsAnimation.addLag(to: l, offset: oldTop - top, spring: spring, delay: 0)
                    }
                }
            }
        }
        resize(specs: specs)
        CATransaction.commit()
    }

    private func reveal(_ block: CALayer, specs: LyricsSpecs) {
        block.opacity = 0
        LyricsAnimation.animate(block, "opacity", to: Float(1), duration: LyricsAnimation.secondaryRevealDuration, curve: LyricsAnimation.secondaryFadeCurve, key: "opacity")
        block.add(LyricsAnimation.spring("transform.translation.y", from: -specs.translationRevealOffset, to: 0, specs.showTranslationSpring), forKey: "reveal")
    }

    private func conceal(_ block: CALayer, specs: LyricsSpecs) {
        let offset = -specs.translationRevealOffset
        let move = LyricsAnimation.spring("transform.translation.y", from: (block.presentation() ?? block).value(forKeyPath: "transform.translation.y") ?? 0, to: offset, specs.hideTranslationSpring)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak block] in block?.removeFromSuperlayer() }
        LyricsAnimation.animate(block, "opacity", to: Float(0), duration: LyricsAnimation.secondaryConcealDuration, curve: LyricsAnimation.secondaryFadeCurve, key: "opacity")
        block.add(move, forKey: "reveal")
        block.transform = CATransform3DMakeTranslation(0, offset, 0)
        CATransaction.commit()
    }

    private func crossFade(from old: CALayer, to new: CALayer) {
        let curve = LyricsAnimation.secondaryFadeCurve
        let duration = LyricsAnimation.secondaryCrossFadeDuration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak old] in old?.removeFromSuperlayer() }
        LyricsAnimation.animate(old, "opacity", to: Float(0), duration: duration, curve: curve, key: "opacity")
        CATransaction.commit()
        new.opacity = 0
        LyricsAnimation.animate(new, "opacity", to: Float(1), duration: duration, curve: curve, delay: 0.1, key: "opacity")
    }

    /// Progress targets of one row. A syllable's end x is its inked max x, or the next word's inked
    /// min x when it ends a word that is followed on the same row (so the gap between words is sung
    /// with the word before it). The lead `k` decides how far the feather reaches past that point
    /// when the syllable ends.
    static func progressSteps(row: LineTextLayout.Row, syllables: [LyricSyllable], words: [LyricWord], wordOfSyllable: [Int], lastSyllableOfWord: [Int], feather: CGFloat) -> [RowLayer.Step] {
        let fragments = row.fragments
        var steps: [RowLayer.Step] = []
        var previous = -feather
        var lastInkX: CGFloat = -feather
        for (fi, fragment) in fragments.enumerated() {
            let si = fragment.syllable
            guard si < syllables.count else { continue }
            let syllable = syllables[si]
            let wi = si < wordOfSyllable.count ? wordOfSyllable[si] : 0
            var endX: CGFloat
            if fragment.ink == nil {
                endX = lastInkX
            } else {
                endX = fragment.inkMaxX
                lastInkX = endX
            }
            let isWordEnd = wi < lastSyllableOfWord.count && lastSyllableOfWord[wi] == si
            if isWordEnd, let next = fragments[(fi + 1)...].first(where: { $0.ink != nil && $0.syllable < wordOfSyllable.count && wordOfSyllable[$0.syllable] != wi }) {
                endX = max(endX, next.inkMinX)
            }
            let k: CGFloat
            let wordLength = wi < words.count ? words[wi].length : 0
            if fi == fragments.count - 1 {
                k = 1
            } else if wordLength > 0, wordLength < 3 {
                k = 0.5
            } else if si == syllables.count - 1 {
                k = 0.12
            } else if syllable.text.trimmingCharacters(in: .whitespaces).count < 3 {
                k = 0.25
            } else {
                k = 0.12
            }
            let target = max(previous, endX - feather * (1 - k))
            steps.append(RowLayer.Step(start: syllable.start, end: syllable.end, target: target))
            previous = target
        }
        return steps
    }

    func setColors(unsung: Float, sung: Float, translation: Float, duration: CFTimeInterval, curve: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)) {
        rowColors = (unsung, sung)
        for row in rows {
            Self.fade(row.unsungLayer, to: unsung, duration: duration, curve: curve)
            Self.fade(row.progressLayer, to: sung, duration: duration, curve: curve)
        }
        Self.fade(secondaryLayer, to: translation, duration: duration, curve: curve)
    }

    private static func fade(_ layer: CALayer, to value: Float, duration: CFTimeInterval, curve: CAMediaTimingFunction) {
        if duration > 0, abs((layer.presentation() ?? layer).opacity - value) > 0.001 {
            LyricsAnimation.animate(layer, "opacity", to: value, duration: duration, curve: curve, key: "opacity")
        } else {
            layer.removeAnimation(forKey: "opacity")
            layer.opacity = value
        }
    }

    func updateSyllables(time t: TimeInterval, specs: LyricsSpecs) {
        if !ignoresProgress {
            for row in rows { row.setEdge(row.edge(at: t)) }
        }
        guard line.hasSyllableTiming, specs.perSyllableEnabled else { return }
        let liftSpring: LyricsSpecs.Spring? = specs.springEnabled && !snapsNextUpdate ? specs.syllableLiftSpring : nil
        snapsNextUpdate = false
        for row in rows {
            for word in row.words {
                // Emphasised glyphs carry their own lift, so their syllables stay put;
                // romanization rows never lift.
                if row.liftsSyllables {
                    for s in word.syllables where s.glyphLayers.isEmpty {
                        s.setLifted(specs.syllableLiftEnabled && t >= s.start, lift: specs.syllableLift, spring: liftSpring)
                    }
                }
                word.updateEmphasis(time: t, specs: specs)
            }
        }
    }

    /// Finish wrapped rows sequentially at one edge speed, then ignore the clock.
    /// Aligned romanization sweeps alongside the main rows.
    func finishProgress(duration: TimeInterval) {
        guard !ignoresProgress else { return }
        ignoresProgress = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.finishInSequence(rows.filter(\.liftsSyllables), duration: duration)
        Self.finishInSequence(rows.filter { !$0.liftsSyllables }, duration: duration)
        CATransaction.commit()
    }

    private static func finishInSequence(_ rows: [RowLayer], duration: TimeInterval) {
        let distances = rows.map(\.remainingDistance)
        let total = distances.reduce(0, +)
        var delay: TimeInterval = 0
        for (row, distance) in zip(rows, distances) {
            let share = total > 0 ? duration * Double(distance / total) : 0
            row.finish(duration: share, delay: delay)
            delay += share
        }
    }

    func settle(specs: LyricsSpecs, past: Bool) {
        if past {
            finishProgress(duration: specs.lineFinishProgressAnimationDuration)
        } else {
            rows.forEach { $0.setEdge($0.startEdge) }
        }
        for row in rows {
            for word in row.words { word.settleEmphasis(specs: specs) }
        }
    }

    func resume() {
        ignoresProgress = false
    }

    func markSung() {
        ignoresProgress = true
        rows.forEach { $0.setEdge($0.finalEdge) }
    }

    func reset() {
        ignoresProgress = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in rows {
            row.setEdge(row.startEdge)
            for word in row.words {
                word.resetEmphasis()
                for s in word.syllables { s.setLifted(false, lift: 0, spring: nil) }
            }
        }
        CATransaction.commit()
    }
}

final class LineLayer: NoAnimationLayer {
    enum State { case upcoming, selected, past }

    let lineIndex: Int
    let line: LyricLine
    let alignment: NSTextAlignment
    let main: VoiceLayer
    let background: VoiceLayer?
    let backgroundAbove: Bool
    let containerLayer = NoAnimationLayer()
    let highlightLayer = NoAnimationLayer()
    private let snapshotLayer = NoAnimationLayer()
    private let snapshotFadeLayer = NoAnimationLayer()
    private(set) var installedRadius: CGFloat = 0
    private var pendingBlurTransition: BlurTransition?
    private var blurFilter: CIFilter?
    private(set) var blurTarget: CGFloat = 0
    /// Radius the line shows (or would show, see `isOffscreen`).
    private(set) var appliedBlur: CGFloat = 0
    private(set) var isShowingSnapshot = false
    private var staticPending = false
    /// Host time before which the line must not freeze (the longest pending hold).
    private var staticDeadline: CFTimeInterval = 0
    var lagsEnd: CFTimeInterval = 0
    /// Set by the view: the line is outside the viewport margin. It then carries no filter
    /// object while it waits for its image — nobody sees it, and every filter object costs the
    /// render server work on each commit. Coming back on screen restores the filter at once.
    var isOffscreen = false {
        didSet {
            guard isOffscreen != oldValue, !isShowingSnapshot else { return }
            if isOffscreen {
                removeFilter()
            } else if appliedBlur > 0.01 {
                installFilter(radius: appliedBlur)
            }
        }
    }
    var snapshotRequest: ((LineLayer) -> Void)?
    private var isHighlighted = false
    private(set) var state: State = .upcoming
    private var appliedScrolling: Bool?
    private(set) var isExpanded = false
    private var backgroundSpacing: CGFloat = 0
    private var highlightMargin: CGFloat = 16
    private var width: CGFloat = 0
    private var renderScale: CGFloat = 2
    private(set) var renderColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(lineIndex: Int, line: LyricLine, main: VoiceLayout, background: VoiceLayout?, alignment: NSTextAlignment) {
        self.lineIndex = lineIndex
        self.line = line
        self.alignment = alignment
        self.main = VoiceLayer(layout: main)
        self.background = background.map { VoiceLayer(layout: $0) }
        self.backgroundAbove = line.background?.isAbove(line) ?? false
        super.init()
        highlightLayer.opacity = 0
        containerLayer.addSublayer(highlightLayer)
        containerLayer.addSublayer(self.main)
        if let bg = self.background { containerLayer.addSublayer(bg) }
        addSublayer(containerLayer)
        snapshotFadeLayer.isHidden = true
        snapshotFadeLayer.anchorPoint = .zero
        addSublayer(snapshotFadeLayer)
        snapshotLayer.isHidden = true
        snapshotLayer.anchorPoint = .zero
        addSublayer(snapshotLayer)
    }

    convenience init(lineIndex: Int, line: LyricLine, textLayout: LineTextLayout, translationLayout: TextBlockLayout?, alignment: NSTextAlignment) {
        self.init(lineIndex: lineIndex, line: line, main: VoiceLayout(voice: line, text: textLayout, translation: translationLayout), background: nil, alignment: alignment)
    }

    override init(layer: Any) {
        let other = layer as! LineLayer
        lineIndex = other.lineIndex
        line = other.line
        alignment = other.alignment
        main = other.main
        background = other.background
        backgroundAbove = other.backgroundAbove
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    var rows: [RowLayer] { main.rows }
    var textLayout: LineTextLayout { main.textLayout }
    var syllables: [SyllableLayer] { main.syllables + (background?.syllables ?? []) }

    var collapsedHeight: CGFloat { main.contentHeight }
    var expandedHeight: CGFloat {
        guard let background else { return main.contentHeight }
        return main.contentHeight + backgroundSpacing + background.contentHeight
    }
    var contentHeight: CGFloat { isExpanded ? expandedHeight : collapsedHeight }

    private var horizontalAnchor: CGFloat {
        switch alignment {
        case .right: 1
        case .center: 0.5
        default: 0
        }
    }

    func build(width: CGFloat, specs: LyricsSpecs, tint: NSColor, scale: CGFloat, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, translationTint: NSColor) {
        renderScale = scale
        renderColorSpace = colorSpace
        self.width = width
        backgroundSpacing = specs.backgroundVocalsTopSpacing
        main.build(width: width, specs: specs, tint: tint, scale: scale, colorSpace: colorSpace, translationTint: translationTint)
        for voice in [main] + [background].compactMap({ $0 }) {
            voice.anchorPoint = CGPoint(x: horizontalAnchor, y: 0.5)
        }
        if let background {
            background.build(width: width, specs: specs, tint: tint, scale: scale, colorSpace: colorSpace, translationTint: translationTint)
            // Only visible while selected, so always in the selected colours.
            background.setColors(unsung: Float(specs.selectedUpcomingBackgroundVocalsAlpha), sung: Float(specs.lineProgressionBackgroundVocalsAlpha), translation: Float(specs.translationAlpha), duration: 0)
            background.opacity = 0
            background.setAffineTransform(CGAffineTransform(scaleX: specs.backgroundVocalsDeselectedScale, y: specs.backgroundVocalsDeselectedScale))
        }
        rasterizationScale = scale
        highlightMargin = specs.highlightViewMargin
        highlightLayer.cornerRadius = specs.highlightViewCornerRadius
        highlightLayer.backgroundColor = tint.withAlphaComponent(specs.highlightViewAlpha).cgColor
        isExpanded = false
        layoutVoices(spring: nil)
    }

    /// Bounds, voice positions and highlight for the current expansion. The main voice moves
    /// with `spring` when background vocals open above it; `backgroundSpring` moves the
    /// background vocals (they otherwise fade in / out in place).
    private func layoutVoices(spring: LyricsSpecs.Spring?, backgroundSpring: LyricsSpecs.Spring? = nil) {
        let height = contentHeight
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let anchor = CGPoint(x: horizontalAnchor, y: 0.5)
        anchorPoint = anchor
        containerLayer.bounds = bounds
        containerLayer.anchorPoint = anchor
        containerLayer.position = CGPoint(x: anchor.x * width, y: anchor.y * height)
        let mainTop: CGFloat = isExpanded && backgroundAbove ? (background?.contentHeight ?? 0) + backgroundSpacing : 0
        place(main, top: mainTop, spring: spring)
        if let background {
            place(background, top: backgroundAbove ? 0 : main.contentHeight + backgroundSpacing, spring: backgroundSpring)
        }
        let margin = highlightMargin
        highlightLayer.frame = CGRect(x: -margin, y: -margin * 0.6, width: width + margin * 2, height: height + margin * 1.2)
    }

    /// Puts a voice at `top` at once; with a spring it lags behind like a line does (an
    /// additive offset, so a size change of the voice itself never makes it jump).
    private func place(_ voice: VoiceLayer, top: CGFloat, spring: LyricsSpecs.Spring?) {
        let oldTop = voice.placedTop
        voice.placedTop = top
        voice.position = CGPoint(x: voice.anchorPoint.x * width, y: top + voice.anchorPoint.y * voice.contentHeight)
        if let spring {
            if let oldTop, abs(oldTop - top) > 0.5 {
                LyricsAnimation.addLag(to: voice, offset: oldTop - top, spring: spring, delay: 0)
            }
        } else {
            LyricsAnimation.removeLags(from: voice)
        }
    }

    func updateSecondary(main mainLayout: VoiceLayout, background backgroundLayout: VoiceLayout?, specs: LyricsSpecs, animated: Bool, spring: LyricsSpecs.Spring) {
        main.updateSecondary(to: mainLayout, specs: specs, animated: animated, spring: spring)
        if let background, let backgroundLayout {
            background.updateSecondary(to: backgroundLayout, specs: specs, animated: animated, spring: spring)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutVoices(spring: animated ? spring : nil, backgroundSpring: animated ? spring : nil)
        CATransaction.commit()
        invalidateStatic(holdFor: animated ? max(spring.settlingDuration, 0.4) : 0)
    }

    /// `linear` (a line change while the playback position is dragged) runs the colour and scale
    /// change on a linear curve of that duration instead of the usual fade and spring.
    func apply(state: State, specs: LyricsSpecs, scrolling: Bool, animated: Bool, spring: LyricsSpecs.Spring? = nil, linear: CFTimeInterval? = nil) {
        let previous = self.state
        guard state != previous || scrolling != appliedScrolling else { return }
        appliedScrolling = scrolling
        self.state = state
        let unsung: Float
        let sung: Float
        switch state {
        case .selected:
            unsung = Float(specs.selectedUpcomingTextAlpha)
            sung = Float(specs.lineProgressionAlpha)
        case .past, .upcoming:
            unsung = Float(scrolling ? specs.deselectedScrollTextAlpha : specs.deselectedTextAlpha)
            sung = 0
        }
        let scale: CGFloat = state == .selected ? 1 : specs.deselectedScale
        let translationAlpha = Float(state == .selected ? specs.translationAlpha : (scrolling ? specs.deselectedScrollTextAlpha : specs.deselectedTextAlpha))
        let linear = animated ? linear : nil
        let duration = animated ? linear ?? LyricsAnimation.stateDuration : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let linear {
            main.setColors(unsung: unsung, sung: sung, translation: translationAlpha, duration: duration, curve: CAMediaTimingFunction(name: .linear))
            LyricsAnimation.animate(self, "transform.scale", to: scale, duration: linear, curve: CAMediaTimingFunction(name: .linear), key: "lineScale")
        } else {
            main.setColors(unsung: unsung, sung: sung, translation: translationAlpha, duration: duration)
            setScale(scale, specs: specs, animated: animated)
        }
        if state != previous {
            setExpanded(state == .selected, specs: specs, animated: animated, spring: spring ?? specs.lineChangeSpring)
        }
        CATransaction.commit()
        if previous == .selected, state != .selected {
            main.settle(specs: specs, past: state == .past)
            background?.settle(specs: specs, past: state == .past)
        } else if state == .upcoming {
            resetSyllables()
        } else if state == .past, previous != .past {
            main.markSung()
            background?.markSung()
        } else if state == .selected {
            main.resume()
            background?.resume()
        }
        invalidateStatic(holdFor: animated ? LyricsAnimation.stateDuration + 0.05 : 0)
    }

    private func setExpanded(_ selected: Bool, specs: LyricsSpecs, animated: Bool, spring: LyricsSpecs.Spring) {
        guard let background else { return }
        let expand = selected
        guard expand != isExpanded else { return }
        isExpanded = expand
        layoutVoices(spring: animated && specs.springEnabled ? spring : nil)
        let opacity: Float = expand ? 1 : 0
        let scale = expand ? 1 : specs.backgroundVocalsDeselectedScale
        if animated {
            let s = expand ? specs.backgroundVocalsSelectSpring : specs.backgroundVocalsDeselectSpring
            LyricsAnimation.animate(background, "opacity", to: opacity, spring: s, key: "backgroundOpacity")
            LyricsAnimation.animate(background, "transform.scale", to: scale, spring: s, key: "backgroundScale")
        } else {
            background.removeAnimation(forKey: "backgroundOpacity")
            background.removeAnimation(forKey: "backgroundScale")
            background.opacity = opacity
            background.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
    }

    private func setScale(_ scale: CGFloat, specs: LyricsSpecs, animated: Bool) {
        if animated, specs.springEnabled {
            LyricsAnimation.animate(self, "transform.scale", to: scale, spring: specs.lineChangeSpring, key: "lineScale")
        } else {
            removeAnimation(forKey: "lineScale")
            transform = CATransform3DMakeScale(scale, scale, 1)
        }
    }

    func animateLag(offset: CGFloat, spring: LyricsSpecs.Spring, delay: TimeInterval, speed: Float = 1) {
        LyricsAnimation.addLag(to: self, offset: offset, spring: spring, delay: delay, speed: speed)
    }

    private func invalidateStatic(holdFor delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(becomeStatic), object: nil)
        staticPending = false
        // A live blur and its snapshot must use the same local raster grid, including while
        // the line's scale/position springs run. Re-rasterizing changed contents is expected.
        shouldRasterize = blurFilter != nil
        showLive()
        guard state != .selected else {
            staticDeadline = 0
            return
        }
        // A shorter hold never cuts a longer one short: the 0.12 s blur change that follows a
        // state change must not freeze the line while its 0.4 s colour fade still runs.
        let now = CACurrentMediaTime()
        staticDeadline = max(staticDeadline, now + delay)
        perform(#selector(becomeStatic), with: nil, afterDelay: staticDeadline - now, inModes: [.common])
    }

    @objc private func becomeStatic() {
        guard state != .selected else { return }
        if Self.hasVisibleMotion(containerLayer) {
            perform(#selector(becomeStatic), with: nil, afterDelay: 0.2, inModes: [.common])
            return
        }
        staticPending = true
        if appliedBlur > 0.01, let snapshotRequest {
            snapshotRequest(self)
        } else {
            rasterizationScale = renderScale
            shouldRasterize = true
        }
    }

    /// Wait until presentation values are within 0.02 pt / 0.1 % of the model, including masks.
    /// This lets settled spring tails release their live filter before the declared end time.
    /// Values that cannot be compared (colours, groups, missing presentation) wait for the end.
    private static func hasVisibleMotion(_ layer: CALayer, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        if let keys = layer.animationKeys(), !keys.isEmpty {
            let t = layer.convertTime(now, from: nil)
            let presentation = layer.presentation()
            for key in keys {
                guard let animation = layer.animation(forKey: key) else { continue }
                if animation.beginTime == 0 { return true }
                if t >= animation.beginTime + animation.duration / Double(max(animation.speed, 0.001)) { continue }
                guard let property = animation as? CAPropertyAnimation, let keyPath = property.keyPath, let presentation,
                      let shown = presentation.value(forKeyPath: keyPath), let model = layer.value(forKeyPath: keyPath),
                      let motion = remainingMotion(from: shown, to: model, keyPath: keyPath) else { return true }
                if motion > 1 { return true }
            }
        }
        if let mask = layer.mask, hasVisibleMotion(mask, now: now) { return true }
        return layer.sublayers?.contains { hasVisibleMotion($0, now: now) } ?? false
    }

    /// Distance between two animated values in units of what is visible: 1 = 0.02 pt for
    /// lengths, 0.1 % for opacity and scale. Nil for values that cannot be compared.
    private static func remainingMotion(from a: Any, to b: Any, keyPath: String) -> Double? {
        let length = 0.02, ratio = 0.001
        if let x = a as? NSNumber, let y = b as? NSNumber {
            let unit = keyPath.lowercased().contains("opacity") || keyPath.contains("scale") ? ratio : length
            return abs(x.doubleValue - y.doubleValue) / unit
        }
        guard let x = a as? NSValue, let y = b as? NSValue else { return nil }
        let type = String(cString: x.objCType)
        if type.contains("CGRect") {
            let r = x.rectValue, s = y.rectValue
            return max(abs(r.minX - s.minX), abs(r.minY - s.minY), abs(r.width - s.width), abs(r.height - s.height)) / length
        }
        if type.contains("CATransform3D") {
            let m = x.caTransform3DValue, n = y.caTransform3DValue
            return max(max(abs(m.m11 - n.m11), abs(m.m22 - n.m22)) / ratio, max(abs(m.m41 - n.m41), abs(m.m42 - n.m42)) / length)
        }
        if type.contains("CGPoint") {
            let p = x.pointValue, q = y.pointValue
            return max(abs(p.x - q.x), abs(p.y - q.y)) / length
        }
        if type.contains("CGSize") {
            let p = x.sizeValue, q = y.sizeValue
            return max(abs(p.width - q.width), abs(p.height - q.height)) / length
        }
        return nil
    }

    var wantsSnapshot: Bool {
        staticPending && state != .selected && appliedBlur > 0.01 && (!isShowingSnapshot || abs(installedRadius - appliedBlur) > 0.01)
    }

    /// Shows `snapshot` instead of the live layers (it must match the current radius). A line
    /// already showing an image crossfades to the new one with the transition of the radius
    /// change that asked for it (`applyBlur`), the way the live filter's radius would animate.
    func install(_ snapshot: LineSnapshot) {
        guard wantsSnapshot, abs(snapshot.radius - appliedBlur) < 0.01 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isShowingSnapshot, let transition = pendingBlurTransition {
            snapshotFadeLayer.contentsScale = snapshotLayer.contentsScale
            snapshotFadeLayer.frame = snapshotLayer.frame
            snapshotFadeLayer.contents = snapshotLayer.contents
            snapshotFadeLayer.isHidden = false
            Self.fade(snapshotFadeLayer, from: 1, to: 0, transition)
            Self.fade(snapshotLayer, from: 0, to: 1, transition)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(endSnapshotFade), object: nil)
            perform(#selector(endSnapshotFade), with: nil, afterDelay: transition.duration + 0.05, inModes: [.common])
        }
        snapshotLayer.contentsScale = snapshot.scale
        snapshotLayer.frame = snapshot.rect
        snapshotLayer.contents = snapshot.image
        snapshotLayer.isHidden = false
        containerLayer.isHidden = true
        removeFilter()
        shouldRasterize = false
        isShowingSnapshot = true
        installedRadius = snapshot.radius
        pendingBlurTransition = nil
        CATransaction.commit()
    }

    private static func fade(_ layer: CALayer, from: Float, to: Float, _ transition: BlurTransition) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = transition.duration
        anim.timingFunction = transition.curve
        layer.add(anim, forKey: "opacity")
        layer.opacity = to
    }

    @objc private func endSnapshotFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotFadeLayer.isHidden = true
        snapshotFadeLayer.contents = nil
        snapshotFadeLayer.removeAnimation(forKey: "opacity")
        snapshotFadeLayer.opacity = 1
        CATransaction.commit()
    }

    private func showLive() {
        guard isShowingSnapshot else { return }
        isShowingSnapshot = false
        containerLayer.isHidden = false
        snapshotLayer.isHidden = true
        snapshotLayer.contents = nil
        snapshotLayer.removeAnimation(forKey: "opacity")
        snapshotLayer.opacity = 1
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(endSnapshotFade), object: nil)
        endSnapshotFade()
        // The filter comes back at the radius on screen; a radius change still waiting for its
        // image animates from there, as it would have on the live layers.
        let shown = installedRadius
        installedRadius = 0
        let transition = pendingBlurTransition
        pendingBlurTransition = nil
        guard !isOffscreen, max(shown, appliedBlur) > 0.01 else { return }
        installFilter(radius: shown)
        guard abs(shown - appliedBlur) > 0.01 else { return }
        if let transition {
            LyricsAnimation.animate(self, "filters.blur.inputRadius", to: appliedBlur, duration: transition.duration, curve: transition.curve, key: "blur")
        } else {
            setValue(appliedBlur, forKeyPath: "filters.blur.inputRadius")
        }
    }

    var showsBlur: Bool { isShowingSnapshot || blurFilter != nil }

    func snapshotExtent(radius: CGFloat, scale: CGFloat) -> CGRect {
        var union = CGRect.null
        func visit(_ layer: CALayer, root: Bool = false) {
            guard root || !layer.isHidden, layer.opacity > 0 else { return }
            let paints = layer.contents != nil || (layer.backgroundColor?.alpha ?? 0) > 0 || layer is CAGradientLayer
            if paints { union = union.union(layer.convert(layer.bounds, to: self)) }
            layer.sublayers?.forEach { visit($0) }
        }
        visit(containerLayer, root: true)
        if union.isNull || union.isEmpty { union = bounds }
        let pad = ceil(radius * 3) + 2
        let r = union.insetBy(dx: -pad, dy: -pad)
        let minX = floor(r.minX * scale) / scale, minY = floor(r.minY * scale) / scale
        return CGRect(x: minX, y: minY, width: ceil((r.maxX - minX) * scale) / scale, height: ceil((r.maxY - minY) * scale) / scale)
    }

    /// `CIGaussianBlur` on the line (`filters.gaussianBlur.inputRadius`), animated from the
    /// presentation value. The filter is dropped once the radius settles at 0 so the selected line
    /// is not filtered every frame, and replaced by an image once a blurred line is static (see
    /// `invalidateStatic`).
    func setBlurRadius(_ radius: CGFloat, animated: Bool) {
        blurTarget = max(0, radius)
        applyBlur(animated ? .init(duration: LyricsAnimation.blurDuration, curve: LyricsAnimation.blurCurve) : nil)
    }

    private struct BlurTransition {
        var duration: CFTimeInterval
        var curve: CAMediaTimingFunction
    }

    private func applyBlur(_ transition: BlurTransition?) {
        let r = isHighlighted ? 0 : blurTarget
        guard abs(r - appliedBlur) > 0.01 else { return }
        if isShowingSnapshot, r > 0.01 {
            // Crossfade to a new image instead of reinstalling live filters on the neighbours
            // each time the selected line changes.
            appliedBlur = r
            pendingBlurTransition = transition
            snapshotRequest?(self)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        invalidateStatic(holdFor: (transition?.duration ?? 0) + 0.05)
        let from = appliedBlur
        appliedBlur = r
        if !isOffscreen {
            if blurFilter == nil, max(from, r) > 0 { installFilter(radius: from) }
            if blurFilter != nil {
                if let transition {
                    LyricsAnimation.animate(self, "filters.blur.inputRadius", to: r, duration: transition.duration, curve: transition.curve, key: "blur")
                } else {
                    removeAnimation(forKey: "blur")
                    setValue(r, forKeyPath: "filters.blur.inputRadius")
                }
            }
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(dropIdleBlurFilter), object: nil)
        if r == 0 {
            perform(#selector(dropIdleBlurFilter), with: nil, afterDelay: (transition?.duration ?? 0) + 0.02, inModes: [.common])
        }
        CATransaction.commit()
    }

    private func installFilter(radius: CGFloat) {
        guard blurFilter == nil, let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.name = "blur"
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        blurFilter = filter
        filters = [filter]
        // Rasterize in local coordinates to match snapshots; destination-space sampling
        // causes subpixel jumps when switching back to live layers.
        rasterizationScale = renderScale
        shouldRasterize = true
    }

    private func removeFilter() {
        guard blurFilter != nil else { return }
        removeAnimation(forKey: "blur")
        filters = nil
        blurFilter = nil
        shouldRasterize = false
    }

    @objc private func dropIdleBlurFilter() {
        guard appliedBlur == 0 else { return }
        removeFilter()
    }

    /// Pointer highlight: rounded background fades in and the line is un-blurred (in 0.2 s (0, 0,
    /// 0.55, 1), out 0.3 s (0.25, 0.1, 0.25, 0.1)).
    func setHovered(_ hovered: Bool, enabled: Bool) {
        let on = hovered && enabled
        guard on != isHighlighted else { return }
        isHighlighted = on
        let duration = on ? LyricsAnimation.highlightInDuration : LyricsAnimation.highlightOutDuration
        let curve = on ? LyricsAnimation.highlightInCurve : LyricsAnimation.highlightOutCurve
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        LyricsAnimation.animate(highlightLayer, "opacity", to: Float(on ? 1 : 0), duration: duration, curve: curve, key: "opacity")
        CATransaction.commit()
        applyBlur(BlurTransition(duration: duration, curve: curve))
        invalidateStatic(holdFor: duration + 0.05)
    }

    func setPressed(_ pressed: Bool, specs: LyricsSpecs) {
        let scale = pressed ? specs.touchDownScale : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        LyricsAnimation.animate(containerLayer, "transform.scale", to: scale, spring: pressed ? specs.touchDownSpring : specs.touchUpSpring, key: "press")
        CATransaction.commit()
        invalidateStatic(holdFor: 0.8)
    }

    func updateSyllables(time t: TimeInterval, specs: LyricsSpecs) {
        main.updateSyllables(time: t, specs: specs)
        background?.updateSyllables(time: t, specs: specs)
    }

    func finishMainProgress(specs: LyricsSpecs) {
        main.finishProgress(duration: specs.lineFinishProgressAnimationDuration)
    }

    func resetSyllables() {
        main.reset()
        background?.reset()
    }
}
