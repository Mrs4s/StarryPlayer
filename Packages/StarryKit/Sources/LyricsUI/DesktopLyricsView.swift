import AppKit
import LyricsCore
import QuartzCore

/// Call `sync()` on play, pause and seek, and now and then for drift.
@MainActor
public final class DesktopLyricsView: NSView {
    public typealias Content = MenuBarLyricsView.Content

    public struct Style: Equatable {
        public var fontSize: CGFloat = 30
        public var litColor: NSColor = .white
        public var unlitColor: NSColor = NSColor(white: 1, alpha: 0.5)
        public var translationColor: NSColor = NSColor(white: 1, alpha: 0.85)
        public var perSyllable = true
        public var showsTranslation = true
        public var showsCard = false
        public init() {}

        var colorsOnly: Style {
            var style = self
            style.litColor = .clear
            style.unlitColor = .clear
            style.translationColor = .clear
            return style
        }
    }

    public struct Metrics: Equatable {
        public var font: NSFont
        public var translationFont: NSFont
        public var rowHeight: CGFloat
        public var translationRowHeight: CGFloat
        public var gap: CGFloat
        public var inset: CGSize

        public init(fontSize: CGFloat) {
            let size = min(max(fontSize, 10), 120)
            font = .systemFont(ofSize: size, weight: .semibold)
            translationFont = .systemFont(ofSize: max((size * 0.6).rounded(), 11), weight: .medium)
            rowHeight = ceil((font.ascender - font.descender) * 1.2)
            translationRowHeight = ceil((translationFont.ascender - translationFont.descender) * 1.2)
            gap = (size * 0.12).rounded()
            inset = CGSize(width: (size * 0.6).rounded(), height: (size * 0.2).rounded())
        }

        public func height(showsTranslation: Bool) -> CGFloat {
            (showsTranslation ? rowHeight + gap + translationRowHeight : rowHeight) + inset.height * 2
        }

        func outline(for font: NSFont) -> TextOutline {
            TextOutline(color: CGColor(gray: 0, alpha: 0.7), width: max(1, (font.pointSize * 0.05 * 2).rounded() / 2),
                        shadowColor: CGColor(gray: 0, alpha: 0.45), shadowRadius: (font.pointSize * 0.12).rounded())
        }
    }

    public var content = Content() {
        didSet { if content != oldValue { contentChanged(from: oldValue) } }
    }

    public var style = Style() {
        didSet { if style != oldValue { styleChanged(from: oldValue) } }
    }

    /// Seconds added to the player time before lyrics are resolved (positive = lyrics earlier).
    public var timeOffset: TimeInterval = 0 {
        didSet { if timeOffset != oldValue { sync() } }
    }

    public var timeSource: (() -> (time: TimeInterval, rate: Double))?

    public var isSuspended = false {
        didSet { if isSuspended != oldValue { suspensionChanged() } }
    }

