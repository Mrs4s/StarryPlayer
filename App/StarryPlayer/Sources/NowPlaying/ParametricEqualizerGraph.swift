import AppKit
import AudioProcessing
import QuartzCore
import SwiftUI

/// The parametric equalizer's curve on a log-frequency axis with a handle per band, over the
/// post-EQ spectrum, rendered with Core Animation like `EqualizerGraph`.
///
/// Drag a handle for frequency (across) and gain (up and down; a low- or high-pass's resonance),
/// with Shift to keep the frequency; scroll on it for Q; double-click it for 0 dB. Double-click
/// empty space to add a peak there. The arrow keys and Delete act on the selected band.
struct ParametricEqualizerGraph: View {
    var bands: [ParametricBand]
    var isEnabled: Bool
    var tint: Color
    var selection: Int?
    /// The spectrum moves (music plays); otherwise it settles to nothing.
    var spectrumLive: Bool
    var spectrum: @MainActor () -> [Float]
    var onSelect: (Int?) -> Void
    var onChange: (ParametricBand) -> Void
    /// The slot the band went into; nil when all are taken.
    var onAdd: (ParametricBand) -> Int?
    var onRemove: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ParametricGraphRepresentable(graph: self, reduceMotion: reduceMotion)
            .accessibilityElement()
            .accessibilityLabel("参数均衡曲线")
            .accessibilityValue(bands.isEmpty ? "没有频段" : "\(bands.count) 个频段")
    }
}

private struct ParametricGraphRepresentable: NSViewRepresentable {
    var graph: ParametricEqualizerGraph
    var reduceMotion: Bool

    func makeNSView(context: Context) -> ParametricEqualizerGraphView { ParametricEqualizerGraphView() }

    func updateNSView(_ view: ParametricEqualizerGraphView, context: Context) {
        view.spectrum = graph.spectrum
        view.onSelect = graph.onSelect
        view.onChange = graph.onChange
        view.onAdd = graph.onAdd
        view.onRemove = graph.onRemove
        view.reduceMotion = reduceMotion
        view.update(bands: graph.bands, enabled: graph.isEnabled, tint: NSColor(graph.tint), selection: graph.selection, spectrumLive: graph.spectrumLive)
    }
}

final class ParametricEqualizerGraphView: NSView {
    static let axisWidth: CGFloat = 34
    static let rightInset: CGFloat = 8
    private static let labelHeight: CGFloat = 24
    private static let topInset: CGFloat = 14
    private static let knobSize: CGFloat = 18
    private static let hitRadius: CGFloat = 13
    private static let curveSamples = 220
    private static let slots = ParametricEqualizer.maxBands
    private static let low = ParametricEqualizer.displayRange.lowerBound
    private static let octaves = log2(ParametricEqualizer.displayRange.upperBound / ParametricEqualizer.displayRange.lowerBound)
    private static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    private static let gridLabels = ["20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"]
    private static let gridDecibels: [Double] = [24, 18, 12, 6, 0, -6, -12, -18, -24]

    var spectrum: (@MainActor () -> [Float])?
    var onSelect: ((Int?) -> Void)?
    var onChange: ((ParametricBand) -> Void)?
    var onAdd: ((ParametricBand) -> Int?)?
    var onRemove: ((Int) -> Void)?
    var reduceMotion = false

    /// One slot's handle and its part of the curve, springing between the band's values.
    private struct Handle {
        /// The band as last given (kept while it shrinks away).
        var band: ParametricBand?
        var present = false
        /// Octaves above the axis' low end.
        var position = BandMotion()
        var gain = BandMotion()
        var logQ = BandMotion()
        /// How much of it the curve has: 0 when off or gone.
        var weight = BandMotion()
        /// The handle's size: 0 when gone.
        var presence = BandMotion()

        var moving: Bool { position.moving || gain.moving || logQ.moving || weight.moving || presence.moving }
    }

