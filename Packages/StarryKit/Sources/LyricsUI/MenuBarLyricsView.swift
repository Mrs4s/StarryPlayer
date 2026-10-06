import AppKit
import CoreText
import LyricsCore
import QuartzCore

/// Syllable-highlighted menu bar lyrics using clock-aligned Core Animation keyframes.
/// Call `sync()` on playback changes and periodically for drift; width changes use
/// `onPreferredWidthChange`.
@MainActor
public final class MenuBarLyricsView: NSView {
    public struct Content: Equatable, Sendable {
        /// nil shows the song throughout.
        public var document: LyricsDocument?
        public var duration: TimeInterval
        public var title: String
        public var artist: String

        public init(document: LyricsDocument? = nil, duration: TimeInterval = 0, title: String = "", artist: String = "") {
            self.document = document
            self.duration = duration
            self.title = title
            self.artist = artist
        }
    }

    public var content = Content() {
        didSet { if content != oldValue { contentChanged(from: oldValue) } }
    }

    public var perSyllable = true {
        didSet { if perSyllable != oldValue { restyle() } }
    }

    public var maxTextWidth: CGFloat = 300 {
        didSet { if maxTextWidth != oldValue { restyle() } }
    }

    public var font: NSFont = .menuBarFont(ofSize: 0) {
        didSet { if font != oldValue { restyle() } }
    }

    /// The text's colour; nil follows the appearance (`labelColor`, the menu bar's).
    public var textColor: NSColor? {
        didSet { if textColor != oldValue { shown?.slot.setColor(labelColor) } }
    }

    /// Seconds added to the player time before lyrics are resolved (positive = lyrics earlier).
    public var timeOffset: TimeInterval = 0 {
        didSet { if timeOffset != oldValue { sync() } }
    }

    public var timeSource: (() -> (time: TimeInterval, rate: Double))?

    public private(set) var preferredWidth: CGFloat = 0
    public var onPreferredWidthChange: ((CGFloat) -> Void)?

    public private(set) var displayedText = ""
    public var onDisplayedTextChange: ((String) -> Void)?

