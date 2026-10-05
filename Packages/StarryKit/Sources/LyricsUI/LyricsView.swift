import AppKit
import LyricsCore
import QuartzCore

@MainActor
public final class LyricsView: NSView {

    public var document: LyricsDocument? {
        didSet { if document != oldValue { rebuildAll() } }
    }

    /// Unscaled specs; the view applies `scale`.
    public var specs: LyricsSpecs = .windowed {
        didSet { if specs != oldValue { specsChanged(from: oldValue) } }
    }

    public var tintColor: NSColor = .white {
        didSet {
            if tintColor != oldValue {
                rebuildLayers()
                tick()
            }
        }
    }

    public var textAlignment: NSTextAlignment = .left {
        didSet { if textAlignment != oldValue { rebuildAll() } }
    }

    public var onSeek: ((TimeInterval) -> Void)?
    public var onUserScrollingChanged: ((Bool) -> Void)?

    /// Seconds added to the playback time before lyrics are resolved (positive = lyrics earlier).
    public var timeOffset: TimeInterval = 0

    /// Precise player clock (time, rate), asked on every display-link frame; return nil to fall
    /// back to the samples from `update(time:rate:)`.
    public var timeSource: (() -> (time: TimeInterval, rate: Double)?)?

    /// Feeds a clock sample (used when `timeSource` is nil or returns nil). `rate` is 0 while paused.
    /// Ignored while the playback position is being dragged (`scrub(to:)`).
    public func update(time: TimeInterval, rate: Double) {
        guard !isScrubbing else { return }
        displayLink?.isPaused = false
        if timeSource?() != nil { return }
        ingest(time: time, rate: rate, at: CACurrentMediaTime())
        if rate == 0 { tick() }
    }

    public private(set) var isScrubbing = false

    public func scrub(to time: TimeInterval?) {
        guard let time else {
            endScrubbing()
            return
        }
        let now = CACurrentMediaTime()
        if !isScrubbing {
            let moved = abs(time - playerTime(at: now)) > 0.5 && now >= tapGuardUntil
            holdClock(at: time, now: now)
            if moved { reselect(at: now) }
            beginScrubbing()
        } else if time != scrubTime {
            holdClock(at: time, now: now)
            reselect(at: now)
        }
        scrubTime = time
    }

    private enum Entry: Equatable {
        case line(Int)
        case gap(Int)
    }

    private struct Placement {
        var entry: Entry
        var y: CGFloat
        var height: CGFloat
        var extra: CGFloat
        var alignment: NSTextAlignment
        var start: TimeInterval
        var end: TimeInterval
        var backgroundEnd: TimeInterval?
    }

    private var effective: LyricsSpecs = LyricsSpecs.windowed.scaled()
    private var placements: [Placement] = []
    private var placementOfLine: [Int: Int] = [:]
    private var placementOfGap: [Int: Int] = [:]
    private var voiceLayouts: [Int: (main: VoiceLayout, background: VoiceLayout?)] = [:]
    private var gaps: [InstrumentalGap] = []
    private var collapsedContentHeight: CGFloat = 0
    private var layoutWidth: CGFloat = 0
    private var lineWidth: CGFloat = 0
    private var laidOutSize: CGSize = .zero
    private var pendingSpecs = false

    private let contentLayer = NoAnimationLayer()
    private var lineLayers: [Int: LineLayer] = [:]
    private var gapLayers: [Int: InstrumentalBreakLayer] = [:]

    private var displayLink: CADisplayLink?
    private var baseTime: TimeInterval = 0
    private var baseHost: CFTimeInterval = CACurrentMediaTime()
    private var rate: Double = 0
    private var lastTime: TimeInterval?
    private var freezeUntil: CFTimeInterval = 0
    private var tapGuardUntil: CFTimeInterval = 0
    private var needsTapHandling = false
    private var scrubTime: TimeInterval?

    private enum ScrubChange {
        /// A line that was not lit: page and states move together, linearly, nothing staggered.
        case move
        case restyle
    }

