import AppKit
import CoreText
import StarryCore
import SwiftUI

struct SongTablePalette: Equatable {
    var theme: Theme
    var surface: NSColor
    var onSurface: NSColor
    var onSurfaceVariant: NSColor
    var primary: NSColor
    var outlineVariant: NSColor
    var accent: NSColor
    var tagAmber: NSColor
    var tagRed: NSColor
    static let liked = NSColor(red: 0xFE / 255, green: 0x79 / 255, blue: 0x71 / 255, alpha: 1)

    init(theme: Theme) {
        self.theme = theme
        surface = NSColor(theme.surface)
        onSurface = NSColor(theme.onSurface)
        onSurfaceVariant = NSColor(theme.onSurfaceVariant)
        primary = NSColor(theme.primary)
        outlineVariant = NSColor(theme.outlineVariant)
        accent = NSColor(theme.accent)
        tagAmber = NSColor(Color(hex: theme.isDark ? "#F5B94E" : "#B7791F"))
        tagRed = NSColor(Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A"))
    }

    static func == (a: SongTablePalette, b: SongTablePalette) -> Bool { a.theme == b.theme }
}

struct SongTagSpec: Equatable {
    enum Style { case neutral, amber, red }
    var text: String
    var style: Style
}

struct SongRowColumns: Equatable {
    var artwork = true
    var album = true
    var popularity = false
    var trailingWidth: CGFloat = 0

    var rowHeight: CGFloat { artwork ? Metrics.songRowHeight : 56 }

    static let playCountWidth: CGFloat = 52
}

struct SongSectionHeader: Equatable {
    var title: String
    var systemImage: String
}

struct SongRowGeometry: Equatable {
    var indexRect: NSRect
    var coverRect: NSRect
    var textRect: NSRect
    var albumRect: NSRect
    var heartRect: NSRect
    var durationRect: NSRect
    var popularityRect: NSRect
    var trailingRect: NSRect

    static let spacing: CGFloat = 16
    static let inset = Metrics.pagePadding + 12
    static let coverSide: CGFloat = 40
    static let popularityBarSize = NSSize(width: 48, height: 4)

    init(width: CGFloat, height: CGFloat, columns: SongRowColumns = SongRowColumns()) {
        let content = NSRect(x: Self.inset, y: 0, width: max(width - Self.inset * 2, 0), height: height)
        var fixed = SongColumns.indexWidth + SongColumns.likeWidth + SongColumns.durationWidth
        var count = 4
        if columns.album { count += 1 }
        if columns.popularity {
            fixed += SongColumns.popularityWidth
            count += 1
        }
        if columns.trailingWidth > 0 {
            fixed += columns.trailingWidth
            count += 1
        }
        let free = max(content.width - fixed - Self.spacing * CGFloat(count - 1), 0)
        let titleWidth = columns.album ? free * 3 / 5 : free
        var x = content.minX
        indexRect = NSRect(x: x, y: 0, width: SongColumns.indexWidth, height: height)
        x += SongColumns.indexWidth + Self.spacing
        if columns.artwork {
            coverRect = NSRect(x: x, y: (height - Self.coverSide) / 2, width: Self.coverSide, height: Self.coverSide)
            textRect = NSRect(x: coverRect.maxX + 12, y: 0, width: max(titleWidth - Self.coverSide - 12, 0), height: height)
        } else {
            coverRect = .zero
            textRect = NSRect(x: x, y: 0, width: titleWidth, height: height)
        }
        x += titleWidth + Self.spacing
        if columns.album {
            let albumWidth = free * 2 / 5
            albumRect = NSRect(x: x, y: 0, width: albumWidth, height: height)
            x += albumWidth + Self.spacing
        } else {
            albumRect = .zero
        }
        heartRect = NSRect(x: x, y: (height - SongColumns.likeWidth) / 2, width: SongColumns.likeWidth, height: SongColumns.likeWidth)
        x += SongColumns.likeWidth + Self.spacing
        durationRect = NSRect(x: x, y: 0, width: SongColumns.durationWidth, height: height)
        x += SongColumns.durationWidth + Self.spacing
        if columns.popularity {
            popularityRect = NSRect(x: x, y: 0, width: SongColumns.popularityWidth, height: height)
            x += SongColumns.popularityWidth + Self.spacing
        } else {
            popularityRect = .zero
        }
        trailingRect = columns.trailingWidth > 0 ? NSRect(x: x, y: 0, width: columns.trailingWidth, height: height) : .zero
    }