    /// Space on either side of the text, inside the view: what is left of `titleInset` after the
    /// room the status item's window already keeps around its button (8 pt on macOS 26 for an
    /// item of a set length, none before).
    public private(set) var horizontalPadding: CGFloat = MenuBarLyricsView.titleInset
    public static let titleInset: CGFloat = 10
    public static let pausedOpacity: Float = 0.55

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        clip.masksToBounds = true
        layer?.addSublayer(clip)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateClip()
    }

    public override func layout() {
        super.layout()
        updateClip()
    }

    private func updateClip() {
        let outer = window == nil ? 0 : max(convert(NSPoint.zero, to: nil).x, 0)
        let padding = max(Self.titleInset - outer, 2)
        let paddingChanged = padding != horizontalPadding
        horizontalPadding = padding
        let frame = bounds.insetBy(dx: horizontalPadding, dy: 0)
        guard clip.frame != frame else { return }
        let heightChanged = clip.frame.height != frame.height
        clip.frame = frame
        shown?.slot.frame = clip.bounds
        if heightChanged || paddingChanged, shown != nil { scheduleRestyle() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleRestyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shown?.slot.setColor(labelColor)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer.cancel()
        } else {
            updateClip()
            scheduleRestyle()
        }
    }

    public func sync() {
        guard let clock = timeSource?(), window != nil else { return }
        let now = CACurrentMediaTime()
        let t = clock.time + timeOffset
        let rate = max(clock.rate, 0)
        let jumped = anchor.map { rate != $0.rate || abs($0.time + (now - $0.host) * $0.rate - t) > 0.08 } ?? true
        anchor = (t, now, rate)
        let item = timeline?.item(at: t) ?? .idle
        if item != shown?.item || needsRebuild {
            show(item, at: t, rate: rate, now: now)
        } else if jumped {
            shown?.slot.play(at: t, rate: rate, now: now)
        }
        setPaused(rate == 0)
        timer.schedule(timeline?.nextChange(after: t), from: t, rate: rate, keepIfSame: !jumped) { [weak self] in self?.sync() }
    }

    private let clip = NoAnimationLayer()
    private var shown: (item: CompactLyricsTimeline.Item, slot: MenuBarSlotLayer)?
    var currentSlot: MenuBarSlotLayer? { shown?.slot }
    var slotCount: Int { clip.sublayers?.count ?? 0 }
    private var timeline: CompactLyricsTimeline?
    private var anchor: (time: TimeInterval, host: CFTimeInterval, rate: Double)?
    private let timer = LyricsChangeTimer()
    private var needsRebuild = false
    private var restyleScheduled = false
    private var isPaused = false

    private var renderScale: CGFloat { window?.backingScaleFactor ?? 2 }
    /// The status window's space, so Core Animation shows the text images without a converted
    /// copy (see `LineTextLayout.renderRow`).
    private var renderColorSpace: CGColorSpace { window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)! }

    private var labelColor: CGColor {
        var color = CGColor(gray: 0, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance { color = (textColor ?? NSColor.labelColor).cgColor }
        return color
    }

    private func contentChanged(from old: Content) {
        if content.document != old.document || content.duration != old.duration {
            timeline = content.document.map { CompactLyricsTimeline(document: $0, duration: content.duration > 0 ? content.duration : nil) }
        }
        needsRebuild = true
        sync()
    }

    private func restyle() {
        needsRebuild = true
        sync()
    }

    /// Defer rebuilding until NSStatusItem's window layout finishes to avoid reentrant layout.
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
        let slot = makeSlot(for: item)
        slot.frame = clip.bounds
        if let old = shown?.slot { clip.replaceSublayer(old, with: slot) } else { clip.addSublayer(slot) }
        slot.play(at: t, rate: rate, now: now)
        shown = (item, slot)
        let width = slot.text.isEmpty ? 0 : ceil(slot.visibleWidth) + horizontalPadding * 2
        let textChanged = displayedText != slot.text
        let widthChanged = preferredWidth != width
        // Publish both properties before callbacks, which may read them together.
        displayedText = slot.text
        preferredWidth = width
        if textChanged { onDisplayedTextChange?(slot.text) }
        if widthChanged { onPreferredWidthChange?(width) }
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        let target: Float = paused ? Self.pausedOpacity : 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = (clip.presentation() ?? clip).opacity
        animation.toValue = target
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        clip.opacity = target
        clip.add(animation, forKey: "opacity")
    }

    private func makeSlot(for item: CompactLyricsTimeline.Item) -> MenuBarSlotLayer {
        let slot = MenuBarSlotLayer()
        let scale = renderScale
        let space = renderColorSpace
        let height = clip.bounds.height
        switch item {
        case .line(let index):
            guard let document = content.document, index < document.lines.count else { break }
            slot.configure(line: Self.singleRow(document.lines[index]), font: font, perSyllable: perSyllable, maxWidth: maxTextWidth, height: height, scale: scale, colorSpace: space, style: .init(color: labelColor))
        case .idle:
            slot.configure(title: content.title, artist: content.artist, font: font, maxWidth: maxTextWidth, height: height, scale: scale, colorSpace: space, style: .init(color: labelColor))
        }
        return slot
    }

    /// The line with any line breaks as spaces, so it lays out as one row.
    static func singleRow(_ line: LyricLine) -> LyricLine {
        guard line.text.contains(where: \.isNewline) else { return line }
        var line = line
        func flatten(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        line.words = line.words.map { word in
            var word = word
            word.text = flatten(word.text)
            word.syllables = word.syllables.map { LyricSyllable(start: $0.start, end: $0.end, text: flatten($0.text)) }
            return word
        }
        return line
    }
}

struct MenuBarTrack: Equatable {
    struct Key: Equatable {
        var time: TimeInterval
        var value: CGFloat
    }

