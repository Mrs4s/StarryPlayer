import Foundation

public struct CompactLyricsTimeline: Sendable, Equatable {
    public enum Item: Sendable, Hashable {
        case line(Int)
        case idle
    }

    public struct Change: Sendable, Equatable {
        public var time: TimeInterval
        public var item: Item
    }

    public let changes: [Change]

    /// `duration` enables the final instrumental break; `lead` shows lines before
    /// their start to match the lyric progress headstart.
    public init(document: LyricsDocument, duration: TimeInterval? = nil, lead: TimeInterval = 0.1, breakMinimum: TimeInterval = 7) {
        var changes: [Change] = []
        let sung = document.lines.indices.filter { !document.lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for index in sung {
            changes.append(Change(time: document.lines[index].start - lead, item: .line(index)))
        }
        for gap in document.instrumentalGaps(minimum: breakMinimum) where gap.afterLine != nil {
            changes.append(Change(time: gap.start, item: .idle))
        }
        if let duration, let lastEnd = sung.map({ document.lines[$0].end }).max(), duration - lastEnd > breakMinimum {
            changes.append(Change(time: lastEnd + 0.1, item: .idle))
        }
        // Stable, so of two changes at the same time the later-listed (the later line) wins.
        let ordered = changes.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map(\.element)
        var result: [Change] = []
        for change in ordered {
            if let last = result.last, last.time == change.time {
                result.removeLast()
            }
            if (result.last?.item ?? .idle) != change.item {
                result.append(change)
            }
        }
        self.changes = result
    }

    public func item(at t: TimeInterval) -> Item {
        guard let index = lastChange(atOrBefore: t) else { return .idle }
        return changes[index].item
    }

    /// The first time after `t` at which the shown item changes; nil when it never does.
    public func nextChange(after t: TimeInterval) -> TimeInterval? {
        let next = (lastChange(atOrBefore: t) ?? -1) + 1
        return next < changes.count ? changes[next].time : nil
    }

    private func lastChange(atOrBefore t: TimeInterval) -> Int? {
        var lo = 0, hi = changes.count - 1, result: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if changes[mid].time <= t {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }
}