    var popularityBar: NSRect {
        NSRect(x: popularityRect.minX, y: popularityRect.midY - Self.popularityBarSize.height / 2, width: Self.popularityBarSize.width, height: Self.popularityBarSize.height)
    }
}

@MainActor
enum SongRowDrawing {
    static let titleFont = NSFont.systemFont(ofSize: 15)
    static let titleFontCurrent = NSFont.systemFont(ofSize: 15, weight: .medium)
    static let smallFont = NSFont.systemFont(ofSize: 13)
    static let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static let indexFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static let trailingFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
    static let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let tagFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let hoverDuration: CFTimeInterval = 0.18
    static let hoverKey = "hover"
    private static var symbols: [String: NSImage] = [:]

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    static func attributed(_ text: String, font: NSFont, color: NSColor, underlined: Bool = false) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        SongTextLine(text, font: font, color: .black).width
    }

    static func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, centred: Bool, horizontally: Bool = false, underlined: Bool = false) {
        SongTextLine(text, font: font, color: color, underlined: underlined).draw(in: rect, centred: centred, horizontally: horizontally)
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color)"
        if let image = symbols[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbols[key] = image
        return image
    }

    static func drawSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centredIn rect: NSRect) {
        guard let image = symbol(name, size: size, weight: weight, color: color) else { return }
        let drawn = NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
        image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func fadeHover(_ layer: CALayer?) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = hoverDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // Core Animation files a transition under this key whatever it is given.
        layer?.add(fade, forKey: kCATransition)
    }

    static func enter(_ layer: CALayer, direction: CGFloat, rise: CGFloat = 8, delay: TimeInterval) {
        let fade = spring(keyPath: "opacity", from: 0, to: 1)
        let up = spring(keyPath: "transform.translation.y", from: rise, to: 0)
        var animations: [CAAnimation] = [fade, up]
        var duration = fade.settlingDuration
        if direction != 0 {
            animations.append(slide(direction))
            duration = max(duration, 0.36)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        layer.add(group, forKey: "enter")
    }

    static func slideIn(_ layer: CALayer, direction: CGFloat) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = direction == 0 ? [fade] : [fade, slide(direction)]
        group.duration = 0.36
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layer.add(group, forKey: "enter")
    }

    private static func slide(_ direction: CGFloat) -> CABasicAnimation {
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 28 * direction
        slide.toValue = 0
        slide.duration = 0.36
        slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        return slide
    }

    /// `Animation.spring(response:dampingFraction:)` as a layer animation.
    static func spring(keyPath: String, from: CGFloat, to: CGFloat, response: Double = 0.55, dampingFraction: Double = 0.86) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / response, 2)
        animation.damping = 2 * dampingFraction * sqrt(animation.stiffness)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }
}

@MainActor
struct SongTextLine {
    let text: NSAttributedString
    let font: NSFont
    let line: CTLine
    let width: CGFloat

    init(_ text: NSAttributedString, font: NSFont) {
        self.text = text
        self.font = font
        line = CTLineCreateWithAttributedString(text)
        width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    init(_ string: String, font: NSFont, color: NSColor, underlined: Bool = false) {
        self.init(SongRowDrawing.attributed(string, font: font, color: color, underlined: underlined), font: font)
    }

    @discardableResult
    func draw(in rect: NSRect, centred: Bool, horizontally: Bool = false) -> CGFloat {
        guard text.length > 0, rect.width > 0, let context = NSGraphicsContext.current?.cgContext else { return 0 }
        var line = line
        var width = width
        if width > rect.width + 0.5 {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
            guard let truncated = CTLineCreateTruncatedLine(line, rect.width, .end, ellipsis) else { return 0 }
            line = truncated
            width = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        let height = SongRowDrawing.lineHeight(font)
        let top = centred ? rect.minY + (rect.height - height) / 2 : rect.minY
        let x = horizontally ? rect.minX + (rect.width - width) / 2 : rect.minX
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: x, y: (top + font.ascender).rounded())
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }
}

final class SongCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SongCellView")

    struct State: Equatable {
        var isCurrent = false
        var isPlaying = false
        var barsAnimate = false
        var hovered = false
        var liked = false
        var canLike = false
    }

