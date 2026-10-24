import Foundation

/// An editable lyric for the lyric editor: lines of syllables whose timing may still be missing.
/// The editor times it syllable by syllable; `document()` fills in whatever is untimed from the
/// neighbouring timing, so a half-timed draft can still be previewed and exported.
/// `LyricsProject` saves it whole; TTML keeps only what `document()` makes of it.
public struct LyricsDraft: Sendable, Hashable, Codable {
    public var lines: [Line]
    public var metadata: [String: String]
    public var tracks: [Track]

    public init(lines: [Line] = [], metadata: [String: String] = [:], tracks: [Track] = []) {
        self.lines = lines
        self.metadata = metadata
        self.tracks = tracks
    }

    public struct Syllable: Sendable, Hashable, Identifiable, Codable {
        public var id: UUID
        /// A trailing space ends the syllable's word.
        public var text: String
        public var start: TimeInterval?
        public var end: TimeInterval?

        public init(id: UUID = UUID(), text: String, start: TimeInterval? = nil, end: TimeInterval? = nil) {
            self.id = id
            self.text = text
            self.start = start
            self.end = end
        }

        public var isTimed: Bool { start != nil }
        var weight: Double { Double(max(text.trimmingCharacters(in: .whitespaces).count, 1)) }
    }

    public struct Line: Sendable, Hashable, Identifiable, Codable {
        public var id: UUID
        public var syllables: [Syllable]
        public var translation: String
        public var romanization: String
        public var singer: LyricSinger
        /// Background vocals of the line above.
        public var isBackground: Bool
        public var isParagraphStart: Bool
        /// Line timing without syllable timing (an LRC line), for the syllables still untimed.
        public var start: TimeInterval?
        public var end: TimeInterval?
        /// The track it is drawn on; nil draws it by its singer, or under the line it backs.
        public var track: UUID?

        public init(id: UUID = UUID(), syllables: [Syllable], translation: String = "", romanization: String = "", singer: LyricSinger = .primary, isBackground: Bool = false, isParagraphStart: Bool = false, start: TimeInterval? = nil, end: TimeInterval? = nil, track: UUID? = nil) {
            self.id = id
            self.syllables = syllables
            self.translation = translation
            self.romanization = romanization
            self.singer = singer
            self.isBackground = isBackground
            self.isParagraphStart = isParagraphStart
            self.start = start
            self.end = end
            self.track = track
        }

        public var text: String { syllables.map(\.text).joined() }

        public var timedRange: ClosedRange<TimeInterval>? {
            let starts = syllables.compactMap(\.start) + [start].compactMap { $0 }
            let ends = syllables.compactMap { $0.end ?? $0.start } + [end].compactMap { $0 }
            guard let lo = starts.min() ?? ends.min(), let hi = ends.max() ?? starts.max() else { return nil }
            return lo...max(lo, hi)
        }
    }

    public struct Position: Sendable, Hashable, Comparable {
        public var line: Int
        public var syllable: Int

        public init(line: Int, syllable: Int) {
            self.line = line
            self.syllable = syllable
        }

        public static func < (a: Position, b: Position) -> Bool {
            (a.line, a.syllable) < (b.line, b.syllable)
        }
    }

    public var isEmpty: Bool { lines.allSatisfy { $0.syllables.isEmpty } }
    public var syllableCount: Int { lines.reduce(0) { $0 + $1.syllables.count } }
    public var timedCount: Int { lines.reduce(0) { $0 + $1.syllables.filter(\.isTimed).count } }

    public subscript(position: Position) -> Syllable {
        get { lines[position.line].syllables[position.syllable] }
        set { lines[position.line].syllables[position.syllable] = newValue }
    }

    public func contains(_ position: Position) -> Bool {
        lines.indices.contains(position.line) && lines[position.line].syllables.indices.contains(position.syllable)
    }

    public func position(after position: Position) -> Position? {
        if position.syllable + 1 < lines[position.line].syllables.count {
            return Position(line: position.line, syllable: position.syllable + 1)
        }
        return firstPosition(fromLine: position.line + 1)
    }

