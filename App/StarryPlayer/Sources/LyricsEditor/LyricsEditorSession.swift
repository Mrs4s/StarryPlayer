import Foundation
import LyricsCore
import Observation
import StarryCore
import SwiftUI

/// Retained by `AppModel` across editor window closures.
@MainActor @Observable
final class LyricsEditorSession {
    typealias Position = LyricsDraft.Position

    let track: Track
    private(set) var draft: LyricsDraft
    /// The syllable the next tap starts; nil once the last one is timed.
    var caret: Position?
    /// Taps land this much earlier than they are pressed, for the time it takes to react.
    var tapLead: TimeInterval = 0
    var editingLine: UUID?
    /// The song's `amll:meta` entries, in order; a key may repeat (one entry per artist).
    var metadata: [MetadataEntry]
    /// The syllable tapped last and a count of taps, for the chip to bounce.
    private(set) var lastTapped: UUID?
    private(set) var tapSerial = 0
    private(set) var revision = 0
    private var savedRevision = 0
    private(set) var flashText: String?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    @ObservationIgnored private var previewCache: (revision: Int, document: LyricsDocument)?
    @ObservationIgnored private var rangesCache: (revision: Int, ranges: [ClosedRange<TimeInterval>?], end: TimeInterval)?
    @ObservationIgnored private var windowsCache: (revision: Int, windows: [ClosedRange<TimeInterval>])?

    private struct Snapshot {
        var draft: LyricsDraft
        var caret: Position?
    }

    struct MetadataEntry: Identifiable, Hashable {
        var id = UUID()
        var key: String
        var value: String
    }

    static let metadataKeys: [(key: String, name: String)] = [
        ("musicName", "歌名"),
        ("artists", "歌手"),
        ("album", "专辑"),
        ("isrc", "ISRC"),
        ("ncmMusicId", "网易云音乐 ID"),
        ("qqMusicId", "QQ 音乐 ID"),
        ("spotifyId", "Spotify ID"),
        ("appleMusicId", "Apple Music ID"),
        ("ttmlAuthorGithub", "作者 GitHub ID"),
        ("ttmlAuthorGithubLogin", "作者 GitHub 用户名"),
    ]

    init(track: Track, draft: LyricsDraft = LyricsDraft()) {
        self.track = track
        self.draft = draft
        var entries = [MetadataEntry(key: "musicName", value: track.title)]
        entries += track.artists.map { MetadataEntry(key: "artists", value: $0.name) }
        if let album = track.album?.name, !album.isEmpty { entries.append(MetadataEntry(key: "album", value: album)) }
        metadata = entries
        caret = draft.firstUntimed ?? draft.firstPosition(fromLine: 0)
        adoptMetadata(of: draft)
    }

    private func adoptMetadata(of draft: LyricsDraft) {
        let own = Set(metadata.map(\.key))
        metadata += draft.metadata.filter { !own.contains($0.key) && !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { MetadataEntry(key: $0.key, value: $0.value) }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasUnsavedChanges: Bool { revision != savedRevision && !draft.isEmpty }

    var document: LyricsDocument {
        if let previewCache, previewCache.revision == revision { return previewCache.document }
        let document = draft.document()
        previewCache = (revision, document)
        return document
    }

    /// Shared by the clock, overview and timeline. Pointer movement and selection do not
    /// change timing, so they must not scan every syllable or interpolate the whole draft.
    var timedRanges: [ClosedRange<TimeInterval>?] {
        if let rangesCache, rangesCache.revision == revision { return rangesCache.ranges }
        let ranges = draft.lines.map(\.timedRange)
        rangesCache = (revision, ranges, ranges.compactMap { $0?.upperBound }.max() ?? 0)
        return ranges
    }

    var timedEnd: TimeInterval {
        _ = timedRanges
        return rangesCache?.end ?? 0
    }

    var lineWindows: [ClosedRange<TimeInterval>] {
        if let windowsCache, windowsCache.revision == revision { return windowsCache.windows }
        let windows = draft.lineWindows()
        windowsCache = (revision, windows)
        return windows
    }

    func markSaved() { savedRevision = revision }

    func flash(_ text: String) {
        flashTask?.cancel()
        withAnimation(Motion.popover) { flashText = text }
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.popover) { self?.flashText = nil }
        }
    }

    // MARK: Editing

    func edit(_ change: (inout LyricsDraft) -> Void) {
        let before = Snapshot(draft: draft, caret: caret)
        var next = draft
        change(&next)
        guard next != draft else { return }
        undoStack.append(before)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        draft = next
        revision += 1
        clampCaret()
    }

    /// Opens an undo step for a drag; `adjust` then changes the draft without adding more.
    func beginAdjusting() {
        undoStack.append(Snapshot(draft: draft, caret: caret))
        redoStack.removeAll()
    }