    struct Actions {
        var play: @MainActor () -> Void = {}
        var toggleLike: @MainActor () -> Void = {}
        var showArtist: @MainActor (ArtistRef) -> Void = { _ in }
        var showAlbum: @MainActor () -> Void = {}
    }

    var palette = SongTablePalette(theme: .darkBase) {
        didSet {
            guard palette != oldValue else { return }
            content.palette = palette
            mark.palette = palette
            heart.palette = palette
            glow.layer?.borderColor = palette.primary.withAlphaComponent(0.45).cgColor
            glow.layer?.backgroundColor = palette.primary.withAlphaComponent(0.14).cgColor
            applyState()
        }
    }
    /// Set before `show`: a row without artwork does not load its cover.
    var columns = SongRowColumns() {
        didSet {
            guard columns != oldValue else { return }
            content.columns = columns
            needsLayout = true
        }
    }
    private(set) var track: Track?
    private var state = State()
    private var actions = Actions()
    private let score = SongScoreBarView()
    private let fill = NSView()
    private let glow = SongRowGlowView()
    private let content = SongContentView()
    private let mark = SongMarkView()
    private let heart = SongHeartView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Radius.menu
        fill.layer?.cornerCurve = .continuous
        glow.wantsLayer = true
        glow.layer?.cornerRadius = Radius.menu
        glow.layer?.cornerCurve = .continuous
        glow.layer?.borderWidth = 1
        glow.alphaValue = 0
        for view in [score, fill, content, mark, heart, glow] { addSubview(view) }
        mark.onPlay = { [weak self] in self?.actions.play() }
        heart.onToggle = { [weak self] in self?.actions.toggleLike() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let geometry = SongRowGeometry(width: bounds.width, height: bounds.height, columns: columns)
        let inset = NSRect(x: Metrics.pagePadding, y: 0, width: max(bounds.width - Metrics.pagePadding * 2, 0), height: bounds.height)
        score.frame = inset.insetBy(dx: 0, dy: SongScoreBarView.inset)
        fill.frame = inset
        glow.frame = inset
        content.frame = bounds
        mark.frame = geometry.indexRect
        heart.frame = geometry.heartRect
    }

    func show(_ track: Track, index: Int, tags: [SongTagSpec], trailing: String? = nil, state: State, actions: Actions) {
        self.track = track
        self.state = state
        self.actions = actions
        content.show(track, tags: tags, trailing: trailing, current: state.isCurrent, actions: actions)
        mark.index = index
        glow.alphaValue = 0
        glow.layer?.removeAllAnimations()
        layer?.removeAllAnimations()
        fill.layer?.removeAnimation(forKey: SongRowDrawing.hoverKey)
        for view in [mark, heart] { view.layer?.removeAnimation(forKey: kCATransition) }
        applyState(fresh: true)
    }

    func setIndex(_ index: Int) {
        mark.index = index
    }

    func setTrailing(_ text: String?) {
        content.trailing = text
    }

    func setScore(_ fraction: Double?, tint: NSColor, growingAfter delay: TimeInterval? = nil) {
        score.show(fraction, tint: tint, dark: palette.theme.isDark, growingAfter: delay)
    }

    func apply(_ state: State) {
        guard state != self.state else { return }
        let wasCurrent = self.state.isCurrent
        let wasHovered = self.state.hovered
        self.state = state
        if state.isCurrent != wasCurrent { content.current = state.isCurrent }
        applyState(fading: state.hovered != wasHovered)
    }

    func pointerMoved(to point: NSPoint?) {
        content.pointer(at: point.map { convert($0, to: content) })
        heart.pointer(at: point.map { convert($0, to: heart) })
    }

    func glowOnce() {
        glow.layer?.removeAllAnimations()
        glow.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glow.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.fadeGlow()
            }
        }
    }

    private func fadeGlow() {
        guard glow.alphaValue == 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.9
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.animator().alphaValue = 0
        }
    }

    private func applyState(fresh: Bool = false, fading: Bool = false) {
        let color = state.isCurrent ? palette.primary.withAlphaComponent(state.hovered ? 0.14 : 0.10) : palette.onSurface.withAlphaComponent(state.hovered ? 0.06 : 0)
        if let layer = fill.layer {
            if fading {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor ?? color.withAlphaComponent(0).cgColor
                fade.toValue = color.cgColor
                fade.duration = SongRowDrawing.hoverDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: SongRowDrawing.hoverKey)
                SongRowDrawing.fadeHover(mark.layer)
                SongRowDrawing.fadeHover(heart.layer)
            }
            layer.backgroundColor = state.isCurrent || state.hovered ? color.cgColor : nil
        }
        mark.state = state
        if fresh { heart.reset(state) } else { heart.state = state }
    }
}

