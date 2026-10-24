import Foundation
import LyricsCore

/// `.track(nil)` returns the line to its singer's lane.
enum LyricsTimelineLane: Equatable {
    case unchanged
    case track(UUID?)
}

/// A drag edits one local line. The shared draft and its preview caches change only on
/// mouse-up; a stale drag can never overwrite a keyboard edit, undo, or imported document.
struct LyricsTimelineAdjustment {
    enum Part {
        case start, end, body
        case line

        /// Dropped on the tray, it leaves the timeline.
        var lifts: Bool { self == .body || self == .line }
    }
    let position: LyricsDraft.Position
    let original: LyricsDraft.Line
    let revision: Int
    let part: Part
    let secondsPerPoint: Double
    static let stickiness = 6.0

    @MainActor init?(session: LyricsEditorSession, position: LyricsDraft.Position, part: Part,
                     range: ClosedRange<TimeInterval>, width: Double) {
        guard width > 0, range.upperBound > range.lowerBound, session.draft.contains(position),
              session.draft[position].start != nil else { return nil }
        self.position = position
        original = session.draft.lines[position.line]
        revision = session.revision
        self.part = part
        secondsPerPoint = (range.upperBound - range.lowerBound) / width
    }

    static func stick(_ value: TimeInterval, to edges: [TimeInterval?], reach: TimeInterval) -> TimeInterval {
        edges.compactMap { $0 }.filter { abs($0 - value) <= reach }.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    func preview(translation: Double, onsets: [TimeInterval] = [], lane: LyricsTimelineLane = .unchanged) -> LyricsDraft.Line {
        var line = retimed(translation: translation, onsets: onsets)
        if part == .line, case .track(let track) = lane { line.track = track }
        return line
    }

    private func retimed(translation: Double, onsets: [TimeInterval]) -> LyricsDraft.Line {
        guard translation.isFinite, translation != 0 else { return original }
        let s = position.syllable
        let syllable = original.syllables[s]
        guard let start = syllable.start else { return original }
        let previous = s > 0 ? original.syllables[s - 1] : nil
        let next = s + 1 < original.syllables.count ? original.syllables[s + 1] : nil
        let end = syllable.end ?? next?.start ?? start + 0.3
        let delta = translation * secondsPerPoint
        let reach = Self.stickiness * secondsPerPoint
        let snap = { (t: Double) in (t * 100).rounded() / 100 }
        let minimum = 0.02
        // Pixel reach keeps dragging predictable; the time cap prevents large jumps when
        // zoomed out. Existing neighbouring boundaries retain priority over suggestions.
        let onsetReach = min(reach, 0.05)
        let suggest = { (time: Double) in
            Self.stick(time, to: onsets.map(Optional.some), reach: onsetReach)
        }
        let linkedPrevious = previous?.end.map { abs($0 - start) < 0.002 } ?? false
        let linkedNext = next?.start.map { abs($0 - end) < 0.002 } ?? false
        var line = original
        switch part {
        case .start:
            let floor = previous?.start.map { $0 + minimum } ?? 0
            let moved = Self.stick(suggest(snap(start + delta)), to: linkedPrevious ? [] : [previous?.end], reach: reach)
            let value = min(max(moved, linkedPrevious ? floor : 0), end - minimum)
            line.syllables[s].start = value
            if linkedPrevious { line.syllables[s - 1].end = value }
        case .end:
            let ceiling = next?.end.map { $0 - minimum } ?? .infinity
            let moved = Self.stick(suggest(snap(end + delta)), to: linkedNext ? [] : [next?.start], reach: reach)
            let value = max(min(moved, linkedNext ? ceiling : .infinity), start + minimum)
            line.syllables[s].end = value
            if linkedNext { line.syllables[s + 1].start = value }
        case .body:
            let edges = [previous?.end.map { $0 - start }, next?.start.map { $0 - end }]
            let shift = max(Self.stick(snap(delta), to: edges, reach: reach), -start)
            guard shift != 0 else { return original }
            line.syllables[s].start = start + shift
            line.syllables[s].end = end + shift
        case .line:
            let first = original.timedRange?.lowerBound ?? start
            let shift = max(Self.stick(snap(delta), to: onsets.map { Optional($0 - first) }, reach: onsetReach), -first)
            guard shift != 0 else { return original }
            let moved = { (time: TimeInterval?) in time.map { $0 + shift } }
            line.start = moved(line.start)
            line.end = moved(line.end)
            for k in line.syllables.indices {
                line.syllables[k].start = moved(line.syllables[k].start)
                line.syllables[k].end = moved(line.syllables[k].end)
            }
        }
        return line
    }

    @MainActor @discardableResult
    func commit(translation: Double, onsets: [TimeInterval] = [], lane: LyricsTimelineLane = .unchanged, in session: LyricsEditorSession) -> Bool {
        guard session.revision == revision, session.draft.lines.indices.contains(position.line),
              session.draft.lines[position.line].id == original.id else { return false }
        let line = preview(translation: translation, onsets: onsets, lane: lane)
        guard line != original else { return false }
        session.edit { $0.lines[position.line] = line }
        return true
    }
}