    func adjust(_ change: (inout LyricsDraft) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        draft = next
        revision += 1
    }

    func endAdjusting() {
        if let last = undoStack.last, last.draft == draft { undoStack.removeLast() }
    }

    func replace(with draft: LyricsDraft) {
        edit { $0 = draft }
        caret = draft.firstUntimed ?? draft.firstPosition(fromLine: 0)
        adoptMetadata(of: draft)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(draft: draft, caret: caret))
        draft = snapshot.draft
        caret = snapshot.caret
        revision += 1
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(draft: draft, caret: caret))
        draft = snapshot.draft
        caret = snapshot.caret
        revision += 1
    }

    private func clampCaret() {
        guard let caret, !draft.contains(caret) else { return }
        if draft.lines.indices.contains(caret.line), !draft.lines[caret.line].syllables.isEmpty {
            self.caret = Position(line: caret.line, syllable: draft.lines[caret.line].syllables.count - 1)
        } else {
            self.caret = draft.firstPosition(fromLine: caret.line) ?? draft.firstPosition(throughLine: caret.line)
        }
    }

    // MARK: Timing

    var lastStarted: Position? {
        if let caret { return draft.position(before: caret) }
        guard let line = draft.lines.lastIndex(where: { !$0.syllables.isEmpty }) else { return nil }
        return Position(line: line, syllable: draft.lines[line].syllables.count - 1)
    }

    /// Tap lead is measured in real time, so slower playback needs a smaller song-time offset.
    func tap(at time: TimeInterval, rate: Double = 1) {
        guard let caret, draft.contains(caret) else { return }
        let time = max(0, time - tapLead * rate)
        let previous = draft.position(before: caret)
        edit { draft in
            if let previous, let start = draft[previous].start, start < time, (draft[previous].end ?? .infinity) > time {
                draft[previous].end = time
            }
            draft[caret].start = time
            // Timed again: its old end no longer holds.
            draft[caret].end = nil
        }
        lastTapped = draft[caret].id
        tapSerial += 1
        self.caret = draft.position(after: caret)
    }

    func release(at time: TimeInterval, rate: Double = 1) {
        guard let target = lastStarted, let start = draft[target].start else { return }
        let time = max(0, time - tapLead * rate)
        guard time > start else { return }
        edit { $0[target].end = time }
    }

    func stepBack() {
        guard let target = lastStarted else { return }
        edit { draft in
            draft[target].start = nil
            draft[target].end = nil
        }
        caret = target
    }

    func moveCaret(by step: Int) {
        guard let current = caret ?? lastStarted else { return }
        var position: Position? = current
        for _ in 0..<abs(step) {
            guard let p = position else { break }
            position = step > 0 ? draft.position(after: p) : draft.position(before: p)
        }
        if let position { caret = position }
    }

    func playbackStart(of position: Position) -> TimeInterval? {
        guard draft.contains(position) else { return nil }
        if let start = draft[position].start { return start }
        let line = draft.lines[position.line]
        return line.timedRange?.lowerBound ?? lineWindows[position.line].lowerBound
    }

    func selectLine(_ index: Int) {
        guard draft.lines.indices.contains(index), caret?.line != index else { return }
        let syllables = draft.lines[index].syllables
        guard !syllables.isEmpty else { return }
        caret = Position(line: index, syllable: syllables.firstIndex { !$0.isTimed } ?? 0)
    }

    func moveCaretLine(by step: Int) {
        guard let current = caret ?? lastStarted else { return }
        let target = current.line + step
        let position = step > 0 ? draft.firstPosition(fromLine: target) : draft.firstPosition(throughLine: target)
        if let position { caret = position }
    }

    func nudge(by delta: TimeInterval) {
        guard let target = caret.flatMap({ draft[$0].isTimed ? $0 : nil }) ?? lastStarted, draft[target].isTimed else { return }
        edit { draft in
            draft[target].start = draft[target].start.map { max(0, $0 + delta) }
            draft[target].end = draft[target].end.map { max(0, $0 + delta) }
        }
    }

    // MARK: Export

    var exportMetadata: [(key: String, value: String)] {
        metadata.compactMap { entry in
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            let value = entry.value.trimmingCharacters(in: .whitespaces)
            return key.isEmpty || value.isEmpty ? nil : (key, value)
        }
    }

    func ttml() -> String {
        TTMLWriter.write(document, metadata: exportMetadata, duration: track.duration > 0 ? track.duration : nil)
    }

    var exportFileName: String {
        let name = track.artistText.isEmpty ? track.title : "\(track.artistText) - \(track.title)"
        return name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：") + ".ttml"
    }
}