/// The locate animation sits above the row's controls, even when fully transparent.
private final class SongRowGlowView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SongContentView: NSView {
    private struct Run {
        var text: String
        var action: (@MainActor () -> Void)?
        var rect = NSRect.zero
    }

    var palette = SongTablePalette(theme: .darkBase) { didSet { if palette != oldValue { needsDisplay = true } } }
    var current = false { didSet { if current != oldValue { needsDisplay = true } } }
    var columns = SongRowColumns() {
        didSet {
            guard columns != oldValue else { return }
            needsDisplay = true
            updateToolTips()
        }
    }
    var trailing: String? { didSet { if trailing != oldValue { needsDisplay = true } } }
    private var track: Track?
    private var tags: [SongTagSpec] = []
    private var image: NSImage?
    private var loading: Task<Void, Never>?
    private var runs: [Run] = []
    private var hoveredRun: Int?
    private var pressedRun: Int?
    private var cursorSet = false
    private static let coverPixels = 120
    private static let tagPaddingX: CGFloat = 4
    private static let tagPaddingY: CGFloat = 1.5
    private static let minTruncatedWidth: CGFloat = 28

    override var isFlipped: Bool { true }

    static func lines(_ height: CGFloat) -> (first: CGFloat, second: CGFloat, titleHeight: CGFloat, lineHeight: CGFloat) {
        let titleHeight = SongRowDrawing.lineHeight(SongRowDrawing.titleFont)
        let lineHeight = max(SongRowDrawing.lineHeight(SongRowDrawing.smallFont), tagHeight)
        let top = ((height - titleHeight - 3 - lineHeight) / 2).rounded()
        return (top, top + titleHeight + 3, titleHeight, lineHeight)
    }

    static var tagHeight: CGFloat { SongRowDrawing.lineHeight(SongRowDrawing.tagFont) + tagPaddingY * 2 }

