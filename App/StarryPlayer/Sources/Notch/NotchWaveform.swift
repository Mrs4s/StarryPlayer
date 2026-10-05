import AppKit
import QuartzCore
import SwiftUI

/// The bars' heights from the spectrum, the way the iPhone's Dynamic Island shows a song: the
/// bass in the middle bars, higher bands further out, each bar jumping with what changes in its
/// bands and settling back slower.
struct WaveformMeter {
    static let barCount = 6

    /// The bars as shown, 0…1, left to right.
    private(set) var levels: [CGFloat]
    /// For each bar, the spectrum bands it reads (`groups[i]` for bar `order[i]`).
    private var groups: [Range<Int>] = []
    private var order: [Int]
    /// Where each group's level has been lately: its quiet floor and loud ceiling, followed
    /// slowly, so a bar moves with the music's swings rather than sitting at its level.
    private var floor: [Float]
    private var ceiling: [Float]

    init(barCount: Int = Self.barCount) {
        levels = Array(repeating: 0, count: barCount)
        floor = Array(repeating: 1, count: barCount)
        ceiling = Array(repeating: 0, count: barCount)
        order = Self.order(barCount)
    }

    /// Bars from the middle outwards: the lowest group in the middle, the highest at the edges.
    static func order(_ count: Int) -> [Int] {
        let middle = Double(count - 1) / 2
        return (0..<count).sorted { a, b in
            let (da, db) = (abs(Double(a) - middle), abs(Double(b) - middle))
            return da != db ? da < db : a < b
        }
    }

    /// `bandCount` log-spaced bands in `barCount` equal runs, lowest first.
    static func groups(bandCount: Int, barCount: Int) -> [Range<Int>] {
        guard bandCount >= barCount else { return [] }
        return (0..<barCount).map { i in (bandCount * i / barCount)..<(bandCount * (i + 1) / barCount) }
    }

    /// Moves the bars `dt` seconds on towards the spectrum `bands` (0…1 each); while not
    /// playing they sink to nothing. Returns whether any bar moved.
    @discardableResult
    mutating func step(bands: [Float], playing: Bool, dt: Double) -> Bool {
        let count = levels.count
        if groups.count != count || groups.last?.upperBound != bands.count {
            groups = Self.groups(bandCount: bands.count, barCount: count)
        }
        var moved = false
        for rank in 0..<count {
            var target: CGFloat = 0
            if playing, rank < groups.count {
                let run = groups[rank]
                let value = bands[run].reduce(0, +) / Float(run.count)
                ceiling[rank] = value > ceiling[rank] ? value : max(ceiling[rank] - Float(0.2 * dt), value)
                floor[rank] = value < floor[rank] ? value : min(floor[rank] + Float(0.08 * dt), value)
                let relative = (value - floor[rank]) / max(ceiling[rank] - floor[rank], 0.12)
                let absolute = (value - 0.3) / 0.6
                target = CGFloat(min(max(0.6 * relative + 0.4 * absolute, 0), 1))
            }
            let bar = order[rank]
            let shown = levels[bar]
            let time = target > shown ? 0.025 : 0.11
            let next = shown + (target - shown) * CGFloat(1 - exp(-dt / time))
            if abs(next - shown) > 0.001 { moved = true }
            levels[bar] = next
        }
        return moved
    }

    /// Nothing left to move: not playing, every bar down.
    var isSettled: Bool { levels.allSatisfy { $0 < 0.002 } }
}

/// The island's sound bars (`WaveformMeter`) from the spectrum of what is heard, drawn by Core
/// Animation and stepped by a display link only while a song plays where the panel can be seen
/// (and a little after, as they sink).
struct NotchWaveform: NSViewRepresentable {
    var color: Color
    var playing: Bool
    @Environment(AppModel.self) private var model

    func makeNSView(context: Context) -> NotchWaveformView {
        let view = NotchWaveformView()
        let player = model.player
        view.spectrum = { [weak player] lead, after in player?.audibleSpectrum(lead: lead, after: after) ?? ([], 0) }
        return view
    }

    func updateNSView(_ view: NotchWaveformView, context: Context) {
        view.setColor(NSColor(color))
        view.playing = playing
    }

    static func dismantleNSView(_ view: NotchWaveformView, coordinator: ()) {
        view.playing = false
        view.stop()
    }
}

final class NotchWaveformView: NSView {
    /// The spectrum heard `lead` seconds from now, the loudest since `after` (the time it last
    /// returned), and the time it is for (`PlayerController.audibleSpectrum`).
    var spectrum: (@MainActor (_ lead: TimeInterval, _ after: TimeInterval?) -> (bands: [Float], time: TimeInterval))?
    var playing = false {
        didSet { if playing != oldValue { update() } }
    }

    private var meter = WaveformMeter()
    private var spectrumTime: TimeInterval?
    private let bars: [CALayer] = (0..<WaveformMeter.barCount).map { _ in CALayer() }
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Shown, still, with reduced motion while a song plays.
    private static let still: [CGFloat] = [0.3, 0.55, 0.85, 0.7, 0.45, 0.25]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for bar in bars {
            bar.actions = ["bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        update()
    }

    /// Nothing to draw for while the panel is out of sight (a full-screen app over its Space).
    @objc private func occlusionChanged() { update() }

    private var visible: Bool { window?.occlusionState.contains(.visible) ?? false }

    func setColor(_ color: NSColor) {
        let cg = color.cgColor
        guard bars[0].backgroundColor != cg else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.8)
        bars.forEach { $0.backgroundColor = cg }
        CATransaction.commit()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private func update() {
        let needed = visible && !reduceMotion && (playing || !meter.isSettled)
        if needed, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = CACurrentMediaTime()
        } else if !needed {
            stop()
        }
        if !playing { spectrumTime = nil }
        render()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 120), 1.0 / 15)
        lastTick = now
        var bands: [Float] = []
        if playing, let spectrum {
            // What will be heard when this frame shows.
            let heard = spectrum(max(link.targetTimestamp - now, 0), spectrumTime)
            bands = heard.bands
            spectrumTime = heard.time
        }
        if meter.step(bands: bands, playing: playing, dt: dt) { render() }
        if !playing, meter.isSettled { stop() }
    }

    /// Bars centred on the middle line, growing up and down from a dot.
    private func render() {
        let count = CGFloat(bars.count)
        let unit = bounds.width / (count + (count - 1) * 0.8)
        let width = max(min(unit, 3), 1.5)
        let gap = (bounds.width - width * count) / (count - 1)
        let levels = reduceMotion ? (playing ? Self.still : Array(repeating: 0, count: bars.count)) : meter.levels
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let height = width + (bounds.height - width) * levels[index]
            bar.cornerRadius = width / 2
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            bar.position = CGPoint(x: (width + gap) * CGFloat(index) + width / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }
}
