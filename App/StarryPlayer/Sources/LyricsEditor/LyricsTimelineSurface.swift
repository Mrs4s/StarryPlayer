import AppKit
import AudioProcessing
import LyricsCore
import QuartzCore
import SwiftUI

struct LyricsTimelineSurface: NSViewRepresentable {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    let viewport: LyricsTimelineViewport
    var revision: Int
    var caret: LyricsDraft.Position?
    var rubyPiece: Int?
    var range: ClosedRange<TimeInterval>
    var theme: Theme
    var accent: NSColor
    var onSpectrogram: Bool
    var canPlay: Bool
    var onsets: [VocalOnset] = []
    var aiReviewNotes: [UUID: [String]] = [:]

    func makeNSView(context: Context) -> LyricsTimelineView { LyricsTimelineView() }
    func updateNSView(_ view: LyricsTimelineView, context: Context) {
        view.configure(self)
    }
    static func dismantleNSView(_ view: LyricsTimelineView, coordinator: ()) { view.disconnect() }
}

final class LyricsTimelineView: NSView {
    static let trayHeight: CGFloat = 34
    private static let trayLeading: CGFloat = 56
    private static let trayFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let trayNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    private struct Block {
        enum Mark { case none, placing, leaving }
        var position: LyricsDraft.Position
        var syllable: LyricsDraft.Syllable
        var rect: NSRect
        var background: Bool
        var label: NSAttributedString
        var reviewNotes: [String]
        var mark = Mark.none
        var rubyBand: CGFloat = 0
    }
    private struct RubyBand {
        var line: Int
        var annotation: LyricsDraft.RubyAnnotation
        var rect: NSRect
        var pieces: [NSRect]
        var times: [LyricRuby]
        var labels: [NSAttributedString]
        var timed: Bool
        var editable: Bool
        var base: ClosedRange<TimeInterval>
    }
    private struct RubyDrag {
        var edit: LyricsTimelineRubyAdjustment
        var origin: CGFloat
        var translation: CGFloat = 0
        var onsets: [TimeInterval]
        var snapping = true
        var activeOnsets: [TimeInterval] { snapping ? onsets : [] }
    }
    private enum RubyHit {
        case edge(band: Int, piece: Int, edge: LyricsDraft.RubyEdge)
        case piece(band: Int, piece: Int)
    }
    private struct Drag {
        var edit: LyricsTimelineAdjustment
        var origin: CGFloat
        var translation: CGFloat = 0
        var onsets: [TimeInterval]
        var snapping = true
        var lifting = false
        var lane = LyricsTimelineLane.unchanged
        var activeOnsets: [TimeInterval] { snapping ? onsets : [] }
    }
    private struct Placement {
        var edit: LyricsTimelinePlacement
        var origin: NSPoint
        var moved = false
        var time: TimeInterval?
        var snapping = true
        var lane = LyricsTimelineLane.unchanged
        var edges: [TimeInterval]
        var onsets: [TimeInterval]
        var activeEdges: [TimeInterval] { snapping ? edges : [] }
        var activeOnsets: [TimeInterval] { snapping ? onsets : [] }
    }
    /// Tray coordinates before applying the scroll offset.
    private struct TrayItem {
        var line: Int
        var run: Range<Int>
        var rect: NSRect
        var chips: [NSRect]
        var texts: [String]
    }
    struct UntimedRun: Equatable {
        var line: Int
        var syllables: Range<Int>
    }
    private var configuration: LyricsTimelineSurface?
    private var blocks: [Block] = []
    private var bands: [RubyBand] = []
    private var drag: Drag?
    private var rubyDrag: RubyDrag?
    private var placement: Placement?
    private var scrubbing = false
    private var clockToken: UUID?
    private var activeLines: Set<Int> = []
    private var tracking: NSTrackingArea?
    private var measuredSize = NSSize.zero
    private let playhead = CALayer()
    private let dot = CALayer()
    private var windowObserver: NSObjectProtocol?
    private var accessible: [LyricsEditorActionElement] = []
    private var hints: [VocalOnset] = []
    private var lanes: [LyricsDraft.Lane] = [.lead]
    private var laneHeight: CGFloat = 74
    private var targetLane: Int?
    private var guide: (x: CGFloat, time: TimeInterval)?
    private var tray: [TrayItem] = []
    private var trayWidth: CGFloat = 0
    private var trayOffset: CGFloat = 0
    private var textWidths: [String: CGFloat] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        layer?.addSublayer(playhead)
        playhead.addSublayer(dot)
        dot.cornerRadius = 4
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("歌词时间轴")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(_ new: LyricsTimelineSurface) {
        let old = configuration
        let clockChanged = old?.clock !== new.clock
        if clockChanged { disconnect() }
        if let drag, drag.edit.revision != new.revision { cancelInteraction() }
        if let placement, placement.edit.revision != new.revision { cancelInteraction() }
        if let rubyDrag, rubyDrag.edit.revision != new.revision { cancelInteraction() }
        configuration = new
        if clockChanged { connect() }
        if old?.revision != new.revision { rebuildTray() }
        if old?.revision != new.revision || old?.caret != new.caret || old?.range != new.range
            || old?.theme != new.theme || old?.onSpectrogram != new.onSpectrogram || old?.accent != new.accent
            || old?.onsets != new.onsets || old?.aiReviewNotes != new.aiReviewNotes || old?.rubyPiece != new.rubyPiece {
            rebuildBlocks()
        }
        if old?.revision != new.revision || old?.caret != new.caret { revealTrayTarget() }
        updatePlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { disconnect() } else { connect() }
    }