    func show(_ track: Track, tags: [SongTagSpec], trailing: String? = nil, current: Bool, actions: SongCellView.Actions) {
        self.track = track
        self.tags = tags
        self.trailing = trailing
        self.current = current
        runs = []
        for (index, artist) in track.artists.enumerated() {
            if index > 0 { runs.append(Run(text: " / ", action: nil)) }
            var action: (@MainActor () -> Void)?
            if artist.isLinkable { action = { actions.showArtist(artist) } }
            runs.append(Run(text: artist.name, action: action))
        }
        var albumAction: (@MainActor () -> Void)?
        if track.album?.isLinkable == true { albumAction = actions.showAlbum }
        runs.append(Run(text: track.album?.name ?? "", action: albumAction))
        hoveredRun = nil
        pressedRun = nil
        loading?.cancel()
        loading = nil
        image = nil
        updateToolTips()
        if columns.artwork, let url = track.artwork?.sized(Self.coverPixels) {
            if let cached = ImageStore.shared.image(for: url, maxPixelSize: Self.coverPixels) {
                image = cached
            } else {
                let id = track.id
                loading = Task { [weak self] in
                    let loaded = await ImageStore.shared.load(url, maxPixelSize: Self.coverPixels)
                    guard !Task.isCancelled, let self, self.track?.id == id else { return }
                    image = loaded
                    needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let track else { return }
        let geometry = SongRowGeometry(width: bounds.width, height: bounds.height, columns: columns)
        if columns.artwork { drawCover(track, in: geometry.coverRect) }

        let lines = Self.lines(bounds.height)
        let titleFont = current ? SongRowDrawing.titleFontCurrent : SongRowDrawing.titleFont
        let title = NSMutableAttributedString(attributedString: SongRowDrawing.attributed(track.title, font: titleFont, color: current ? palette.primary : palette.onSurface))
        if let alias = track.alias {
            title.append(SongRowDrawing.attributed(" (\(alias))", font: titleFont, color: palette.onSurfaceVariant))
        }
        let text = geometry.textRect
        SongTextLine(title, font: titleFont).draw(in: NSRect(x: text.minX, y: lines.first, width: text.width, height: lines.titleHeight), centred: false)

        var x = text.minX
        let tagHeight = Self.tagHeight
        for tag in tags {
            let color = switch tag.style {
            case .neutral: palette.onSurfaceVariant
            case .amber: palette.tagAmber
            case .red: palette.tagRed
            }
            let label = SongTextLine(tag.text, font: SongRowDrawing.tagFont, color: color)
            let width = label.width + Self.tagPaddingX * 2
            guard x + width <= text.maxX else { break }
            let rect = NSRect(x: x, y: lines.second + (lines.lineHeight - tagHeight) / 2, width: width, height: tagHeight)
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            label.draw(in: rect.insetBy(dx: Self.tagPaddingX, dy: 0), centred: true, horizontally: true)
            x += width + 4
        }
        x += 2
        let smallHeight = SongRowDrawing.lineHeight(SongRowDrawing.smallFont)
        let artistsY = lines.second + ((lines.lineHeight - smallHeight) / 2).rounded()
        var full = false
        for index in runs.indices.dropLast() {
            let line = runLine(index)
            let remaining = text.maxX - x
            var rect = NSRect.zero
            if !full, line.width <= remaining + 0.5 {
                rect = NSRect(x: x, y: artistsY, width: line.width, height: smallHeight)
                x += line.width
            } else if !full, remaining >= Self.minTruncatedWidth {
                rect = NSRect(x: x, y: artistsY, width: remaining, height: smallHeight)
                full = true
            } else {
                full = true
            }
            runs[index].rect = rect
            if !rect.isEmpty { line.draw(in: rect, centred: false) }
        }

        if let album = runs.indices.last {
            if columns.album {
                let line = runLine(album)
                let rect = NSRect(x: geometry.albumRect.minX, y: ((bounds.height - smallHeight) / 2).rounded(), width: geometry.albumRect.width, height: smallHeight)
                runs[album].rect = NSRect(x: rect.minX, y: rect.minY, width: min(line.width, rect.width), height: smallHeight)
                line.draw(in: rect, centred: false)
            } else {
                runs[album].rect = .zero
            }
        }

        SongTextLine(TimeFormatting.clock(track.duration), font: SongRowDrawing.digitFont, color: palette.onSurfaceVariant).draw(in: geometry.durationRect, centred: true)

        if columns.popularity { drawPopularity(track.popularity, in: geometry.popularityBar) }

        if let trailing, columns.trailingWidth > 0 {
            let line = SongTextLine(trailing, font: SongRowDrawing.trailingFont, color: palette.onSurfaceVariant)
            let width = min(line.width, geometry.trailingRect.width)
            line.draw(in: NSRect(x: geometry.trailingRect.maxX - width, y: 0, width: width, height: bounds.height), centred: true)
        }
    }

    private func drawPopularity(_ value: Double?, in bar: NSRect) {
        let radius = bar.height / 2
        palette.onSurface.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        guard let value, value > 0 else { return }
        palette.primary.setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.width * value, 4), height: bar.height), xRadius: radius, yRadius: radius).fill()
    }

    private var popularityText: String? {
        guard columns.popularity, let value = track?.popularity else { return nil }
        return "热度 \(Int((value * 100).rounded()))"
    }