    private var handles = [Handle](repeating: Handle(), count: slots)
    /// dB from the centre line to the top of the plot: 12, 18 or 24 as the bands need.
    private var range = BandMotion()

    private let gridLayer = CAShapeLayer()
    private let zeroLayer = CAShapeLayer()
    private let decadeLayer = CAShapeLayer()
    private let spectrumGradient = CAGradientLayer()
    private let spectrumLayer = CAShapeLayer()
    private let selectedFill = CAShapeLayer()
    private let fillGradient = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let curveLayer = CAShapeLayer()
    private let sweepLayer = CAShapeLayer()
    private var knobs: [CALayer] = []
    private var dots: [CALayer] = []
    private var rings: [CALayer] = []
    private var numbers: [CATextLayer] = []
    private var frequencyLabels: [CATextLayer] = []
    private var decibelLabels: [CATextLayer] = []
    private let bubble = CALayer()
    private let bubbleText = CATextLayer()

    private var enabled = true
    private var tint = NSColor.white
    private var selection: Int?
    private var spectrumLive = false
    private var shownSpectrum: [CGFloat] = []
    private var spectrumOpacity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var hasEntered = false
    private var hovered: Int?
    private var dragging: Int?
    /// Pointer to handle centre when the drag began (the handle then does not jump).
    private var grabOffset = CGSize.zero
    private var restsOnZero = false
    private var scrollSteps: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var curveXs: [CGFloat] = []
    private var sampler: ResponseSampler?
    private var sampledWidth: CGFloat = -1
    /// What the handles were last coloured for.
    private var knobStyle: [Int] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        range.jump(to: 12)
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(bands: [ParametricBand], enabled: Bool, tint: NSColor, selection: Int?, spectrumLive: Bool) {
        let tintChanged = !EqualizerGraphView.sameColor(tint, self.tint)
        self.tint = tint
        let enabledChanged = enabled != self.enabled
        self.enabled = enabled
        let selectionChanged = selection != self.selection
        self.selection = selection
        setBands(bands)
        if tintChanged || enabledChanged {
            applyColors(duration: !hasEntered ? 0 : (tintChanged ? 0.8 : 0.3))
        } else {
            colorKnobs(duration: 0.18)
        }
        if enabledChanged, enabled, hasEntered, !reduceMotion { powerOn() }
        if selectionChanged, window != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            render()
            CATransaction.commit()
        }
        self.spectrumLive = spectrumLive
        ensureTicking()
    }

    private func setBands(_ bands: [ParametricBand]) {
        let now = CACurrentMediaTime()
        var bySlot = [ParametricBand?](repeating: nil, count: Self.slots)
        for band in bands where (0..<Self.slots).contains(band.slot) { bySlot[band.slot] = band }
        var jumped = false
        for slot in 0..<Self.slots {
            var handle = handles[slot]
            let animate = hasEntered && !reduceMotion && slot != dragging
            guard let band = bySlot[slot] else {
                if handle.present {
                    handle.present = false
                    if animate {
                        handle.presence.spring(to: 0, at: now, response: 0.3, damping: 0.9)
                        handle.weight.spring(to: 0, at: now, response: 0.3, damping: 0.9)
                    } else {
                        handle.presence.jump(to: 0)
                        handle.weight.jump(to: 0)
                        jumped = true
                    }
                    if hovered == slot { setHovered(nil) }
                    handles[slot] = handle
                }
                continue
            }
            let targets = (Self.position(of: band.frequency), band.filter.hasGain ? band.gain : 0, log(band.q), band.isOn ? 1.0 : 0)
            if !handle.present {
                // Arriving: in place, growing in.
                handle.position.jump(to: targets.0)
                handle.gain.jump(to: targets.1)
                handle.logQ.jump(to: targets.2)
                handle.present = true
                if animate {
                    handle.presence.spring(to: 1, at: now, response: 0.4, damping: 0.62)
                    handle.weight.spring(to: targets.3, at: now, response: 0.4, damping: 0.8)
                } else {
                    handle.presence.jump(to: 1)
                    handle.weight.jump(to: targets.3)
                    jumped = true
                }
            } else {
                let motions: [(WritableKeyPath<Handle, BandMotion>, Double)] = [(\.position, targets.0), (\.gain, targets.1), (\.logQ, targets.2), (\.weight, targets.3)]
                for (motion, target) in motions where handle[keyPath: motion].target != target {
                    if animate {
                        handle[keyPath: motion].spring(to: target, at: now, response: 0.32, damping: 0.82)
                    } else {
                        handle[keyPath: motion].jump(to: target)
                        jumped = true
                    }
                }
            }
            // A new type moves nothing that springs: draw it now.
            if handle.band?.filter != band.filter { jumped = true }
            handle.band = band
            handles[slot] = handle
        }
        if dragging == nil, updateRange() { jumped = true }
        if jumped, window != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutGrid()
            render()
            CATransaction.commit()
        }
    }

    /// Moves the range to the smallest of ±12, ±18 and ±24 dB that holds the handles and the
    /// curve's peaks; whether it jumped there (no animation).
    private func updateRange() -> Bool {
        let bands = handles.compactMap { $0.present ? $0.band : nil }
        var top = bands.map { abs(Self.level(of: $0)) }.max() ?? 0
        if let sampler { top = max(top, sampler.response(bands: bands).max() ?? 0) }
        let goal: Double = top <= 12.5 ? 12 : (top <= 18.5 ? 18 : 24)
        guard goal != range.target else { return false }
        guard hasEntered, !reduceMotion else {
            range.jump(to: goal)
            return true
        }
        range.spring(to: goal, at: CACurrentMediaTime(), response: 0.45, damping: 0.86)
        return false
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
        // Only now is there a sampler for the curve's peaks.
        if dragging == nil { _ = updateRange() }
        layoutGrid()
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

    // MARK: Geometry

    private var plot: CGRect {
        CGRect(x: Self.axisWidth, y: Self.labelHeight, width: max(bounds.width - Self.axisWidth - Self.rightInset, 1), height: max(bounds.height - Self.labelHeight - Self.topInset, 1))
    }

    /// Half the height the range spans (the handles stay inside the plot).
    private var halfSpan: CGFloat { max(plot.height / 2 - Self.knobSize / 2 - 2, 1) }

    static func position(of frequency: Double) -> Double {
        log2(max(frequency, 1) / low)
    }

    static func frequency(at position: Double) -> Double {
        low * pow(2, position)
    }

    private func x(position: Double) -> CGFloat {
        plot.minX + CGFloat(min(max(position, 0), Self.octaves) / Self.octaves) * plot.width
    }

    private func x(frequency: Double) -> CGFloat { x(position: Self.position(of: frequency)) }

    private func frequency(x: CGFloat) -> Double {
        let fraction = Double((x - plot.minX) / plot.width)
        let frequency = Self.frequency(at: min(max(fraction, 0), 1) * Self.octaves)
        return min(max(ParametricEqualizer.rounded(frequency: frequency), ParametricEqualizer.displayRange.lowerBound), ParametricEqualizer.displayRange.upperBound)
    }

    private func y(decibels: Double) -> CGFloat {
        plot.midY + CGFloat(decibels / range.value) * halfSpan
    }

    /// Past the plot's edge too (a drag beyond it reaches ±24 dB; the range widens after it).
    private func decibels(y: CGFloat) -> Double {
        let value = Double((y - plot.midY) / halfSpan) * range.value
        return min(max(value, ParametricEqualizer.gainRange.lowerBound), ParametricEqualizer.gainRange.upperBound)
    }

    /// Where a band's handle sits: on its own curve at its frequency — a peak's gain, half a
    /// shelf's, a pass filter's resonance (20·log Q) — and on the centre line for the rest.
    private static func level(of band: ParametricBand) -> Double {
        switch band.filter {
        case .peak: band.gain
        case .lowShelf, .highShelf: band.gain / 2
        case .lowPass, .highPass: 20 * log10(band.q)
        case .bandPass, .notch, .allPass: 0
        }
    }

    /// The band as the handle shows it now (on, for its own curve).
    private func animatedBand(_ slot: Int) -> ParametricBand? {
        let handle = handles[slot]
        guard let band = handle.band else { return nil }
        return ParametricBand(slot: slot, filter: band.filter, frequency: Self.frequency(at: handle.position.value), gain: handle.gain.value, q: exp(handle.logQ.value))
    }

    // MARK: Layers

    private func buildLayers() {
        guard let root = layer else { return }
        for shape in [gridLayer, decadeLayer, zeroLayer] {
            shape.fillColor = nil
            root.addSublayer(shape)
        }
        gridLayer.lineDashPattern = [2, 4]
        gridLayer.lineWidth = 1
        decadeLayer.lineDashPattern = [2, 4]
        decadeLayer.lineWidth = 1
        zeroLayer.lineWidth = 1

        spectrumGradient.mask = spectrumLayer
        spectrumGradient.startPoint = CGPoint(x: 0.5, y: 0)
        spectrumGradient.endPoint = CGPoint(x: 0.5, y: 1)
        spectrumGradient.opacity = 0
        root.addSublayer(spectrumGradient)

        selectedFill.lineWidth = 1.2
        selectedFill.lineJoin = .round
        root.addSublayer(selectedFill)

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

        for slot in 0..<Self.slots {
            let size = Self.knobSize
            let knob = CALayer()
            knob.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            knob.isHidden = true
            let ring = CALayer()
            ring.frame = knob.bounds.insetBy(dx: -4, dy: -4)
            ring.cornerRadius = size / 2 + 4
            ring.borderWidth = 1.5
            ring.opacity = 0
            knob.addSublayer(ring)
            let dot = CALayer()
            dot.frame = knob.bounds
            dot.cornerRadius = size / 2
            dot.shadowColor = NSColor.black.cgColor
            dot.shadowOpacity = 0.35
            dot.shadowRadius = 3
            dot.shadowOffset = CGSize(width: 0, height: -1)
            dot.shadowPath = CGPath(ellipseIn: knob.bounds, transform: nil)
            knob.addSublayer(dot)
            let number = textLayer("\(slot + 1)", size: 9.5, weight: .bold)
            number.alignmentMode = .center
            number.frame = CGRect(x: 0, y: (size - 12) / 2, width: size, height: 12)
            knob.addSublayer(number)
            root.addSublayer(knob)
            knobs.append(knob)
            rings.append(ring)
            dots.append(dot)
            numbers.append(number)
        }
        for title in Self.gridLabels {
            let label = textLayer(title, size: 10.5, weight: .semibold)
            label.alignmentMode = .center
            root.addSublayer(label)
            frequencyLabels.append(label)
        }
        for value in Self.gridDecibels {
            let label = textLayer(value > 0 ? "+\(Int(value))" : "\(Int(value))", size: 10, weight: .medium)
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
        for label in frequencyLabels + decibelLabels + numbers + [bubbleText] { label.contentsScale = scale }
        for shape in [gridLayer, decadeLayer, zeroLayer, spectrumLayer, selectedFill, fillMask, glowLayer, curveLayer, sweepLayer] { shape.contentsScale = scale }
    }

    private func layoutStaticLayers() {
        let plot = plot
        for layer in [gridLayer, decadeLayer, zeroLayer, spectrumGradient, selectedFill, fillGradient, glowLayer, curveLayer, sweepLayer] {
            layer.frame = bounds
        }
        fillMask.frame = fillGradient.bounds
        spectrumLayer.frame = spectrumGradient.bounds

        let zero = CGMutablePath()
        zero.move(to: CGPoint(x: plot.minX, y: plot.midY))
        zero.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        zeroLayer.path = zero
        let decades = CGMutablePath()
        for (index, frequency) in Self.gridFrequencies.enumerated() {
            let x = x(frequency: frequency)
            if index > 0, index < Self.gridFrequencies.count - 1 {
                decades.move(to: CGPoint(x: x, y: plot.minY))
                decades.addLine(to: CGPoint(x: x, y: plot.maxY))
            }
            let width: CGFloat = 32
            let labelX = min(max(x - width / 2, plot.minX - 10), plot.maxX - width + 10)
            frequencyLabels[index].frame = CGRect(x: labelX, y: 2, width: width, height: 14)
        }
        decadeLayer.path = decades

        if sampledWidth != plot.width {
            sampledWidth = plot.width
            curveXs = (0...Self.curveSamples).map { plot.minX + plot.width * CGFloat($0) / CGFloat(Self.curveSamples) }
            sampler = ResponseSampler(frequencies: curveXs.map { Self.frequency(at: Double(($0 - plot.minX) / plot.width) * Self.octaves) })
        }
    }

    /// The decibel lines and labels, which follow the range.
    private func layoutGrid() {
        let plot = plot
        let grid = CGMutablePath()
        for (index, value) in Self.gridDecibels.enumerated() {
            let shown = abs(value) <= range.value + 0.01
            decibelLabels[index].opacity = shown ? 1 : 0
            guard shown else { continue }
            let y = y(decibels: value)
            decibelLabels[index].frame = CGRect(x: 0, y: y - 7, width: Self.axisWidth - 10, height: 14)
            if value != 0 {
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
        }
        gridLayer.path = grid
    }

    private func render() {
        guard let sampler, !curveXs.isEmpty else { return }
        let plot = plot
        var total = [Double](repeating: 0, count: curveXs.count)
        var own: [Double]?
        for slot in 0..<Self.slots {
            let weight = handles[slot].weight.value
            guard abs(weight) > 0.001, let band = animatedBand(slot) else { continue }
            let response = sampler.response(bands: [band])
            for i in total.indices { total[i] += response[i] * weight }
            if slot == selection { own = response.map { $0 * weight } }
        }
        // Deep cuts (passes, notches) stop at the plot's edge.
        let limit = range.value * Double(plot.height / 2 / halfSpan)
        func path(_ values: [Double]) -> CGMutablePath {
            let path = CGMutablePath()
            for (index, decibels) in values.enumerated() {
                let point = CGPoint(x: curveXs[index], y: y(decibels: min(max(decibels, -limit), limit)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
        func area(_ curve: CGPath) -> CGMutablePath {
            let area = CGMutablePath()
            area.addPath(curve)
            area.addLine(to: CGPoint(x: curveXs[curveXs.count - 1], y: plot.midY))
            area.addLine(to: CGPoint(x: curveXs[0], y: plot.midY))
            area.closeSubpath()
            return area
        }
        let curve = path(total)
        curveLayer.path = curve
        glowLayer.path = curve
        sweepLayer.path = curve
        fillMask.path = area(curve)
        selectedFill.path = own.map { area(path($0)) }

        for slot in 0..<Self.slots {
            let handle = handles[slot]
            let knob = knobs[slot]
            guard handle.presence.value > 0.01, let band = animatedBand(slot) else {
                knob.isHidden = true
                continue
            }
            knob.isHidden = false
            let level = min(max(Self.level(of: band), -range.value), range.value)
            knob.position = CGPoint(x: x(position: handle.position.value), y: y(decibels: level))
            let scale = CGFloat(max(handle.presence.value, 0)) * (slot == (dragging ?? hovered) ? 1.15 : 1)
            knob.transform = CATransform3DMakeScale(scale, scale, 1)
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
        guard let slot = dragging ?? hovered, let band = handles[slot].band else { return }
        var parts = [ParametricEqualizer.frequencyText(band.frequency)]
        if band.filter.hasGain { parts.append(ParametricEqualizer.gainText(band.gain)) }
        parts.append("Q \(ParametricEqualizer.qText(band.q))")
        let text = parts.joined(separator: " · ")
        bubbleText.string = text
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16, height: CGFloat = 18
        let knob = knobs[slot].position
        let above = knob.y + 18 + height <= bounds.maxY
        bubble.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        bubble.position = CGPoint(x: min(max(knob.x, plot.minX + width / 2 - 6), plot.maxX - width / 2 + 6), y: above ? knob.y + 18 + height / 2 : knob.y - 18 - height / 2)
        bubbleText.frame = CGRect(x: 0, y: 2, width: width, height: 14)
    }

    private func applyColors(duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        if duration == 0 { CATransaction.setDisableActions(true) }
        let on = enabled
        func tint(_ alpha: CGFloat) -> CGColor { self.tint.withAlphaComponent(alpha).cgColor }
        gridLayer.strokeColor = tint(0.09)
        decadeLayer.strokeColor = tint(0.06)
        zeroLayer.strokeColor = tint(0.22)
        spectrumLayer.fillColor = NSColor.black.cgColor
        spectrumGradient.colors = [tint(0), tint(0.07), tint(0.17)]
        spectrumGradient.locations = [0, 0.45, 1]
        selectedFill.fillColor = tint(on ? 0.14 : 0.06)
        selectedFill.strokeColor = tint(on ? 0.5 : 0.2)
        fillGradient.colors = [tint(0.3), tint(0.04), tint(0.3)]
        fillGradient.locations = [0, 0.5, 1]
        fillGradient.opacity = on ? 1 : 0
        glowLayer.strokeColor = tint(0.16)
        glowLayer.opacity = on ? 1 : 0
        curveLayer.strokeColor = tint(on ? 1 : 0.4)
        sweepLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        for label in frequencyLabels { label.foregroundColor = tint(0.45) }
        for label in decibelLabels { label.foregroundColor = tint(0.38) }
        bubble.backgroundColor = tint(on ? 0.95 : 0.6)
        bubbleText.foregroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        knobStyle = []
        colorKnobs(duration: duration)
        CATransaction.commit()
    }

    /// Filled handles for the bands that play, hollow ones for those off (or all, with the
    /// equalizer off), a ring round the selected one.
    private func colorKnobs(duration: CFTimeInterval) {
        let style = [enabled ? 1 : 0, selection ?? -1] + handles.map { $0.band?.isOn == false ? 0 : 1 }
        guard style != knobStyle else { return }
        knobStyle = style
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        func tint(_ alpha: CGFloat) -> CGColor { self.tint.withAlphaComponent(alpha).cgColor }
        for slot in 0..<Self.slots {
            let filled = enabled && handles[slot].band?.isOn != false
            dots[slot].backgroundColor = filled ? tint(1) : NSColor.black.withAlphaComponent(0.45).cgColor
            dots[slot].borderColor = filled ? NSColor.black.withAlphaComponent(0.2).cgColor : tint(0.6)
            dots[slot].borderWidth = filled ? 1 : 1.5
            numbers[slot].foregroundColor = filled ? NSColor.black.withAlphaComponent(0.78).cgColor : tint(0.85)
            rings[slot].borderColor = tint(0.7)
            rings[slot].opacity = slot == selection ? 1 : 0
        }
        CATransaction.commit()
    }

    // MARK: Motion

    /// The handles grow in one after another (low to high) as the dialog opens, drawing the
    /// curve out.
    private func enter() {
        let now = CACurrentMediaTime()
        let order = (0..<Self.slots).filter { handles[$0].present }.sorted { handles[$0].position.target < handles[$1].position.target }
        for (index, slot) in order.enumerated() {
            let weight = handles[slot].weight.target
            handles[slot].presence.jump(to: 0)
            handles[slot].weight.jump(to: 0)
            handles[slot].presence.spring(to: 1, at: now + 0.16 + Double(index) * 0.03, response: 0.5, damping: 0.62)
            handles[slot].weight.spring(to: weight, at: now + 0.16 + Double(index) * 0.03, response: 0.55, damping: 0.75)
        }
        if enabled { sweep(delay: 0.3) }
    }

    private func powerOn() {
        let now = CACurrentMediaTime()
        for (index, knob) in knobs.enumerated() where handles[index].present {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.45, 0.94, 1]
            pulse.keyTimes = [0, 0.35, 0.7, 1]
            pulse.duration = 0.42
            pulse.beginTime = knob.convertTime(now, from: nil) + Double(index) * 0.02
            pulse.fillMode = .backwards
            pulse.isAdditive = false
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
        let springing = range.moving || handles.contains { $0.moving }
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
        for slot in 0..<Self.slots where handles[slot].moving {
            handles[slot].position.step(dt, now: now)
            handles[slot].gain.step(dt, now: now)
            handles[slot].logQ.step(dt, now: now)
            handles[slot].weight.step(dt, now: now)
            handles[slot].presence.step(dt, now: now)
            moved = true
        }
        let rangeMoved = range.moving
        if rangeMoved { range.step(dt, now: now) }
        let spectrumMoved = stepSpectrum()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rangeMoved { layoutGrid() }
        if moved || rangeMoved { render() }
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

    // MARK: Interaction

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// The handle under the point (the selected one where they overlap).
    private func handle(at point: CGPoint) -> Int? {
        var best: Int?
        var bestDistance = Self.hitRadius
        for slot in 0..<Self.slots where handles[slot].present && !knobs[slot].isHidden {
            let centre = knobs[slot].position
            let distance = hypot(point.x - centre.x, point.y - centre.y)
            if distance < bestDistance || (distance <= Self.hitRadius && slot == selection) {
                best = slot
                bestDistance = slot == selection ? 0 : distance
            }
        }
        return best
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragging == nil else { return }
        setHovered(handle(at: location(event)))
    }

    override func mouseExited(with event: NSEvent) {
        if dragging == nil { setHovered(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = location(event)
        if let slot = handle(at: point), let band = handles[slot].band {
            if event.clickCount >= 2 {
                if band.filter.hasGain { change(slot, animated: true) { $0.gain = 0 } }
                return
            }
            select(slot)
            dragging = slot
            let centre = knobs[slot].position
            grabOffset = CGSize(width: point.x - centre.x, height: point.y - centre.y)
            restsOnZero = Self.level(of: band) == 0
            setHovered(slot)
            return
        }
        setHovered(nil)
        guard plot.insetBy(dx: -6, dy: -6).contains(point) else { return }
        if event.clickCount == 2 {
            var gain = (min(max(decibels(y: point.y), -range.value), range.value) * 10).rounded() / 10
            if abs(gain) < 0.5 { gain = 0 }
            let band = ParametricBand(slot: 0, frequency: frequency(x: point.x), gain: gain)
            if let slot = onAdd?(band) {
                select(slot)
            } else {
                NSSound.beep()
            }
        } else {
            select(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let slot = dragging, var band = handles[slot].band else { return }
        let point = location(event)
        if !event.modifierFlags.contains(.shift) {
            band.frequency = frequency(x: point.x - grabOffset.width)
        }
        let level = decibels(y: point.y - grabOffset.height)
        switch band.filter {
        case .peak, .lowShelf, .highShelf:
            var gain = ((band.filter == .peak ? level : level * 2) * 10).rounded() / 10
            // 0 dB holds the handle for a moment on the way through.
            if abs(gain) < 0.4 {
                gain = 0
                if !restsOnZero { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                restsOnZero = true
            } else {
                restsOnZero = false
            }
            band.gain = gain
        case .lowPass, .highPass:
            band.q = min(max((pow(10, level / 20) * 100).rounded() / 100, ParametricEqualizer.qRange.lowerBound), ParametricEqualizer.qRange.upperBound)
        case .bandPass, .notch, .allPass:
            break
        }
        guard band != handles[slot].band else { return }
        change(slot, animated: false) { $0 = band }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return }
        dragging = nil
        setHovered(handle(at: location(event)))
        // The range waited for the drag.
        if updateRange() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutGrid()
            render()
            CATransaction.commit()
        }
        ensureTicking()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = location(event)
        guard let slot = handle(at: point) ?? (plot.contains(point) ? selection : nil), let band = handles[slot].band else {
            super.scrollWheel(with: event)
            return
        }
        guard let steps = EqualizerScroll.steps(event, carry: &scrollSteps) else { return }
        let q = min(max(band.q * pow(1.06, steps), ParametricEqualizer.qRange.lowerBound), ParametricEqualizer.qRange.upperBound)
        change(slot, animated: true) { $0.q = (q * 100).rounded() / 100 }
    }

    override func keyDown(with event: NSEvent) {
        guard let slot = selection, handles[slot].present else {
            super.keyDown(with: event)
            return
        }
        let fine = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 51, 117: // Delete, forward delete
            select(nil)
            onRemove?(slot)
        case 123, 124: // ← →
            let direction = event.keyCode == 124 ? 1.0 : -1.0
            change(slot, animated: true) {
                let frequency = $0.frequency * pow(2, direction / (fine ? 48 : 12))
                $0.frequency = min(max(ParametricEqualizer.rounded(frequency: frequency), ParametricEqualizer.displayRange.lowerBound), ParametricEqualizer.displayRange.upperBound)
            }
        case 125, 126: // ↓ ↑
            let direction = event.keyCode == 126 ? 1.0 : -1.0
            change(slot, animated: true) {
                if $0.filter.hasGain {
                    $0.gain = (($0.gain + direction * (fine ? 0.1 : 0.5)) * 10).rounded() / 10
                } else {
                    $0.q = (($0.q * pow(1.06, direction)) * 100).rounded() / 100
                }
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let slot = handle(at: location(event)), let band = handles[slot].band else { return nil }
        select(slot)
        let menu = NSMenu()
        for filter in ParametricFilter.allCases {
            let item = NSMenuItem(title: filter.name, action: #selector(chooseFilter(_:)), keyEquivalent: "")
            item.target = self
            item.tag = slot
            item.representedObject = filter.rawValue
            item.state = filter == band.filter ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: band.isOn ? "停用此频段" : "启用此频段", action: #selector(toggleBand(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.tag = slot
        menu.addItem(toggle)
        let remove = NSMenuItem(title: "删除频段", action: #selector(removeBand(_:)), keyEquivalent: "")
        remove.target = self
        remove.tag = slot
        menu.addItem(remove)
        return menu
    }

    @objc private func chooseFilter(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let filter = ParametricFilter(rawValue: raw) else { return }
        change(item.tag, animated: true) { $0.filter = filter }
    }

    @objc private func toggleBand(_ item: NSMenuItem) {
        change(item.tag, animated: true) { $0.isOn.toggle() }
    }

    @objc private func removeBand(_ item: NSMenuItem) {
        if selection == item.tag { select(nil) }
        onRemove?(item.tag)
    }

    /// Applies an edit here at once (a drag) or springing to it, and hands it on.
    private func change(_ slot: Int, animated: Bool, _ edit: (inout ParametricBand) -> Void) {
        guard var band = handles[slot].band else { return }
        edit(&band)
        band = band.clamped
        guard band != handles[slot].band else { return }
        if animated {
            onChange?(band)
            return
        }
        handles[slot].band = band
        handles[slot].position.jump(to: Self.position(of: band.frequency))
        handles[slot].gain.jump(to: band.filter.hasGain ? band.gain : 0)
        handles[slot].logQ.jump(to: log(band.q))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()
        onChange?(band)
    }

    private func select(_ slot: Int?) {
        guard slot != selection else { return }
        selection = slot
        colorKnobs(duration: 0.18)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()
        onSelect?(slot)
    }

    private func setHovered(_ slot: Int?) {
        guard slot != hovered else {
            placeBubble()
            return
        }
        hovered = slot
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        bubble.opacity = (dragging ?? slot) == nil ? 0 : 1
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()
    }
}
