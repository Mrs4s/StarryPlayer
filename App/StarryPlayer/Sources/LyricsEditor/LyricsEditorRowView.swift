import AppKit
import LyricsCore
import QuartzCore

/// Only geometry-affecting fields belong in this key. Timing, selection and hover reuse it.
struct LyricsEditorLineLayout {
    struct Input: Equatable {
        var texts: [String]
        var rubies: [String]
        var translation: String
        var romanization: String
        var badge: String?
        var background: Bool
        var width: CGFloat
        var paragraph: Bool
        var editing: Bool

        init(line: LyricsDraft.Line, width: CGFloat, paragraph: Bool, editing: Bool) {
            texts = line.syllables.map(\.text)
            rubies = line.syllables.map { ($0.ruby ?? []).map(\.text).joined() }
            translation = line.translation
            romanization = line.romanization
            badge = line.isBackground ? "背景" : line.singer == .secondary ? "对唱" : line.singer == .duet ? "合唱" : nil
            background = line.isBackground
            self.width = width
            self.paragraph = paragraph
            self.editing = editing
        }
    }

    let input: Input
    let chips: [NSRect]
    let badge: NSRect?
    let translation: NSRect?
    let romanization: NSRect?
    let editor: NSRect
    let height: CGFloat
    /// Room over the text of every chip for ruby, when any syllable of the line has some.
    let rubyBand: CGFloat
    var top: CGFloat { input.paragraph ? 19 : 7 }
    var leading: CGFloat { input.background ? 70 : 46 }
    /// Where the first row of chips has its text, which the row's number and buttons line up with.
    var textTop: CGFloat { top + rubyBand }
    var play: NSRect { NSRect(x: input.width - 122, y: textTop + 2, width: 26, height: 26) }
    var more: NSRect { NSRect(x: input.width - 94, y: textTop + 2, width: 26, height: 26) }

    static func rubyFont(background: Bool) -> NSFont { .systemFont(ofSize: background ? 9 : 10, weight: .medium) }

    @MainActor init(input: Input) {
        self.input = input
        let top: CGFloat = input.paragraph ? 19 : 7
        let leading: CGFloat = input.background ? 70 : 46
        let available = max(26, input.width - leading - 132)
        let font = NSFont.systemFont(ofSize: input.background ? 15 : 17, weight: .medium)
        let rubyFont = Self.rubyFont(background: input.background)
        let band: CGFloat = !input.editing && input.rubies.contains { !$0.isEmpty } ? ceil(rubyFont.ascender - rubyFont.descender) : 0
        rubyBand = band
        let chipHeight: CGFloat = (input.background ? 26 : 30) + band
        var x = leading
        var y = top
        var badgeRect: NSRect?
        if let badge = input.badge, !input.editing {
            let width = ceil((badge as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)]).width) + 12
            badgeRect = NSRect(x: x, y: y + band + (chipHeight - band - 20) / 2, width: width, height: 20)
            x += width + 6
        }
        badge = badgeRect
        var frames: [NSRect] = []
        if !input.editing {
            for (text, ruby) in zip(input.texts, input.rubies) {
                let label = text.trimmingCharacters(in: .whitespaces)
                let labelWidth = (label as NSString).size(withAttributes: [.font: font]).width
                let rubyWidth = (ruby as NSString).size(withAttributes: [.font: rubyFont]).width
                let width = min(available, max(26, ceil(max(labelWidth, rubyWidth)) + 12))
                if x > leading, x + width > leading + available {
                    x = leading
                    y += chipHeight + 4
                }
                frames.append(NSRect(x: x, y: y, width: width, height: chipHeight))
                x += width + 2 + (text.hasSuffix(" ") ? 8 : 0)
            }
        }
        chips = frames
        editor = NSRect(x: leading, y: top, width: available, height: 30)
        y += input.editing ? 50 : max(chipHeight, 30 + band)
        func annotation(_ text: String, font: NSFont) -> NSRect? {
            guard !text.isEmpty else { return nil }
            let measured = (text as NSString).boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let height = min(ceil(measured.height), ceil(font.ascender - font.descender + font.leading) * 2)
            y += 4
            let rect = NSRect(x: leading, y: y, width: available, height: height)
            y += height
            return rect
        }
        translation = annotation(input.translation, font: .systemFont(ofSize: 12.5))
        romanization = annotation(input.romanization, font: .systemFont(ofSize: 12))
        height = y + 7
    }

    func syllable(at point: NSPoint) -> Int? { chips.firstIndex { $0.contains(point) } }
}

