import Foundation
import LyricsCore

struct LyricsTimelineRubyAdjustment {
    let line: Int
    let original: LyricsDraft.Line
    let revision: Int
    let annotation: LyricsDraft.RubyAnnotation
    let piece: Int
    let edge: LyricsDraft.RubyEdge
    let base: ClosedRange<TimeInterval>
    let origin: TimeInterval
    let secondsPerPoint: Double

    @MainActor init?(session: LyricsEditorSession, line: Int, annotation: LyricsDraft.RubyAnnotation, piece: Int,
                     edge: LyricsDraft.RubyEdge, range: ClosedRange<TimeInterval>, width: Double) {
        guard width > 0, range.upperBound > range.lowerBound, session.draft.lines.indices.contains(line) else { return nil }
        let original = session.draft.lines[line]
        guard original.syllables.indices.contains(annotation.syllables.upperBound),
              let base = original.rubyBase(of: annotation) else { return nil }
        let times = original.rubyTimes(of: annotation, base: base)
        guard times.indices.contains(piece) else { return nil }
        self.line = line
        self.original = original
        revision = session.revision
        self.annotation = annotation
        self.piece = piece
        self.edge = edge
        self.base = base
        origin = edge == .start ? times[piece].start : times[piece].end
        secondsPerPoint = (range.upperBound - range.lowerBound) / width
    }

    func time(translation: Double, onsets: [TimeInterval] = []) -> TimeInterval {
        let reach = LyricsTimelineAdjustment.stickiness * secondsPerPoint
        var time = ((origin + translation * secondsPerPoint) * 100).rounded() / 100
        time = LyricsTimelineAdjustment.stick(time, to: onsets.map(Optional.some), reach: min(reach, 0.05))
        let boundaries = original.syllables[annotation.syllables].flatMap { [$0.start, $0.end] }
        return LyricsTimelineAdjustment.stick(time, to: boundaries, reach: reach)
    }

    func preview(translation: Double, onsets: [TimeInterval] = []) -> LyricsDraft.Line {
        previewWithSnap(translation: translation, onsets: onsets).line
    }

    func previewWithSnap(translation: Double, onsets: [TimeInterval] = []) -> LyricsTimelinePreview {
        guard translation.isFinite else { return LyricsTimelinePreview(line: original) }
        let time = translation == 0 ? origin : time(translation: translation, onsets: onsets)
        let line = translation == 0 ? original : original.movingRubyEdge(edge, ofPiece: piece, in: annotation, base: base, to: time)
        let boundaries = original.syllables[annotation.syllables].flatMap { [$0.start, $0.end] }
        let aligned = edgeTime(in: line).map { abs($0 - time) < 1e-9 } ?? false
        let snappedTime = aligned && (boundaries.contains(time) || onsets.contains(time)) ? time : nil
        return LyricsTimelinePreview(line: line, snappedTime: snappedTime)
    }

    func edgeTime(in line: LyricsDraft.Line) -> TimeInterval? {
        let times = line.rubyTimes(of: annotation, base: base)
        guard times.indices.contains(piece) else { return nil }
        return edge == .start ? times[piece].start : times[piece].end
    }

    @MainActor @discardableResult
    func commit(translation: Double, onsets: [TimeInterval] = [], in session: LyricsEditorSession) -> Bool {
        guard session.revision == revision, session.draft.lines.indices.contains(line),
              session.draft.lines[line].id == original.id else { return false }
        let edited = preview(translation: translation, onsets: onsets)
        guard edited != original else { return false }
        session.edit { $0.lines[line] = edited }
        return true
    }
}
