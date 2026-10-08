import AppKit
import AudioProcessing
import QuartzCore
import SwiftUI

/// Ten-band equalizer and post-EQ spectrum rendered with Core Animation.
/// The display link runs only while animating or playing.
struct EqualizerGraph: View {
    var gains: [Double]
    var isEnabled: Bool
    var tint: Color
    /// The spectrum moves (music plays); otherwise it settles to nothing.
    var spectrumLive: Bool
    var spectrum: @MainActor () -> [Float]
    var onChange: (Int, Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        EqualizerGraphRepresentable(gains: gains, isEnabled: isEnabled, tint: tint, spectrumLive: spectrumLive, reduceMotion: reduceMotion, spectrum: spectrum, onChange: onChange)
            .overlay { accessibilityBands }
    }

    private var accessibilityBands: some View {
        HStack(spacing: 0) {
            ForEach(0..<EqualizerBands.count, id: \.self) { band in
                let gain = gains.indices.contains(band) ? gains[band] : 0
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel(EqualizerGraphView.spokenFrequency(band))
                    .accessibilityValue(String(format: "%+.1f dB", gain))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onChange(band, gain + 0.5)
                        case .decrement: onChange(band, gain - 0.5)
                        @unknown default: break
                        }
                    }
            }
        }
        .padding(.leading, EqualizerGraphView.axisWidth)
        .padding(.trailing, EqualizerGraphView.rightInset)
        .allowsHitTesting(false)
    }
}

private struct EqualizerGraphRepresentable: NSViewRepresentable {
    var gains: [Double]
    var isEnabled: Bool
    var tint: Color
    var spectrumLive: Bool
    var reduceMotion: Bool
    var spectrum: @MainActor () -> [Float]
    var onChange: (Int, Double) -> Void

    func makeNSView(context: Context) -> EqualizerGraphView { EqualizerGraphView() }

    func updateNSView(_ view: EqualizerGraphView, context: Context) {
        view.spectrum = spectrum
        view.onChange = onChange
        view.reduceMotion = reduceMotion
        view.update(gains: gains, enabled: isEnabled, tint: NSColor(tint), spectrumLive: spectrumLive)
    }
}

/// A value that springs to its target (the knobs and curve of both equalizer graphs).
struct BandMotion {
    var value = 0.0
    var velocity = 0.0
    var target = 0.0
    var start: CFTimeInterval = 0
    var response = 0.42
    var damping = 0.72
    var moving = false

    mutating func jump(to value: Double) {
        self.value = value
        target = value
        velocity = 0
        moving = false
    }

    mutating func spring(to value: Double, at start: CFTimeInterval, response: Double, damping: Double) {
        target = value
        self.start = start
        self.response = response
        self.damping = damping
        moving = value != self.value || velocity != 0
    }

    mutating func step(_ dt: Double, now: CFTimeInterval) {
        guard moving, now > start else { return }
        let omega = 2 * Double.pi / response
        let stiffness = omega * omega, friction = 2 * damping * omega
        var remaining = min(dt, now - start)
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            velocity += (stiffness * (target - value) - friction * velocity) * h
            value += velocity * h
            remaining -= h
        }
        if abs(target - value) < 0.004, abs(velocity) < 0.04 { jump(to: target) }
    }
}

final class EqualizerGraphView: NSView {
    static let axisWidth: CGFloat = 34
    static let rightInset: CGFloat = 8
    private static let labelHeight: CGFloat = 24
    private static let topInset: CGFloat = 14
    private static let knobSize: CGFloat = 14
    private static let curveSamples = 180

    var spectrum: (@MainActor () -> [Float])?
    var onChange: ((Int, Double) -> Void)?
    var reduceMotion = false

    private let bands = EqualizerBands.count

    private let gridLayer = CAShapeLayer()
    private let zeroLayer = CAShapeLayer()
    private let slotLayer = CAShapeLayer()
    private let spectrumGradient = CAGradientLayer()
    private let spectrumLayer = CAShapeLayer()
    private let columnHighlight = CALayer()
    private let fillGradient = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let curveLayer = CAShapeLayer()
    private let sweepLayer = CAShapeLayer()
    private var stems: [CALayer] = []
    private var knobs: [CALayer] = []
    private var dots: [CALayer] = []
    private var frequencyLabels: [CATextLayer] = []
    private var decibelLabels: [CATextLayer] = []
    private let bubble = CALayer()
    private let bubbleText = CATextLayer()