    private func updateToolTips() {
        removeAllToolTips()
        guard popularityText != nil else { return }
        let bar = SongRowGeometry(width: bounds.width, height: bounds.height, columns: columns).popularityBar
        addToolTip(bar.insetBy(dx: 0, dy: -6), owner: self, userData: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { updateToolTips() }
    }

    private func runLine(_ index: Int) -> SongTextLine {
        let hot = hoveredRun == index && runs[index].action != nil
        return SongTextLine(runs[index].text, font: SongRowDrawing.smallFont, color: hot ? palette.onSurface : palette.onSurfaceVariant, underlined: hot)
    }

    private func drawCover(_ track: Track, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        if let image {
            let size = image.size
            let scale = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
            let drawn = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
            image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            let colors = PlaceholderArt.colors(for: track.artwork?.seed ?? "starry").map { NSColor($0) }
            NSGradient(colors: colors)?.draw(in: rect, angle: -45)
            SongRowDrawing.drawSymbol("music.note", size: 18, weight: .light, color: .white.withAlphaComponent(0.35), centredIn: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Links

    private func link(at point: NSPoint) -> Int? {
        runs.indices.first { runs[$0].action != nil && !runs[$0].rect.isEmpty && runs[$0].rect.insetBy(dx: 0, dy: -2).contains(point) }
    }

    func pointer(at point: NSPoint?) {
        let now = point.flatMap(link(at:))
        guard now != hoveredRun else { return }
        hoveredRun = now
        needsDisplay = true
        if now != nil {
            NSCursor.pointingHand.set()
            cursorSet = true
        } else if cursorSet {
            NSCursor.arrow.set()
            cursorSet = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = link(at: convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        pressedRun = index
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressedRun else { return super.mouseUp(with: event) }
        self.pressedRun = nil
        if link(at: convert(event.locationInWindow, from: nil)) == pressedRun { runs[pressedRun].action?() }
    }
}

extension SongContentView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        popularityText ?? ""
    }
}

final class SongScoreBarView: NSView {
    static let inset: CGFloat = 5
    private static let radius: CGFloat = 10
    private let bar = CAGradientLayer()
    private var fraction: CGFloat?
    private var colors: [NSColor] = []
    /// When the bar is to start growing; kept until the row has a width to grow to.
    private var growsAt: CFTimeInterval?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bar.startPoint = CGPoint(x: 0, y: 0.5)
        bar.endPoint = CGPoint(x: 1, y: 0.5)
        bar.cornerCurve = .continuous
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        place()
        grow()
    }

    func show(_ fraction: Double?, tint: NSColor, dark: Bool, growingAfter delay: TimeInterval?) {
        let fraction = fraction.map { CGFloat(min(max($0, 0), 1)) }
        let colors = [tint.withAlphaComponent(dark ? 0.15 : 0.11), tint.withAlphaComponent(dark ? 0.04 : 0.03)]
        // Leave a bar that is already right alone: it may still be growing.
        guard fraction != self.fraction || colors != self.colors || delay != nil else { return }
        self.fraction = fraction
        self.colors = colors
        bar.removeAnimation(forKey: "grow")
        growsAt = delay.map { CACurrentMediaTime() + $0 }
        isHidden = fraction == nil
        place()
        grow()
    }

    private func grow() {
        // A row new to the table is laid out only after it is shown.
        guard let growsAt, bounds.width > 0 else { return }
        self.growsAt = nil
        guard bar.bounds.width > 0.5 else { return }
        // Match the ranking's spring: response 0.9 s, damping fraction 0.92.
        let grow = SongRowDrawing.spring(keyPath: "bounds.size.width", from: 0, to: bar.bounds.width, response: 0.9, dampingFraction: 0.92)
        grow.beginTime = growsAt
        grow.fillMode = .backwards
        bar.add(grow, forKey: "grow")
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = bounds.width * (fraction ?? 0)
        bar.colors = colors.map(\.cgColor)
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        bar.position = CGPoint(x: 0, y: bounds.midY)
        bar.cornerRadius = min(Self.radius, width / 2)
        bar.isHidden = width <= 0.5
        CATransaction.commit()
    }
}

final class SongSectionHeaderCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SongSectionHeaderCell")

    var palette = SongTablePalette(theme: .darkBase) { didSet { if palette != oldValue { needsDisplay = true } } }
    var header: SongSectionHeader? { didSet { if header != oldValue { needsDisplay = true } } }

    private static let bottomPadding: CGFloat = 6

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    static func height(leading: Bool) -> CGFloat {
        (leading ? 6 : 22) + SongRowDrawing.lineHeight(SongRowDrawing.headerFont) + bottomPadding
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let header else { return }
        let height = SongRowDrawing.lineHeight(SongRowDrawing.headerFont)
        let line = NSRect(x: SongRowGeometry.inset, y: bounds.height - Self.bottomPadding - height, width: max(bounds.width - SongRowGeometry.inset * 2, 0), height: height)
        var x = line.minX
        if let image = SongRowDrawing.symbol(header.systemImage, size: 12, weight: .medium, color: palette.onSurfaceVariant) {
            SongRowDrawing.drawSymbol(header.systemImage, size: 12, weight: .medium, color: palette.onSurfaceVariant, centredIn: NSRect(x: x, y: line.minY, width: image.size.width, height: height))
            x += image.size.width + 6
        }
        SongRowDrawing.draw(header.title, font: SongRowDrawing.headerFont, color: palette.onSurfaceVariant, in: NSRect(x: x, y: line.minY, width: max(line.maxX - x, 0), height: height), centred: false)
    }
}

final class SongMarkView: NSView {
    var palette = SongTablePalette(theme: .darkBase) {
        didSet {
            guard palette != oldValue else { return }
            bars.setColor(palette.primary)
            needsDisplay = true
        }
    }
    var index = 0 { didSet { if index != oldValue { needsDisplay = true } } }
    var state = SongCellView.State() { didSet { update(from: oldValue) } }
    var onPlay: (() -> Void)?
    private let bars = PlayingBarsView()
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bars.isHidden = true
        addSubview(bars)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        bars.frame = NSRect(x: ((bounds.width - 14) / 2).rounded(), y: ((bounds.height - 12) / 2).rounded(), width: 14, height: 12)
    }

    private var showsBars: Bool { state.isCurrent && state.isPlaying }
    private var showsPlay: Bool { !showsBars && (state.hovered || state.isCurrent) }

    private func update(from old: SongCellView.State) {
        bars.isHidden = !showsBars
        bars.setAnimating(showsBars && state.barsAnimate)
        if (old.isCurrent, old.isPlaying, old.hovered) != (state.isCurrent, state.isPlaying, state.hovered) { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsBars {
            return
        }
        if showsPlay {
            SongRowDrawing.drawSymbol("play.fill", size: 12, weight: .bold, color: state.isCurrent ? palette.primary : palette.onSurfaceVariant, centredIn: bounds)
        } else {
            SongRowDrawing.draw(String(format: "%02d", index), font: SongRowDrawing.indexFont, color: state.isCurrent ? palette.primary : palette.onSurfaceVariant, in: bounds, centred: true, horizontally: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard showsPlay, bounds.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return super.mouseUp(with: event) }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPlay?() }
    }
}

final class SongHeartView: NSView {
    var palette = SongTablePalette(theme: .darkBase) { didSet { if palette != oldValue { needsDisplay = true } } }
    var state = SongCellView.State() { didSet { update(from: oldValue) } }
    var onToggle: (() -> Void)?
    private var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var resetting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The view stays in place and draws nothing when not shown, so the heart can fade.
    private var shown: Bool { state.canLike && (state.liked || state.hovered) }

    override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }

    func reset(_ state: SongCellView.State) {
        resetting = true
        self.state = state
        resetting = false
        layer?.removeAnimation(forKey: "bounce")
    }

    private func update(from old: SongCellView.State) {
        let shown = shown
        if shown != (old.canLike && (old.liked || old.hovered)) {
            needsDisplay = true
            if !shown { hot = false }
        }
        guard shown else {
            toolTip = nil
            return
        }
        toolTip = state.liked ? "取消喜欢" : "喜欢"
        if old.liked != state.liked, !resetting {
            needsDisplay = true
            wantsLayer = true
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
            bounce.values = [1, 1.3, 0.9, 1.05, 1]
            bounce.keyTimes = [0, 0.3, 0.6, 0.8, 1]
            bounce.duration = 0.3
            layer?.add(bounce, forKey: "bounce")
        } else if (old.liked, old.hovered, old.canLike) != (state.liked, state.hovered, state.canLike) {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard shown else { return }
        if hot {
            palette.onSurface.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let color = state.liked ? SongTablePalette.liked : palette.onSurfaceVariant
        let rect = pressed ? bounds.insetBy(dx: bounds.width * 0.02, dy: bounds.height * 0.02) : bounds
        SongRowDrawing.drawSymbol(state.liked ? "heart.fill" : "heart", size: 16, weight: .medium, color: color, centredIn: rect)
    }

    func pointer(at point: NSPoint?) {
        hot = shown && (point.map { bounds.contains($0) } ?? false)
    }

    override func mouseDown(with event: NSEvent) {
        guard shown, bounds.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        wantsLayer = true
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return super.mouseUp(with: event) }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }
}

final class InsertionLineView: NSView {
    var palette = SongTablePalette(theme: .darkBase) { didSet { if palette != oldValue { needsDisplay = true } } }
    static let height: CGFloat = 9

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        palette.accent.setStroke()
        palette.accent.setFill()
        let ring = NSBezierPath(ovalIn: NSRect(x: 5, y: 1, width: 7, height: 7))
        ring.lineWidth = 2
        ring.stroke()
        NSBezierPath(roundedRect: NSRect(x: 13, y: 3, width: max(bounds.width - 17, 0), height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class PlainRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("PlainRowView")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}