    private var selection = LyricsSelection(entries: [], configuration: .init(animationDuration: { _ in 0 }))
    private var needsJump = true
    private var focus: Int?
    private var selectedPlacements: [Int] = []
    private var expanded: Set<Int> = []
    private var scrollY: CGFloat = 0
    private var userOffset: CGFloat = 0
    private var isUserScrolling = false
    var userScrollTimer: Timer?
    private var hoveredPlacement: Int?
    private var pressedPlacement: Int?
    private var trackingArea: NSTrackingArea?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        layer?.addSublayer(contentLayer)
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            // At most ProMotion's 120: on a 240 Hz display the frame work (clock, progress,
            // a commit) would run twice as often with no visible gain; line motion is Core
            // Animation and still renders at the display's rate.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
            rebuildLayers()
        } else {
            // The renderer is shared and would otherwise keep its targets for the whole session.
            LineSnapshotRenderer.shared?.releaseTargets()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildLayers()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func layout() {
        super.layout()
        let size = bounds.size
        guard abs(size.width - laidOutSize.width) > 0.5 || abs(size.height - laidOutSize.height) > 0.5 else { return }
        let widthChanged = abs(size.width - laidOutSize.width) > 0.5
        laidOutSize = size
        if widthChanged {
            relayout()
            rebuildLayers()
            anchorToCurrentTime()
        } else {
            updateContentBounds()
            applyFocus(animated: false)
        }
    }

    /// Spec changes rebuild everything; during a live window resize (auto-scale follows the
    /// height) they wait for the end of the resize instead of rebuilding every frame. Switching
    /// translation / romanization on or off animates instead.
    private func specsChanged(from old: LyricsSpecs) {
        var others = old
        others.selectedLinePosition = specs.selectedLinePosition
        if others == specs, !pendingSpecs {
            effective = specs.scaled()
            applyFocus(animated: false)
            return
        }
        others = old
        others.showTranslation = specs.showTranslation
        others.showRomanization = specs.showRomanization
        if others == specs, !inLiveResize, !pendingSpecs, document != nil, !placements.isEmpty {
            effective = specs.scaled()
            let switchedOn = specs.showTranslation != old.showTranslation ? specs.showTranslation : specs.showRomanization
            secondaryTextChanged(switchedOn: switchedOn)
            return
        }
        if inLiveResize {
            pendingSpecs = true
        } else {
            rebuildAll()
        }
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if pendingSpecs {
            pendingSpecs = false
            rebuildAll()
        }
    }

    private var renderScale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var renderColorSpace: CGColorSpace { window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)! }

    private var horizontalInset: CGFloat { max(effective.horizontalInset, effective.highlightViewMargin) }

    private func playerTime(at host: CFTimeInterval) -> TimeInterval {
        baseTime + (host - baseHost) * rate
    }

    func lyricTime(at host: CFTimeInterval) -> TimeInterval {
        playerTime(at: host) + timeOffset
    }

    /// Takes a player-clock sample. Samples are compared with the extrapolated player time (never
    /// with the offset lyric time); within 1 s of a click, samples that disagree by more than 0.5 s
    /// are stale pre-seek times and are dropped. A sample more than 0.5 s away from the
    /// extrapolated time is a seek.
    private func ingest(time: TimeInterval, rate: Double, at now: CFTimeInterval) {
        guard now >= freezeUntil else { return }
        let drift = time - playerTime(at: now)
        if now < tapGuardUntil, abs(drift) > 0.5 { return }
        if rate != self.rate || abs(drift) > (rate == 0 ? 0.001 : 0.06) {
            if abs(drift) > 0.5 { needsJump = true }
            baseTime = time
            baseHost = now
            self.rate = rate
        }
    }

    private func holdClock(at time: TimeInterval, now: CFTimeInterval) {
        baseTime = time
        baseHost = now
        rate = 0
        freezeUntil = 0
    }

    /// Restarts the selection at the clock without the per-frame update that would follow on the
    /// next display-link frame; lines that overlap it are appended once playback resumes.
    private func reselect(at now: CFTimeInterval) {
        guard document != nil, !placements.isEmpty else { return }
        let t = lyricTime(at: now)
        lastTime = t
        needsJump = false
        let events = selection.jump(to: t)
        let alreadyLit = events.contains { event in
            if case .jump(let pi, true) = event { return selectedPlacements.contains(pi) }
            return false
        }
        guard apply(events).changed else { return }
        applyFocus(animated: true, time: t, scrub: isScrubbing ? (alreadyLit ? .restyle : .move) : nil)
    }

    private func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        stopUserScrolling()
        restyle(animated: true)
        displayLink?.isPaused = true
    }

    private func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        scrubTime = nil
        restyle(animated: true)
        displayLink?.isPaused = false
    }

    private func rebuildAll() {
        effective = specs.scaled()
        if isUserScrolling { stopUserScrolling() }
        relayout()
        rebuildLayers()
        lastTime = nil
        anchorToCurrentTime()
    }

    private func anchorToCurrentTime() {
        let t = lyricTime(at: CACurrentMediaTime())
        needsJump = false
        lastTime = t
        let events = selection.jump(to: t) + selection.update(at: t)
        _ = apply(events)
        applyFocus(animated: false, time: t)
        tick()
    }

    private func alignment(for line: LyricLine) -> NSTextAlignment {
        switch line.singer {
        case .secondary: .right
        case .duet: .center
        case .primary: textAlignment
        }
    }

    private func relayout(keepingSelection: Bool = false) {
        let previous = keepingSelection ? voiceLayouts : [:]
        placements = []
        placementOfLine = [:]
        placementOfGap = [:]
        voiceLayouts = [:]
        gaps = []
        collapsedContentHeight = 0
        if !keepingSelection {
            focus = nil
            selectedPlacements = []
            expanded = []
            needsJump = true
        }
        let width = max(0, bounds.width - horizontalInset * 2)
        layoutWidth = width
        lineWidth = width
        guard let document, width > 10 else {
            selection = LyricsSelection(entries: [], configuration: selectionConfiguration())
            return
        }
        let s = effective
        if document.hasMultipleVocalists { lineWidth = (width * s.vocalGroupWidthCoefficient).rounded(.down) }
        gaps = document.instrumentalGaps(minimum: s.instrumentalBreakMinimumGap)
        var gapAfter: [Int: Int] = [:]  // line index (-1 intro) → gap index
        for (gi, gap) in gaps.enumerated() { gapAfter[gap.afterLine ?? -1] = gi }

        var y: CGFloat = 0
        var pendingGap = gapAfter[-1]
        for (index, line) in document.lines.enumerated() {
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let spacing: CGFloat = placements.isEmpty ? 0 : (line.isParagraphStart ? s.paragraphSpacing : s.lineSpacing)
            y += spacing
            if let gi = pendingGap {
                placementOfGap[gi] = placements.count
                let below = placements.isEmpty ? s.lineSpacing : spacing
                placements.append(Placement(entry: .gap(gi), y: y, height: 0, extra: s.instrumentalBreakViewHeight + below, alignment: textAlignment, start: gaps[gi].start, end: gaps[gi].end))
                pendingGap = nil
            }
            let align = alignment(for: line)
            let old = previous[index]
            let main = voiceLayout(line, translation: line.translation, romanization: line.romanization, romanizationWords: line.romanizationWords, font: s.font, secondaryFont: s.translationFont, rubyFont: s.romanizationFont, leading: s.fontLeading, alignment: align, old: old?.main)
            let background = line.background.map { bg in
                voiceLayout(LyricLine(id: index, start: bg.start, end: bg.end, words: bg.words), translation: bg.translation, romanization: bg.romanization, romanizationWords: bg.romanizationWords, font: s.backgroundVocalsFont, secondaryFont: s.translationBackgroundVocalsFont, rubyFont: s.romanizationBackgroundVocalsFont, leading: nil, alignment: align, old: old?.background)
            }
            voiceLayouts[index] = (main, background)
            let height = main.height(specs: s)
            let extra = background.map { s.backgroundVocalsTopSpacing + $0.height(specs: s) } ?? 0
            placementOfLine[index] = placements.count
            placements.append(Placement(entry: .line(index), y: y, height: height, extra: extra, alignment: align, start: line.start, end: line.end, backgroundEnd: line.background?.end))
            y += height
            pendingGap = gapAfter[index]
        }
        collapsedContentHeight = y
        if !keepingSelection {
            let entries = placements.map { p -> LyricsTimelineEntry in
                let kind: LyricsTimelineEntry.Kind = switch p.entry {
                case .line(let li): .line(li)
                case .gap(let gi): .instrumental(gi)
                }
                return LyricsTimelineEntry(kind: kind, start: p.start, end: p.end, backgroundEnd: p.backgroundEnd)
            }
            selection = LyricsSelection(entries: entries, configuration: selectionConfiguration())
        }
        updateContentBounds()
    }

    private func voiceLayout(_ voice: LyricLine, translation: String?, romanization: String?, romanizationWords: [LyricWord]?, font: NSFont, secondaryFont: NSFont, rubyFont: NSFont, leading: CGFloat?, alignment: NSTextAlignment, old: VoiceLayout? = nil) -> VoiceLayout {
        let s = effective
        let perSyllable = s.perSyllableEnabled && voice.hasSyllableTiming
        var text: LineTextLayout?
        var ruby: RubyLayout?
        if s.showRomanization, perSyllable, let romanizationWords, !romanizationWords.isEmpty {
            if let old, let oldRuby = old.ruby {
                (text, ruby) = (old.text, oldRuby)
            } else {
                let metrics = RubyLayout.Metrics(font: font, rubyFont: rubyFont, width: lineWidth, leading: leading, alignment: alignment,
                                                 minWordSpacing: s.romanizationMinWordSpacing, lineHeightAdjustment: s.romanizationLineHeightAdjustment)
                if let built = RubyLayout.layout(line: voice, romanization: romanizationWords, metrics: metrics) { (text, ruby) = (built.text, built.ruby) }
            }
        }
        let mainText = text ?? (old?.ruby == nil ? old?.text : nil) ?? LineTextLayout.layout(line: voice, font: font, width: lineWidth, leading: leading, alignment: alignment, perSyllable: perSyllable)
        func block(_ string: String?, shown: Bool) -> TextBlockLayout? {
            guard shown, let string, !string.isEmpty else { return nil }
            return TextBlockLayout.layout(text: string, font: secondaryFont, width: lineWidth, alignment: alignment)
        }
        return VoiceLayout(voice: voice, text: mainText, translation: block(translation, shown: s.showTranslation), romanization: block(romanization, shown: s.showRomanization && ruby == nil), ruby: ruby)
    }

    private func selectionConfiguration() -> LyricsSelection.Configuration {
        let s = effective
        let wordSynced = document?.hasSyllables ?? false
        let fixed = lineChangeSpring(gap: nil, tapped: false).settlingDuration
        let spring = s.springEnabled
        return LyricsSelection.Configuration(maxEndTimeOffset: s.maxEndTimeOffset, finishLineAnimationDuration: s.lineFinishProgressAnimationDuration) { gap in
            guard wordSynced, spring else { return fixed }
            return s.wordSyncedLineChangeSpring(gap: gap).settlingDuration
        }
    }

    private func lineChangeSpring(gap: TimeInterval?, tapped: Bool) -> LyricsSpecs.Spring {
        let s = effective
        guard s.springEnabled else { return LyricsSpecs.Spring(mass: 1, stiffness: 300, damping: 34) }
        if let gap, document?.hasSyllables == true { return s.wordSyncedLineChangeSpring(gap: gap) }
        return tapped ? s.tapLineChangeSpring : s.lineChangeSpring
    }

    private func top(of pi: Int, expanded set: Set<Int>) -> CGFloat {
        var y = placements[pi].y
        for e in set where e < pi { y += placements[e].extra }
        return y
    }

    private func height(of pi: Int, expanded set: Set<Int>) -> CGFloat {
        placements[pi].height + (set.contains(pi) ? placements[pi].extra : 0)
    }

    private func visibleHeight(of pi: Int, expanded set: Set<Int>) -> CGFloat {
        guard case .gap = placements[pi].entry else { return height(of: pi, expanded: set) }
        return set.contains(pi) ? effective.instrumentalBreakViewHeight : 0
    }

    private func frame(of pi: Int) -> ClosedRange<CGFloat> {
        let y = top(of: pi, expanded: expanded)
        return y...(y + visibleHeight(of: pi, expanded: expanded))
    }

    private var contentHeight: CGFloat {
        collapsedContentHeight + expanded.reduce(0) { $0 + placements[$1].extra }
    }

    private func updateContentBounds() {
        contentLayer.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: max(contentHeight, bounds.height)))
    }

    private func rebuildLayers() {
        lineLayers.values.forEach { $0.removeFromSuperlayer() }
        gapLayers.values.forEach { $0.removeFromSuperlayer() }
        lineLayers = [:]
        gapLayers = [:]
        hoveredPlacement = nil
        ensureLayers(in: bufferRange(at: contentPosition))
    }

    private var contentPosition: CGFloat { contentLayer.position.y }

    /// Visible part of the content (content coordinates) when the content sits at `position`.
    private func viewport(at position: CGFloat) -> ClosedRange<CGFloat> {
        (-position)...(-position + max(bounds.height, 1))
    }

    private func bufferRange(at position: CGFloat) -> ClosedRange<CGFloat> {
        let h = max(bounds.height, 1)
        return (-position - h * 0.6)...(-position + h * 1.6)
    }

    private func intersects(_ pi: Int, _ range: ClosedRange<CGFloat>, expanded set: Set<Int>? = nil) -> Bool {
        let set = set ?? expanded
        let y = top(of: pi, expanded: set)
        return y + height(of: pi, expanded: set) >= range.lowerBound && y <= range.upperBound
    }

    private func ensureLayers(in range: ClosedRange<CGFloat>, prune: Bool = true) {
        guard let document, layoutWidth > 10 else { return }
        var keep = Set<Int>()
        for pi in placements.indices where intersects(pi, range) {
            keep.insert(pi)
            let p = placements[pi]
            switch p.entry {
            case .line(let li):
                if lineLayers[pi] == nil, let layouts = voiceLayouts[li] {
                    makeLineLayer(pi, lineIndex: li, line: document.lines[li], layouts: layouts)
                }
            case .gap(let gi):
                if gapLayers[pi] == nil {
                    let layer = InstrumentalBreakLayer(gap: gaps[gi], specs: effective, tint: tintColor.cgColor)
                    layer.anchorPoint = CGPoint(x: 0, y: 0.5)
                    layer.layout(size: CGSize(width: layoutWidth, height: effective.instrumentalBreakViewHeight), alignment: p.alignment)
                    contentLayer.addSublayer(layer)
                    gapLayers[pi] = layer
                    place(layer, pi)
                    if selectedPlacements.contains(pi) {
                        layer.setSelected(true, animated: false)
                        layer.appear(at: lyricTime(at: CACurrentMediaTime()))
                    }
                }
            }
        }
        guard prune else { return }
        for (pi, layer) in lineLayers where !keep.contains(pi) && !LyricsAnimation.hasLags(layer) {
            dropLineLayer(layer, at: pi)
        }
        for (pi, layer) in gapLayers where !keep.contains(pi) && !LyricsAnimation.hasLags(layer) {
            layer.removeFromSuperlayer()
            gapLayers[pi] = nil
        }
        updateOffscreenFlags()
    }

    private func dropLineLayer(_ layer: LineLayer, at pi: Int) {
        layer.removeFromSuperlayer()
        lineLayers[pi] = nil
        if hoveredPlacement == pi { hoveredPlacement = nil }
    }

    /// Drop settled offscreen entries every frame; line changes alone retain springing
    /// layers and let snapshots accumulate for the entire song.
    private func updateOffscreenFlags() {
        let vp = viewport(at: contentPosition)
        let margin = max(bounds.height, 1) * 0.25
        let range = (vp.lowerBound - margin)...(vp.upperBound + margin)
        let buffer = bufferRange(at: contentPosition)
        let now = CACurrentMediaTime()
        for (pi, layer) in lineLayers {
            let settled = now >= layer.lagsEnd
            if settled, !intersects(pi, buffer) {
                dropLineLayer(layer, at: pi)
                continue
            }
            layer.isOffscreen = settled && !intersects(pi, range)
        }
        for (pi, layer) in gapLayers where !intersects(pi, buffer) && !LyricsAnimation.hasLags(layer) {
            layer.removeFromSuperlayer()
            gapLayers[pi] = nil
        }
    }

    public static var snapshotsEnabled = true
    private var snapshotQueue: [LineLayer] = []
    private var snapshotDrainScheduled = false

    private func requestSnapshot(_ layer: LineLayer) {
        guard Self.snapshotsEnabled, LineSnapshotRenderer.shared != nil else { return }
        if !snapshotQueue.contains(where: { $0 === layer }) { snapshotQueue.append(layer) }
        scheduleSnapshotDrain()
    }

    private func scheduleSnapshotDrain() {
        guard !snapshotDrainScheduled else { return }
        snapshotDrainScheduled = true
        perform(#selector(drainSnapshots), with: nil, afterDelay: 0.004, inModes: [.common])
    }

    @objc private func drainSnapshots() {
        snapshotDrainScheduled = false
        guard let renderer = LineSnapshotRenderer.shared, window != nil else {
            snapshotQueue.removeAll()
            return
        }
        let scale = renderScale
        var rendered = 0
        while rendered < 2, !snapshotQueue.isEmpty {
            let index = snapshotQueue.firstIndex(where: { !$0.isOffscreen }) ?? 0
            let layer = snapshotQueue.remove(at: index)
            guard layer.superlayer === contentLayer, layer.wantsSnapshot else { continue }
            if let snapshot = renderer.render(layer, radius: layer.appliedBlur, scale: scale) {
                layer.install(snapshot)
            }
            rendered += 1
        }
        if !snapshotQueue.isEmpty { scheduleSnapshotDrain() }
    }

    @discardableResult
    private func makeLineLayer(_ pi: Int, lineIndex li: Int, line: LyricLine, layouts: (main: VoiceLayout, background: VoiceLayout?)) -> LineLayer {
        let layer = LineLayer(lineIndex: li, line: line, main: layouts.main, background: layouts.background, alignment: placements[pi].alignment)
        layer.build(width: lineWidth, specs: effective, tint: tintColor, scale: renderScale, colorSpace: renderColorSpace, translationTint: tintColor)
        layer.snapshotRequest = { [weak self] layer in self?.requestSnapshot(layer) }
        contentLayer.addSublayer(layer)
        lineLayers[pi] = layer
        styleLine(layer, placementIndex: pi, animated: false)
        place(layer, pi)
        return layer
    }

    private func place(_ layer: LineLayer, _ pi: Int) {
        let x: CGFloat
        switch placements[pi].alignment {
        case .right: x = horizontalInset + layoutWidth
        case .center: x = horizontalInset + layoutWidth / 2
        default: x = horizontalInset
        }
        layer.position = CGPoint(x: x, y: top(of: pi, expanded: expanded) + layer.contentHeight / 2)
    }

    private func place(_ layer: InstrumentalBreakLayer, _ pi: Int) {
        layer.position = CGPoint(x: horizontalInset, y: top(of: pi, expanded: expanded) + effective.instrumentalBreakViewHeight / 2)
    }

    private func apply(_ events: [LyricsSelection.Event]) -> (changed: Bool, gap: TimeInterval?, jumped: Bool) {
        var changed = false
        var gap: TimeInterval?
        var jumped = false
        for event in events {
            switch event {
            case .jump(let pi, let isSelected):
                selectedPlacements = isSelected ? [pi] : []
                focus = isSelected ? pi : nil
                gap = nil
                changed = true
                jumped = true
            case .select(let pi, let g):
                selectedPlacements = [pi]
                focus = pi
                gap = g
                changed = true
            case .append(let pi):
                // A line already fully on screen is lit in place; otherwise the page scrolls to it.
                selectedPlacements.append(pi)
                if !intersectsFully(pi, viewport(at: contentPosition)) { focus = pi }
                gap = nil
                changed = true
            case .deselect(let pi):
                selectedPlacements.removeAll { $0 == pi }
                if let first = selectedPlacements.first { focus = first }
                gap = nil
                changed = true
            case .finish(let pi):
                lineLayers[pi]?.finishMainProgress(specs: effective)
            }
        }
        return (changed, gap, jumped)
    }

    private func intersectsFully(_ pi: Int, _ range: ClosedRange<CGFloat>) -> Bool {
        let f = frame(of: pi)
        return f.lowerBound >= range.lowerBound && f.upperBound <= range.upperBound
    }

    private func targetScroll(for focus: Int?) -> CGFloat {
        let s = effective
        if let inset = s.selectedLineTop(viewHeight: bounds.height) {
            guard let focus, placements.indices.contains(focus) else { return -(inset + s.firstLineStartingPosition) }
            return top(of: focus, expanded: expanded) - inset
        }
        guard case .center(let rect) = s.selectedLinePosition, let pi = focus ?? placements.indices.first, placements.indices.contains(pi) else { return 0 }
        let area = rect ?? CGRect(origin: .zero, size: bounds.size)
        let y = top(of: pi, expanded: expanded)
        return min(y, y - (area.height - visibleHeight(of: pi, expanded: expanded)) / 2 - area.minY)
    }

    private func applyFocus(animated: Bool, gap: TimeInterval? = nil, time: TimeInterval? = nil, followsPlayback: Bool = false, scrub: ScrubChange? = nil, returningFromScroll: Bool = false) {
        // The content position and the lags must be committed together (see `tick`); the callers
        // outside the frame loop (a drag of the playback position, the return from a wheel scroll)
        // have no transaction open.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tapped = needsTapHandling
        needsTapHandling = false
        let oldExpanded = expanded
        let oldPosition = contentPosition
        let oldViewport = viewport(at: oldPosition)
        let anchors = ([focus].compactMap { $0 } + selectedPlacements).filter { placements.indices.contains($0) }
        let anchorsVisible = returningFromScroll || tapped || followsPlayback || scrub != nil || anchors.contains { intersects($0, oldViewport, expanded: oldExpanded) }

        expanded = Set(selectedPlacements.filter { placements.indices.contains($0) && placements[$0].extra > 0 })
        updateContentBounds()
        scrollY = targetScroll(for: focus)
        let newPosition: CGFloat
        if isUserScrolling || scrub == .restyle {
            newPosition = oldPosition
            userOffset = newPosition + scrollY
        } else {
            newPosition = -scrollY
            userOffset = 0
        }
        let delta = oldPosition - newPosition
        let layoutChanged = oldExpanded != expanded
        let tooFar = (scrub == .move || followsPlayback) && abs(delta) > max(bounds.height, 1) * 2
        guard animated, anchorsVisible, !tooFar, abs(delta) > 0.5 || layoutChanged else {
            setContentPosition(newPosition)
            ensureLayers(in: bufferRange(at: newPosition))
            for (pi, layer) in lineLayers {
                styleLine(layer, placementIndex: pi, animated: animated)
                place(layer, pi)
            }
            for (pi, layer) in gapLayers { place(layer, pi) }
            syncGaps(animated: animated, time: time)
            return
        }

        let old = bufferRange(at: oldPosition)
        let new = bufferRange(at: newPosition)
        ensureLayers(in: min(old.lowerBound, new.lowerBound)...max(old.upperBound, new.upperBound), prune: false)
        setContentPosition(newPosition)
        var spring = lineChangeSpring(gap: gap, tapped: tapped)
        if isUserScrolling || scrub != nil { spring = effective.springEnabled ? effective.lineChangeSpring : spring }
        let linear = scrub == .move ? LyricsAnimation.scrubDuration : nil
        let speed = linear == nil ? lineChangeSpeed(spring: spring, tapped: tapped, time: time) : 1
        let newViewport = viewport(at: newPosition)
        let delays: (Int) -> TimeInterval = isUserScrolling || scrub != nil || returningFromScroll ? { _ in 0 } : staggerDelays(delta: delta, visible: min(oldViewport.lowerBound, newViewport.lowerBound)...max(oldViewport.upperBound, newViewport.upperBound))
        func addLag(_ layer: CALayer, _ pi: Int, offset: CGFloat) {
            guard abs(offset) > 0.5 else { return }
            if let linear {
                LyricsAnimation.addLinearLag(to: layer, offset: offset, duration: linear)
            } else {
                LyricsAnimation.addLag(to: layer, offset: offset, spring: spring, delay: delays(pi), speed: speed)
            }
        }
        for (pi, layer) in lineLayers {
            let oldTop = oldPosition + top(of: pi, expanded: oldExpanded)
            styleLine(layer, placementIndex: pi, animated: true, spring: spring, linear: linear)
            place(layer, pi)
            addLag(layer, pi, offset: oldTop - (newPosition + top(of: pi, expanded: expanded)))
        }
        for (pi, layer) in gapLayers {
            let oldTop = oldPosition + top(of: pi, expanded: oldExpanded)
            place(layer, pi)
            addLag(layer, pi, offset: oldTop - (newPosition + top(of: pi, expanded: expanded)))
        }
        syncGaps(animated: true, time: time)
        ensureLayers(in: bufferRange(at: newPosition))
    }

    private func secondaryTextChanged(switchedOn: Bool) {
        guard let document else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let spring = switchedOn ? effective.hideTranslationSpring : effective.showTranslationSpring
        let oldPosition = contentPosition
        let oldTops = placements.indices.map { oldPosition + top(of: $0, expanded: expanded) }
        let oldViewport = viewport(at: oldPosition)
        let anchor = selectedPlacements.sorted().first { intersects($0, oldViewport) } ?? placements.indices.first { intersects($0, oldViewport) }
        let oldLayouts = voiceLayouts
        relayout(keepingSelection: true)
        guard placements.count == oldTops.count else {
            rebuildLayers()
            anchorToCurrentTime()
            return
        }
        scrollY = targetScroll(for: focus)
        var newPosition = -scrollY
        if isUserScrolling, let anchor {
            newPosition = oldTops[anchor] - top(of: anchor, expanded: expanded)
            userOffset = newPosition + scrollY
        } else {
            userOffset = 0
        }
        setContentPosition(newPosition)

        // Lines coming on screen start from their old layout so they animate as well.
        let old = bufferRange(at: oldPosition)
        let new = bufferRange(at: newPosition)
        let range = min(old.lowerBound, new.lowerBound)...max(old.upperBound, new.upperBound)
        for pi in placements.indices where lineLayers[pi] == nil && intersects(pi, range) {
            guard case .line(let li) = placements[pi].entry, let layouts = oldLayouts[li] ?? voiceLayouts[li] else { continue }
            makeLineLayer(pi, lineIndex: li, line: document.lines[li], layouts: layouts)
        }
        ensureLayers(in: range, prune: false)
        for (pi, layer) in lineLayers {
            guard case .line(let li) = placements[pi].entry, let layouts = voiceLayouts[li] else { continue }
            layer.updateSecondary(main: layouts.main, background: layouts.background, specs: effective, animated: true, spring: spring)
            place(layer, pi)
            let offset = oldTops[pi] - (newPosition + top(of: pi, expanded: expanded))
            if abs(offset) > 0.5 { layer.animateLag(offset: offset, spring: spring, delay: 0) }
        }
        for (pi, layer) in gapLayers {
            place(layer, pi)
            let offset = oldTops[pi] - (newPosition + top(of: pi, expanded: expanded))
            if abs(offset) > 0.5 { LyricsAnimation.addLag(to: layer, offset: offset, spring: spring, delay: 0) }
        }
        ensureLayers(in: new)
    }

    /// Shorten transitions when a line ends soon, but enforce `minimumLineChangeDuration`
    /// to prevent short lines from jumping several heights in a frame.
    private func lineChangeSpeed(spring: LyricsSpecs.Spring, tapped: Bool, time: TimeInterval?) -> Float {
        guard !tapped, let time, let focus, selection.entries.indices.contains(focus) else { return 1 }
        let settle = spring.settlingDuration
        let end = selection.entries[focus].releaseTime(margin: effective.maxEndTimeOffset)
        let duration = max(end - time, effective.minimumLineChangeDuration)
        guard duration < settle else { return 1 }
        return Float(settle / duration)
    }

    private func staggerDelays(delta: CGFloat, visible: ClosedRange<CGFloat>) -> (Int) -> TimeInterval {
        let members = placements.indices.filter { intersects($0, visible) }
        guard let first = members.first, let last = members.last else { return { _ in 0 } }
        let forward = delta >= 0
        let step = effective.lineDelay * (forward ? 1 : 0.5)
        let count = members.count
        return { pi in
            let i = min(max(pi, first), last) - first
            let j = forward ? i : count - 1 - i
            return step * Double(max(j - 1, 0))
        }
    }

    private func setContentPosition(_ y: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.position = CGPoint(x: 0, y: y)
        CATransaction.commit()
    }

    private func restyle(animated: Bool) {
        for (pi, layer) in lineLayers {
            styleLine(layer, placementIndex: pi, animated: animated)
            place(layer, pi)
        }
        syncGaps(animated: animated, time: nil)
    }

    private func syncGaps(animated: Bool, time: TimeInterval?) {
        for (pi, layer) in gapLayers {
            let selected = selectedPlacements.contains(pi)
            guard selected != layer.isSelected else { continue }
            layer.setSelected(selected, animated: animated)
            if selected { layer.appear(at: time ?? lyricTime(at: CACurrentMediaTime())) }
        }
    }

    private func state(of pi: Int) -> LineLayer.State {
        if selectedPlacements.contains(pi) { return .selected }
        if let last = selectedPlacements.max() { return pi < last ? .past : .upcoming }
        if let focus { return pi < focus ? .past : .upcoming }
        return .upcoming
    }

    private func styleLine(_ layer: LineLayer, placementIndex pi: Int, animated: Bool, spring: LyricsSpecs.Spring? = nil, linear: CFTimeInterval? = nil) {
        let state = state(of: pi)
        layer.apply(state: state, specs: effective, scrolling: isUserScrolling, animated: animated, spring: spring, linear: linear)
        // Blur: none while the user scrolls or drags the playback position (entering either clears
        // it and tracking mode never sets it) or on selected lines; lines before the last selected
        // one get the base radius, later ones grow with the distance.
        let radius: CGFloat
        if isUserScrolling || isScrubbing || state == .selected {
            radius = 0
        } else if let last = selectedPlacements.max() {
            radius = effective.blurRadius(distance: state == .past ? 0 : pi - last)
        } else {
            radius = effective.blurRadius(distance: pi + 1, beforeFirstLine: true)
        }
        layer.setBlurRadius(radius, animated: animated)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        tick()
    }

    /// Commit content position and lag springs in one transaction; separate commits
    /// can briefly show the final position before the springs arrive.
    private func tick() {
        guard document != nil, !placements.isEmpty, !isScrubbing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let now = CACurrentMediaTime()
        if let sample = timeSource?() { ingest(time: sample.time, rate: sample.rate, at: now) }
        var t = lyricTime(at: now)
        if let last = lastTime, !needsJump {
            // Never rewind by less than 0.5 s: a stale sample must not pull the progress edge back.
            // Larger jumps either way are seeks.
            if t < last - 0.5 || t > last + 1 {
                needsJump = true
            } else if t < last {
                t = last
            }
        }
        lastTime = t
        let events = needsJump ? selection.jump(to: t) + selection.update(at: t) : selection.update(at: t)
        needsJump = false
        let result = apply(events)
        if result.changed {
            LyricsSignposts.poi.emitEvent("Line change", "\(result.jumped ? "jump" : "follow", privacy: .public) to placement \(self.selectedPlacements.first ?? -1)")
        }
        if result.changed || needsTapHandling {
            applyFocus(animated: true, gap: result.gap, time: t, followsPlayback: !result.jumped)
        }
        let progressTime = t + effective.animationHeadstart
        for pi in selectedPlacements {
            if let layer = lineLayers[pi] {
                layer.updateSyllables(time: progressTime, specs: effective)
            } else if let gapLayer = gapLayers[pi] {
                // Countdown uses playback time without the lyric progress headstart.
                gapLayer.update(at: t)
            }
        }
        updateOffscreenFlags()
        if rate == 0, displayLink?.isPaused == false, now - baseHost > 2 {
            displayLink?.isPaused = true
        }
    }

    private func placementIndex(at point: NSPoint) -> Int? {
        let contentY = point.y - contentPosition
        for pi in placements.indices {
            guard case .line = placements[pi].entry else { continue }
            let f = frame(of: pi)
            if contentY >= f.lowerBound - 8, contentY <= f.upperBound + 8 { return pi }
        }
        return nil
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(placementIndex(at: point))
    }

    public override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ pi: Int?) {
        guard pi != hoveredPlacement else { return }
        if let old = hoveredPlacement, let layer = lineLayers[old] { layer.setHovered(false, enabled: effective.hoverHighlightEnabled) }
        hoveredPlacement = pi
        if let pi, let layer = lineLayers[pi] { layer.setHovered(true, enabled: effective.hoverHighlightEnabled) }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedPlacement = placementIndex(at: point)
        if let pi = pressedPlacement, let layer = lineLayers[pi] { layer.setPressed(true, specs: effective) }
    }

    /// Click on a line: the clock is frozen at the line start, the player is asked to seek, and the
    /// selection restarts there as one tap-spring motion from wherever the content is (scrolled or
    /// not). Samples disagreeing with the target are ignored for a second.
    public override func mouseUp(with event: NSEvent) {
        defer { pressedPlacement = nil }
        guard let pi = pressedPlacement else { return }
        if let layer = lineLayers[pi] { layer.setPressed(false, specs: effective) }
        let point = convert(event.locationInWindow, from: nil)
        guard placementIndex(at: point) == pi, let document, case .line(let li) = placements[pi].entry else { return }
        let target = document.lines[li].start
        let now = CACurrentMediaTime()
        baseTime = target - timeOffset
        baseHost = now
        freezeUntil = now + effective.lineTapProgressFreezeDuration
        tapGuardUntil = now + 1
        lastTime = nil
        needsTapHandling = true
        needsJump = true
        if isUserScrolling { stopUserScrolling() }
        onSeek?(target - timeOffset)
        displayLink?.isPaused = false
        tick()
    }

    public override func scrollWheel(with event: NSEvent) {
        guard contentHeight > 0, !isScrubbing else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        guard delta != 0 else { return }
        if !isUserScrolling {
            isUserScrolling = true
            onUserScrollingChanged?(true)
            restyle(animated: true)
        }
        userOffset += delta
        let minOffset = -(contentHeight - scrollY - bounds.height * 0.5)
        let maxOffset = scrollY + bounds.height * 0.5
        userOffset = min(max(userOffset, min(minOffset, maxOffset)), max(minOffset, maxOffset))
        setContentPosition(-scrollY + userOffset)
        ensureLayers(in: bufferRange(at: contentPosition))
        userScrollTimer?.invalidate()
        userScrollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endUserScrolling() }
        }
    }

    private func stopUserScrolling() {
        userScrollTimer?.invalidate()
        userScrollTimer = nil
        guard isUserScrolling else { return }
        isUserScrolling = false
        onUserScrollingChanged?(false)
    }

    private func endUserScrolling() {
        guard isUserScrolling else { return }
        stopUserScrolling()
        applyFocus(animated: true, returningFromScroll: true)
    }
}
