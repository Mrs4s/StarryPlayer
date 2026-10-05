import Foundation

public struct LyricsTimelineEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case line(Int)
        case instrumental(Int)
    }

    public var kind: Kind
    public var start: TimeInterval
    public var end: TimeInterval
    /// End of the line's background vocals (`LyricLine.background?.end`); nil without any.
    public var backgroundEnd: TimeInterval?

    public init(kind: Kind, start: TimeInterval, end: TimeInterval, backgroundEnd: TimeInterval? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.backgroundEnd = backgroundEnd
    }

    public var isInstrumental: Bool {
        if case .instrumental = kind { true } else { false }
    }

    /// The time from which the entry may give way to the next: `margin` before its end, but
    /// never while its background vocals are still sung. The main vocals are completed early
    /// by `finish`; background vocals only follow the clock, so cutting them short would leave
    /// them visibly unfinished.
    public func releaseTime(margin: TimeInterval) -> TimeInterval {
        guard let backgroundEnd else { return end - margin }
        return max(end - margin, backgroundEnd)
    }
}

public struct LyricsSelection: Sendable {
    public struct Configuration: Sendable {
        public var maxEndTimeOffset: TimeInterval
        public var finishLineAnimationDuration: TimeInterval
        public var animationDuration: @Sendable (TimeInterval) -> TimeInterval

        public init(maxEndTimeOffset: TimeInterval = 0.5, finishLineAnimationDuration: TimeInterval = 0.25, animationDuration: @escaping @Sendable (TimeInterval) -> TimeInterval) {
            self.maxEndTimeOffset = maxEndTimeOffset
            self.finishLineAnimationDuration = finishLineAnimationDuration
            self.animationDuration = animationDuration
        }
    }

    public enum Event: Sendable, Equatable {
        /// The entry becomes the only selected one (the page animates to it). `gap` is
        /// `entry.start − previous.end`, nil when nothing was selected.
        case select(Int, gap: TimeInterval?)
        case append(Int)
        case deselect(Int)
        case finish(Int)
        case jump(Int, selected: Bool)

        var changesSelection: Bool {
            if case .finish = self { false } else { true }
        }
    }

    public let entries: [LyricsTimelineEntry]
    public var configuration: Configuration {
        didSet { lastLead = nil }
    }
    /// Cache by gap: measuring the word-synced spring every frame is expensive.
    private var lastLead: (gap: TimeInterval, duration: TimeInterval)?
    public private(set) var selected: [Int] = []
    public private(set) var next: Int?

    public init(entries: [LyricsTimelineEntry], configuration: Configuration) {
        self.entries = entries
        self.configuration = configuration
    }