    var keys: [Key]

    static func constant(_ value: CGFloat) -> MenuBarTrack { MenuBarTrack(keys: [Key(time: 0, value: value)]) }

    func value(at t: TimeInterval) -> CGFloat {
        guard let first = keys.first else { return 0 }
        if t <= first.time { return first.value }
        for (a, b) in zip(keys, keys.dropFirst()) where t < b.time {
            guard b.time > a.time else { continue }
            return a.value + (b.value - a.value) * CGFloat((t - a.time) / (b.time - a.time))
        }
        return keys[keys.count - 1].value
    }

    var isConstant: Bool { Set(keys.map(\.value)).count <= 1 }

    static func edge(steps: [RowLayer.Step], startEdge: CGFloat, headstart: TimeInterval) -> MenuBarTrack {
        guard let first = steps.first else { return .constant(startEdge) }
        var keys = [Key(time: first.start - headstart, value: startEdge)]
        var previous = startEdge
        for step in steps {
            let start = max(step.start - headstart, keys[keys.count - 1].time)
            let end = max(step.end - headstart, start)
            keys.append(Key(time: start, value: previous))
            keys.append(Key(time: end, value: step.target))
            previous = step.target
        }
        return MenuBarTrack(keys: keys)
    }

    /// `clamp((value − offset) · factor, 0, 1…)`: each value mapped through a clamped line, with
    /// keys added where the clamp starts or stops biting, so the result is exact between keys.
    func clamped(offset: CGFloat, factor: CGFloat = 1, range: ClosedRange<CGFloat>) -> MenuBarTrack {
        func map(_ v: CGFloat) -> CGFloat { min(max((v - offset) * factor, range.lowerBound), range.upperBound) }
        let bounds = [range.lowerBound / factor + offset, range.upperBound / factor + offset]
        guard let first = keys.first else { return self }
        var result = [Key(time: first.time, value: map(first.value))]
        for (a, b) in zip(keys, keys.dropFirst()) {
            if b.value != a.value {
                let crossings = bounds.compactMap { bound -> TimeInterval? in
                    let p = (bound - a.value) / (b.value - a.value)
                    return p > 0 && p < 1 ? a.time + (b.time - a.time) * Double(p) : nil
                }.sorted()
                for time in crossings {
                    result.append(Key(time: time, value: map(a.value + (b.value - a.value) * CGFloat((time - a.time) / max(b.time - a.time, 1e-9)))))
                }
            }
            result.append(Key(time: b.time, value: map(b.value)))
        }
        return MenuBarTrack(keys: result)
    }

    /// Lays the track on `layer.keyPath` for lyric time `t` at host time `now`: a keyframe
    /// animation while the clock runs and the track still changes, the value at `t` otherwise.
    func play(on layer: CALayer, keyPath: String, at t: TimeInterval, rate: Double, now: CFTimeInterval, transform: (CGFloat) -> Any) {
        layer.removeAnimation(forKey: keyPath)
        guard let first = keys.first, let last = keys.last, rate > 0, t < last.time, last.time > first.time, !isConstant else {
            layer.setValue(transform(value(at: t)), forKeyPath: keyPath)
            return
        }
        let span = last.time - first.time
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = keys.map { transform($0.value) }
        animation.keyTimes = keys.map { NSNumber(value: ($0.time - first.time) / span) }
        animation.calculationMode = .linear
        animation.duration = span / rate
        animation.beginTime = layer.convertTime(now, from: nil) + (first.time - t) / rate
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        layer.setValue(transform(last.value), forKeyPath: keyPath)
        layer.add(animation, forKey: keyPath)
    }
}

final class MenuBarSlotLayer: NoAnimationLayer {
    /// Opacity of the part of a line not sung yet.
    static let unsungOpacity: Float = 0.38
    static let readingPosition: CGFloat = 0.65
    static let fadeWidth: CGFloat = 12
    static let imagePadding: CGFloat = 2