    private var motion = [BandMotion](repeating: BandMotion(), count: EqualizerBands.count)
    private var enabled = true
    private var tint = NSColor.white
    private var spectrumLive = false
    private var shownSpectrum: [CGFloat] = []
    private var spectrumOpacity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var hasEntered = false
    private var hovered: Int?
    private var dragging: Int?
    /// Pointer to knob centre when the drag began on the knob (it then does not jump).
    private var grabOffset: CGFloat = 0
    private var restsOnZero = false
    private var scrollSteps: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var curveXs: [CGFloat] = []
    private var sampler: ResponseSampler?
    private var sampledWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(gains: [Double], enabled: Bool, tint: NSColor, spectrumLive: Bool) {
        let tintChanged = !Self.sameColor(tint, self.tint)
        self.tint = tint
        let enabledChanged = enabled != self.enabled
        self.enabled = enabled
        if tintChanged || enabledChanged {
            applyColors(duration: !hasEntered ? 0 : (tintChanged ? 0.8 : 0.3))
        }
        if enabledChanged, enabled, hasEntered, !reduceMotion { powerOn() }
        setGains(gains)
        self.spectrumLive = spectrumLive
        ensureTicking()
    }

    private func setGains(_ gains: [Double]) {
        guard gains.count == bands else { return }
        let now = CACurrentMediaTime()
        var order = 0
        var jumped = false
        for band in 0..<bands where motion[band].target != gains[band] {
            if band == dragging || !hasEntered || reduceMotion {
                if band != dragging {
                    motion[band].jump(to: gains[band])
                    jumped = true
                } else {
                    motion[band].target = gains[band]
                }
                continue
            }
            motion[band].spring(to: gains[band], at: now + Double(order) * 0.022, response: 0.42, damping: 0.72)
            order += 1
        }
        if jumped, window != nil { render() }
    }