    public func position(before position: Position) -> Position? {
        if position.syllable > 0 { return Position(line: position.line, syllable: position.syllable - 1) }
        var line = position.line - 1
        while line >= 0 {
            if !lines[line].syllables.isEmpty { return Position(line: line, syllable: lines[line].syllables.count - 1) }
            line -= 1
        }
        return nil
    }

    public func firstPosition(fromLine line: Int) -> Position? {
        var line = max(line, 0)
        while line < lines.count {
            if !lines[line].syllables.isEmpty { return Position(line: line, syllable: 0) }
            line += 1
        }
        return nil
    }

    public func firstPosition(throughLine line: Int) -> Position? {
        var line = min(line, lines.count - 1)
        while line >= 0 {
            if !lines[line].syllables.isEmpty { return Position(line: line, syllable: 0) }
            line -= 1
        }
        return nil
    }

    public var firstUntimed: Position? {
        for (l, line) in lines.enumerated() {
            if let s = line.syllables.firstIndex(where: { !$0.isTimed }) { return Position(line: l, syllable: s) }
        }
        return nil
    }
}

// MARK: - From lyrics

extension LyricsDraft {
    /// A draft of parsed lyrics. Syllable-timed lines keep their timing; lines timed only as a
    /// whole (LRC) are split into syllables that keep the line's timing for the editor to fill.
    /// Background vocals become a background line under their line.
    public init(document: LyricsDocument) {
        var lines: [Line] = []
        for line in document.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if line.hasSyllableTiming {
                lines.append(Line(syllables: Self.syllables(of: line.words), translation: line.translation ?? "", romanization: line.romanization ?? "", singer: line.singer, isParagraphStart: line.isParagraphStart))
            } else {
                lines.append(Line(syllables: LyricsDraftImport.syllables(in: text), translation: line.translation ?? "", romanization: line.romanization ?? "", singer: line.singer, isParagraphStart: line.isParagraphStart, start: line.primaryStart, end: line.primaryEnd))
            }
            if let background = line.background {
                lines.append(Line(syllables: Self.syllables(of: background.words), translation: background.translation ?? "", romanization: background.romanization ?? "", singer: line.singer, isBackground: true))
            }
        }
        self.init(lines: lines, metadata: document.format == .ttml ? document.metadata : [:])
    }

    private static func syllables(of words: [LyricWord]) -> [Syllable] {
        words.flatMap(\.syllables).filter { !$0.text.isEmpty }.map { Syllable(text: $0.text, start: $0.start, end: $0.end) }
    }
}

// MARK: - To lyrics

extension LyricsDraft {
    /// The first syllable that starts before the preceding syllable ends in the same line.
    /// Check the draft's explicit times before `document()` clamps them for preview; only
    /// missing times use the same interpolation as export. Separate lines may overlap.
    public var firstTimingOverlap: Position? {
        let windows = lineWindows()
        for (l, line) in lines.enumerated() where line.syllables.count > 1 {
            let filled = Self.fill(line.syllables, window: windows[l])
            for s in line.syllables.indices.dropFirst() {
                let start = line.syllables[s].start ?? filled[s].start
                let previousEnd = line.syllables[s - 1].end ?? filled[s - 1].end
                if start < previousEnd { return Position(line: l, syllable: s) }
            }
        }
        return nil
    }

    public enum ExportIssue: Sendable, Hashable {
        case timingOverlap(Position)
        case strayBackground(line: Int)
    }

    /// The first issue in lyric order. Editing allows all of them; exporting checks.
    public var firstExportIssue: ExportIssue? {
        let overlap = firstTimingOverlap
        if let stray = firstStrayBackground, stray < overlap?.line ?? .max { return .strayBackground(line: stray) }
        return overlap.map(ExportIssue.timingOverlap)
    }