final class LyricsEditorRowView: NSView, NSTextFieldDelegate {
    static let reuseID = NSUserInterfaceItemIdentifier("LyricsEditorRow")
    var select: ((Int?) -> Void)?
    var toggle: ((Int) -> Void)?
    var extend: ((Int) -> Void)?
    /// Dragging from a syllable, in window coordinates: the list selects across rows.
    var drag: ((NSEvent) -> Void)?
    var edit: (() -> Void)?
    var commit: ((String) -> Void)?
    var cancel: (() -> Void)?
    var play: (() -> Void)?
    /// Menu anchor in row coordinates; an empty rect represents a right-click.
    var showMenu: ((_ syllable: Int?, _ rect: NSRect) -> Void)?

    private var line: LyricsDraft.Line?
    private var rowLayout: LyricsEditorLineLayout?
    private var index = 0
    private var theme = Theme.darkBase
    private var caret: Int?
    private var selected = IndexSet()
    private var dragging = false
    private var hovered = false
    private var hoveredChip: Int?
    private var active = false
    private var pulse = 0
    private var tracking: NSTrackingArea?
    private var field: NSTextField?
    private var endingEdit = false
    private var labels: [NSAttributedString] = []
    private var rubyLabels: [NSAttributedString?] = []
    private var sweeps: [(clip: CALayer, fill: CALayer)] = []
    private let pulseLayer = CAShapeLayer()
    private var accessible: [LyricsEditorActionElement] = []
    private var accessibilityGeneration = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.addSublayer(pulseLayer)
        pulseLayer.fillColor = nil
        pulseLayer.lineWidth = 2
        pulseLayer.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(line: LyricsDraft.Line, index: Int, layout: LyricsEditorLineLayout, theme: Theme,
                   caret: Int?, selected: IndexSet = [], pulse: Int, lastTapped: UUID?) {
        let reused = self.line?.id != line.id
        let contentChanged = self.line != line || self.theme != theme || rowLayout?.input != layout.input
        let selectionChanged = self.selected != selected
        let changed = contentChanged || selectionChanged || self.caret != caret || self.index != index
        if reused {
            finishEditing(cancelled: false)
            hovered = false
            hoveredChip = nil
        }
        self.line = line
        self.index = index
        self.rowLayout = layout
        self.theme = theme
        self.caret = caret
        self.selected = selected
        if contentChanged {
            let font = NSFont.systemFont(ofSize: line.isBackground ? 15 : 17, weight: .medium)
            labels = line.syllables.map {
                NSAttributedString(string: $0.text.trimmingCharacters(in: .whitespaces), attributes: [
                    .font: font, .foregroundColor: NSColor(theme.onSurface).withAlphaComponent($0.isTimed ? 0.95 : 0.5)
                ])
            }
            let rubyFont = LyricsEditorLineLayout.rubyFont(background: line.isBackground)
            rubyLabels = zip(line.syllables, layout.input.rubies).map { syllable, ruby in
                ruby.isEmpty ? nil : NSAttributedString(string: ruby, attributes: [
                    .font: rubyFont, .foregroundColor: NSColor(theme.onSurfaceVariant).withAlphaComponent(syllable.isTimed ? 0.9 : 0.5)
                ])
            }
            for sweep in sweeps { sweep.clip.removeFromSuperlayer() }
            sweeps = []
            rebuildAccessibility()
        } else if selectionChanged {
            rebuildAccessibility()
        }
        if layout.input.editing {
            if field == nil {
                let field = NSTextField(string: LyricsDraft.editableText(of: line))
                field.font = .systemFont(ofSize: 16, weight: .medium)
                field.isBordered = false
                field.focusRingType = .none
                field.setAccessibilityElement(true)
                field.setAccessibilityRole(.textField)
                field.setAccessibilityLabel("这一行的歌词")
                field.delegate = self
                field.target = self
                field.action = #selector(submit)
                addSubview(field)
                self.field = field
            }
            field?.textColor = NSColor(theme.onSurface)
            field?.backgroundColor = NSColor(theme.surfaceAlt)
            field?.frame = layout.editor.insetBy(dx: 6, dy: 4)
        } else if field != nil {
            finishEditing(cancelled: true, notify: false)
        }
        if changed { needsDisplay = true }
        if pulse != self.pulse, !reused, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let s = line.syllables.firstIndex(where: { $0.id == lastTapped }), layout.chips.indices.contains(s) {
            let rect = layout.chips[s].insetBy(dx: -2, dy: -2)
            pulseLayer.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            pulseLayer.strokeColor = NSColor(theme.primary).cgColor
            let flash = CABasicAnimation(keyPath: "opacity")
            flash.fromValue = 1
            flash.toValue = 0
            flash.duration = 0.4
            pulseLayer.add(flash, forKey: "tap")
        }
        self.pulse = pulse
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let layout = rowLayout else { return }
        let foreground = NSColor(theme.onSurface)
        let secondary = NSColor(theme.onSurfaceVariant)
        let accent = NSColor(theme.primary)
        let card = NSRect(x: 0, y: layout.top - 7, width: bounds.width, height: bounds.height - layout.top + 7)
        if caret != nil || hovered {
            (caret != nil ? accent.withAlphaComponent(theme.isDark ? 0.1 : 0.06) : foreground.withAlphaComponent(0.035)).setFill()
            NSBezierPath(roundedRect: card, xRadius: Radius.card, yRadius: Radius.card).fill()
        }
        if active {
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: line.isBackground ? 26 : 2, y: layout.textTop + 6, width: 3, height: 18), xRadius: 1.5, yRadius: 1.5).fill()
        }
        text("\(index + 1)", rect: NSRect(x: 10 + (line.isBackground ? 24 : 0), y: layout.textTop + 8, width: 26, height: 16), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: caret != nil ? accent : secondary.withAlphaComponent(0.7), alignment: .right)
        if layout.input.editing {
            accent.withAlphaComponent(0.5).setStroke()
            NSBezierPath(roundedRect: layout.editor, xRadius: Radius.menu, yRadius: Radius.menu).stroke()
            text("用 | 分开音节；回车保存，Esc 取消", rect: layout.editor.offsetBy(dx: 0, dy: 34), font: .systemFont(ofSize: 11), color: secondary)
        } else {
            if let badge = layout.badge, let title = layout.input.badge {
                accent.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                text(title, rect: badge.insetBy(dx: 6, dy: 3), font: .systemFont(ofSize: 10.5, weight: .semibold), color: accent)
            }
            if line.syllables.isEmpty {
                text("空行", rect: layout.editor, font: .systemFont(ofSize: 15), color: secondary)
            }
            for (s, rect) in layout.chips.enumerated() where rect.insetBy(dx: -3, dy: -3).intersects(dirtyRect) {
                let timed = line.syllables[s].isTimed
                let picked = selected.contains(s)
                let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                if picked {
                    accent.withAlphaComponent(theme.isDark ? 0.34 : 0.22).setFill()
                } else {
                    (timed ? accent.withAlphaComponent(theme.isDark ? 0.14 : 0.09) : foreground.withAlphaComponent(hoveredChip == s ? 0.05 : 0)).setFill()
                }
                path.fill()
                if picked {
                    accent.setStroke()
                    path.lineWidth = 1.25
                    path.stroke()
                } else if !timed {
                    foreground.withAlphaComponent(0.18).setStroke()
                    path.setLineDash([3, 3], count: 2, phase: 0)
                    path.stroke()
                }
                NSGraphicsContext.saveGraphicsState()
                rect.insetBy(dx: 4, dy: 0).clip()
                let label = labels[s]
                let textMidY = rect.minY + layout.rubyBand + (rect.height - layout.rubyBand) / 2
                if let ruby = rubyLabels[s] {
                    ruby.draw(at: NSPoint(x: max(rect.minX + 6, rect.midX - ruby.size().width / 2), y: rect.minY + 3))
                    label.draw(at: NSPoint(x: max(rect.minX + 6, rect.midX - label.size().width / 2), y: textMidY - label.size().height / 2))
                } else {
                    label.draw(at: NSPoint(x: rect.minX + 6, y: textMidY - label.size().height / 2))
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let rect = layout.translation { text(line.translation, rect: rect, font: .systemFont(ofSize: 12.5), color: secondary, wrap: true) }
        if let rect = layout.romanization {
            text(line.romanization, rect: rect, font: NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask), color: secondary.withAlphaComponent(0.8), wrap: true)
        }
        if hovered || caret != nil {
            text("▶", rect: layout.play.insetBy(dx: 7, dy: 5), font: .systemFont(ofSize: 11), color: foreground)
            text("•••", rect: layout.more.insetBy(dx: 4, dy: 5), font: .systemFont(ofSize: 11, weight: .semibold), color: foreground)
        }
        text(LyricsEditorFormat.time(line.timedRange?.lowerBound), rect: NSRect(x: layout.input.width - 68, y: layout.textTop + 8, width: 58, height: 16), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: secondary.withAlphaComponent(line.timedRange == nil ? 0.4 : 0.8), alignment: .right)
    }

    private func text(_ value: String, rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, wrap: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// Playback only moves overlay layers. It never invalidates glyph drawing or row height.
    func updatePlayback(time: TimeInterval, active: Bool) {
        guard let line, let layout = rowLayout else { return }
        if self.active != active { self.active = active; setNeedsDisplay(NSRect(x: 0, y: 0, width: 30, height: bounds.height)) }
        guard active || !sweeps.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if active, sweeps.isEmpty, !layout.input.editing {
            for rect in layout.chips {
                let clip = CALayer()
                clip.frame = rect
                clip.cornerRadius = 7
                clip.masksToBounds = true
                let fill = CALayer()
                fill.backgroundColor = NSColor(theme.primary).withAlphaComponent(theme.isDark ? 0.22 : 0.15).cgColor
                clip.addSublayer(fill)
                layer?.addSublayer(clip)
                sweeps.append((clip, fill))
            }
        }
        for (s, sweep) in sweeps.enumerated() {
            let syllable = line.syllables[s]
            let start = syllable.start ?? .infinity
            let end = max(syllable.end ?? start + 0.3, start + 0.01)
            let fraction = min(max((time - start) / (end - start), 0), 1)
            sweep.clip.isHidden = !active || !fraction.isFinite || fraction <= 0 || fraction >= 1
            if !sweep.clip.isHidden { sweep.fill.frame = NSRect(x: 0, y: 0, width: sweep.clip.bounds.width * fraction, height: sweep.clip.bounds.height) }
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = false; hoveredChip = nil; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        guard let layout = rowLayout else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = layout.syllable(at: point)
        if next != hoveredChip {
            if let old = hoveredChip, layout.chips.indices.contains(old) { setNeedsDisplay(layout.chips[old]) }
            if let next { setNeedsDisplay(layout.chips[next]) }
            hoveredChip = next
        }
        if let next, let syllable = line?.syllables[next] {
            toolTip = syllable.isTimed ? "\(LyricsEditorFormat.time(syllable.start, digits: 3)) – \(LyricsEditorFormat.time(syllable.end, digits: 3))" : "还没有打点"
        } else { toolTip = layout.play.contains(point) ? "从这一行播放（Q）" : layout.more.contains(point) ? "更多操作" : nil }
    }

    override func mouseDown(with event: NSEvent) {
        guard let layout = rowLayout else { return }
        let point = convert(event.locationInWindow, from: nil)
        if layout.play.contains(point) { play?(); return }
        if layout.more.contains(point) { openMoreMenu(); return }
        if layout.input.editing { focusEditor(); return }
        window?.makeFirstResponder(self)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let syllable = layout.syllable(at: point)
        if flags.contains(.command) || flags.contains(.shift) {
            guard let syllable else { return }
            if flags.contains(.shift) { extend?(syllable) } else { toggle?(syllable) }
            dragging = true
            return
        }
        if event.clickCount == 2 { edit?() }
        else {
            select?(syllable)
            dragging = syllable != nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if dragging { drag?(event) }
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    /// The app's own menu replaces the system's: nothing is returned for AppKit to show.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let layout = rowLayout, !layout.input.editing else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        showMenu?(layout.syllable(at: point), NSRect(origin: point, size: .zero))
        return nil
    }

    private func openMoreMenu() {
        guard let layout = rowLayout else { return }
        showMenu?(nil, layout.more)
    }

    func focusEditor() {
        // selectText installs AppKit's shared field editor itself. Making the field first
        // responder immediately before it ends and restarts editing, committing the row.
        if let field, field.currentEditor() == nil { field.selectText(nil) }
    }
    @objc private func submit() { finishEditing(cancelled: false) }
    func controlTextDidEndEditing(_ notification: Notification) { finishEditing(cancelled: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(cancelled: true); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishEditing(cancelled: false); return true }
        return false
    }

    private func finishEditing(cancelled: Bool, notify: Bool = true) {
        guard !endingEdit, let field else { return }
        endingEdit = true
        let value = field.currentEditor()?.string ?? field.stringValue
        self.field = nil
        if field.currentEditor() != nil { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        if notify {
            if cancelled { cancel?() } else { commit?(value) }
        }
        endingEdit = false
    }

    private func rebuildAccessibility() {
        guard let line, let layout = rowLayout else { return }
        accessibilityGeneration += 1
        for element in accessible {
            element.setAccessibilityEnabled(false)
            element.setAccessibilityParent(nil)
        }
        setAccessibilityLabel("第 \(index + 1) 行，\(line.text)")
        accessible = layout.chips.enumerated().map { s, rect in
            let syllable = line.syllables[s]
            let state = selected.contains(s) ? "，已选中" : ""
            let ruby = layout.input.rubies[s].isEmpty ? "" : "，注音 \(layout.input.rubies[s])"
            return actionElement(label: "\(syllable.text)\(ruby)，\(LyricsEditorFormat.time(syllable.start, digits: 3))\(state)", rect: rect) { [weak self] in self?.select?(s) }
        }
        accessible.append(actionElement(label: "编辑这一行", rect: layout.editor) { [weak self] in self?.edit?() })
        accessible.append(actionElement(label: "从这一行播放", rect: layout.play) { [weak self] in self?.play?() })
        accessible.append(actionElement(label: "更多操作", rect: layout.more) { [weak self] in self?.openMoreMenu() })
    }

    private func actionElement(label: String, rect: NSRect, action: @escaping @MainActor @Sendable () -> Void) -> LyricsEditorActionElement {
        let generation = accessibilityGeneration
        return LyricsEditorActionElement(host: self, label: label, rect: rect) { [weak self] in
            // Assistive clients may retain an element after its row has been reused.
            guard self?.accessibilityGeneration == generation else { return }
            action()
        }
    }

    override func accessibilityChildren() -> [Any]? { field != nil ? super.accessibilityChildren() : accessible }
}

/// AppKit invokes these synchronous accessibility callbacks on the main thread. Capture
/// immutable, actor-isolated callbacks rather than transferring the mutable AX object.
final class LyricsEditorActionElement: NSAccessibilityElement {
    private let frameProvider: @MainActor @Sendable () -> NSRect
    private let press: @MainActor @Sendable () -> Void

    @MainActor init(host: NSView, label: String, rect: NSRect, action: @escaping @MainActor @Sendable () -> Void) {
        frameProvider = { [weak host] in
            guard let host, let window = host.window else { return .zero }
            return window.convertToScreen(host.convert(rect, to: nil))
        }
        press = action
        super.init()
        setAccessibilityParent(host)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityEnabled(true)
    }

    override func accessibilityFrame() -> NSRect {
        let callback = frameProvider
        return MainActor.assumeIsolated { callback() }
    }
    override func accessibilityPerformPress() -> Bool {
        let callback = press
        MainActor.assumeIsolated { callback() }
        return true
    }
}
