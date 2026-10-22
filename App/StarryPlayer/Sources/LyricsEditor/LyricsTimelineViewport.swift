import Foundation
import Observation

@MainActor @Observable
final class LyricsTimelineViewport {
    /// Picked by dragging or resizing the overview's frame; nil follows the caret's line.
    var manual: ClosedRange<TimeInterval>?

    func range(caretLine line: Int?, in session: LyricsEditorSession) -> ClosedRange<TimeInterval>? {
        if let manual { return manual }
        guard let line, session.draft.lines.indices.contains(line), !session.draft.lines[line].syllables.isEmpty else { return nil }
        let window = session.lineWindows[line]
        let span = max(window.upperBound - window.lowerBound + 1, 4)
        let middle = (window.lowerBound + window.upperBound) / 2
        let start = max(0, middle - span / 2)
        return start...(start + span)
    }
}