    /// Background vocals must immediately follow a nonempty lead line, one background line per lead.
    public var firstStrayBackground: Int? {
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard !line.syllables.isEmpty else { continue }
            if line.isBackground { return index - 1 }
            if index < lines.count, lines[index].isBackground { index += 1 }
        }
        return nil
    }

    /// The draft as lyrics, untimed syllables timed from their neighbours: a run of them shares
    /// the time between the timed syllables around it by length, a line without any timing
    /// shares the time between the lines around it. A background line becomes the background
    /// vocals of the line above it.
    public func document() -> LyricsDocument {
        let windows = lineWindows()
        var result: [LyricLine] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let syllables = Self.fill(line.syllables, window: windows[index])
            index += 1
            guard !syllables.isEmpty else { continue }
            var background: LyricBackgroundVocals?
            if !line.isBackground, index < lines.count, lines[index].isBackground {
                let bg = lines[index]
                let bgSyllables = Self.fill(bg.syllables, window: windows[index])
                index += 1
                if !bgSyllables.isEmpty {
                    let words = Self.words(bgSyllables)
                    background = LyricBackgroundVocals(start: bgSyllables.map(\.start).min() ?? 0, end: bgSyllables.map(\.end).max() ?? 0, words: words, translation: bg.translation.nonEmpty, romanization: bg.romanization.nonEmpty)
                }
            }
            let words = Self.words(syllables)
            let primaryStart = syllables.map(\.start).min() ?? 0
            let primaryEnd = syllables.map(\.end).max() ?? primaryStart
            let start = min(primaryStart, background?.start ?? primaryStart)
            let end = max(primaryEnd, background?.end ?? primaryEnd)
            result.append(LyricLine(id: result.count, start: start, end: end, words: words, translation: line.translation.nonEmpty, romanization: line.romanization.nonEmpty, singer: line.singer, background: background, primaryStart: primaryStart, primaryEnd: primaryEnd, isParagraphStart: line.isParagraphStart || result.isEmpty))
        }
        return LyricsDocument(format: .ttml, lines: result, metadata: metadata)
    }

    private static func words(_ syllables: [LyricSyllable]) -> [LyricWord] {
        var words = LyricWordGrouping.words(from: syllables)
        if let last = words.indices.last, words[last].text.hasSuffix(" ") {
            words[last].text = String(words[last].text.dropLast())
            let n = words[last].syllables.count
            words[last].syllables[n - 1].text = String(words[last].syllables[n - 1].text.dropLast())
        }
        return words
    }

    static let untimedLineLength: TimeInterval = 3
    static let untimedSyllableLength: TimeInterval = 0.3

    /// Each line's time span: its own timing where it has any; where the last syllables are still
    /// untimed, a little past it (never into the next line); and for lines without timing a share
    /// of the time between the timed lines around them.
    public func lineWindows() -> [ClosedRange<TimeInterval>] {
        var windows: [ClosedRange<TimeInterval>?] = lines.map(\.timedRange)
        let starts = lines.map { $0.timedRange?.lowerBound }
        for i in lines.indices {
            guard let window = windows[i] else { continue }
            let line = lines[i]
            let lastTimed = line.syllables.lastIndex { $0.start != nil }
            var trailing = Double(line.syllables.count - 1 - (lastTimed ?? -1))
            if let lastTimed, line.syllables[lastTimed].end == nil { trailing += 1 }
            // An LRC line's end already bounds its untimed syllables.
            guard trailing > 0, line.end == nil else { continue }
            var end = window.upperBound + trailing * Self.untimedSyllableLength
            if let next = starts[(i + 1)...].lazy.compactMap({ $0 }).first, next > window.upperBound {
                end = min(end, next)
            }
            windows[i] = window.lowerBound...max(window.upperBound, end)
        }
        var i = 0
        while i < windows.count {
            guard windows[i] == nil else { i += 1; continue }
            var j = i
            while j < windows.count, windows[j] == nil { j += 1 }
            let count = Double(j - i)
            // Every line around counts: a background line may end before the line it backs.
            let before = windows[..<i].compactMap { $0?.upperBound }.max()
            let after = windows[j...].compactMap { $0?.lowerBound }.min()
            let lo: TimeInterval
            let hi: TimeInterval
            switch (before, after) {
            case let (before?, after?) where after > before:
                (lo, hi) = (before, after)
            case let (before?, _):
                (lo, hi) = (before, before + count * Self.untimedLineLength)
            case let (nil, after?):
                (lo, hi) = (max(0, after - count * Self.untimedLineLength), after)
            case (nil, nil):
                (lo, hi) = (0, count * Self.untimedLineLength)
            }
            let step = max(hi - lo, 0) / count
            for k in i..<j {
                let s = lo + Double(k - i) * step
                windows[k] = s...(s + step)
            }
            i = j
        }
        return windows.map { $0 ?? 0...0 }
    }

    /// Times every syllable: known times stay; unknown ones are interpolated along the line by
    /// syllable length between the known ones, the window standing in at the ends.
    static func fill(_ syllables: [Syllable], window: ClosedRange<TimeInterval>) -> [LyricSyllable] {
        guard !syllables.isEmpty else { return [] }
        // Cumulative length before each syllable: syllable k spans offsets[k]…offsets[k + 1].
        var offsets = [0.0]
        for syllable in syllables { offsets.append(offsets[offsets.count - 1] + syllable.weight) }
        var anchors: [(at: Double, time: TimeInterval)] = []
        for (k, syllable) in syllables.enumerated() {
            if let start = syllable.start { anchors.append((offsets[k], start)) }
            if let end = syllable.end { anchors.append((offsets[k + 1], end)) }
        }
        if syllables.first?.start == nil { anchors.append((0, min(window.lowerBound, anchors.map(\.time).min() ?? window.lowerBound))) }
        if syllables.last?.end == nil { anchors.append((offsets[syllables.count], max(window.upperBound, anchors.map(\.time).max() ?? window.upperBound))) }
        anchors.sort { ($0.at, $0.time) < ($1.at, $1.time) }

        func time(at offset: Double, preferLate: Bool) -> TimeInterval {
            let same = anchors.filter { $0.at == offset }
            if !same.isEmpty { return preferLate ? same.map(\.time).max()! : same.map(\.time).min()! }
            let left = anchors.last { $0.at < offset }
            let right = anchors.first { $0.at > offset }
            switch (left, right) {
            case let (l?, r?): return l.time + (r.time - l.time) * (offset - l.at) / (r.at - l.at)
            case let (l?, nil): return l.time
            case let (nil, r?): return r.time
            case (nil, nil): return window.lowerBound
            }
        }

        var result: [LyricSyllable] = []
        var floor = -Double.infinity
        for (k, syllable) in syllables.enumerated() {
            let start = max(syllable.start ?? time(at: offsets[k], preferLate: true), floor)
            let end = max(syllable.end ?? time(at: offsets[k + 1], preferLate: false), start)
            result.append(LyricSyllable(start: start, end: end, text: syllable.text))
            floor = start
        }
        return result
    }
}

