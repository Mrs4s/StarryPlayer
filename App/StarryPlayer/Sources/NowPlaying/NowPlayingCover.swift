import AppKit
import QuartzCore
import StarryCore
import SwiftUI

/// Pointer animations stay in Core Animation; SwiftUI controls the flight from the player bar.
struct NowPlayingCover: View, Animatable {
    var artwork: Artwork?
    var fallback: NSImage?
    var radius: CGFloat = CoverStyle.radius
    var playing: Bool
    var pausedScale: CGFloat = CoverStyle.pausedScale
    var raised: Bool
    var tilts: Bool
    @State private var image: NSImage?

    private static let pixelSize = 800

    nonisolated var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    var body: some View {
        NowPlayingCoverSurface(image: image ?? fallback, seed: artwork?.seed ?? "starry", configuration: .init(radius: radius, playing: playing, pausedScale: pausedScale, raised: raised, tilts: tilts))
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = ImageStore.shared.image(for: url, maxPixelSize: Self.pixelSize) { image = cached; return }
                let loaded = await ImageStore.shared.load(url, maxPixelSize: Self.pixelSize)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }

    private var url: URL? { artwork?.sized(Self.pixelSize) }
}

enum CoverStyle {
    static let radius: CGFloat = 12
    static let pausedScale: CGFloat = 0.85
    static let hoverScale: CGFloat = 1.02
    static let baseShadowOpacity: Double = 0.33
    static let playingShadowRadius: Double = 20
    static let pausedShadowRadius: Double = 10
    static let hoverShadowOpacity: Double = 0.1
    static let hoverShadowRadius: Double = 10
    static let playbackDelay: CFTimeInterval = 0.25
    static let glareSpread: Double = 0.2
}

/// Pointer offset from the card's centre, in AppKit's y-up coordinates.
struct CoverTilt: Equatable {
    static let maxDegrees = 3.5
    static let flat = CoverTilt(degrees: 0, axis: .zero)

    var degrees: Double
    var axis: CGVector

    private init(degrees: Double, axis: CGVector) {
        self.degrees = degrees
        self.axis = axis
    }

    init(offset: CGVector, size: CGSize) {
        guard size.width > 0, size.height > 0 else { self = .flat; return }
        let cx = size.width / 2, cy = size.height / 2
        let factor = min(max((offset.dx * offset.dx + offset.dy * offset.dy) / (cx * cx + cy * cy), 0), 1)
        self.init(degrees: Self.maxDegrees * factor, axis: CGVector(dx: offset.dy, dy: -offset.dx))
    }

    /// Scale, tilt, then perspective, all about the layer's centre.
    static func transform(degrees: Double, axis: CGVector, scale: CGFloat, size: CGSize) -> CATransform3D {
        var transform = CATransform3DMakeScale(scale, scale, 1)
        let length = hypot(axis.dx, axis.dy)
        if length > 1e-6, abs(degrees) > 1e-6 {
            transform = CATransform3DConcat(transform, CATransform3DMakeRotation(degrees * .pi / 180, axis.dx / length, axis.dy / length, 0))
        }
        var perspective = CATransform3DIdentity
        let depth = max(size.width, size.height)
        if depth > 0 { perspective.m34 = -1 / depth }
        return CATransform3DConcat(transform, perspective)
    }
}

/// Closed-form springs preserve velocity when retargeted and behave consistently across frame rates.
struct CoverSpring {
    let omega: Double
    let dampingRatio: Double

    init(duration: Double, bounce: Double = 0) {
        omega = 2 * .pi / duration
        dampingRatio = 1 - min(max(bounce, 0), 1)
    }

    static let smooth = CoverSpring(duration: 0.45)
    static let playback = CoverSpring(duration: 0.65, bounce: 0.45)
}

struct SpringValue {
    var value: Double
    var target: Double
    var velocity: Double = 0

    init(_ value: Double) {
        self.value = value
        target = value
    }

    mutating func step(_ dt: Double, _ spring: CoverSpring) {
        guard dt > 0 else { return }
        let x0 = value - target, v0 = velocity
        let w = spring.omega, z = spring.dampingRatio
        if z >= 1 {
            // Critically damped (the springs here never overdamp).
            let e = exp(-w * dt), b = v0 + w * x0
            value = target + (x0 + b * dt) * e
            velocity = (v0 - w * b * dt) * e
        } else {
            let wd = w * (1 - z * z).squareRoot()
            let e = exp(-z * w * dt), c = cos(wd * dt), s = sin(wd * dt)
            value = target + e * (x0 * c + (v0 + z * w * x0) / wd * s)
            velocity = e * (v0 * c - (z * w * v0 + w * w * x0) / wd * s)
        }
    }

