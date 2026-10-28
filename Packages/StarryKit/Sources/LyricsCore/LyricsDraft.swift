import Foundation

/// An editable lyric for the lyric editor: lines of syllables whose timing may still be missing.
/// The editor times it syllable by syllable; `document()` fills in whatever is untimed from the
/// neighbouring timing, so a half-timed draft can still be previewed and exported.
/// `LyricsProject` saves it whole; TTML keeps only what `document()` makes of it.
public struct LyricsDraft: Sendable, Hashable, Codable {
    public var lines: [Line]
    public var metadata: [String: String]
    public var tracks: [Track]
    public var agents: [LyricAgent]

    public init(lines: [Line] = [], metadata: [String: String] = [:], tracks: [Track] = [], agents: [LyricAgent] = []) {
        self.lines = lines
        self.metadata = metadata
        self.tracks = tracks
        self.agents = agents
    }

    public struct Syllable: Sendable, Hashable, Identifiable, Codable {
        public var id: UUID
        /// A trailing space ends the syllable's word.
        public var text: String
        public var start: TimeInterval?
        public var end: TimeInterval?
        public var ruby: [Ruby]?
        /// Empty inherits the line's performers.
        public var agentIDs: [String]
        /// Seconds from the syllable's start; nil entries are untimed RL beats.
        public var checkpoints: [TimeInterval?]?
        public var isRest: Bool
        public var hasRelease: Bool

        public init(id: UUID = UUID(), text: String, start: TimeInterval? = nil, end: TimeInterval? = nil, ruby: [Ruby]? = nil, agentIDs: [String] = [], checkpoints: [TimeInterval?]? = nil, isRest: Bool = false, hasRelease: Bool = false) {
            self.id = id
            self.text = text
            self.start = start
            self.end = end
            self.ruby = ruby
            self.agentIDs = agentIDs
            self.checkpoints = checkpoints
            self.isRest = isRest
            self.hasRelease = hasRelease
        }

        public var isTimed: Bool { start != nil }
        var weight: Double { Double(max(text.trimmingCharacters(in: .whitespaces).count, 1)) }
    }

    /// A piece of ruby text (furigana). Timed relative to its syllable, so it follows whatever
    /// retimes the syllable.
    public struct Ruby: Sendable, Hashable, Codable {
        public var text: String
        /// Where it is sung within the syllable, 0 at its start and 1 at its end. Unless every
        /// piece of a syllable has one, they share the syllable by length.
        public var span: ClosedRange<Double>?

        public init(text: String, span: ClosedRange<Double>? = nil) {
            self.text = text
            self.span = span
        }

        static func relative(_ ruby: [LyricRuby], start: TimeInterval, end: TimeInterval) -> [Ruby]? {
            guard !ruby.isEmpty else { return nil }
            let length = end - start
            return ruby.map { r in
                guard length > 0 else { return Ruby(text: r.text) }
                return Ruby(text: r.text, span: clamped((r.start - start) / length, (r.end - start) / length))
            }
        }

        static func absolute(_ ruby: [Ruby]?, start: TimeInterval, end: TimeInterval) -> [LyricRuby] {
            guard let ruby, !ruby.isEmpty else { return [] }
            let spans = ruby.compactMap(\.span)
            guard spans.count == ruby.count else { return LyricRuby.spread(ruby.map(\.text), start: start, end: end) }
            let length = max(end - start, 0)
            return zip(ruby, spans).map { r, span in
                LyricRuby(start: start + length * span.lowerBound, end: start + length * span.upperBound, text: r.text)
            }
        }

        static func clamped(_ lower: Double, _ upper: Double) -> ClosedRange<Double> {
            let lower = min(max(lower, 0), 1)
            return lower...min(max(upper, lower), 1)
        }
    }

