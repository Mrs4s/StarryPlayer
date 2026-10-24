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
    /// IDs preserve selection when syllables move between lines.
    private(set) var selection: Set<UUID> = []
    @ObservationIgnored private var selectionAnchor: UUID?
    /// The song's `amll:meta` entries, in order; a key may repeat (one entry per artist).
    var metadata: [MetadataEntry]
    /// The syllable tapped last and a count of taps, for the chip to bounce.
    private(set) var lastTapped: UUID?
    private(set) var tapSerial = 0
    private(set) var revision = 0
    private var savedRevision = 0
    private(set) var flashText: String?
    var isGeneratingRomanization = false
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    @ObservationIgnored private var previewCache: (revision: Int, document: LyricsDocument)?
    @ObservationIgnored private var rangesCache: (revision: Int, ranges: [ClosedRange<TimeInterval>?], end: TimeInterval)?
    @ObservationIgnored private var windowsCache: (revision: Int, windows: [ClosedRange<TimeInterval>])?
    /// Restores durations and gaps when syllables are placed back from the tray.
    @ObservationIgnored private(set) var staged: [UUID: StagedTiming] = [:]

    struct StagedTiming: Hashable {
        /// The gap after the syllable before it, when that went into the tray along with it.
        var lead: TimeInterval
        var length: TimeInterval
    }

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
        pruneSelection()
    }

    func replace(with draft: LyricsDraft) {
        edit { $0 = draft }
        staged = [:]
        caret = draft.firstUntimed ?? draft.firstPosition(fromLine: 0)
        adoptMetadata(of: draft)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(draft: draft, caret: caret))
        draft = snapshot.draft
        caret = snapshot.caret
        revision += 1
        pruneSelection()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(draft: draft, caret: caret))
        draft = snapshot.draft
        caret = snapshot.caret
        revision += 1
        pruneSelection()
    }

    private func clampCaret() {
        guard let caret, !draft.contains(caret) else { return }
        if draft.lines.indices.contains(caret.line), !draft.lines[caret.line].syllables.isEmpty {
            self.caret = Position(line: caret.line, syllable: draft.lines[caret.line].syllables.count - 1)
        } else {
            self.caret = draft.firstPosition(fromLine: caret.line) ?? draft.firstPosition(throughLine: caret.line)
        }
    }

    // MARK: Selection

    var selectedPositions: [Position] {
        guard !selection.isEmpty else { return [] }
        return draft.lines.indices.flatMap { l in
            draft.lines[l].syllables.indices.compactMap { selection.contains(draft.lines[l].syllables[$0].id) ? Position(line: l, syllable: $0) : nil }
        }
    }

    var editTargets: [Position] {
        if !selection.isEmpty { return selectedPositions }
        return caret.flatMap { draft.contains($0) ? [$0] : nil } ?? []
    }

    func select(_ position: Position) {
        guard draft.contains(position) else { return }
        caret = position
        selection = []
        selectionAnchor = draft[position].id
    }

    func toggleSelection(_ position: Position) {
        guard draft.contains(position) else { return }
        let id = draft[position].id
        if selection.isEmpty, let caret, caret != position, draft.contains(caret) { selection.insert(draft[caret].id) }
        if selection.remove(id) == nil {
            selection.insert(id)
            caret = position
        }
        selectionAnchor = id
    }

    func extendSelection(to position: Position) {
        guard draft.contains(position) else { return }
        let anchor = selectionAnchor.flatMap(self.position(of:)) ?? caret.flatMap { draft.contains($0) ? $0 : nil } ?? position
        selectionAnchor = draft[anchor].id
        let (from, to) = (min(anchor, position), max(anchor, position))
        var ids = Set<UUID>()
        for l in from.line...to.line {
            let syllables = draft.lines[l].syllables
            let lo = l == from.line ? from.syllable : 0
            let hi = l == to.line ? to.syllable : syllables.count - 1
            if lo <= hi { ids.formUnion(syllables[lo...hi].map(\.id)) }
        }
        // Avoid observation updates on every mouse move.
        if selection != ids { selection = ids }
    }

    func selectAll() {
        selection = Set(draft.lines.flatMap { $0.syllables.map(\.id) })
    }

    func selectSyllables(ofLine index: Int) {
        guard draft.lines.indices.contains(index) else { return }
        selection = Set(draft.lines[index].syllables.map(\.id))
        selectionAnchor = draft.lines[index].syllables.first?.id
        if let first = draft.firstPosition(fromLine: index), first.line == index { caret = first }
    }

    func clearSelection() {
        selection = []
    }

    func position(of id: UUID) -> Position? {
        for (l, line) in draft.lines.enumerated() {
            if let s = line.syllables.firstIndex(where: { $0.id == id }) { return Position(line: l, syllable: s) }
        }
        return nil
    }

    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        selection.formIntersection(draft.lines.flatMap { $0.syllables.map(\.id) })
    }

    // MARK: Quick edits

    func moveToNewLine(_ positions: [Position]? = nil) {
        var targets = positions ?? editTargets
        if positions == nil, selection.isEmpty, let caret, draft.contains(caret) {
            guard caret.syllable > 0 else { return flash("已经在行首了") }
            targets = (caret.syllable..<draft.lines[caret.line].syllables.count).map { Position(line: caret.line, syllable: $0) }
        }
        move(targets) { _ = $0.moveSyllablesToNewLine(targets) }
    }

    func moveToLine(by offset: Int, _ positions: [Position]? = nil) {
        let targets = positions ?? editTargets
        guard let first = targets.min(), let last = targets.max() else { return }
        guard draft.lines.indices.contains(offset < 0 ? first.line - 1 : last.line + 1) else {
            return flash(offset < 0 ? "上面没有行了" : "下面没有行了")
        }
        move(targets) { _ = $0.moveSyllables(targets, toLineBy: offset) }
    }

    private func move(_ targets: [Position], _ change: (inout LyricsDraft) -> Void) {
        guard !targets.isEmpty else { return }
        let ids = targets.sorted().map { draft[$0].id }
        edit(change)
        if let first = ids.first, let position = position(of: first) { caret = position }
    }

    func moveLine(by offset: Int, id: UUID? = nil) {
        guard let index = id.flatMap({ id in draft.lines.firstIndex { $0.id == id } }) ?? caret?.line,
              draft.lines.indices.contains(index) else { return }
        let held = caret.flatMap { draft.lines.indices.contains($0.line) ? (line: draft.lines[$0.line].id, syllable: $0.syllable) : nil }
        var moved: Int?
        edit { moved = $0.moveLine(at: index, by: offset) }
        guard moved != nil else { return flash(offset < 0 ? "已经是第一行了" : "已经是最后一行了") }
        if let held, let line = draft.lines.firstIndex(where: { $0.id == held.line }) {
            caret = Position(line: line, syllable: held.syllable)
        }
    }

    var canMergeSelection: Bool { selection.count > 1 && LyricsDraft.isRun(selectedPositions) }

    func mergeSelection() {
        let targets = selectedPositions
        guard targets.count > 1 else { return }
        guard LyricsDraft.isRun(targets) else { return flash("只能合并同一行里相邻的音节") }
        var merged: Position?
        edit { merged = $0.mergeSyllables(targets) }
        guard let merged else { return }
        caret = merged
        selection = [draft[merged].id]
        selectionAnchor = draft[merged].id
    }

    func clearTiming(_ positions: [Position]? = nil) {
        let targets = positions ?? editTargets
        edit { draft in
            for position in targets where draft.contains(position) {
                draft[position].start = nil
                draft[position].end = nil
            }
        }
    }

    func delete(_ positions: [Position]? = nil) {
        let targets = positions ?? editTargets
        guard !targets.isEmpty else { return }
        edit { $0.removeSyllables(targets) }
        flash("已删除 \(targets.count) 个音节")
    }

    // MARK: Tray

    func stage(_ positions: [Position]) {
        let targets = Set(positions).filter { draft.contains($0) && draft[$0].isTimed }.sorted()
        guard !targets.isEmpty else { return }
        var timing: [UUID: StagedTiming] = [:]
        var previous: (position: Position, end: TimeInterval)?
        for position in targets {
            let syllables = draft.lines[position.line].syllables
            let start = syllables[position.syllable].start ?? 0
            let next = syllables.indices.contains(position.syllable + 1) ? syllables[position.syllable + 1].start : nil
            let end = max(syllables[position.syllable].end ?? next ?? start + LyricsTimelinePlacement.syllableLength, start)
            let follows = previous.map { $0.position == Position(line: position.line, syllable: position.syllable - 1) } ?? false
            timing[syllables[position.syllable].id] = StagedTiming(lead: follows ? max(0, start - previous!.end) : 0, length: end - start)
            previous = (position, end)
        }
        edit { draft in
            for position in targets {
                draft[position].start = nil
                draft[position].end = nil
            }
            for line in Set(targets.map(\.line)) where !draft.lines[line].syllables.contains(where: \.isTimed) {
                draft.lines[line].start = nil
                draft.lines[line].end = nil
            }
        }
        staged.merge(timing) { $1 }
    }

    func stageLine(_ index: Int) {
        guard draft.lines.indices.contains(index) else { return }
        stage(draft.lines[index].syllables.indices.map { Position(line: index, syllable: $0) })
    }

    // MARK: Tracks

    nonisolated static func name(of track: LyricsDraft.Track) -> String {
        track.name.isEmpty ? "未命名轨道" : track.name
    }

    nonisolated private static func newTrackName(after tracks: [LyricsDraft.Track]) -> String {
        let names = Set(tracks.map(\.name))
        var number = 1
        while names.contains("轨道 \(number)") { number += 1 }
        return "轨道 \(number)"
    }

    @discardableResult
    func addTrack(moving line: UUID? = nil) -> UUID {
        let track = LyricsDraft.Track(name: Self.newTrackName(after: draft.tracks))
        edit { draft in
            draft.tracks.append(track)
            if let index = draft.lines.firstIndex(where: { $0.id == line }) { draft.lines[index].track = track.id }
        }
        return track.id
    }

    func setTrack(_ track: UUID?, ofLine line: UUID) {
        edit { draft in
            guard let index = draft.lines.firstIndex(where: { $0.id == line }) else { return }
            draft.lines[index].track = track
        }
    }

    func renameTrack(_ id: UUID, to name: String) {
        edit { draft in
            guard let index = draft.tracks.firstIndex(where: { $0.id == id }) else { return }
            draft.tracks[index].name = name
        }
    }

    func removeTrack(_ id: UUID) {
        edit { $0.removeTrack(id) }
    }

    func separateOverlaps() {
        var moved = 0
        edit { draft in
            moved = draft.separateOverlaps { LyricsDraft.Track(name: Self.newTrackName(after: $0)) }
        }
        flash(moved == 0 ? "没有重叠的行" : "已把 \(moved) 行重叠的歌词分到虚拟轨")
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
        // Another voice may still be singing when this one starts.
        let previous = draft.position(before: caret).flatMap { previous in
            Self.sameVoice(draft.lines[previous.line], draft.lines[caret.line]) ? previous : nil
        }
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

    static func sameVoice(_ a: LyricsDraft.Line, _ b: LyricsDraft.Line) -> Bool {
        a.id == b.id || (a.singer == b.singer && a.isBackground == b.isBackground)
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

    /// Validate at TTML output boundaries; editing and project files allow incomplete drafts.
    func validateForExport() -> Bool {
        switch draft.firstExportIssue {
        case nil:
            return true
        case .timingOverlap(let position):
            select(position)
            flash("无法导出：第 \(position.line + 1) 行第 \(position.syllable + 1) 个音节早于前一音节的结束时间")
        case .strayBackground(let line):
            if let position = draft.firstPosition(fromLine: line), position.line == line { select(position) }
            flash("无法导出：第 \(line + 1) 行是背景人声，但它正上方没有可以跟随的主歌词行")
        }
        return false
    }

    func exportTTML() -> String? {
        validateForExport() ? ttml() : nil
    }

    private var fileStem: String {
        let name = track.artistText.isEmpty ? track.title : "\(track.artistText) - \(track.title)"
        return name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
    }

    var exportFileName: String { fileStem + ".ttml" }

    // MARK: Project

    var projectFileName: String { fileStem + "." + LyricsProject.fileExtension }

    var project: LyricsProject {
        LyricsProject(draft: draft, metadata: metadata.map { .init(key: $0.key, value: $0.value) },
                      title: track.title, artists: track.artists.map(\.name))
    }

    func open(_ project: LyricsProject) {
        replace(with: project.draft)
        if !project.metadata.isEmpty { metadata = project.metadata.map { MetadataEntry(key: $0.key, value: $0.value) } }
    }
}