    private func connect() {
        guard let window, let configuration, clockToken == nil else { return }
        clockToken = configuration.clock.observeFrames { [weak self] in self?.updatePlayback() }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInteraction() }
        }
    }

    func disconnect() {
        cancelInteraction()
        if let clockToken { configuration?.clock.removeFrameObserver(clockToken) }
        clockToken = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
    }

    override func layout() {
        super.layout()
        guard measuredSize != bounds.size else { return }
        measuredSize = bounds.size
        if drag != nil || scrubbing || placement != nil || rubyDrag != nil { cancelInteraction() }
        trayOffset = clampedTrayOffset(trayOffset)
        rebuildBlocks()
        revealTrayTarget()
        updatePlayback()
    }

    private var scale: CGFloat {
        guard let configuration else { return 0 }
        return bounds.width / (configuration.range.upperBound - configuration.range.lowerBound)
    }

    private func x(_ time: TimeInterval) -> CGFloat {
        guard let configuration else { return 0 }
        return CGFloat(time - configuration.range.lowerBound) * scale
    }

    private var trayTop: CGFloat { max(bounds.height - Self.trayHeight, 30) }
    private var trayRect: NSRect { NSRect(x: 0, y: trayTop, width: bounds.width, height: bounds.height - trayTop) }

    private func rebuildBlocks() {
        guard let c = configuration, scale > 0 else { return }
        blocks = []
        bands = []
        hints = []
        lanes = c.session.draft.lanes
        laneHeight = min(74, max(trayTop - 34, 30) / CGFloat(lanes.count))
        for onset in c.onsets where c.onSpectrogram && c.range.contains(onset.time) {
            if let last = hints.last, (onset.time - last.time) * scale < 5 {
                if onset.strength > last.strength { hints[hints.count - 1] = onset }
            } else { hints.append(onset) }
        }
        let caretLine = (c.session.caret ?? c.session.lastStarted)?.line
        let ranges = c.session.timedRanges
        for index in c.session.draft.lines.indices
        where index == caretLine || index == drag?.edit.position.line || index == placement?.edit.line || index == rubyDrag?.edit.line
            || (ranges[index]?.overlaps(c.range) ?? false) {
            appendBlocks(ofLine: index)
        }
        rebuildAccessibility()
        needsDisplay = true
    }

    private func appendBlocks(ofLine index: Int) {
        guard let c = configuration else { return }
        if let rubyDrag, rubyDrag.edit.line == index {
            appendBlocks(rubyDrag.edit.preview(translation: rubyDrag.translation, onsets: rubyDrag.activeOnsets), index: index)
        } else if let drag, drag.edit.position.line == index {
            if drag.lifting {
                let s = drag.edit.position.syllable
                appendBlocks(drag.edit.original, index: index, marking: drag.edit.part == .line ? drag.edit.original.syllables.indices : s..<(s + 1), as: .leaving)
            } else {
                appendBlocks(drag.edit.preview(translation: drag.translation, onsets: drag.activeOnsets, lane: drag.lane), index: index)
            }
        } else if let placement, placement.edit.line == index, let time = placement.time {
            let line = placement.edit.preview(at: time, edges: placement.activeEdges, onsets: placement.activeOnsets, lane: placement.lane)
            appendBlocks(line, index: index, marking: placement.edit.run, as: .placing)
        } else if c.session.draft.lines.indices.contains(index) {
            appendBlocks(c.session.draft.lines[index], index: index)
        }
    }

    private func appendBlocks(_ line: LyricsDraft.Line, index: Int, marking marked: Range<Int> = 0..<0, as mark: Block.Mark = .none) {
        guard let c = configuration else { return }
        let slot = c.session.draft.slot(ofLine: index, as: line, in: lanes)
        let row = laneRow(slot.lane, background: slot.background)
        for (s, syllable) in line.syllables.enumerated() {
            guard let start = syllable.start else { continue }
            let end = syllable.end ?? (s + 1 < line.syllables.count ? line.syllables[s + 1].start : nil) ?? start + 0.3
            guard start <= c.range.upperBound, end >= c.range.lowerBound else { continue }
            let rect = NSRect(x: x(start), y: row.y, width: max(x(max(end, start)) - x(start), 8), height: row.height)
            let label = NSAttributedString(string: syllable.text.trimmingCharacters(in: .whitespaces), attributes: [
                .font: NSFont.systemFont(ofSize: slot.background ? min(10.5, max(8, row.height - 4)) : min(13, max(9, row.height - 6)), weight: .semibold),
                .foregroundColor: c.onSpectrogram ? NSColor.white : NSColor(c.theme.onSurface)
            ])
            blocks.append(Block(position: .init(line: index, syllable: s), syllable: syllable, rect: rect, background: slot.background,
                                label: label, reviewNotes: c.aiReviewNotes[syllable.id] ?? [], mark: marked.contains(s) ? mark : .none))
        }
        appendRubyBands(line, index: index, row: row, background: slot.background, interactive: marked.isEmpty || mark == .none)
    }

    private func appendRubyBands(_ line: LyricsDraft.Line, index: Int, row: (y: CGFloat, height: CGFloat), background: Bool, interactive: Bool) {
        guard let c = configuration else { return }
        let compact = row.height < 30
        let height = compact ? max(5, floor(row.height * 0.28)) : min(15, floor(row.height * 0.36))
        let font = NSFont.systemFont(ofSize: background ? 9 : 10, weight: .semibold)
        for annotation in line.rubyAnnotations {
            guard let start = line.syllables[annotation.syllables.lowerBound].start,
                  let end = displayEnd(of: annotation.syllables.upperBound, in: line), end > start,
                  start <= c.range.upperBound, end >= c.range.lowerBound else { continue }
            let times = line.rubyTimes(of: annotation, base: start...end)
            guard !times.isEmpty else { continue }
            let labels = compact ? [] : times.map {
                NSAttributedString(string: $0.text.trimmingCharacters(in: .whitespaces), attributes: [
                    .font: font, .foregroundColor: c.onSpectrogram ? NSColor.white : NSColor(c.theme.onSurface)
                ])
            }
            bands.append(RubyBand(line: index, annotation: annotation,
                                  rect: NSRect(x: x(start), y: row.y, width: max(x(end) - x(start), 8), height: height),
                                  pieces: times.map { NSRect(x: x($0.start), y: row.y, width: max(x($0.end) - x($0.start), 1), height: height) },
                                  times: times, labels: labels, timed: LyricsDraft.Ruby.isTimed(line.ruby(of: annotation)),
                                  editable: interactive && line.rubyBase(of: annotation) != nil, base: start...end))
            for k in blocks.indices where blocks[k].position.line == index && annotation.syllables.contains(blocks[k].position.syllable) {
                blocks[k].rubyBand = height
            }
        }
    }

    private func displayEnd(of s: Int, in line: LyricsDraft.Line) -> TimeInterval? {
        guard let start = line.syllables[s].start else { return nil }
        return line.syllables[s].end ?? (s + 1 < line.syllables.count ? line.syllables[s + 1].start : nil) ?? start + 0.3
    }

    private func laneRow(_ lane: Int, background: Bool) -> (y: CGFloat, height: CGFloat) {
        let top = 30 + CGFloat(lane) * laneHeight
        let main = (laneHeight - 8) * 2 / 3
        return background ? (top + main + 4, (laneHeight - 8) / 3) : (top, main)
    }

    private func laneRect(_ lane: Int) -> NSRect {
        NSRect(x: 0, y: 30 + CGFloat(lane) * laneHeight - 2, width: bounds.width, height: laneHeight)
    }

    private func laneName(_ lane: LyricsDraft.Lane) -> String {
        switch lane {
        case .lead: "主唱"
        case .secondary: "对唱"
        case .track(let id): configuration?.session.draft.tracks.first { $0.id == id }.map { LyricsEditorSession.name(of: $0) } ?? "轨道"
        }
    }

    private func drawLanes(in dirtyRect: NSRect) {
        guard let c = configuration else { return }
        if let targetLane, laneRect(targetLane).intersects(dirtyRect) {
            c.accent.withAlphaComponent(c.onSpectrogram ? 0.18 : 0.08).setFill()
            NSBezierPath(roundedRect: laneRect(targetLane).insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard lanes.count > 1 else { return }
        let color = c.onSpectrogram ? NSColor.white.withAlphaComponent(0.2) : NSColor(c.theme.onSurfaceVariant).withAlphaComponent(0.25)
        for lane in 1..<lanes.count {
            let y = 30 + CGFloat(lane) * laneHeight - 2
            guard dirtyRect.minY <= y + 14, dirtyRect.maxY >= y else { continue }
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 0, y: y + 0.5))
            divider.line(to: NSPoint(x: bounds.width, y: y + 0.5))
            divider.setLineDash([2, 3], count: 2, phase: 0)
            divider.lineWidth = 1
            color.setStroke()
            divider.stroke()
            (laneName(lanes[lane]) as NSString).draw(at: NSPoint(x: 6, y: y + 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: color.withAlphaComponent(min(1, color.alphaComponent * 2.5))
            ])
        }
    }

    private func refreshLine(_ index: Int) {
        let oldRects = blocks.filter { $0.position.line == index }.map(\.rect) + bands.filter { $0.line == index }.map(\.rect)
        blocks.removeAll { $0.position.line == index }
        bands.removeAll { $0.line == index }
        appendBlocks(ofLine: index)
        blocks.sort { $0.position < $1.position }
        for rect in oldRects + blocks.filter({ $0.position.line == index }).map(\.rect) + bands.filter({ $0.line == index }).map(\.rect) {
            setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
        }
    }

    private func previewDrag(at point: NSPoint, snapping: Bool) {
        guard var drag else { return }
        let lifting = drag.edit.part.lifts && point.y >= trayTop
        let target: (change: LyricsTimelineLane, lane: Int?) = drag.edit.part == .line && !lifting
            ? laneChange(forLine: drag.edit.position.line, at: point.y) : (.unchanged, nil)
        if lifting != drag.lifting { setNeedsDisplay(trayRect) }
        drag.translation = point.x - drag.origin
        drag.snapping = snapping
        drag.lifting = lifting
        drag.lane = target.change
        self.drag = drag
        setTargetLane(target.lane)
        refreshLine(drag.edit.position.line)
    }

    private func previewRubyDrag(at point: NSPoint, snapping: Bool) {
        guard var rubyDrag else { return }
        rubyDrag.translation = point.x - rubyDrag.origin
        rubyDrag.snapping = snapping
        self.rubyDrag = rubyDrag
        refreshLine(rubyDrag.edit.line)
        let line = rubyDrag.edit.preview(translation: rubyDrag.translation, onsets: rubyDrag.activeOnsets)
        setGuide(rubyDrag.edit.edgeTime(in: line).map { (x: x($0), time: $0) })
    }

    private func updatePlacement(at point: NSPoint, snapping: Bool) {
        guard var placement, let c = configuration else { return }
        if !placement.moved {
            guard hypot(point.x - placement.origin.x, point.y - placement.origin.y) >= 3 else { return }
            placement.moved = true
            c.viewport.interactionRange = c.range
            setNeedsDisplay(trayRect)
        }
        NSCursor.closedHand.set()
        placement.snapping = snapping
        placement.time = point.y < trayTop ? time(at: point) : nil
        let free = !placement.edit.original.syllables.contains(where: \.isTimed)
        let target: (change: LyricsTimelineLane, lane: Int?) = placement.time != nil && free
            ? laneChange(forLine: placement.edit.line, at: point.y) : (.unchanged, nil)
        placement.lane = target.change
        self.placement = placement
        setTargetLane(target.lane)
        refreshLine(placement.edit.line)
        setGuide(blocks.first { $0.mark == .placing }.map { (x: $0.rect.minX, time: $0.syllable.start ?? 0) })
    }

    private func laneChange(forLine index: Int, at y: CGFloat) -> (change: LyricsTimelineLane, lane: Int?) {
        guard let c = configuration, y >= 28, y < trayTop, c.session.draft.lines.indices.contains(index) else { return (.unchanged, nil) }
        let lane = min(max(Int((y - 28) / laneHeight), 0), lanes.count - 1)
        let draft = c.session.draft
        let line = draft.lines[index]
        if case .track(let id) = lanes[lane] {
            return line.track == id ? (.unchanged, nil) : (.track(id), lane)
        }
        var own = line
        own.track = nil
        guard draft.isOnTrack(line), draft.slot(ofLine: index, as: own, in: lanes).lane == lane else { return (.unchanged, nil) }
        return (.track(nil), lane)
    }

    private func setTargetLane(_ lane: Int?) {
        guard lane != targetLane else { return }
        for old in [targetLane, lane].compactMap({ $0 }) { setNeedsDisplay(laneRect(old)) }
        targetLane = lane
    }

    private func setGuide(_ new: (x: CGFloat, time: TimeInterval)?) {
        guard new?.x != guide?.x || new?.time != guide?.time else { return }
        for x in [guide?.x, new?.x].compactMap({ $0 }) { setNeedsDisplay(guideRect(x)) }
        guide = new
    }

    private func guideRect(_ x: CGFloat) -> NSRect { NSRect(x: x - 50, y: 0, width: 100, height: trayTop) }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = configuration else { return }
        if dirtyRect.minY < 26 { drawRuler() }
        drawLanes(in: dirtyRect)
        drawHints(in: dirtyRect)
        let caretLine = (c.session.caret ?? c.session.lastStarted)?.line
        for block in blocks where block.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            drawBlock(block, caretLine: caretLine)
        }
        for band in bands where band.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            drawBand(band, caretLine: caretLine)
        }
        drawGuide(in: dirtyRect)
        if dirtyRect.maxY > trayTop { drawTray(in: dirtyRect) }
    }

    private func drawBlock(_ block: Block, caretLine: Int?) {
        guard let c = configuration else { return }
        let selected = block.mark == .none && c.session.caret == block.position
        var alpha: CGFloat = block.position.line == caretLine || activeLines.contains(block.position.line) ? 1 : 0.5
        var fill = c.onSpectrogram ? (selected ? c.accent.withAlphaComponent(0.42) : .black.withAlphaComponent(0.45)) : NSColor(c.theme.primary).withAlphaComponent(selected ? 0.32 : 0.16)
        var stroke = c.onSpectrogram ? (selected ? c.accent : .white.withAlphaComponent(0.42)) : NSColor(c.theme.primary).withAlphaComponent(selected ? 0.9 : 0.3)
        let needsReview = !block.reviewNotes.isEmpty
        let warning = NSColor(c.onSpectrogram ? Theme.darkBase.warning : c.theme.warning)
        if needsReview {
            stroke = warning
            alpha = max(alpha, 0.85)
        }
        switch block.mark {
        case .none: break
        case .placing:
            alpha = 1
            fill = c.accent.withAlphaComponent(0.3)
            stroke = c.accent
        case .leaving:
            alpha = 0.3
        }
        let radius: CGFloat = block.background ? 4 : 6
        let path = NSBezierPath(roundedRect: block.rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
        path.fill()
        stroke.withAlphaComponent(stroke.alphaComponent * alpha).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        if block.mark != .none || needsReview { path.setLineDash([4, 3], count: 2, phase: 0) }
        path.stroke()
        let badge = needsReview && block.rect.width >= 36 && block.rect.height >= 18
        var labelRect = block.rect.insetBy(dx: 3, dy: 0)
        if badge { labelRect.size.width -= 13 }
        NSGraphicsContext.saveGraphicsState()
        labelRect.clip()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        let size = block.label.size()
        let labelMidY = block.rect.minY + block.rubyBand + (block.rect.height - block.rubyBand) / 2
        block.label.draw(at: NSPoint(x: max(labelRect.minX + 1, labelRect.midX - size.width / 2), y: labelMidY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        if badge {
            let rect = NSRect(x: block.rect.maxX - 14, y: block.rect.minY + block.rubyBand + 4, width: 10, height: 10)
            warning.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let mark = NSAttributedString(string: "!", attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .heavy),
                .foregroundColor: c.onSpectrogram ? NSColor.black : NSColor(c.theme.onPrimary)
            ])
            let size = mark.size()
            mark.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    private func drawBand(_ band: RubyBand, caretLine: Int?) {
        guard let c = configuration else { return }
        let alpha: CGFloat = band.line == caretLine || activeLines.contains(band.line) ? 1 : 0.5
        let ink = c.onSpectrogram ? NSColor.white : NSColor(c.theme.onSurface)
        let tint = c.onSpectrogram ? NSColor.black.withAlphaComponent(0.4) : NSColor(c.theme.primary).withAlphaComponent(0.12)
        let strip = band.rect.insetBy(dx: 1, dy: 1)
        tint.withAlphaComponent(tint.alphaComponent * alpha).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 4, yRadius: 4).fill()
        let selected = c.session.selectedRuby.flatMap { $0.position.line == band.line && $0.annotation == band.annotation ? $0.piece : nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        strip.clip()
        for (k, rect) in band.pieces.enumerated() {
            let fill = k == selected ? c.accent.withAlphaComponent(0.55) : ink.withAlphaComponent(band.timed ? 0.14 : 0.07)
            fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
        let dividers = NSBezierPath()
        func divide(at x: CGFloat) {
            dividers.move(to: NSPoint(x: x + 0.5, y: strip.minY + 1))
            dividers.line(to: NSPoint(x: x + 0.5, y: strip.maxY - 1))
        }
        for (k, rect) in band.pieces.enumerated() {
            if k > 0 { divide(at: rect.minX) }
            if k + 1 < band.pieces.count, band.pieces[k + 1].minX - rect.maxX > 1 { divide(at: rect.maxX) }
        }
        dividers.lineWidth = 1
        if !band.timed { dividers.setLineDash([2, 2], count: 2, phase: 0) }
        ink.withAlphaComponent(0.6 * alpha).setStroke()
        dividers.stroke()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        for (k, label) in band.labels.enumerated() {
            let rect = band.pieces[k], size = label.size()
            guard size.width + 4 <= rect.width else { continue }
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: strip.midY - size.height / 2))
        }
    }

    private func drawHints(in dirtyRect: NSRect) {
        guard let c = configuration, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineDash(phase: 0, lengths: [3, 4])
        context.setLineWidth(1)
        for hint in hints {
            let position = x(hint.time)
            guard position >= dirtyRect.minX - 1, position <= dirtyRect.maxX + 1 else { continue }
            context.setStrokeColor(c.accent.withAlphaComponent(0.25 + 0.5 * CGFloat(hint.strength)).cgColor)
            context.move(to: CGPoint(x: position, y: 27))
            context.addLine(to: CGPoint(x: position, y: trayTop))
            context.strokePath()
        }
    }

    private func drawGuide(in dirtyRect: NSRect) {
        guard let c = configuration, let guide, guideRect(guide.x).intersects(dirtyRect) else { return }
        c.accent.setFill()
        NSRect(x: guide.x - 0.5, y: 24, width: 1, height: trayTop - 24).fill()
        let label = NSAttributedString(string: LyricsEditorFormat.time(guide.time), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white
        ])
        let size = label.size()
        let capsule = NSRect(x: min(max(guide.x - size.width / 2 - 5, 0), bounds.width - size.width - 10), y: 8, width: size.width + 10, height: 16)
        let path = NSBezierPath(roundedRect: capsule, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        c.accent.setStroke()
        path.stroke()
        label.draw(at: NSPoint(x: capsule.minX + 5, y: capsule.midY - size.height / 2))
    }

    private func drawRuler() {
        guard let c = configuration, scale > 0 else { return }
        let step = [1.0, 2, 5, 10, 15, 30, 60, 120].first { $0 * scale >= 56 } ?? 120
        let minor = step / 4
        var k = Int((c.range.lowerBound / minor).rounded(.up))
        let color = NSColor(c.theme.onSurfaceVariant)
        while Double(k) * minor <= c.range.upperBound {
            let time = Double(k) * minor
            let labelled = k % 4 == 0
            color.withAlphaComponent(labelled ? 0.5 : 0.25).setFill()
            NSRect(x: x(time), y: 0, width: 1, height: labelled ? 10 : k % 2 == 0 ? 6 : 3).fill()
            if labelled {
                (String(LyricsEditorFormat.time(time).dropLast(3)) as NSString).draw(at: NSPoint(x: x(time) + 3, y: 12), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium), .foregroundColor: color.withAlphaComponent(0.8)])
            }
            k += 1
        }
    }

    private func updatePlayback() {
        guard let c = configuration else { return }
        if activeLines != c.clock.activeLines {
            activeLines = c.clock.activeLines
            for block in blocks { setNeedsDisplay(block.rect.insetBy(dx: -2, dy: -2)) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playhead.isHidden = !c.canPlay || !c.range.contains(c.clock.time)
        playhead.backgroundColor = c.accent.cgColor
        playhead.frame = NSRect(x: x(c.clock.time) - 1, y: 0, width: 2, height: trayTop)
        dot.backgroundColor = c.accent.cgColor
        dot.frame = NSRect(x: -3, y: -2, width: 8, height: 8)
        CATransaction.commit()
    }

    // MARK: Tray

    static func untimedRuns(in lines: [LyricsDraft.Line]) -> [UntimedRun] {
        var runs: [UntimedRun] = []
        for (l, line) in lines.enumerated() {
            var s = 0
            while s < line.syllables.count {
                guard !line.syllables[s].isTimed else { s += 1; continue }
                var end = s + 1
                while end < line.syllables.count, !line.syllables[end].isTimed { end += 1 }
                runs.append(UntimedRun(line: l, syllables: s..<end))
                s = end
            }
        }
        return runs
    }

    private func rebuildTray() {
        guard let c = configuration else { return }
        let lines = c.session.draft.lines
        let chipHeight: CGFloat = 22
        let top = (Self.trayHeight - chipHeight - 6) / 2 + 1
        var x: CGFloat = 0
        tray = Self.untimedRuns(in: lines).map { run in
            var chipX = x + 6 + width(of: "\(run.line + 1)", font: Self.trayNumberFont) + 5
            var chips: [NSRect] = []
            var texts: [String] = []
            for s in run.syllables {
                let text = lines[run.line].syllables[s].text.trimmingCharacters(in: .whitespaces)
                let chip = NSRect(x: chipX, y: top + 3, width: max(18, width(of: text, font: Self.trayFont) + 10), height: chipHeight)
                chips.append(chip)
                texts.append(text)
                chipX = chip.maxX + 2
            }
            let item = TrayItem(line: run.line, run: run.syllables, rect: NSRect(x: x, y: top, width: chipX + 2 - x, height: chipHeight + 6), chips: chips, texts: texts)
            x = item.rect.maxX + 6
            return item
        }
        trayWidth = x
        trayOffset = clampedTrayOffset(trayOffset)
        setNeedsDisplay(trayRect)
    }

    private func width(of text: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)\u{1F}\(text)"
        if let width = textWidths[key] { return width }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        textWidths[key] = width
        return width
    }

    private func trayFrame(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: Self.trayLeading - trayOffset, dy: trayTop) }

    private func clampedTrayOffset(_ offset: CGFloat) -> CGFloat {
        min(max(offset, 0), max(0, trayWidth + 8 - (bounds.width - Self.trayLeading)))
    }

    private func trayTarget() -> Int? {
        guard let c = configuration, let caret = c.caret ?? c.session.lastStarted else { return tray.isEmpty ? nil : 0 }
        return tray.firstIndex { $0.line > caret.line || ($0.line == caret.line && $0.run.upperBound > caret.syllable) }
    }

    private func revealTrayTarget() {
        guard let index = trayTarget() ?? tray.indices.last else { return }
        let rect = tray[index].rect
        guard rect.minX < trayOffset || rect.maxX > trayOffset + bounds.width - Self.trayLeading else { return }
        scrollTray(to: rect.minX - 8)
    }

    private func scrollTray(to offset: CGFloat) {
        let offset = clampedTrayOffset(offset)
        guard offset != trayOffset else { return }
        trayOffset = offset
        setNeedsDisplay(trayRect)
        rebuildAccessibility()
    }

    private func trayHit(_ point: NSPoint) -> (item: Int, syllable: Int?)? {
        guard point.y >= trayTop, point.x >= Self.trayLeading else { return nil }
        let local = NSPoint(x: point.x - Self.trayLeading + trayOffset, y: point.y - trayTop)
        guard let index = tray.firstIndex(where: { $0.rect.contains(local) }) else { return nil }
        return (index, tray[index].chips.firstIndex { $0.contains(local) }.map { tray[index].run.lowerBound + $0 })
    }

    private func drawTray(in dirtyRect: NSRect) {
        guard let c = configuration else { return }
        let rect = trayRect
        let primary = NSColor(c.theme.primary)
        let foreground = NSColor(c.theme.onSurface)
        let secondary = NSColor(c.theme.onSurfaceVariant)
        let lifting = drag?.lifting ?? false
        (lifting ? primary.withAlphaComponent(0.12) : foreground.withAlphaComponent(c.theme.isDark ? 0.04 : 0.03)).setFill()
        rect.fill()
        (lifting ? primary.withAlphaComponent(0.7) : foreground.withAlphaComponent(0.1)).setFill()
        NSRect(x: 0, y: rect.minY, width: rect.width, height: lifting ? 2 : 1).fill()
        ((lifting ? "松开暂存" : "暂存区") as NSString).draw(at: NSPoint(x: 10, y: rect.minY + 5), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: lifting ? primary : secondary
        ])
        let count = tray.reduce(0) { $0 + $1.run.count }
        ("\(count) 个音节" as NSString).draw(at: NSPoint(x: 10, y: rect.minY + 19), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium), .foregroundColor: secondary.withAlphaComponent(0.8)
        ])
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSRect(x: Self.trayLeading, y: rect.minY, width: max(rect.width - Self.trayLeading, 0), height: rect.height).clip()
        guard !tray.isEmpty else {
            let hint = lifting ? "松开后它会离开时间轴，留在这里，需要时再拖回去" : "没打点的歌词会排在这里，拖到上面的时间轴即可放置；时间轴上的字块也能拖下来暂存"
            (hint as NSString).draw(at: NSPoint(x: Self.trayLeading + 4, y: rect.midY - 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: secondary.withAlphaComponent(0.8)
            ])
            return
        }
        let target = trayTarget()
        let held = placement?.moved == true ? placement : nil
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Self.trayNumberFont, .foregroundColor: secondary]
        let textAttributes: [NSAttributedString.Key: Any] = [.font: Self.trayFont, .foregroundColor: foreground]
        for (index, item) in tray.enumerated() {
            let frame = trayFrame(item.rect)
            guard frame.maxX > Self.trayLeading, frame.minX < rect.maxX, frame.intersects(dirtyRect) else { continue }
            let group = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            foreground.withAlphaComponent(c.theme.isDark ? 0.07 : 0.05).setFill()
            group.fill()
            if index == target {
                primary.withAlphaComponent(0.65).setStroke()
                group.lineWidth = 1
                group.stroke()
            }
            ("\(item.line + 1)" as NSString).draw(at: NSPoint(x: frame.minX + 6, y: frame.midY - 7), withAttributes: numberAttributes)
            for (k, chip) in item.chips.enumerated() {
                let s = item.run.lowerBound + k
                let chipFrame = trayFrame(chip)
                let isCaret = c.caret == LyricsDraft.Position(line: item.line, syllable: s)
                let inHand = held.map { $0.edit.line == item.line && $0.edit.run.contains(s) } ?? false
                let path = NSBezierPath(roundedRect: chipFrame, xRadius: 5, yRadius: 5)
                (isCaret ? primary.withAlphaComponent(0.26) : foreground.withAlphaComponent(c.theme.isDark ? 0.08 : 0.06)).setFill()
                path.fill()
                if isCaret {
                    primary.setStroke()
                    path.stroke()
                }
                NSGraphicsContext.saveGraphicsState()
                chipFrame.insetBy(dx: 3, dy: 0).clip()
                NSGraphicsContext.current?.cgContext.setAlpha(inHand ? 0.35 : 1)
                let text = item.texts[k] as NSString
                let size = text.size(withAttributes: textAttributes)
                text.draw(at: NSPoint(x: max(chipFrame.minX + 5, chipFrame.midX - size.width / 2), y: chipFrame.midY - size.height / 2), withAttributes: textAttributes)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func placeAtPlayhead(_ edit: LyricsTimelinePlacement) {
        guard let c = configuration else { return }
        guard c.canPlay else { return c.session.flash("音频载入后才能放到播放头") }
        if edit.commit(at: c.clock.time, in: c.session) { c.viewport.hold(c.range) }
    }

    // MARK: Pointer

    private func hit(_ point: NSPoint) -> Block? { blocks.last { $0.rect.contains(point) } }

    private func rubyHit(_ point: NSPoint) -> RubyHit? {
        guard let index = bands.lastIndex(where: { $0.rect.insetBy(dx: -4, dy: 0).contains(point) }) else { return nil }
        let band = bands[index]
        if band.editable {
            var best: (piece: Int, edge: LyricsDraft.RubyEdge, distance: CGFloat)?
            for (k, rect) in band.pieces.enumerated() {
                let reach = min(5, max(2, rect.width / 3))
                for (edge, x) in [(LyricsDraft.RubyEdge.start, rect.minX), (.end, rect.maxX)] {
                    let distance = abs(point.x - x)
                    if distance <= reach, distance < best?.distance ?? .infinity { best = (k, edge, distance) }
                }
            }
            if let best { return .edge(band: index, piece: best.piece, edge: best.edge) }
        }
        guard let piece = band.pieces.firstIndex(where: { point.x >= $0.minX && point.x <= $0.maxX }) else { return nil }
        return .piece(band: index, piece: piece)
    }

    private func syllableEdge(of band: RubyBand, piece: Int, edge: LyricsDraft.RubyEdge) -> (position: LyricsDraft.Position, part: LyricsTimelineAdjustment.Part)? {
        switch edge {
        case .start where piece == 0 && abs(band.times[0].start - band.base.lowerBound) < 0.002:
            return (.init(line: band.line, syllable: band.annotation.syllables.lowerBound), .start)
        case .end where piece == band.times.count - 1 && abs(band.times[piece].end - band.base.upperBound) < 0.002:
            return (.init(line: band.line, syllable: band.annotation.syllables.upperBound), .end)
        default:
            return nil
        }
    }

    private func syllable(at x: CGFloat, in band: RubyBand) -> LyricsDraft.Position {
        let s = blocks.last { $0.position.line == band.line && band.annotation.syllables.contains($0.position.syllable) && $0.rect.minX <= x && x <= $0.rect.maxX }?
            .position.syllable ?? band.annotation.syllables.lowerBound
        return .init(line: band.line, syllable: s)
    }

    private func beginDrag(_ edit: LyricsTimelineAdjustment, at point: NSPoint, snapping: Bool) {
        guard let c = configuration else { return }
        drag = Drag(edit: edit, origin: point.x, onsets: hints.map(\.time), snapping: snapping)
        c.viewport.interactionRange = c.range
        c.viewport.hold(c.range)
        c.session.caret = edit.position
        c.session.rubyPiece = nil
        needsDisplay = true
    }

    private func pressRuby(_ target: RubyHit, at point: NSPoint, event: NSEvent) -> Bool {
        guard let c = configuration else { return false }
        let snapping = !event.modifierFlags.contains(.option)
        switch target {
        case .edge(let index, let piece, let edge):
            let band = bands[index]
            if let outer = syllableEdge(of: band, piece: piece, edge: edge) {
                guard let edit = LyricsTimelineAdjustment(session: c.session, position: outer.position, part: outer.part,
                                                          range: c.range, width: bounds.width) else { return false }
                beginDrag(edit, at: point, snapping: snapping)
                c.session.rubyPiece = piece
                return true
            }
            guard let edit = LyricsTimelineRubyAdjustment(session: c.session, line: band.line, annotation: band.annotation, piece: piece,
                                                          edge: edge, range: c.range, width: bounds.width) else { return false }
            rubyDrag = RubyDrag(edit: edit, origin: point.x, onsets: hints.map(\.time), snapping: snapping)
            c.viewport.interactionRange = c.range
            c.viewport.hold(c.range)
            c.session.selectRuby(piece: piece, at: syllable(at: point.x, in: band))
            needsDisplay = true
            return true
        case .piece(let index, let piece):
            let band = bands[index]
            let position = syllable(at: point.x, in: band)
            if let block = hit(point), block.position.line == band.line,
               let edit = LyricsTimelineAdjustment(session: c.session, position: block.position, part: .body, range: c.range, width: bounds.width) {
                beginDrag(edit, at: point, snapping: snapping)
            } else {
                c.viewport.hold(c.range)
            }
            c.session.selectRuby(piece: piece, at: position)
            needsDisplay = true
            return true
        }
    }
    private func part(at point: NSPoint, in rect: NSRect) -> LyricsTimelineAdjustment.Part {
        let edge = min(7, rect.width / 3)
        if point.x < rect.minX + edge { return .start }
        if point.x > rect.maxX - edge { return .end }
        return .body
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = configuration else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= trayTop {
            guard let hit = trayHit(point) else { return }
            let item = tray[hit.item]
            let run = hit.syllable.map { $0..<($0 + 1) } ?? item.run
            guard let edit = LyricsTimelinePlacement(session: c.session, line: item.line, run: run, range: c.range, width: bounds.width) else { return }
            var edges = blocks.flatMap { [$0.syllable.start, $0.syllable.end].compactMap { $0 } }
            if c.canPlay { edges.append(c.clock.time) }
            placement = Placement(edit: edit, origin: point, snapping: !event.modifierFlags.contains(.option), edges: edges, onsets: hints.map(\.time))
            return
        }
        if !event.modifierFlags.contains(.command), let ruby = rubyHit(point), pressRuby(ruby, at: point, event: event) { return }
        if let block = hit(point), let edit = LyricsTimelineAdjustment(session: c.session, position: block.position,
                                                                       part: event.modifierFlags.contains(.command) ? .line : part(at: point, in: block.rect),
                                                                       range: c.range, width: bounds.width) {
            beginDrag(edit, at: point, snapping: !event.modifierFlags.contains(.option))
        } else if c.canPlay {
            scrubbing = true
            c.viewport.interactionRange = c.range
            scrub(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let snapping = !event.modifierFlags.contains(.option)
        if placement != nil { updatePlacement(at: point, snapping: snapping) }
        else if drag != nil { previewDrag(at: point, snapping: snapping) }
        else if rubyDrag != nil { previewRubyDrag(at: point, snapping: snapping) }
        else if scrubbing { scrub(at: point) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = configuration else { return }
        let point = convert(event.locationInWindow, from: nil)
        let snapping = !event.modifierFlags.contains(.option)
        if placement != nil {
            updatePlacement(at: point, snapping: snapping)
            guard let placement else { return }
            self.placement = nil
            setTargetLane(nil)
            setGuide(nil)
            if !placement.moved {
                if event.clickCount >= 2 { placeAtPlayhead(placement.edit) }
                else {
                    c.viewport.hold(c.range)
                    c.session.select(.init(line: placement.edit.line, syllable: placement.edit.run.lowerBound))
                }
            } else if let time = placement.time, placement.edit.commit(at: time, edges: placement.activeEdges, onsets: placement.activeOnsets,
                                                                        lane: placement.lane, in: c.session) {
                c.viewport.hold(c.range)
            }
        } else if let drag {
            self.drag = nil
            setTargetLane(nil)
            if drag.edit.part.lifts, point.y >= trayTop {
                if c.session.revision == drag.edit.revision {
                    drag.edit.part == .line ? c.session.stageLine(drag.edit.position.line) : c.session.stage([drag.edit.position])
                }
            } else {
                let lane = drag.edit.part == .line ? laneChange(forLine: drag.edit.position.line, at: point.y).change : .unchanged
                drag.edit.commit(translation: point.x - drag.origin, onsets: snapping ? drag.onsets : [], lane: lane, in: c.session)
            }
        } else if let rubyDrag {
            self.rubyDrag = nil
            setGuide(nil)
            rubyDrag.edit.commit(translation: point.x - rubyDrag.origin, onsets: snapping ? rubyDrag.onsets : [], in: c.session)
        } else if scrubbing {
            scrub(at: point)
            scrubbing = false
            c.clock.finishScrubbing { c.audio.seek(to: $0) }
        }
        c.viewport.interactionRange = nil
        rebuildBlocks()
    }

    private func scrub(at point: NSPoint) {
        guard let c = configuration, scale > 0 else { return }
        c.clock.scrub(to: c.range.lowerBound + Double(point.x / scale), duration: c.audio.duration, ranges: c.session.timedRanges)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = configuration, drag == nil, placement == nil, rubyDrag == nil, !scrubbing, scale > 0 else { return }
        let precise = event.hasPreciseScrollingDeltas
        if convert(event.locationInWindow, from: nil).y >= trayTop {
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            scrollTray(to: trayOffset - (precise ? delta : delta * 30))
            return
        }
        let range = c.range
        let span = range.upperBound - range.lowerBound
        let duration = LyricsTimelineViewport.duration(of: c.session, audio: c.audio)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) {
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0 else { return }
            let factor = precise ? exp(-Double(delta) * 0.01) : pow(0.85, Double(delta))
            c.viewport.zoom(range, by: factor, around: time(at: convert(event.locationInWindow, from: nil)), duration: duration)
            return
        }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard delta != 0 else { return }
        let seconds = precise ? -Double(delta / scale) : -Double(delta) * span * 0.1
        c.viewport.pan(range, by: seconds, duration: duration)
    }

    override func magnify(with event: NSEvent) {
        guard let c = configuration, drag == nil, placement == nil, rubyDrag == nil, !scrubbing, scale > 0, event.magnification > -1 else { return }
        c.viewport.zoom(c.range, by: 1 / (1 + event.magnification), around: time(at: convert(event.locationInWindow, from: nil)),
                        duration: LyricsTimelineViewport.duration(of: c.session, audio: c.audio))
    }

    private func time(at point: NSPoint) -> TimeInterval {
        guard let configuration, scale > 0 else { return 0 }
        return configuration.range.lowerBound + Double(point.x / scale)
    }

    override func cancelOperation(_ sender: Any?) { cancelInteraction() }
    private func cancelInteraction() {
        guard drag != nil || scrubbing || placement != nil || rubyDrag != nil else { return }
        drag = nil
        placement = nil
        rubyDrag = nil
        scrubbing = false
        targetLane = nil
        guide = nil
        configuration?.clock.cancelScrubbing()
        configuration?.viewport.interactionRange = nil
        rebuildBlocks()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= trayTop {
            if let hit = trayHit(point) {
                NSCursor.openHand.set()
                let item = tray[hit.item]
                if let s = hit.syllable {
                    toolTip = "「\(item.texts[s - item.run.lowerBound])」：拖到时间轴上单独放置，双击放到播放头"
                } else {
                    toolTip = "第 \(item.line + 1) 行的 \(item.run.count) 个音节：拖到时间轴上一起放置，双击放到播放头；拖到别的轨道会换轨"
                }
            } else {
                NSCursor.arrow.set()
                toolTip = "暂存区：没打点的音节在这里，拖到时间轴上放置；时间轴上的字块拖到这里可以暂时移出，再放回时保留原来的长度"
            }
        } else if let ruby = rubyHit(point) {
            let (band, piece, onEdge): (RubyBand, Int, Bool) = switch ruby {
            case .edge(let index, let piece, _): (bands[index], piece, true)
            case .piece(let index, let piece): (bands[index], piece, false)
            }
            (onEdge ? NSCursor.resizeLeftRight : NSCursor.openHand).set()
            let time = band.times[piece]
            var tip = "注音「\(time.text.trimmingCharacters(in: .whitespaces))」\(LyricsEditorFormat.time(time.start, digits: 3)) – \(LyricsEditorFormat.time(time.end, digits: 3))"
            if !band.timed { tip += "（按字数平分，还没有单独打轴）" }
            tip += band.editable
                ? "\n拖动注音之间的分隔线调整边界，按住 Option 跳过吸附；点按选中这一段，可在右下角输入时间"
                : "\n音节还没有结束时间：先打上结束时间，再调整注音"
            toolTip = tip
        } else if let block = hit(point) {
            (part(at: point, in: block.rect) == .body ? NSCursor.openHand : NSCursor.resizeLeftRight).set()
            toolTip = "\(LyricsEditorFormat.time(block.syllable.start, digits: 3)) – \(LyricsEditorFormat.time(block.syllable.end, digits: 3))\n⌘ 拖动整行，可上下换轨；拖到下方暂存区移出时间轴"
            if !block.reviewNotes.isEmpty { toolTip = "AI 待核对\n" + block.reviewNotes.joined(separator: "\n") + "\n\n" + (toolTip ?? "") }
        } else {
            NSCursor.iBeam.set()
            if let hint = hints.min(by: { abs(x($0.time) - point.x) < abs(x($1.time) - point.x) }), abs(x(hint.time) - point.x) <= 5 {
                toolTip = "疑似起字点 \(LyricsEditorFormat.time(hint.time, digits: 3)) · 拖动边界可吸附，按住 Option 跳过提示吸附"
            } else { toolTip = "拖动或点按跳转；滚动平移，⌘ 滚动或捏合缩放" }
        }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    private func rebuildAccessibility() {
        accessible = blocks.map { block in
            LyricsEditorActionElement(host: self,
                                      label: "\(block.syllable.text)，\(LyricsEditorFormat.time(block.syllable.start, digits: 3)) 至 \(LyricsEditorFormat.time(block.syllable.end, digits: 3))"
                                        + (block.reviewNotes.isEmpty ? "" : "，AI 待核对，" + block.reviewNotes.joined(separator: "；")),
                                      rect: block.rect) { [weak self] in
                guard let c = self?.configuration else { return }
                c.viewport.hold(c.range)
                c.session.caret = block.position
            }
        }
        for band in bands {
            for (k, time) in band.times.enumerated() {
                let position = LyricsDraft.Position(line: band.line, syllable: band.annotation.syllables.lowerBound)
                accessible.append(LyricsEditorActionElement(host: self, label: "注音「\(time.text.trimmingCharacters(in: .whitespaces))」，\(LyricsEditorFormat.time(time.start, digits: 3)) 至 \(LyricsEditorFormat.time(time.end, digits: 3))",
                                                            rect: band.pieces[k]) { [weak self] in
                    guard let c = self?.configuration else { return }
                    c.viewport.hold(c.range)
                    c.session.selectRuby(piece: k, at: position)
                })
            }
        }
        let visible = NSRect(x: Self.trayLeading, y: trayTop, width: max(bounds.width - Self.trayLeading, 0), height: Self.trayHeight)
        for item in tray where trayFrame(item.rect).intersects(visible) {
            accessible.append(LyricsEditorActionElement(host: self, label: "暂存区，第 \(item.line + 1) 行：\(item.texts.joined(separator: " "))",
                                                        rect: trayFrame(item.rect)) { [weak self] in
                guard let c = self?.configuration else { return }
                c.viewport.hold(c.range)
                c.session.select(.init(line: item.line, syllable: item.run.lowerBound))
            })
        }
    }
    override func accessibilityChildren() -> [Any]? { accessible }
}