    public struct Line: Sendable, Hashable, Identifiable, Codable {
        public var id: UUID
        public var syllables: [Syllable]
        public var translation: String
        public var romanization: String {
            didSet { if romanization != oldValue { romanizationTiming = nil } }
        }
        public var romanizationTiming: [RomanizationSegment]?
        public var singer: LyricSinger
        public var agentIDs: [String]
        /// Background vocals of the line above.
        public var isBackground: Bool
        public var isParagraphStart: Bool
        /// Line timing without syllable timing (an LRC line), for the syllables still untimed.
        public var start: TimeInterval?
        public var end: TimeInterval?
        /// The track it is drawn on; nil draws it by its singer, or under the line it backs.
        public var track: UUID?

        public init(id: UUID = UUID(), syllables: [Syllable], translation: String = "", romanization: String = "", singer: LyricSinger = .primary, isBackground: Bool = false, isParagraphStart: Bool = false, start: TimeInterval? = nil, end: TimeInterval? = nil, track: UUID? = nil, agentIDs: [String] = [], romanizationTiming: [RomanizationSegment]? = nil) {
            self.id = id
            self.syllables = syllables
            self.translation = translation
            self.romanization = romanization
            self.romanizationTiming = romanizationTiming
            self.singer = singer
            self.agentIDs = agentIDs
            self.isBackground = isBackground
            self.isParagraphStart = isParagraphStart
            self.start = start
            self.end = end
            self.track = track
        }

        public var text: String { syllables.filter { !$0.isRest }.map(\.text).joined() }

        public var timedRange: ClosedRange<TimeInterval>? {
            let starts = syllables.compactMap(\.start) + [start].compactMap { $0 }
            let ends = syllables.compactMap { $0.end ?? $0.start } + [end].compactMap { $0 }
            guard let lo = starts.min() ?? ends.min(), let hi = ends.max() ?? starts.max() else { return nil }
            return lo...max(lo, hi)
        }

        public mutating func setSinger(_ singer: LyricSinger, agents: [LyricAgent]) {
            guard self.singer != singer else { return }
            self.singer = singer
            if let agent = agents.first(where: { LyricAgent.singer(for: [$0.id], in: agents) == singer }) {
                agentIDs = [agent.id]
            } else if singer == .duet {
                let members = agents.filter { $0.kind != .group }.prefix(2).map(\.id)
                agentIDs = members.count == 2 ? members : []
            } else {
                agentIDs = []
            }
            for index in syllables.indices { syllables[index].agentIDs = [] }
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
    public var hasAuthoringTiming: Bool {
        lines.contains { line in
            line.romanizationTiming?.contains(where: { $0.end == nil }) == true
                || line.syllables.contains { $0.isRest || ($0.checkpoints?.count ?? 0) > 1 || $0.hasRelease && $0.end == nil }
        }
    }

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
            if line.hasSyllableTiming || line.hasRuby || line.syllables.contains(where: { !$0.agentIDs.isEmpty || $0.checkpoints != nil || $0.isRest }) {
                lines.append(Line(syllables: Self.syllables(of: line.words), translation: line.translation ?? "", romanization: line.romanization ?? "", singer: line.singer, isParagraphStart: line.isParagraphStart, agentIDs: line.agentIDs))
            } else {
                lines.append(Line(syllables: LyricsDraftImport.syllables(in: text, explicitBoundaries: false, preservesLineBreaks: document.format == .srt), translation: line.translation ?? "", romanization: line.romanization ?? "", singer: line.singer, isParagraphStart: line.isParagraphStart, start: line.primaryStart, end: line.primaryEnd, agentIDs: line.agentIDs))
            }
            if let last = lines.indices.last {
                lines[last].romanizationTiming = RomanizationSegment.relative(line.romanizationWords, start: line.primaryStart, end: line.primaryEnd)
            }
            if let background = line.background {
                lines.append(Line(syllables: Self.syllables(of: background.words), translation: background.translation ?? "", romanization: background.romanization ?? "", singer: line.singer, isBackground: true, agentIDs: background.agentIDs.isEmpty ? line.agentIDs : background.agentIDs))
                lines[lines.count - 1].romanizationTiming = RomanizationSegment.relative(background.romanizationWords, start: background.start, end: background.end)
            }
        }
        self.init(lines: lines, metadata: document.metadata, agents: document.agents)
    }