    func isSettled(within tolerance: Double) -> Bool {
        abs(value - target) <= tolerance && abs(velocity) <= tolerance * 10
    }

    mutating func snap() {
        value = target
        velocity = 0
    }
}

/// Precomputed blurred-disc gradient avoids a live blur filter while hovering.
private enum CoverGlare {
    static let discRadius = 50.0
    static let sigma = 50.0
    static let opacity = 0.1
    static let reach = discRadius + 3.5 * sigma
    static let stopCount = 24

    private static func coverage(at r: Double) -> Double {
        let rings = 48, spokes = 48
        let dRho = discRadius / Double(rings), dPhi = Double.pi / Double(spokes)
        var sum = 0.0
        for i in 0..<rings {
            let rho = (Double(i) + 0.5) * dRho
            for j in 0..<spokes {
                let d2 = rho * rho + r * r - 2 * rho * r * cos((Double(j) + 0.5) * dPhi)
                sum += exp(-d2 / (2 * sigma * sigma)) * rho
            }
        }
        // Twice the half turn, over the Gaussian's normalization 2πσ².
        return 2 * sum * dRho * dPhi / (2 * .pi * sigma * sigma)
    }

    static let alphas: [Double] = (0..<stopCount).map { i in
        i == stopCount - 1 ? 0 : opacity * coverage(at: reach * Double(i) / Double(stopCount - 1))
    }
}

private struct NowPlayingCoverSurface: NSViewRepresentable {
    var image: NSImage?
    var seed: String
    var configuration: NowPlayingCoverView.Configuration

    func makeNSView(context: Context) -> NowPlayingCoverView { NowPlayingCoverView() }

    func updateNSView(_ view: NowPlayingCoverView, context: Context) {
        view.update(image: image, seed: seed, configuration: configuration)
    }
}

/// `stage` scales for playback; `card` tilts on hover. Each face clips independently to avoid offscreen compositing.
private final class NowPlayingCoverView: NSView {
    struct Configuration: Equatable {
        var radius: CGFloat
        var playing: Bool
        var pausedScale: CGFloat
        var raised: Bool
        var tilts: Bool
    }

    private struct Pose {
        var stageScale = SpringValue(1)
        var baseRadius = SpringValue(CoverStyle.playingShadowRadius)
        var baseOpacity = SpringValue(0)
        var hoverScale = SpringValue(1)
        var hoverShadowOpacity = SpringValue(0)
        var hoverShadowRadius = SpringValue(0)
        var degrees = SpringValue(0)
        var axisX = SpringValue(0)
        var axisY = SpringValue(0)
        var glare = SpringValue(0)

        mutating func step(_ dt: Double) {
            stageScale.step(dt, .playback)
            baseRadius.step(dt, .playback)
            baseOpacity.step(dt, .smooth)
            hoverScale.step(dt, .smooth)
            hoverShadowOpacity.step(dt, .smooth)
            hoverShadowRadius.step(dt, .smooth)
            degrees.step(dt, .smooth)
            axisX.step(dt, .smooth)
            axisY.step(dt, .smooth)
            glare.step(dt, .smooth)
        }

        var isSettled: Bool {
            stageScale.isSettled(within: 1e-4) && baseRadius.isSettled(within: 0.01) && baseOpacity.isSettled(within: 1e-3)
                && hoverScale.isSettled(within: 1e-4) && hoverShadowOpacity.isSettled(within: 1e-3) && hoverShadowRadius.isSettled(within: 0.01)
                && degrees.isSettled(within: 1e-3) && axisX.isSettled(within: 0.01) && axisY.isSettled(within: 0.01) && glare.isSettled(within: 1e-3)
        }

        mutating func snap() {
            stageScale.snap(); baseRadius.snap(); baseOpacity.snap()
            hoverScale.snap(); hoverShadowOpacity.snap(); hoverShadowRadius.snap()
            degrees.snap(); axisX.snap(); axisY.snap(); glare.snap()
        }

        mutating func setPlayback(playing: Bool, pausedScale: CGFloat) {
            stageScale.target = playing ? 1 : pausedScale
            baseRadius.target = playing ? CoverStyle.playingShadowRadius : CoverStyle.pausedShadowRadius
        }

        mutating func setHovering(_ hovering: Bool) {
            hoverScale.target = hovering ? CoverStyle.hoverScale : 1
            hoverShadowOpacity.target = hovering ? CoverStyle.hoverShadowOpacity : 0
            hoverShadowRadius.target = hovering ? CoverStyle.hoverShadowRadius : 0
            glare.target = hovering ? 1 : 0
        }
    }

