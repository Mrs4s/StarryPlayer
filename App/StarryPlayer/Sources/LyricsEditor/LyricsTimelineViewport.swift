import Foundation
import Observation

@MainActor @Observable
final class LyricsTimelineViewport {
    /// The current pan/zoom range; nil derives the initial view.
    var manual: ClosedRange<TimeInterval>?
    /// Frozen while AppKit owns a drag, including when clicking selects a different line.
    var interactionRange: ClosedRange<TimeInterval>?

    func range(caretLine line: Int?, in session: LyricsEditorSession) -> ClosedRange<TimeInterval>? {
        if let interactionRange { return interactionRange }
        if let manual { return manual }
        guard let line, session.draft.lines.indices.contains(line), !session.draft.lines[line].syllables.isEmpty else { return nil }
        let window = session.lineWindows[line]
        let span = max(window.upperBound - window.lowerBound + 1, 4)
        let middle = (window.lowerBound + window.upperBound) / 2
        let start = max(0, middle - span / 2)
        return start...(start + span)
    }

    func hold(_ range: ClosedRange<TimeInterval>) {
        manual = range
    }

    /// Freeze the previous initial range before selection can derive a new one.
    func selectionChanged(from previous: Int?, to line: Int?, in session: LyricsEditorSession) {
        guard previous != line else { return }
        if let visible = range(caretLine: previous, in: session) ?? range(caretLine: line, in: session) { manual = visible }
    }

    static let minimumSpan: TimeInterval = 1

    static func duration(of session: LyricsEditorSession, audio: LyricsEditorAudio) -> TimeInterval {
        max(audio.duration, session.track.duration, session.timedEnd, 1)
    }

    // Panning forward must not jump backward when the range already extends past the song.
    func pan(_ range: ClosedRange<TimeInterval>, by delta: TimeInterval, duration: TimeInterval) {
        let span = range.upperBound - range.lowerBound
        var start = max(range.lowerBound + delta, 0)
        if delta > 0 { start = min(start, max(duration - span, range.lowerBound)) }
        manual = start...(start + span)
    }

    func zoom(_ range: ClosedRange<TimeInterval>, by factor: Double, around anchor: TimeInterval, duration: TimeInterval) {
        let span = range.upperBound - range.lowerBound
        guard span > 0, factor > 0 else { return }
        let next = min(max(span * factor, Self.minimumSpan), max(duration, Self.minimumSpan))
        let fraction = min(max((anchor - range.lowerBound) / span, 0), 1)
        let start = min(max(anchor - fraction * next, 0), max(duration - next, 0))
        manual = start...(start + next)
    }
}
