import Foundation
import LyricsCore

/// Previews tray placement without changing the draft; commits only at the captured revision.
struct LyricsTimelinePlacement {
    let line: Int
    let original: LyricsDraft.Line
    let revision: Int
    let run: Range<Int>
    let secondsPerPoint: Double
    /// The timed syllables around the run in its line: it lands between them.
    let floor: TimeInterval
    let ceiling: TimeInterval
    /// Fresh runs end before the next line of the same voice when there is room.
    let next: TimeInterval?
    let pieces: [(lead: TimeInterval, length: TimeInterval)]
    /// Staged runs retain their timing instead of fitting to the next line.
    let remembered: Bool
    static let syllableLength = 0.3
    static let minimum = 0.02

    @MainActor init?(session: LyricsEditorSession, line: Int, run: Range<Int>, range: ClosedRange<TimeInterval>, width: Double) {
        let lines = session.draft.lines
        guard width > 0, range.upperBound > range.lowerBound, lines.indices.contains(line), !run.isEmpty,
              run.lowerBound >= 0, run.upperBound <= lines[line].syllables.count,
              !lines[line].syllables[run].contains(where: \.isTimed) else { return nil }
        let original = lines[line]
        self.line = line
        self.original = original
        revision = session.revision
        self.run = run
        secondsPerPoint = (range.upperBound - range.lowerBound) / width
        let before = original.syllables[..<run.lowerBound].last(where: \.isTimed)
        floor = before.flatMap { $0.end ?? $0.start.map { $0 + Self.minimum } } ?? 0
        ceiling = original.syllables[run.upperBound...].first(where: \.isTimed)?.start ?? .infinity
        next = lines[(line + 1)...].first { LyricsEditorSession.sameVoice($0, original) && $0.timedRange != nil }?.timedRange?.lowerBound
        // A whole LRC line keeps its length, shared by syllable length like untimed export.
        let lrc = run.count == original.syllables.count ? original.start.flatMap { start in original.end.map { $0 - start } } : nil
        let weights = run.map { Double(max(original.syllables[$0].text.trimmingCharacters(in: .whitespaces).count, 1)) }
        let total = weights.reduce(0, +)
        var remembered = false
        pieces = run.enumerated().map { k, s in
            if let staged = session.staged[original.syllables[s].id] {
                remembered = true
                return (k == 0 ? 0 : staged.lead, staged.length)
            }
            if let lrc, lrc > 0 { return (0, lrc * weights[k] / total) }
            return (0, Self.syllableLength)
        }
        self.remembered = remembered
    }

    static func snap(_ time: TimeInterval) -> TimeInterval { (time * 100).rounded() / 100 }

    func preview(at time: TimeInterval, edges: [TimeInterval] = [], onsets: [TimeInterval] = [],
                 lane: LyricsTimelineLane = .unchanged) -> LyricsDraft.Line {
        guard time.isFinite else { return original }
        let reach = LyricsTimelineAdjustment.stickiness * secondsPerPoint
        let suggested = LyricsTimelineAdjustment.stick(Self.snap(time), to: onsets.map(Optional.some), reach: min(reach, 0.05))
        let stuck = LyricsTimelineAdjustment.stick(suggested, to: edges.map(Optional.some) + [original.start], reach: reach)
        let count = Double(run.count)
        let start = max(min(stuck, ceiling - count * Self.minimum), floor, 0)
        let span = pieces.dropFirst().reduce(0) { $0 + $1.lead } + pieces.reduce(0) { $0 + $1.length }
        var room = ceiling - start
        if !remembered, let next, next - start >= count * 0.1 { room = min(room, next - start) }
        let scale = span > room ? max(room, count * Self.minimum) / span : 1
        var line = original
        var time = start
        for (k, s) in run.enumerated() {
            if k > 0 { time = Self.snap(time + pieces[k].lead * scale) }
            let end = max(Self.snap(time + pieces[k].length * scale), time + 0.01)
            line.syllables[s].start = time
            line.syllables[s].end = end
            time = end
        }
        if line.syllables.allSatisfy(\.isTimed) {
            line.start = nil
            line.end = nil
        }
        if case .track(let track) = lane { line.track = track }
        return line
    }

    @MainActor @discardableResult
    func commit(at time: TimeInterval, edges: [TimeInterval] = [], onsets: [TimeInterval] = [],
                lane: LyricsTimelineLane = .unchanged, in session: LyricsEditorSession) -> Bool {
        guard session.revision == revision, session.draft.lines.indices.contains(line),
              session.draft.lines[line].id == original.id else { return false }
        let placed = preview(at: time, edges: edges, onsets: onsets, lane: lane)
        guard placed != original else { return false }
        session.edit { $0.lines[line] = placed }
        session.select(.init(line: line, syllable: run.lowerBound))
        return true
    }
}