    struct Style: Equatable {
        var color: CGColor
        /// The part not sung yet; nil uses `color` at `unsungOpacity`.
        var unsungColor: CGColor?
        var outline: TextOutline?
        /// Points the baseline sits off the middle (−1 matches `NSStatusBarButton`'s).
        var baselineShift: CGFloat = -1
    }

    private(set) var text = ""
    private(set) var textWidth: CGFloat = 0
    private(set) var visibleWidth: CGFloat = 0
    private(set) var edgeTrack = MenuBarTrack.constant(0)
    private(set) var scrollTrack = MenuBarTrack.constant(0)
    private(set) var feather: CGFloat = 8
    var isTimed: Bool { progress.superlayer != nil }

    let line = NoAnimationLayer()
    private let glyphs = NoAnimationLayer()
    let unsung = NoAnimationLayer()
    let progress = NoAnimationLayer()
    private let fill = NoAnimationLayer()
    private let edgeGradient = NoAnimationGradientLayer()
    let outline = NoAnimationLayer()
    private(set) var outlineInset: CGFloat = 0
    private let fadeMask = NoAnimationLayer()
    let leftCover = NoAnimationLayer()
    let rightCover = NoAnimationLayer()
    private var leftCoverTrack = MenuBarTrack.constant(1)
    private var rightCoverTrack = MenuBarTrack.constant(1)