    /// SwiftUI hands over a new colour object on every update.
    static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return a == b }
        return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002
            && abs(a.blueComponent - b.blueComponent) < 0.002 && abs(a.alphaComponent - b.alphaComponent) < 0.002
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            link?.invalidate()
            link = nil
            return
        }
        updateContentsScale()
        if !hasEntered {
            hasEntered = true
            applyColors(duration: 0)
            if !reduceMotion { enter() }
        }
        needsLayout = true
        ensureTicking()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutStaticLayers()
        render()
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private var plot: CGRect {
        CGRect(x: Self.axisWidth, y: Self.labelHeight, width: max(bounds.width - Self.axisWidth - Self.rightInset, 1), height: max(bounds.height - Self.labelHeight - Self.topInset, 1))
    }

    private var column: CGFloat { plot.width / CGFloat(bands) }

    /// Half the height ±12 dB spans (the knobs stay inside the plot).
    private var halfSpan: CGFloat { max(plot.height / 2 - Self.knobSize / 2 - 2, 1) }

    private func x(band: Int) -> CGFloat { plot.minX + (CGFloat(band) + 0.5) * column }

    private func y(decibels: Double) -> CGFloat {
        plot.midY + CGFloat(decibels / EqualizerBands.gainRange.upperBound) * halfSpan
    }

    private func decibels(y: CGFloat) -> Double {
        let value = Double((y - plot.midY) / halfSpan) * EqualizerBands.gainRange.upperBound
        return (min(max(value, EqualizerBands.gainRange.lowerBound), EqualizerBands.gainRange.upperBound) * 10).rounded() / 10
    }

    private func x(frequency: Double) -> CGFloat {
        plot.minX + (CGFloat(Self.position(of: frequency)) + 0.5) * column
    }

    /// Where a frequency sits on the band axis: 0…9 at the centres, interpolated on a log scale
    /// between them (125 Hz is not exactly an octave above 64), octaves beyond the ends.
    static func position(of frequency: Double) -> Double {
        let centres = EqualizerBands.frequencies
        guard frequency > centres[0] else { return log2(max(frequency, 1) / centres[0]) }
        guard frequency < centres[centres.count - 1] else { return Double(centres.count - 1) + log2(frequency / centres[centres.count - 1]) }
        let i = centres.lastIndex { $0 <= frequency } ?? 0
        return Double(i) + log2(frequency / centres[i]) / log2(centres[i + 1] / centres[i])
    }

    static func frequency(at position: Double) -> Double {
        let centres = EqualizerBands.frequencies
        guard position > 0 else { return centres[0] * pow(2, position) }
        guard position < Double(centres.count - 1) else { return centres[centres.count - 1] * pow(2, position - Double(centres.count - 1)) }
        let i = Int(position)
        return centres[i] * pow(centres[i + 1] / centres[i], position - Double(i))
    }

    static func spokenFrequency(_ band: Int) -> String {
        let frequency = EqualizerBands.frequencies[band]
        return frequency >= 1000 ? "\(Int(frequency / 1000)) 千赫" : "\(Int(frequency)) 赫兹"
    }

    private func buildLayers() {
        guard let root = layer else { return }
        for shape in [gridLayer, zeroLayer, slotLayer] {
            shape.fillColor = nil
            root.addSublayer(shape)
        }
        gridLayer.lineDashPattern = [2, 4]
        gridLayer.lineWidth = 1
        zeroLayer.lineWidth = 1
        slotLayer.lineWidth = 2
        slotLayer.lineCap = .round

        spectrumGradient.mask = spectrumLayer
        spectrumGradient.startPoint = CGPoint(x: 0.5, y: 0)
        spectrumGradient.endPoint = CGPoint(x: 0.5, y: 1)
        spectrumGradient.opacity = 0
        root.addSublayer(spectrumGradient)

        columnHighlight.cornerRadius = 10
        columnHighlight.cornerCurve = .continuous
        columnHighlight.opacity = 0
        root.addSublayer(columnHighlight)

        fillGradient.mask = fillMask
        fillGradient.startPoint = CGPoint(x: 0.5, y: 0)
        fillGradient.endPoint = CGPoint(x: 0.5, y: 1)
        root.addSublayer(fillGradient)

        for shape in [glowLayer, curveLayer, sweepLayer] {
            shape.fillColor = nil
            shape.lineJoin = .round
            shape.lineCap = .round
            root.addSublayer(shape)
        }
        glowLayer.lineWidth = 8
        curveLayer.lineWidth = 2.2
        sweepLayer.lineWidth = 3
        sweepLayer.strokeEnd = 0
        sweepLayer.shadowColor = NSColor.white.cgColor
        sweepLayer.shadowRadius = 4
        sweepLayer.shadowOpacity = 0.8
        sweepLayer.shadowOffset = .zero

        for _ in 0..<bands {
            let stem = CALayer()
            stem.cornerRadius = 1
            root.addSublayer(stem)
            stems.append(stem)
        }
        for _ in 0..<bands {
            let knob = CALayer()
            knob.bounds = CGRect(x: 0, y: 0, width: Self.knobSize, height: Self.knobSize)
            let dot = CALayer()
            dot.frame = knob.bounds
            dot.cornerRadius = Self.knobSize / 2
            dot.shadowColor = NSColor.black.cgColor
            dot.shadowOpacity = 0.35
            dot.shadowRadius = 3
            dot.shadowOffset = CGSize(width: 0, height: -1)
            dot.shadowPath = CGPath(ellipseIn: knob.bounds, transform: nil)
            knob.addSublayer(dot)
            root.addSublayer(knob)
            knobs.append(knob)
            dots.append(dot)
        }
        for band in 0..<bands {
            let label = textLayer(EqualizerBands.labels[band], size: 10.5, weight: .semibold)
            label.alignmentMode = .center
            root.addSublayer(label)
            frequencyLabels.append(label)
        }
        for value in [12, 6, 0, -6, -12] {
            let label = textLayer(value > 0 ? "+\(value)" : "\(value)", size: 10, weight: .medium)
            label.alignmentMode = .right
            root.addSublayer(label)
            decibelLabels.append(label)
        }

        bubble.cornerRadius = 9
        bubble.cornerCurve = .continuous
        bubble.opacity = 0
        bubbleText.alignmentMode = .center
        bubbleText.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        bubbleText.fontSize = 11
        bubble.addSublayer(bubbleText)
        root.addSublayer(bubble)
    }

    private func textLayer(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CATextLayer {
        let label = CATextLayer()
        label.string = string
        label.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.fontSize = size
        return label
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        for label in frequencyLabels + decibelLabels + [bubbleText] { label.contentsScale = scale }
        for shape in [gridLayer, zeroLayer, slotLayer, spectrumLayer, fillMask, glowLayer, curveLayer, sweepLayer] { shape.contentsScale = scale }
    }

    private func layoutStaticLayers() {
        let plot = plot
        for layer in [gridLayer, zeroLayer, slotLayer, spectrumGradient, fillGradient, glowLayer, curveLayer, sweepLayer] {
            layer.frame = bounds
        }
        fillMask.frame = fillGradient.bounds
        spectrumLayer.frame = spectrumGradient.bounds

        let grid = CGMutablePath()
        for value in [12.0, 6, -6, -12] {
            grid.move(to: CGPoint(x: plot.minX, y: y(decibels: value)))
            grid.addLine(to: CGPoint(x: plot.maxX, y: y(decibels: value)))
        }
        gridLayer.path = grid
        let zero = CGMutablePath()
        zero.move(to: CGPoint(x: plot.minX, y: plot.midY))
        zero.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        zeroLayer.path = zero
        let slots = CGMutablePath()
        for band in 0..<bands {
            slots.move(to: CGPoint(x: x(band: band), y: y(decibels: -12)))
            slots.addLine(to: CGPoint(x: x(band: band), y: y(decibels: 12)))
        }
        slotLayer.path = slots

        for (band, label) in frequencyLabels.enumerated() {
            label.frame = CGRect(x: x(band: band) - column / 2, y: 2, width: column, height: 14)
        }
        for (index, label) in decibelLabels.enumerated() {
            let value = [12.0, 6, 0, -6, -12][index]
            label.frame = CGRect(x: 0, y: y(decibels: value) - 7, width: Self.axisWidth - 10, height: 14)
        }
        columnHighlight.bounds = CGRect(x: 0, y: 0, width: min(column - 6, 44), height: plot.height + 6)
        if let hovered { columnHighlight.position = CGPoint(x: x(band: hovered), y: plot.midY) }

        if sampledWidth != plot.width {
            sampledWidth = plot.width
            curveXs = (0...Self.curveSamples).map { plot.minX + plot.width * CGFloat($0) / CGFloat(Self.curveSamples) }
            let frequencies = curveXs.map { Self.frequency(at: Double(($0 - plot.minX) / column - 0.5)) }
            sampler = ResponseSampler(frequencies: frequencies)
        }
    }

    private func render() {
        guard let sampler, !curveXs.isEmpty else { return }
        let values = motion.map(\.value)
        let response = sampler.response(filterGains: EqualizerResponse.filterGains(for: values))
        let curve = CGMutablePath()
        for (index, decibels) in response.enumerated() {
            let point = CGPoint(x: curveXs[index], y: y(decibels: decibels))
            if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        curveLayer.path = curve
        glowLayer.path = curve
        sweepLayer.path = curve
        let area = CGMutablePath()
        area.addPath(curve)
        area.addLine(to: CGPoint(x: curveXs[curveXs.count - 1], y: plot.midY))
        area.addLine(to: CGPoint(x: curveXs[0], y: plot.midY))
        area.closeSubpath()
        fillMask.path = area

        for band in 0..<bands {
            let knobY = y(decibels: values[band])
            knobs[band].position = CGPoint(x: x(band: band), y: knobY)
            stems[band].frame = CGRect(x: x(band: band) - 1, y: min(knobY, plot.midY), width: 2, height: abs(knobY - plot.midY))
        }
        placeBubble()
    }

    private func renderSpectrum() {
        guard !shownSpectrum.isEmpty else {
            spectrumLayer.path = nil
            return
        }
        let plot = plot
        let count = shownSpectrum.count
        let low = 40.0, high = 16000.0
        let height = plot.height * 0.8
        var points: [CGPoint] = [CGPoint(x: plot.minX, y: plot.minY + shownSpectrum[0] * height)]
        for index in 0..<count {
            let centre = low * pow(high / low, (Double(index) + 0.5) / Double(count))
            points.append(CGPoint(x: x(frequency: centre), y: plot.minY + shownSpectrum[index] * height))
        }
        points.append(CGPoint(x: plot.maxX, y: plot.minY))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: plot.minX, y: plot.minY))
        path.addLine(to: points[0])
        for i in 0..<points.count - 1 {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: CGPoint(x: c2.x, y: max(c2.y, plot.minY)))
        }
        path.closeSubpath()
        spectrumLayer.path = path
        spectrumGradient.opacity = Float(spectrumOpacity)
    }

    private func placeBubble() {
        guard let band = dragging ?? hovered else { return }
        let value = motion[band].value
        bubbleText.string = value == 0 ? "0 dB" : String(format: "%+.1f", value)
        let width: CGFloat = 44, height: CGFloat = 18
        let knob = knobs[band].position
        let above = knob.y + 16 + height <= bounds.maxY
        bubble.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        bubble.position = CGPoint(x: min(max(knob.x, plot.minX + width / 2 - 6), plot.maxX - width / 2 + 6), y: above ? knob.y + 16 + height / 2 : knob.y - 16 - height / 2)
        bubbleText.frame = CGRect(x: 0, y: 2, width: width, height: 14)
    }

    private func applyColors(duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        if duration == 0 { CATransaction.setDisableActions(true) }
        let on = enabled
        func tint(_ alpha: CGFloat) -> CGColor { self.tint.withAlphaComponent(alpha).cgColor }
        gridLayer.strokeColor = tint(0.09)
        zeroLayer.strokeColor = tint(0.22)
        slotLayer.strokeColor = tint(0.06)
        spectrumLayer.fillColor = NSColor.black.cgColor
        spectrumGradient.colors = [tint(0), tint(0.07), tint(0.17)]
        spectrumGradient.locations = [0, 0.45, 1]
        columnHighlight.backgroundColor = tint(0.07)
        fillGradient.colors = [tint(0.3), tint(0.04), tint(0.3)]
        fillGradient.locations = [0, 0.5, 1]
        fillGradient.opacity = on ? 1 : 0
        glowLayer.strokeColor = tint(0.16)
        glowLayer.opacity = on ? 1 : 0
        curveLayer.strokeColor = tint(on ? 1 : 0.4)
        sweepLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        for stem in stems { stem.backgroundColor = tint(on ? 0.45 : 0.16) }
        for dot in dots {
            dot.backgroundColor = on ? tint(1) : NSColor.black.withAlphaComponent(0.45).cgColor
            dot.borderColor = on ? NSColor.black.withAlphaComponent(0.2).cgColor : tint(0.6)
            dot.borderWidth = on ? 1 : 1.5
        }
        for (band, label) in frequencyLabels.enumerated() {
            label.foregroundColor = tint(band == (dragging ?? hovered) ? 0.95 : 0.45)
        }
        for label in decibelLabels { label.foregroundColor = tint(0.38) }
        bubble.backgroundColor = tint(on ? 0.95 : 0.6)
        bubbleText.foregroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        CATransaction.commit()
    }

    /// The knobs rise from 0 dB one after another as the dialog opens, drawing the curve out.
    private func enter() {
        let now = CACurrentMediaTime()
        for band in 0..<bands {
            let target = motion[band].target
            motion[band].jump(to: 0)
            motion[band].spring(to: target, at: now + 0.16 + Double(band) * 0.03, response: 0.55, damping: 0.68)
        }
        if enabled { sweep(delay: 0.3) }
    }

    private func powerOn() {
        let now = CACurrentMediaTime()
        for (band, knob) in knobs.enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.45, 0.94, 1]
            pulse.keyTimes = [0, 0.35, 0.7, 1]
            pulse.duration = 0.42
            pulse.beginTime = knob.convertTime(now, from: nil) + Double(band) * 0.03
            pulse.fillMode = .backwards
            knob.add(pulse, forKey: "pulse")
        }
        sweep(delay: 0)
    }

    private func sweep(delay: CFTimeInterval) {
        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = [0, 1, 1]
        end.keyTimes = [0, 0.8, 1]
        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = [0, 0, 1]
        start.keyTimes = [0, 0.2, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.8, 1]
        let group = CAAnimationGroup()
        group.animations = [end, start, fade]
        group.duration = 0.75
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        group.beginTime = sweepLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
        group.fillMode = .backwards
        sweepLayer.add(group, forKey: "sweep")
    }

    private func ensureTicking() {
        let springing = motion.contains { $0.moving }
        let spectrumMoving = spectrumLive || spectrumOpacity > 0.001 || shownSpectrum.contains { $0 > 0.002 }
        let needed = window != nil && (springing || spectrumMoving)
        if needed, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = CACurrentMediaTime()
        } else if !needed, let link {
            link.invalidate()
            self.link = nil
        }
        let rate: Float = springing ? 60 : 30
        if let link, link.preferredFrameRateRange.preferred != rate {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 20)
        lastTick = now
        var moved = false
        for band in 0..<bands where motion[band].moving {
            motion[band].step(dt, now: now)
            moved = true
        }
        let spectrumMoved = stepSpectrum()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if moved { render() }
        if spectrumMoved { renderSpectrum() }
        CATransaction.commit()
        ensureTicking()
    }

    private func stepSpectrum() -> Bool {
        let source = spectrumLive ? (spectrum?() ?? []) : []
        if !source.isEmpty, shownSpectrum.count != source.count {
            shownSpectrum = Array(repeating: 0, count: source.count)
        }
        guard !shownSpectrum.isEmpty else { return false }
        var changed = false
        for index in shownSpectrum.indices {
            let goal = source.isEmpty ? 0 : CGFloat(source[index])
            let next = shownSpectrum[index] + (goal - shownSpectrum[index]) * (goal > shownSpectrum[index] ? 0.45 : 0.18)
            if abs(next - shownSpectrum[index]) > 0.0005 { changed = true }
            shownSpectrum[index] = next
        }
        let opacityGoal: CGFloat = spectrumLive ? 1 : 0
        if spectrumOpacity != opacityGoal {
            spectrumOpacity += (opacityGoal - spectrumOpacity) * 0.12
            if abs(opacityGoal - spectrumOpacity) < 0.002 { spectrumOpacity = opacityGoal }
            changed = true
        }
        return changed
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func band(at point: CGPoint) -> Int? {
        guard bounds.contains(point), point.x >= plot.minX - 4, point.x <= plot.maxX + 4 else { return nil }
        return min(max(Int((point.x - plot.minX) / column), 0), bands - 1)
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragging == nil else { return }
        setHovered(band(at: location(event)))
    }

    override func mouseExited(with event: NSEvent) {
        if dragging == nil { setHovered(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(event)
        guard let band = band(at: point) else { return }
        if event.clickCount >= 2 {
            set(band, to: 0)
            return
        }
        dragging = band
        setHovered(band)
        let knobY = y(decibels: motion[band].value)
        if abs(point.y - knobY) <= Self.knobSize {
            grabOffset = point.y - knobY
        } else {
            grabOffset = 0
            set(band, to: decibels(y: point.y))
        }
        restsOnZero = motion[band].target == 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let band = dragging else { return }
        var value = decibels(y: location(event).y - grabOffset)
        // 0 dB holds the knob for a moment on the way through.
        if abs(value) < 0.4 {
            value = 0
            if !restsOnZero { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            restsOnZero = true
        } else {
            restsOnZero = false
        }
        guard value != motion[band].target || motion[band].moving else { return }
        motion[band].jump(to: value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()
        onChange?(band, value)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return }
        dragging = nil
        setHovered(band(at: location(event)))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let band = band(at: location(event)) else {
            super.scrollWheel(with: event)
            return
        }
        guard let steps = EqualizerScroll.steps(event, carry: &scrollSteps) else { return }
        set(band, to: motion[band].target + steps * 0.5)
    }

    private func set(_ band: Int, to value: Double) {
        let value = (min(max(value, EqualizerBands.gainRange.lowerBound), EqualizerBands.gainRange.upperBound) * 10).rounded() / 10
        guard value != motion[band].target else { return }
        if reduceMotion {
            motion[band].jump(to: value)
            render()
        } else {
            motion[band].spring(to: value, at: CACurrentMediaTime(), response: 0.22, damping: 0.8)
        }
        onChange?(band, value)
        ensureTicking()
    }

    private func setHovered(_ band: Int?) {
        let shown = dragging ?? band
        guard band != hovered else {
            placeBubble()
            return
        }
        let previous = hovered
        hovered = band
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        if let shown {
            let point = CGPoint(x: x(band: shown), y: plot.midY)
            if previous == nil {
                CATransaction.setDisableActions(true)
                columnHighlight.position = point
                CATransaction.setDisableActions(false)
            }
            columnHighlight.position = point
            columnHighlight.opacity = 1
            bubble.opacity = 1
        } else {
            columnHighlight.opacity = 0
            bubble.opacity = 0
        }
        for (index, dot) in dots.enumerated() {
            let scale: CGFloat = index == shown ? 1.3 : 1
            dot.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeBubble()
        CATransaction.commit()
        applyColors(duration: 0.18)
    }
}