    public private(set) var metrics = Metrics(fontSize: 30)
    public private(set) var displayedText = ""
    public private(set) var displayedTranslation = ""

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        root.frame = bounds
        stage.frame = bounds
        card.backgroundColor = CGColor(gray: 0, alpha: 0.38)
        card.opacity = 0
        root.addSublayer(card)
        root.addSublayer(stage)
        layer?.addSublayer(root)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        root.frame = bounds
        stage.frame = bounds
        scheduleRestyle()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleRestyle()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer.cancel()
            anchor = nil
        } else {
            scheduleRestyle()
        }
    }

    public func sync() {
        guard !isSuspended, let clock = timeSource?(), window != nil else { return }
        let now = CACurrentMediaTime()
        let t = clock.time + timeOffset
        let rate = max(clock.rate, 0)
        let jumped = anchor.map { rate != $0.rate || abs($0.time + (now - $0.host) * $0.rate - t) > 0.08 } ?? true
        anchor = (t, now, rate)
        let item = timeline?.item(at: t) ?? .idle
        if item != shown?.item || needsRebuild {
            show(item, at: t, rate: rate, now: now)
        } else if jumped {
            shown?.main.play(at: t, rate: rate, now: now)
            shown?.translation?.play(at: t, rate: rate, now: now)
        }
        setPaused(rate == 0)
        timer.schedule(timeline?.nextChange(after: t), from: t, rate: rate, keepIfSame: !jumped) { [weak self] in self?.sync() }
    }

    private let root = NoAnimationLayer()
    /// Moves to fit the text when the line changes (an implicit animation).
    private let card = CALayer()
    private let stage = NoAnimationLayer()
    private var shown: (item: CompactLyricsTimeline.Item, main: MenuBarSlotLayer, translation: MenuBarSlotLayer?)?
    var mainSlot: MenuBarSlotLayer? { shown?.main }
    var translationSlot: MenuBarSlotLayer? { shown?.translation }
    var cardLayer: CALayer { card }
    var changeTimer: LyricsChangeTimer { timer }
    private var timeline: CompactLyricsTimeline?
    // Reserve this row for the whole song so untranslated lines do not shift vertically.
    private var hasTranslationRow = false
    private var anchor: (time: TimeInterval, host: CFTimeInterval, rate: Double)?
    private let timer = LyricsChangeTimer()
    private var needsRebuild = false
    private var restyleScheduled = false
    private(set) var isPaused = false

    private var renderScale: CGFloat { window?.backingScaleFactor ?? 2 }
    // Match the window's color space to avoid Core Animation keeping a converted copy.
    private var renderColorSpace: CGColorSpace { window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)! }

    private func contentChanged(from old: Content) {
        if content.document != old.document || content.duration != old.duration {
            timeline = content.document.map { CompactLyricsTimeline(document: $0, duration: content.duration > 0 ? content.duration : nil) }
            updateTranslationRow()
        }
        needsRebuild = true
        sync()
    }

    private func styleChanged(from old: Style) {
        if style.fontSize != old.fontSize { metrics = Metrics(fontSize: style.fontSize) }
        if style.showsTranslation != old.showsTranslation { updateTranslationRow() }
        if style.colorsOnly == old.colorsOnly {
            recolor()
            return
        }
        needsRebuild = true
        sync()
    }

    private func updateTranslationRow() {
        hasTranslationRow = style.showsTranslation && content.document?.hasTranslation == true
    }

    private func suspensionChanged() {
        if isSuspended {
            timer.cancel()
            anchor = nil
            if let shown, let clock = timeSource?() {
                let t = clock.time + timeOffset
                let now = CACurrentMediaTime()
                shown.main.play(at: t, rate: 0, now: now)
                shown.translation?.play(at: t, rate: 0, now: now)
            }
        } else {
            sync()
        }
    }

    /// Defer rebuilding until the window's layout finishes, so a resize is laid out once.
    private func scheduleRestyle() {
        needsRebuild = true
        guard !restyleScheduled else { return }
        restyleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restyleScheduled = false
            self.sync()
        }
    }

    private func show(_ item: CompactLyricsTimeline.Item, at t: TimeInterval, rate: Double, now: CFTimeInterval) {
        needsRebuild = false
        let (main, translation) = makeSlots(for: item)
        stage.sublayers = [main] + (translation.map { [$0] } ?? [])
        shown = (item, main, translation)
        layOut()
        main.play(at: t, rate: rate, now: now)
        translation?.play(at: t, rate: rate, now: now)
        displayedText = main.text
        displayedTranslation = translation?.text ?? ""
    }

    private func makeSlots(for item: CompactLyricsTimeline.Item) -> (MenuBarSlotLayer, MenuBarSlotLayer?) {
        let main = MenuBarSlotLayer()
        let scale = renderScale
        let space = renderColorSpace
        let m = metrics
        let width = max(bounds.width - m.inset.width * 2, 40)
        let mainStyle = MenuBarSlotLayer.Style(color: style.litColor.cgColor, unsungColor: style.unlitColor.cgColor, outline: m.outline(for: m.font), baselineShift: 0)
        switch item {
        case .line(let index):
            guard let document = content.document, index < document.lines.count else { return (main, nil) }
            let line = document.lines[index]
            main.configure(line: MenuBarLyricsView.singleRow(line), font: m.font, perSyllable: style.perSyllable, maxWidth: width, height: m.rowHeight, scale: scale, colorSpace: space, style: mainStyle)
            guard hasTranslationRow, let text = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return (main, nil) }
            let translation = MenuBarSlotLayer()
            let plain = MenuBarLyricsView.singleRow(.plain(id: line.id, start: line.start, end: line.end, text: text))
            translation.configure(line: plain, font: m.translationFont, perSyllable: false, maxWidth: width, height: m.translationRowHeight, scale: scale, colorSpace: space,
                                  style: .init(color: style.translationColor.cgColor, outline: m.outline(for: m.translationFont), baselineShift: 0))
            return (main, translation)
        case .idle:
            main.configure(title: content.title, artist: content.artist, font: m.font, maxWidth: width, height: m.rowHeight, scale: scale, colorSpace: space, style: mainStyle)
            return (main, nil)
        }
    }

    private func layOut() {
        guard let shown else { return }
        let m = metrics
        let rowsHeight = hasTranslationRow ? m.rowHeight + m.gap + m.translationRowHeight : m.rowHeight
        let top = ((bounds.height - rowsHeight) / 2).rounded()
        func centred(_ slot: MenuBarSlotLayer, y: CGFloat, height: CGFloat) {
            slot.frame = CGRect(x: ((bounds.width - slot.visibleWidth) / 2).rounded(), y: y, width: slot.visibleWidth, height: height)
        }
        centred(shown.main, y: top, height: m.rowHeight)
        if let translation = shown.translation {
            centred(translation, y: top + m.rowHeight + m.gap, height: m.translationRowHeight)
        }
        updateCard()
    }

    private func updateCard() {
        let m = metrics
        let lit = [shown?.main, shown?.translation].compactMap { $0 }.filter { !$0.text.isEmpty }
        guard style.showsCard, let first = lit.first else {
            card.opacity = 0
            return
        }
        let text = lit.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let frame = text.insetBy(dx: -m.inset.width, dy: -m.inset.height)
        CATransaction.begin()
        // From nothing it appears where the text is rather than growing out of a corner.
        CATransaction.setDisableActions(card.opacity == 0)
        card.frame = frame
        card.cornerRadius = min((m.font.pointSize * 0.4).rounded(), frame.height / 2)
        card.opacity = 1
        CATransaction.commit()
    }

    private func recolor() {
        guard let shown else { return }
        shown.main.setColor(style.litColor.cgColor, unsung: style.unlitColor.cgColor)
        shown.translation?.setColor(style.translationColor.cgColor)
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        let target: Float = paused ? MenuBarLyricsView.pausedOpacity : 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = (root.presentation() ?? root).opacity
        animation.toValue = target
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.opacity = target
        root.add(animation, forKey: "opacity")
    }
}