    private static func syllables(of words: [LyricWord]) -> [Syllable] {
        words.flatMap(\.syllables).filter { !$0.text.isEmpty || $0.isRest }.map {
            let start = $0.start
            return Syllable(text: $0.isRest ? "▨" : $0.text, start: start, end: $0.end, ruby: Ruby.relative($0.ruby, start: start, end: $0.end), agentIDs: $0.agentIDs, checkpoints: $0.checkpoints?.map { $0.map { $0 - start } }, isRest: $0.isRest, hasRelease: $0.hasRelease)
        }
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
                    let start = bgSyllables.map(\.start).min() ?? 0, end = bgSyllables.map(\.end).max() ?? 0
                    background = LyricBackgroundVocals(start: start, end: end, words: words, translation: bg.translation.nonEmpty, romanization: bg.romanization.nonEmpty, romanizationWords: RomanizationSegment.absolute(bg.romanizationTiming, start: start, end: end), agentIDs: bg.agentIDs)
                }
            }
            let words = Self.words(syllables)
            let primaryStart = syllables.map(\.start).min() ?? 0
            let primaryEnd = syllables.map(\.end).max() ?? primaryStart
            let start = min(primaryStart, background?.start ?? primaryStart)
            let end = max(primaryEnd, background?.end ?? primaryEnd)
            result.append(LyricLine(id: result.count, start: start, end: end, words: words, translation: line.translation.nonEmpty, romanization: line.romanization.nonEmpty, romanizationWords: RomanizationSegment.absolute(line.romanizationTiming, start: primaryStart, end: primaryEnd), singer: line.singer, background: background, primaryStart: primaryStart, primaryEnd: primaryEnd, isParagraphStart: line.isParagraphStart || result.isEmpty, agentIDs: line.agentIDs))
        }
        return LyricsDocument(format: .ttml, lines: result, metadata: metadata, agents: agents)
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
            var ruby = Ruby.absolute(syllable.ruby, start: start, end: end)
            if let checkpoints = syllable.checkpoints, checkpoints.count == ruby.count, checkpoints.allSatisfy({ $0 != nil }),
               (syllable.ruby ?? []).contains(where: { $0.span == nil }) {
                for index in ruby.indices {
                    ruby[index].start = start + checkpoints[index]!
                    ruby[index].end = index + 1 < checkpoints.count ? start + checkpoints[index + 1]! : max(end, ruby[index].start)
                }
            }
            result.append(LyricSyllable(start: start, end: end, text: syllable.isRest ? "" : syllable.text, ruby: ruby, agentIDs: syllable.agentIDs, checkpoints: syllable.checkpoints?.map { $0.map { start + $0 } }, isRest: syllable.isRest, hasRelease: syllable.hasRelease))
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
    /// stay the same at the start and at the end of the line keep their timing and ruby.
    public mutating func setText(_ text: String, ofLine index: Int) {
        let old = lines[index].syllables
        var new = LyricsDraftImport.syllables(in: text)
        let key = { (s: Syllable) in s.text.trimmingCharacters(in: .whitespaces) }
        var head = 0
        while head < min(old.count, new.count), key(old[head]) == key(new[head]) {
            let text = new[head].text
            new[head] = old[head]
            new[head].text = text
            head += 1
        }
        var tail = 0
        while tail < min(old.count, new.count) - head, key(old[old.count - 1 - tail]) == key(new[new.count - 1 - tail]) {
            let o = old[old.count - 1 - tail]
            let text = new[new.count - 1 - tail].text
            new[new.count - 1 - tail] = o
            new[new.count - 1 - tail].text = text
            tail += 1
        }
        lines[index].syllables = new
    }

    public static func editableRuby(of syllable: Syllable) -> String {
        (syllable.ruby ?? []).map(\.text).joined(separator: "|")
    }

    /// Replaces a syllable's ruby with `text` split at `|` (or `｜`), each piece trimmed; blank
    /// text removes it. With as many pieces as before, each keeps its timing; otherwise they
    /// share the syllable by length.
    public mutating func setRuby(_ text: String, at position: Position) {
        let pieces = text.split(whereSeparator: { $0 == "|" || $0 == "｜" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let old = self[position].ruby ?? []
        guard !pieces.isEmpty else {
            self[position].ruby = nil
            return
        }
        self[position].ruby = pieces.enumerated().map { k, piece in
            Ruby(text: piece, span: pieces.count == old.count ? old[k].span : nil)
        }
    }

    /// Splits a syllable into its characters (a word's trailing space stays on the last one),
    /// sharing its timing evenly. Its ruby cannot be split with it and is dropped.
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
                     end: k == characters.count - 1 ? syllable.end : step.map { syllable.start! + Double(k + 1) * $0 }, agentIDs: syllable.agentIDs)
        }
        lines[position.line].syllables.replaceSubrange(position.syllable...position.syllable, with: parts)
    }

    public mutating func mergeWithNext(at position: Position) {
        let next = Position(line: position.line, syllable: position.syllable + 1)
        guard contains(next) else { return }
        let a = self[position]
        let b = self[next]
        guard a.isRest == b.isRest else { return }
        let inherited = lines[position.line].agentIDs
        guard (a.agentIDs.isEmpty ? inherited : a.agentIDs) == (b.agentIDs.isEmpty ? inherited : b.agentIDs) else { return }
        var merged = Syllable(id: a.id, text: a.text + b.text, start: a.start ?? b.start, end: b.end ?? b.start ?? a.end, agentIDs: a.agentIDs)
        merged.ruby = Self.ruby(merging: [a, b], into: merged)
        merged.isRest = a.isRest
        merged.hasRelease = b.hasRelease
        if a.checkpoints != nil || b.checkpoints != nil {
            merged.checkpoints = [a, b].flatMap { part in
                (part.checkpoints ?? [0]).map { checkpoint -> TimeInterval? in
                    guard let checkpoint, let origin = merged.start, let start = part.start else { return nil }
                    return start + checkpoint - origin
                }
            }
        }
        lines[position.line].syllables.replaceSubrange(position.syllable...next.syllable, with: [merged])
    }

    /// The ruby of `parts` over their merge, where a part without ruby reads as its own text;
    /// nil when no part has ruby.
    private static func ruby(merging parts: [Syllable], into merged: Syllable) -> [Ruby]? {
        guard parts.contains(where: { !($0.ruby ?? []).isEmpty }) else { return nil }
        var result: [Ruby] = []
        for part in parts {
            let own: [Ruby]
            if let ruby = part.ruby, !ruby.isEmpty {
                own = ruby
            } else {
                let text = part.text.trimmingCharacters(in: .whitespaces)
                own = text.isEmpty ? [] : [Ruby(text: text, span: 0...1)]
            }
            guard let start = merged.start, let end = merged.end, end > start, let ps = part.start, let pe = part.end,
                  own.allSatisfy({ $0.span != nil }) else {
                result += own.map { Ruby(text: $0.text) }
                continue
            }
            result += own.map { r in
                let span = r.span!
                return Ruby(text: r.text, span: Ruby.clamped((ps + (pe - ps) * span.lowerBound - start) / (end - start),
                                                             (ps + (pe - ps) * span.upperBound - start) / (end - start)))
            }
        }
        return result.contains { $0.span == nil } ? result.map { Ruby(text: $0.text) } : result
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
        let line = Line(syllables: take(positions), singer: source.singer, isBackground: source.isBackground, track: source.track, agentIDs: source.agentIDs)
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
        let inherited = lines[first.line].agentIDs
        let agents = self[first].agentIDs.isEmpty ? inherited : self[first].agentIDs
        guard positions.allSatisfy({ (self[$0].agentIDs.isEmpty ? inherited : self[$0].agentIDs) == agents && self[$0].isRest == self[first].isRest }) else { return nil }
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
        let windows = lineWindows()
        let hasRomanizationTiming = lines[index].romanizationTiming != nil || lines[index + 1].romanizationTiming != nil
        var timedRomanization: [LyricSyllable] = []
        if hasRomanizationTiming {
            for source in index...(index + 1) {
                let syllables = Self.fill(lines[source].syllables, window: windows[source])
                let start = syllables.map(\.start).min() ?? windows[source].lowerBound
                let end = syllables.map(\.end).max() ?? windows[source].upperBound
                let pieces = RomanizationSegment.absolute(lines[source].romanizationTiming, start: start, end: end)?.flatMap(\.syllables)
                    ?? lines[source].romanization.nonEmpty.map { [LyricSyllable(start: start, end: end, text: $0)] } ?? []
                if !pieces.isEmpty, let last = timedRomanization.indices.last, !timedRomanization[last].text.hasSuffix(" ") { timedRomanization[last].text += " " }
                timedRomanization += pieces
            }
        }
        let next = lines.remove(at: index + 1)
        if let end = lines[index].syllables.indices.last, let first = next.syllables.first { Self.join(&lines[index].syllables[end], before: first) }
        lines[index].syllables += next.syllables.map { syllable in
            var syllable = syllable
            if syllable.agentIDs.isEmpty { syllable.agentIDs = next.agentIDs }
            return syllable
        }
        lines[index].translation = [lines[index].translation, next.translation].compactMap(\.nonEmpty).joined(separator: " ")
        lines[index].romanization = [lines[index].romanization, next.romanization].compactMap(\.nonEmpty).joined(separator: " ")
        lines[index].end = next.end ?? lines[index].end
        if hasRomanizationTiming {
            let syllables = Self.fill(lines[index].syllables, window: lineWindows()[index])
            let start = syllables.map(\.start).min() ?? 0, end = syllables.map(\.end).max() ?? start
            lines[index].romanizationTiming = RomanizationSegment.relative(LyricWordGrouping.words(from: timedRomanization), start: start, end: end)
        }
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
                    var syllable = syllable
                    if syllable.agentIDs.isEmpty { syllable.agentIDs = lines[index].agentIDs }
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

extension LyricsDraft {
    private enum CodingKeys: String, CodingKey { case lines, metadata, tracks, agents }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lines = try values.decode([Line].self, forKey: .lines)
        metadata = try values.decode([String: String].self, forKey: .metadata)
        tracks = try values.decode([Track].self, forKey: .tracks)
        agents = try values.decodeIfPresent([LyricAgent].self, forKey: .agents) ?? []
    }
}