// MARK: - Editing

extension LyricsDraft {
    /// The line's text for editing: syllables of one word joined by `|`, words by their spaces.
    public static func editableText(of line: Line) -> String {
        var text = ""
        for (index, syllable) in line.syllables.enumerated() {
            if index > 0, !(line.syllables[index - 1].text.last?.isWhitespace ?? false) { text += "|" }
            text += syllable.text
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces a line's text, split again (`LyricsDraftImport.syllables(in:)`). Syllables that
    /// stay the same at the start and at the end of the line keep their timing.
    public mutating func setText(_ text: String, ofLine index: Int) {
        let old = lines[index].syllables
        var new = LyricsDraftImport.syllables(in: text)
        let key = { (s: Syllable) in s.text.trimmingCharacters(in: .whitespaces) }
        var head = 0
        while head < min(old.count, new.count), key(old[head]) == key(new[head]) {
            new[head].start = old[head].start
            new[head].end = old[head].end
            new[head].id = old[head].id
            head += 1
        }
        var tail = 0
        while tail < min(old.count, new.count) - head, key(old[old.count - 1 - tail]) == key(new[new.count - 1 - tail]) {
            let o = old[old.count - 1 - tail]
            new[new.count - 1 - tail].start = o.start
            new[new.count - 1 - tail].end = o.end
            new[new.count - 1 - tail].id = o.id
            tail += 1
        }
        lines[index].syllables = new
    }

    /// Splits a syllable into its characters (a word's trailing space stays on the last one),
    /// sharing its timing evenly.
    public mutating func splitSyllable(at position: Position) {
        let syllable = self[position]
        let body = syllable.text.trimmingCharacters(in: .whitespaces)
        let characters = body.map(String.init)
        guard characters.count > 1 else { return }
        let trailing = syllable.text.hasSuffix(" ") ? " " : ""
        let step = syllable.start.flatMap { s in syllable.end.map { e in (e - s) / Double(characters.count) } }
        let parts = characters.enumerated().map { k, character in
            Syllable(text: character + (k == characters.count - 1 ? trailing : ""),
                     start: k == 0 ? syllable.start : step.map { syllable.start! + Double(k) * $0 },
                     end: k == characters.count - 1 ? syllable.end : step.map { syllable.start! + Double(k + 1) * $0 })
        }
        lines[position.line].syllables.replaceSubrange(position.syllable...position.syllable, with: parts)
    }

    public mutating func mergeWithNext(at position: Position) {
        let next = Position(line: position.line, syllable: position.syllable + 1)
        guard contains(next) else { return }
        let a = self[position]
        let b = self[next]
        let merged = Syllable(id: a.id, text: a.text + b.text, start: a.start ?? b.start, end: b.end ?? b.start ?? a.end)
        lines[position.line].syllables.replaceSubrange(position.syllable...next.syllable, with: [merged])
    }

    public mutating func shift(by delta: TimeInterval) {
        func moved(_ t: TimeInterval?) -> TimeInterval? { t.map { max(0, $0 + delta) } }
        for l in lines.indices {
            lines[l].start = moved(lines[l].start)
            lines[l].end = moved(lines[l].end)
            for s in lines[l].syllables.indices {
                lines[l].syllables[s].start = moved(lines[l].syllables[s].start)
                lines[l].syllables[s].end = moved(lines[l].syllables[s].end)
            }
        }
    }

    public mutating func clearTiming(ofLine index: Int) {
        for s in lines[index].syllables.indices {
            lines[index].syllables[s].start = nil
            lines[index].syllables[s].end = nil
        }
    }
}

// MARK: - Moving syllables

extension LyricsDraft {
    /// Creates a line after the last source, inheriting the first source's voice and track.
    /// Returns its index; moving a whole line alone leaves it in place.
    @discardableResult
    public mutating func moveSyllablesToNewLine(_ positions: [Position]) -> Int? {
        let positions = valid(positions)
        guard let first = positions.first, let last = positions.last else { return nil }
        if first.line == last.line, positions.count == lines[first.line].syllables.count { return first.line }
        let source = lines[first.line]
        let sources = lineIDs(of: positions)
        let line = Line(syllables: take(positions), singer: source.singer, isBackground: source.isBackground, track: source.track)
        lines.insert(line, at: last.line + 1)
        dropEmpty(sources)
        return lines.firstIndex { $0.id == line.id }
    }

    /// Appends to the preceding line (-1) or prepends to the following line (+1).
    /// Returns the destination index, or nil if there is no adjacent line.
    @discardableResult
    public mutating func moveSyllables(_ positions: [Position], toLineBy offset: Int) -> Int? {
        let positions = valid(positions)
        guard let first = positions.first, let last = positions.last else { return nil }
        let target = offset < 0 ? first.line - 1 : last.line + 1
        guard lines.indices.contains(target) else { return nil }
        let id = lines[target].id
        let sources = lineIDs(of: positions)
        var moved = take(positions)
        if offset < 0 {
            if let end = lines[target].syllables.indices.last, let next = moved.first { Self.join(&lines[target].syllables[end], before: next) }
            lines[target].syllables += moved
        } else {
            if let end = moved.indices.last, let next = lines[target].syllables.first { Self.join(&moved[end], before: next) }
            lines[target].syllables.insert(contentsOf: moved, at: 0)
        }
        dropEmpty(sources)
        return lines.firstIndex { $0.id == id }
    }

    public mutating func removeSyllables(_ positions: [Position]) {
        let positions = valid(positions)
        let sources = lineIDs(of: positions)
        _ = take(positions)
        dropEmpty(sources)
    }

    @discardableResult
    public mutating func mergeSyllables(_ positions: [Position]) -> Position? {
        let positions = valid(positions)
        guard let first = positions.first, positions.count > 1, Self.isRun(positions) else { return nil }
        for _ in 1..<positions.count { mergeWithNext(at: first) }
        return first
    }

    /// Whether the syllables follow one another within one line.
    public static func isRun(_ positions: [Position]) -> Bool {
        let positions = Set(positions).sorted()
        guard let first = positions.first else { return false }
        return positions.enumerated().allSatisfy { $1 == Position(line: first.line, syllable: first.syllable + $0) }
    }

    public mutating func mergeLineWithNext(_ index: Int) {
        guard lines.indices.contains(index + 1) else { return }
        let next = lines.remove(at: index + 1)
        if let end = lines[index].syllables.indices.last, let first = next.syllables.first { Self.join(&lines[index].syllables[end], before: first) }
        lines[index].syllables += next.syllables
        lines[index].translation = [lines[index].translation, next.translation].compactMap(\.nonEmpty).joined(separator: " ")
        lines[index].romanization = [lines[index].romanization, next.romanization].compactMap(\.nonEmpty).joined(separator: " ")
        lines[index].end = next.end ?? lines[index].end
    }

    /// The lines that move with line `index`: a line with the background vocals under it, or a
    /// background line on its own.
    public func lineGroup(at index: Int) -> Range<Int> {
        guard !lines[index].isBackground else { return index..<(index + 1) }
        var end = index + 1
        while end < lines.count, lines[end].isBackground { end += 1 }
        return index..<end
    }

    /// Moves a lead line with its background vocals; a background line moves independently.
    /// Returns the new index, or nil at the boundary.
    @discardableResult
    public mutating func moveLine(at index: Int, by offset: Int) -> Int? {
        guard lines.indices.contains(index), offset != 0 else { return nil }
        let group = lineGroup(at: index)
        let single = lines[index].isBackground
        let destination: Int
        if offset < 0 {
            guard group.lowerBound > 0 else { return nil }
            var above = group.lowerBound - 1
            if !single { while above > 0, lines[above].isBackground { above -= 1 } }
            destination = above
        } else {
            guard group.upperBound < lines.count else { return nil }
            let below = single ? group.upperBound + 1 : lineGroup(at: group.upperBound).upperBound
            destination = below - group.count
        }
        let moved = Array(lines[group])
        lines.removeSubrange(group)
        lines.insert(contentsOf: moved, at: destination)
        return destination
    }

    private func valid(_ positions: [Position]) -> [Position] {
        Set(positions).filter(contains).sorted()
    }

    private func lineIDs(of positions: [Position]) -> Set<UUID> {
        Set(positions.map { lines[$0.line].id })
    }

    /// Preserves word boundaries in both the removed and remaining syllables.
    /// Empty source lines remain for `dropEmpty`.
    private mutating func take(_ positions: [Position]) -> [Syllable] {
        var taken: [Syllable] = []
        var previous: Position?
        for (index, group) in Dictionary(grouping: positions, by: \.line).sorted(by: { $0.key < $1.key }) {
            let picked = Set(group.map(\.syllable))
            var kept: [Syllable] = []
            var gap = false
            for (s, syllable) in lines[index].syllables.enumerated() {
                if picked.contains(s) {
                    if let last = taken.indices.last, previous != Position(line: index, syllable: s - 1) { Self.join(&taken[last], before: syllable) }
                    taken.append(syllable)
                    previous = Position(line: index, syllable: s)
                    gap = !kept.isEmpty
                } else {
                    if gap, let last = kept.indices.last { Self.join(&kept[last], before: syllable) }
                    gap = false
                    kept.append(syllable)
                }
            }
            lines[index].syllables = kept
        }
        return taken
    }

    private mutating func dropEmpty(_ ids: Set<UUID>) {
        for index in lines.indices.reversed() where ids.contains(lines[index].id) && lines[index].syllables.isEmpty {
            if lines[index].isParagraphStart, index + 1 < lines.count { lines[index + 1].isParagraphStart = true }
            lines.remove(at: index)
        }
    }

    /// A syllable that now runs into one it did not touch before ends its word, unless either
    /// is Chinese or Japanese, which are written without spaces.
    private static func join(_ left: inout Syllable, before right: Syllable) {
        guard let last = left.text.last, !last.isWhitespace, !right.text.isEmpty,
              !LyricWordGrouping.containsChineseJapanese(left.text), !LyricWordGrouping.containsChineseJapanese(right.text) else { return }
        left.text += " "
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