    override init() {
        super.init()
        line.anchorPoint = .zero
        glyphs.anchorPoint = .zero
        glyphs.contentsGravity = .resize
        line.mask = glyphs
        line.addSublayer(unsung)
        progress.anchorPoint = CGPoint(x: 1, y: 0)
        progress.addSublayer(fill)
        edgeGradient.startPoint = CGPoint(x: 0, y: 0.5)
        edgeGradient.endPoint = CGPoint(x: 1, y: 0.5)
        progress.addSublayer(edgeGradient)
        outline.anchorPoint = .zero
        outline.contentsGravity = .resize
        addSublayer(line)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    func configure(line lyric: LyricLine, font: NSFont, perSyllable: Bool, maxWidth: CGFloat, height: CGFloat, scale: CGFloat, colorSpace: CGColorSpace, style: Style) {
        text = lyric.text.trimmingCharacters(in: .whitespaces)
        let layout = LineTextLayout.layout(line: lyric, font: font, width: 100_000, leading: nil, alignment: .left, perSyllable: true)
        guard let row = layout.rows.first, let image = LineTextLayout.renderRow(row, width: row.width, color: CGColor(gray: 1, alpha: 1), scale: scale, colorSpace: colorSpace, padding: Self.imagePadding) else { return }
        let outlineImage = style.outline.flatMap { LineTextLayout.renderRow(row, width: row.width, color: $0.color, scale: scale, colorSpace: colorSpace, padding: $0.extent, outline: $0) }
        feather = (font.pointSize * 30 / 48).rounded()
        textWidth = row.width
        visibleWidth = min(row.width, maxWidth)
        place(image: image, outline: outlineImage, ascent: row.ascent, descent: row.descent, height: height, scale: scale, baselineShift: style.baselineShift)

        let timed = perSyllable && lyric.hasSyllableTiming
        let finalEdge = row.fragments.map(\.inkMaxX).max() ?? row.width
        if timed {
            var wordOfSyllable: [Int] = []
            var lastSyllableOfWord: [Int] = []
            for (w, word) in lyric.words.enumerated() {
                wordOfSyllable.append(contentsOf: repeatElement(w, count: word.syllables.count))
                lastSyllableOfWord.append(wordOfSyllable.count - 1)
            }
            let steps = VoiceLayer.progressSteps(row: row, syllables: lyric.syllables, words: lyric.words, wordOfSyllable: wordOfSyllable, lastSyllableOfWord: lastSyllableOfWord, feather: feather)
            edgeTrack = MenuBarTrack.edge(steps: steps, startEdge: -feather, headstart: LyricsSpecs.windowed.animationHeadstart)
            line.addSublayer(progress)
        } else {
            edgeTrack = .constant(finalEdge)
        }
        setColor(style.color, unsung: style.unsungColor)

        // Long lines scroll so the lit part stays in view: the reading point follows the edge
        // (a steady sweep over the line's time when it has no syllable timing).
        let overflow = textWidth - visibleWidth
        guard overflow > 0.5 else { return }
        let reading: MenuBarTrack
        if timed {
            reading = MenuBarTrack(keys: edgeTrack.keys.map { .init(time: $0.time, value: $0.value + feather / 2) })
        } else {
            let hold = min(1, lyric.duration * 0.15)
            reading = MenuBarTrack(keys: [.init(time: lyric.start, value: 0), .init(time: max(lyric.end - hold, lyric.start + 0.5), value: textWidth)])
        }
        scrollTrack = reading.clamped(offset: visibleWidth * Self.readingPosition, range: 0...overflow)
        installFades(overflow: overflow, height: height)
    }

    func configure(title: String, artist: String, font: NSFont, maxWidth: CGFloat, height: CGFloat, scale: CGFloat, colorSpace: CGColorSpace, style: Style) {
        text = artist.isEmpty ? title : "\(title) - \(artist)"
        guard !title.isEmpty else { return }
        let attributed = NSMutableAttributedString(string: title, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        if !artist.isEmpty {
            attributed.append(NSAttributedString(string: " - \(artist)", attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.55),
            ]))
        }
        var ctLine = CTLineCreateWithAttributedString(attributed)
        if CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)) > maxWidth {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
            ctLine = CTLineCreateTruncatedLine(ctLine, Double(maxWidth), .end, token) ?? ctLine
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)) - CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine))
        ascent = max(ascent, font.ascender)
        descent = max(descent, -font.descender)
        func render(padding: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
            let pixelWidth = Int(ceil((width + padding * 2) * scale))
            let pixelHeight = Int(ceil((ascent + descent + padding * 2) * scale))
            guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 16384,
                  let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
            context.scaleBy(x: scale, y: scale)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.textPosition = CGPoint(x: padding, y: descent + padding)
            draw(context)
            return context.makeImage()
        }
        guard let image = render(padding: Self.imagePadding, draw: { CTLineDraw(ctLine, $0) }) else { return }
        let outlineImage = style.outline.flatMap { outline in
            render(padding: outline.extent) { context in
                outline.draw(in: context, scale: scale) {
                    LineTextLayout.drawGlyphs(of: ctLine, at: CGPoint(x: outline.extent, y: descent + outline.extent), in: context)
                }
            }
        }
        textWidth = width
        visibleWidth = min(width, maxWidth)
        place(image: image, outline: outlineImage, ascent: ascent, descent: descent, height: height, scale: scale, baselineShift: style.baselineShift)
        edgeTrack = .constant(width)
        setColor(style.color, unsung: style.unsungColor)
    }

    private func place(image: CGImage, outline outlineImage: CGImage?, ascent: CGFloat, descent: CGFloat, height: CGFloat, scale: CGFloat, baselineShift: CGFloat) {
        let padding = Self.imagePadding
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        line.bounds = CGRect(origin: .zero, size: size)
        // Centre the text, shifted for the status bar's baseline, on whole pixels so it stays sharp.
        let baseline = ((height - ceil(ascent + descent)) / 2).rounded(.down) + baselineShift + ascent
        let top = ((baseline - (size.height - descent - padding)) * scale).rounded() / scale
        line.position = CGPoint(x: -padding, y: top)
        glyphs.frame = line.bounds
        glyphs.contents = image
        glyphs.contentsScale = scale
        unsung.frame = line.bounds
        let length = size.width + feather
        progress.bounds = CGRect(x: 0, y: 0, width: length, height: size.height)
        fill.frame = CGRect(x: 0, y: 0, width: length - feather, height: size.height)
        edgeGradient.frame = CGRect(x: length - feather, y: 0, width: feather, height: size.height)
        progress.position = CGPoint(x: padding, y: 0)
        if let outlineImage {
            // Its padding is a whole number of points larger, so it stays on the same pixels.
            outlineInset = (CGFloat(outlineImage.height) / scale - size.height) / 2
            outline.bounds = CGRect(x: 0, y: 0, width: CGFloat(outlineImage.width) / scale, height: CGFloat(outlineImage.height) / scale)
            outline.position = CGPoint(x: line.position.x - outlineInset, y: top - outlineInset)
            outline.contents = outlineImage
            outline.contentsScale = scale
            insertSublayer(outline, below: line)
        }
    }

    private func installFades(overflow: CGFloat, height: CGFloat) {
        let fade = Self.fadeWidth
        let width = visibleWidth
        // Tall enough for the outline's shadow above and below the row.
        let reach = outline.superlayer != nil ? outlineInset : 0
        let height = height + reach * 2
        fadeMask.frame = CGRect(x: 0, y: -reach, width: width, height: height)
        let middle = NoAnimationLayer()
        middle.backgroundColor = CGColor(gray: 0, alpha: 1)
        middle.frame = CGRect(x: fade, y: 0, width: max(width - fade * 2, 0), height: height)
        let left = NoAnimationGradientLayer()
        left.startPoint = CGPoint(x: 0, y: 0.5)
        left.endPoint = CGPoint(x: 1, y: 0.5)
        left.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
        left.frame = CGRect(x: 0, y: 0, width: fade, height: height)
        let right = NoAnimationGradientLayer()
        right.startPoint = CGPoint(x: 0, y: 0.5)
        right.endPoint = CGPoint(x: 1, y: 0.5)
        right.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        right.frame = CGRect(x: width - fade, y: 0, width: fade, height: height)
        for cover in [leftCover, rightCover] { cover.backgroundColor = CGColor(gray: 0, alpha: 1) }
        leftCover.frame = left.frame
        rightCover.frame = right.frame
        fadeMask.sublayers = [middle, left, right, leftCover, rightCover]
        mask = fadeMask
        leftCoverTrack = scrollTrack.clamped(offset: 0, factor: 1 / fade, range: 0...1).inverted
        rightCoverTrack = scrollTrack.clamped(offset: overflow - fade, factor: 1 / fade, range: 0...1)
    }

    func setColor(_ color: CGColor, unsung unsungColor: CGColor? = nil) {
        let timed = isTimed
        unsung.backgroundColor = timed ? unsungColor ?? color : color
        unsung.opacity = timed && unsungColor == nil ? Self.unsungOpacity : 1
        fill.backgroundColor = color
        edgeGradient.colors = [color, color.copy(alpha: 0) ?? CGColor.clear]
    }

    func play(at t: TimeInterval, rate: Double, now: CFTimeInterval) {
        let padding = Self.imagePadding
        let feather = feather
        if isTimed {
            edgeTrack.play(on: progress, keyPath: "position.x", at: t, rate: rate, now: now) { $0 + feather + padding }
        }
        let y = line.position.y
        scrollTrack.play(on: line, keyPath: "position", at: t, rate: rate, now: now) { NSValue(point: CGPoint(x: -padding - $0, y: y)) }
        if outline.superlayer != nil {
            let inset = outlineInset
            scrollTrack.play(on: outline, keyPath: "position", at: t, rate: rate, now: now) { NSValue(point: CGPoint(x: -padding - inset - $0, y: y - inset)) }
        }
        if mask != nil {
            leftCoverTrack.play(on: leftCover, keyPath: "opacity", at: t, rate: rate, now: now) { Float($0) }
            rightCoverTrack.play(on: rightCover, keyPath: "opacity", at: t, rate: rate, now: now) { Float($0) }
        }
    }
}

private extension MenuBarTrack {
    var inverted: MenuBarTrack { MenuBarTrack(keys: keys.map { .init(time: $0.time, value: 1 - $0.value) }) }
}