extension LyricsDraft.Line {
    private enum CodingKeys: String, CodingKey {
        case id, syllables, translation, romanization, romanizationTiming, singer, isBackground, isParagraphStart, start, end, track, agentIDs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        syllables = try values.decode([LyricsDraft.Syllable].self, forKey: .syllables)
        translation = try values.decode(String.self, forKey: .translation)
        romanization = try values.decode(String.self, forKey: .romanization)
        romanizationTiming = try values.decodeIfPresent([LyricsDraft.RomanizationSegment].self, forKey: .romanizationTiming)
        singer = try values.decode(LyricSinger.self, forKey: .singer)
        isBackground = try values.decode(Bool.self, forKey: .isBackground)
        isParagraphStart = try values.decode(Bool.self, forKey: .isParagraphStart)
        start = try values.decodeIfPresent(TimeInterval.self, forKey: .start)
        end = try values.decodeIfPresent(TimeInterval.self, forKey: .end)
        track = try values.decodeIfPresent(UUID.self, forKey: .track)
        agentIDs = try values.decodeIfPresent([String].self, forKey: .agentIDs) ?? []
    }
}

extension LyricsDraft.Syllable {
    private enum CodingKeys: String, CodingKey { case id, text, start, end, ruby, agentIDs, checkpoints, isRest, hasRelease }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        start = try values.decodeIfPresent(TimeInterval.self, forKey: .start)
        end = try values.decodeIfPresent(TimeInterval.self, forKey: .end)
        ruby = try values.decodeIfPresent([LyricsDraft.Ruby].self, forKey: .ruby)
        agentIDs = try values.decodeIfPresent([String].self, forKey: .agentIDs) ?? []
        checkpoints = try values.decodeIfPresent([TimeInterval?].self, forKey: .checkpoints)
        isRest = try values.decodeIfPresent(Bool.self, forKey: .isRest) ?? false
        hasRelease = try values.decodeIfPresent(Bool.self, forKey: .hasRelease) ?? false
    }
}