    private let stage = CALayer()
    private let card = CALayer()
    private let baseShadow = CALayer()
    private let hoverShadow = CALayer()
    private let placeholder = CAGradientLayer()
    private let picture = CALayer()
    private let glare = CAGradientLayer()

    private var configuration: Configuration?
    private var image: NSImage?
    private var seed: String?
    private var aspect: CGFloat = 1
    private var animatesNextLayout = false

    private var pose = Pose()
    private var hovering = false
    /// Retained after exit so the highlight fades out at its last position.
    private var pointer = CGVector.zero
    private var pendingPlayback: (playing: Bool, pausedScale: CGFloat, at: CFTimeInterval)?
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in [baseShadow, hoverShadow] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOffset = .zero
            shadow.shadowOpacity = 0
            shadow.shadowRadius = 0
        }
        for face in [placeholder, picture, glare] as [CALayer] {
            face.masksToBounds = true
            face.cornerCurve = .continuous
            face.allowsEdgeAntialiasing = true
        }
        placeholder.startPoint = CGPoint(x: 0, y: 1)
        placeholder.endPoint = CGPoint(x: 1, y: 0)
        picture.contentsGravity = .resizeAspectFill
        glare.type = .radial
        glare.colors = CoverGlare.alphas.map { CGColor(gray: 1, alpha: $0) }
        glare.locations = (0..<CoverGlare.stopCount).map { NSNumber(value: Double($0) / Double(CoverGlare.stopCount - 1)) }
        glare.opacity = 0
        for face in [baseShadow, hoverShadow, placeholder, picture, glare] as [CALayer] { card.addSublayer(face) }
        stage.addSublayer(card)
        layer?.addSublayer(stage)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Forward interactions while retaining pointer tracking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(image: NSImage?, seed: String, configuration new: Configuration) {
        setImage(image, seed: seed)
        guard let old = configuration else {
            configuration = new
            pose.setPlayback(playing: new.playing, pausedScale: new.pausedScale)
            pose.baseOpacity.target = new.raised ? CoverStyle.baseShadowOpacity : 0
            pose.snap()
            needsLayout = true
            return
        }
        guard new != old else { return }
        configuration = new
        if new.radius != old.radius {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyRadius()
            CATransaction.commit()
        }
        if new.playing != old.playing || new.pausedScale != old.pausedScale {
            pendingPlayback = (new.playing, new.pausedScale, CACurrentMediaTime() + CoverStyle.playbackDelay)
        }
        if new.raised != old.raised {
            pose.baseOpacity.target = new.raised ? CoverStyle.baseShadowOpacity : 0
        }
        if !new.tilts, hovering { setPointer(nil) }
        wake()
    }

    private func setImage(_ image: NSImage?, seed: String) {
        if seed != self.seed {
            self.seed = seed
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeholder.colors = PlaceholderArt.colors(for: seed).map { NSColor($0).cgColor }
            CATransaction.commit()
        }
        guard image !== self.image else { return }
        self.image = image
        let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.begin()
        if configuration == nil {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        if cgImage == nil { placeholder.isHidden = false }
        // Hide the placeholder after the fade to avoid a fringe at antialiased corners.
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.picture.contents != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.placeholder.isHidden = true
            CATransaction.commit()
        }
        picture.contents = cgImage
        CATransaction.commit()
        let aspect = cgImage.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1
        if abs(aspect - self.aspect) > 0.001 {
            self.aspect = aspect
            animatesNextLayout = configuration != nil
            needsLayout = true
        }
    }

    /// Untransformed card size, shared by layout and pointer tracking.
    private var cardSize: CGSize {
        let box = bounds.size
        guard box.width > 0, box.height > 0, aspect > 0 else { return .zero }
        return aspect >= box.width / box.height
            ? CGSize(width: box.width, height: (box.width / aspect).rounded())
            : CGSize(width: (box.height * aspect).rounded(), height: box.height)
    }

    override func layout() {
        super.layout()
        let size = cardSize
        let box = CGRect(origin: .zero, size: size)
        CATransaction.begin()
        if animatesNextLayout {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        animatesNextLayout = false
        stage.bounds = box
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        card.bounds = box
        card.position = CGPoint(x: box.midX, y: box.midY)
        for face in [baseShadow, hoverShadow, placeholder, picture, glare] as [CALayer] { face.frame = box }
        applyRadius()
        CATransaction.commit()
        // The cover moved or resized under a pointer that did not.
        if hovering, let window { setPointer(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        placeholder.contentsScale = scale
        glare.contentsScale = scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else {
            wake()
            return
        }
        // The link holds this view; let it go, and come back at rest.
        link?.invalidate()
        link = nil
        lastFrame = nil
        if hovering { setPointer(nil) }
        if let pending = pendingPlayback {
            pose.setPlayback(playing: pending.playing, pausedScale: pending.pausedScale)
            pendingPlayback = nil
        }
        pose.snap()
        render()
    }

    private func applyRadius() {
        let size = cardSize
        let radius = max(0, min(configuration?.radius ?? CoverStyle.radius, min(size.width, size.height) / 2))
        for face in [placeholder, picture, glare] as [CALayer] { face.cornerRadius = radius }
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        baseShadow.shadowPath = path
        hoverShadow.shadowPath = path
    }

    // MARK: Pointer

    override func mouseEntered(with event: NSEvent) { setPointer(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { setPointer(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setPointer(nil) }

    private func setPointer(_ point: CGPoint?) {
        let size = cardSize
        var offset: CGVector?
        if configuration?.tilts == true, let point, size.width > 0, size.height > 0 {
            // Undo playback scaling before measuring the pointer offset.
            let scale = max(pose.stageScale.value, 0.01)
            let candidate = CGVector(dx: (point.x - bounds.midX) / scale, dy: (point.y - bounds.midY) / scale)
            if abs(candidate.dx) <= size.width / 2, abs(candidate.dy) <= size.height / 2 { offset = candidate }
        }
        let wasHovering = hovering
        hovering = offset != nil
        if let offset {
            // The highlight sits under the pointer at once; only the card's pose is eased.
            pointer = offset
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeGlare()
            CATransaction.commit()
        }
        let tilt = CoverTilt(offset: offset ?? .zero, size: size)
        pose.degrees.target = tilt.degrees
        pose.axisX.target = tilt.axis.dx
        pose.axisY.target = tilt.axis.dy
        if hovering != wasHovering { pose.setHovering(hovering) }
        wake()
    }

    // MARK: Animation

    /// The display link runs only while a spring or delayed playback change is pending.
    private func wake() {
        guard window != nil, !(pose.isSettled && pendingPlayback == nil) else {
            render()
            return
        }
        if let link {
            if link.isPaused {
                lastFrame = nil
                link.isPaused = false
            }
            return
        }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        // A long stall (the window hidden, a busy main thread) resumes as one short step.
        let dt = min(max(now - (lastFrame ?? link.timestamp), 0), 1.0 / 20)
        lastFrame = now
        if let pending = pendingPlayback, CACurrentMediaTime() >= pending.at {
            pose.setPlayback(playing: pending.playing, pausedScale: pending.pausedScale)
            pendingPlayback = nil
        }
        let scaling = !pose.stageScale.isSettled(within: 1e-4)
        pose.step(dt)
        // The card scales under a resting pointer: find where the pointer now falls on it.
        if hovering, scaling, let window { setPointer(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        if pose.isSettled, pendingPlayback == nil {
            pose.snap()
            link.isPaused = true
            lastFrame = nil
        }
        render()
    }

    private func render() {
        let size = cardSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stageScale = CGFloat(pose.stageScale.value)
        stage.transform = CATransform3DMakeScale(stageScale, stageScale, 1)
        card.transform = CoverTilt.transform(degrees: pose.degrees.value, axis: CGVector(dx: pose.axisX.value, dy: pose.axisY.value), scale: pose.hoverScale.value, size: size)
        Self.setShadow(of: baseShadow, opacity: pose.baseOpacity.value, radius: pose.baseRadius.value)
        Self.setShadow(of: hoverShadow, opacity: pose.hoverShadowOpacity.value, radius: pose.hoverShadowRadius.value)
        let level = Float(min(max(pose.glare.value, 0), 1))
        if glare.opacity != level { glare.opacity = level }
        placeGlare()
        CATransaction.commit()
    }

    /// Call inside a transaction without actions.
    private func placeGlare() {
        let size = cardSize
        guard size.width > 0, size.height > 0 else { return }
        let reach = CoverGlare.reach * (1 + CoverStyle.glareSpread * (1 - min(max(pose.glare.value, 0), 1)))
        let start = CGPoint(x: 0.5 + pointer.dx / size.width, y: 0.5 + pointer.dy / size.height)
        let end = CGPoint(x: start.x + reach / size.width, y: start.y + reach / size.height)
        if glare.startPoint != start { glare.startPoint = start }
        if glare.endPoint != end { glare.endPoint = end }
    }

    private static func setShadow(of layer: CALayer, opacity: Double, radius: Double) {
        let opacity = Float(min(max(opacity, 0), 1)), radius = CGFloat(max(radius, 0))
        if layer.shadowOpacity != opacity { layer.shadowOpacity = opacity }
        if layer.shadowRadius != radius { layer.shadowRadius = radius }
    }
}
