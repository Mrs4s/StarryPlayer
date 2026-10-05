import AppKit
import CoreText
import LyricsCore

/// Plain system-title lyrics. Call `sync()` on play, pause and seek; a timer handles
/// line boundaries without periodic clock polling. The owner dims paused text.
@MainActor
public final class MenuBarLyricsTitle {
    public var content = MenuBarLyricsView.Content() {
        didSet {
            guard content != oldValue else { return }
            if content.document != oldValue.document || content.duration != oldValue.duration {
                timeline = content.document.map { CompactLyricsTimeline(document: $0, duration: content.duration > 0 ? content.duration : nil) }
            }
            needsRender = true
            sync()
        }
    }

    public var maxTextWidth: CGFloat = 300 {
        didSet { if maxTextWidth != oldValue { needsRender = true; sync() } }
    }

    public var font: NSFont = .menuBarFont(ofSize: 0) {
        didSet { if font != oldValue { needsRender = true; sync() } }
    }

    /// Seconds added to the player time before lyrics are resolved (positive = lyrics earlier).
    public var timeOffset: TimeInterval = 0 {
        didSet { if timeOffset != oldValue { sync() } }
    }

    public var timeSource: (() -> (time: TimeInterval, rate: Double))?

    public private(set) var title = ""
    /// The whole text, not cut short (accessibility).
    public private(set) var text = ""
    public var onChange: (() -> Void)?

    private var timeline: CompactLyricsTimeline?
    private var shown: CompactLyricsTimeline.Item?
    private var needsRender = true
    private let timer = LyricsChangeTimer()

    public init() {}

    public func sync() {
        guard let clock = timeSource?() else { return }
        let t = clock.time + timeOffset
        let rate = max(clock.rate, 0)
        let item = timeline?.item(at: t) ?? .idle
        if item != shown || needsRender {
            shown = item
            needsRender = false
            render(item)
        }
        timer.schedule(rate > 0 ? timeline?.nextChange(after: t) : nil, from: t, rate: rate) { [weak self] in self?.sync() }
    }

    public func stop() {
        timer.cancel()
    }

    private func render(_ item: CompactLyricsTimeline.Item) {
        let full: String
        switch item {
        case .line(let index):
            guard let document = content.document, index < document.lines.count else { return publish("", text: "") }
            full = MenuBarLyricsView.singleRow(document.lines[index]).text.trimmingCharacters(in: .whitespaces)
        case .idle:
            guard !content.title.isEmpty else { return publish("", text: "") }
            full = content.artist.isEmpty ? content.title : "\(content.title) - \(content.artist)"
        }
        publish(Self.fitted(NSAttributedString(string: full, attributes: [.font: font]), width: maxTextWidth).string, text: full)
    }

    private func publish(_ title: String, text: String) {
        guard title != self.title || text != self.text else { return }
        self.title = title
        self.text = text
        onChange?()
    }

    static func fitted(_ string: NSAttributedString, width: CGFloat) -> NSAttributedString {
        func measure(_ s: NSAttributedString) -> CGFloat {
            let line = CTLineCreateWithAttributedString(s)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        }
        guard string.length > 0, measure(string) > width else { return string }
        let text = string.string as NSString
        let line = CTLineCreateWithAttributedString(string)
        let ellipsis = NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil))
        let room = width - measure(ellipsis)
        var end = min(max(CTLineGetStringIndexForPosition(line, CGPoint(x: room, y: 0)), 0), text.length)
        func prefix(_ end: Int) -> NSMutableAttributedString {
            let cut = NSMutableAttributedString(attributedString: string.attributedSubstring(from: NSRange(location: 0, length: end)))
            while cut.length > 0, (cut.string as NSString).character(at: cut.length - 1) == 0x20 { cut.deleteCharacters(in: NSRange(location: cut.length - 1, length: 1)) }
            return cut
        }
        if end < text.length { end = text.rangeOfComposedCharacterSequence(at: end).location }
        while end > 0, measure(prefix(end)) > room {
            end = text.rangeOfComposedCharacterSequence(at: end - 1).location
        }
        let result = prefix(end)
        let attributes = result.length > 0 ? result.attributes(at: result.length - 1, effectiveRange: nil) : string.attributes(at: 0, effectiveRange: nil)
        result.append(NSAttributedString(string: "…", attributes: attributes))
        return result
    }
}

/// Use common run-loop modes so the timer fires while the status-item menu tracks events.
@MainActor
final class LyricsChangeTimer {
    private var timer: Timer?
    private(set) var target: TimeInterval?
    var isScheduled: Bool { timer != nil }
    static let longestStallWait: TimeInterval = 0.25
    /// The clock and the wait of the last timer set, to notice a clock that does not move.
    private var last: (from: TimeInterval, delay: TimeInterval)?

    /// Fires `action` when lyric time `next` comes, from `t` at `rate`; nil (or a stopped clock)
    /// cancels. `keepIfSame` leaves a timer already set for `next` alone (steady playback).
    func schedule(_ next: TimeInterval?, from t: TimeInterval, rate: Double, keepIfSame: Bool = false, action: @escaping @MainActor () -> Void) {
        let next = rate > 0 ? next : nil
        if keepIfSame, timer != nil, next == target { return }
        let previous = (target: target, last: last)
        cancel()
        target = next
        guard let next else { return }
        var delay = max((next - t) / rate, 0.05)
        // A clock that stood still while it says it plays (a stall, a seek not landed yet):
        // wait twice as long each time, up to a quarter of a second, instead of waking in a
        // loop. The line then comes at most that late once the music goes on.
        if previous.target == next, let last = previous.last, last.from == t {
            delay = max(delay, min(last.delay * 2, Self.longestStallWait))
        }
        last = (t, delay)
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }

    var lastDelay: TimeInterval? { last?.delay }
}