    public static func entries(for document: LyricsDocument, gaps: [InstrumentalGap]) -> [LyricsTimelineEntry] {
        var entries: [LyricsTimelineEntry] = []
        var gapAfter: [Int: Int] = [:]
        for (gi, gap) in gaps.enumerated() { gapAfter[gap.afterLine ?? -1] = gi }
        func addGap(after line: Int) {
            guard let gi = gapAfter[line] else { return }
            entries.append(LyricsTimelineEntry(kind: .instrumental(gi), start: gaps[gi].start, end: gaps[gi].end))
        }
        addGap(after: -1)
        for (index, line) in document.lines.enumerated() where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(LyricsTimelineEntry(kind: .line(index), start: line.start, end: line.end, backgroundEnd: line.background?.end))
            addGap(after: index)
        }
        return entries
    }

    /// A new clock position that is not a continuation of the last one (seek, click, new lyrics):
    /// the last entry starting by `t + 0.1` is selected if it already started (or starts within 0.1
    /// s), otherwise nothing is selected until it does.
    public mutating func jump(to t: TimeInterval) -> [Event] {
        guard !entries.isEmpty else {
            selected = []
            next = nil
            return []
        }
        let candidate = entry(before: t + 0.1) ?? 0
        let start = entries[candidate].start
        if start < t || abs(t - start) <= 0.1 {
            selected = [candidate]
            next = after(candidate)
            return [.jump(candidate, selected: true)]
        }
        selected = []
        next = candidate
        return [.jump(candidate, selected: false)]
    }

    /// The events of one frame. The rules are applied until the selection holds: a line can be
    /// selected and give way at the same instant (shorter than the margins, or reached as the
    /// line it ran under is dropped at its end), and a frame passes it by, so the page makes one
    /// move to the line after it instead of one on each of two frames in a row.
    public mutating func update(at t: TimeInterval) -> [Event] {
        var events: [Event] = []
        for _ in 0...entries.count {
            let step = self.step(at: t)
            events += step.filter { !events.contains($0) }
            guard step.contains(where: \.changesSelection) else { break }
        }
        return events
    }

    private mutating func step(at t: TimeInterval) -> [Event] {
        ensureNext(at: t)
        guard let n = next else { return [] }
        var events: [Event] = []
        let nextEntry = entries[n]
        let lead = animationDuration(gap: selected.last.map { nextEntry.start - entries[$0].end } ?? 0)
        let ahead = t + lead
        let byEnd = selected.sorted { entries[$0].end < entries[$1].end }

        switch finishCheck(at: t + configuration.finishLineAnimationDuration, lead: lead, next: n, byEnd: byEnd) {
        case .finish:
            events += selected.map { .finish($0) }
        case .none, .overlapping:
            if selected.count >= 2, entries[selected[0]].releaseTime(margin: lead) < t {
                events.append(.deselect(selected.removeFirst()))
            }
        }

        // Past the last line the cursor re-finds a line that is already selected; selecting it
        // again would change nothing.
        guard nextEntry.start <= ahead, selected != [n] else { return events }
        guard let last = byEnd.last else {
            select(n)
            events.append(.select(n, gap: nil))
            return events
        }
        let lastEntry = entries[last]
        let maxEnd = configuration.maxEndTimeOffset
        if !nextEntry.isInstrumental, !lastEntry.isInstrumental, last < n, nextEntry.start < t {
            if !selected.contains(n) {
                selected.append(n)
                events.append(.append(n))
            }
            next = after(n)
        } else if t > lastEntry.releaseTime(margin: maxEnd) {
            select(n)
            events.append(.select(n, gap: nextEntry.start - lastEntry.end))
        }
        return events
    }

    private enum FinishCheck { case none, finish, overlapping }

    private mutating func animationDuration(gap: TimeInterval) -> TimeInterval {
        if let lastLead, lastLead.gap == gap { return lastLead.duration }
        let duration = configuration.animationDuration(gap)
        lastLead = (gap, duration)
        return duration
    }

    private func finishCheck(at tf: TimeInterval, lead: TimeInterval, next n: Int, byEnd: [Int]) -> FinishCheck {
        let nextEntry = entries[n]
        guard nextEntry.start <= tf + lead, let last = byEnd.last else { return .none }
        let release = entries[last].releaseTime(margin: configuration.maxEndTimeOffset)
        if !nextEntry.isInstrumental, !entries[last].isInstrumental, last < n {
            if nextEntry.start < tf { return .overlapping }
            if release < tf { return .finish }
        } else if release < tf {
            return .finish
        }
        return .none
    }

    private mutating func select(_ n: Int) {
        selected = [n]
        next = after(n)
    }

    /// Never recover a cursor before the selection: doing so can reselect the preceding
    /// line and make the page jump backwards near the end.
    private mutating func ensureNext(at t: TimeInterval) {
        guard next == nil, let first = entries.first else { return }
        if t > first.start {
            guard let b = entry(before: t) else { return }
            let candidate = t < entries[b].end ? b : after(b)
            if let last = selected.max(), let candidate, candidate < last {
                next = last
            } else {
                next = candidate
            }
        } else {
            next = 0
        }
    }

    /// The entry that started last at or before `t` (`Lyrics.line(before:)`); on equal starts
    /// the later one. Chosen by start time rather than position, so one line with bad timing
    /// cannot capture every seek.
    private func entry(before t: TimeInterval) -> Int? {
        var best: Int?
        for (i, e) in entries.enumerated() where e.start <= t {
            if let b = best, entries[b].start > e.start { continue }
            best = i
        }
        return best
    }

    private func after(_ i: Int) -> Int? {
        i + 1 < entries.count ? i + 1 : nil
    }
}
