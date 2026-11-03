import Foundation

// MARK: - Ruby timing

extension LyricsDraft {
    public struct RubyAnnotation: Sendable, Hashable {
        public var syllables: ClosedRange<Int>
        public var isShared: Bool

        public init(syllables: ClosedRange<Int>, isShared: Bool) {
            self.syllables = syllables
            self.isShared = isShared
        }
    }

    public enum RubyEdge: Sendable, Hashable { case start, end }
}

extension LyricsDraft.Line {
    public var rubyAnnotations: [LyricsDraft.RubyAnnotation] {
        var result: [LyricsDraft.RubyAnnotation] = []
        var groups = LyricsDraft.rubyGroups(in: syllables)[...]
        var index = 0
        while index < syllables.count {
            if let group = groups.first, group.lowerBound == index {
                result.append(.init(syllables: group, isShared: true))
                groups = groups.dropFirst()
                index = group.upperBound + 1
            } else {
                if !(syllables[index].ruby ?? []).isEmpty { result.append(.init(syllables: index...index, isShared: false)) }
                index += 1
            }
        }
        return result
    }

    public func rubyAnnotation(containing syllable: Int) -> LyricsDraft.RubyAnnotation? {
        rubyAnnotations.first { $0.syllables.contains(syllable) }
    }

    public func ruby(of annotation: LyricsDraft.RubyAnnotation) -> [LyricsDraft.Ruby] {
        guard syllables.indices.contains(annotation.syllables.lowerBound) else { return [] }
        let head = syllables[annotation.syllables.lowerBound]
        return (annotation.isShared ? head.groupRuby : head.ruby) ?? []
    }

    mutating func setRuby(_ pieces: [LyricsDraft.Ruby], of annotation: LyricsDraft.RubyAnnotation) {
        if annotation.isShared { syllables[annotation.syllables.lowerBound].groupRuby = pieces }
        else { syllables[annotation.syllables.lowerBound].ruby = pieces }
    }

    public func rubyBase(of annotation: LyricsDraft.RubyAnnotation) -> ClosedRange<TimeInterval>? {
        guard syllables.indices.contains(annotation.syllables.upperBound),
              let start = syllables[annotation.syllables.lowerBound].start,
              let end = syllables[annotation.syllables.upperBound].end, end > start else { return nil }
        return start...end
    }

    /// Untimed pieces share the base span by text length.
    public func rubyTimes(of annotation: LyricsDraft.RubyAnnotation, base: ClosedRange<TimeInterval>) -> [LyricRuby] {
        LyricsDraft.Ruby.absolute(ruby(of: annotation), start: base.lowerBound, end: base.upperBound)
    }

    /// Touching neighbours move together; untimed ruby starts from its length-based timing.
    public func movingRubyEdge(_ edge: LyricsDraft.RubyEdge, ofPiece piece: Int, in annotation: LyricsDraft.RubyAnnotation,
                               base: ClosedRange<TimeInterval>, to time: TimeInterval, minimum: TimeInterval = 0.02) -> Self {
        var times = rubyTimes(of: annotation, base: base)
        guard times.indices.contains(piece), base.upperBound > base.lowerBound, time.isFinite else { return self }
        let gap = min(minimum, (base.upperBound - base.lowerBound) / Double(times.count * 2))
        let link = 0.002
        switch edge {
        case .start:
            let linked = piece > 0 && abs(times[piece - 1].end - times[piece].start) < link
            let lower = linked ? times[piece - 1].start + gap : piece > 0 ? times[piece - 1].end : base.lowerBound
            let upper = times[piece].end - gap
            guard lower <= upper else { return self }
            let value = min(max(time, lower), upper)
            times[piece].start = value
            if linked { times[piece - 1].end = value }
        case .end:
            let linked = piece + 1 < times.count && abs(times[piece + 1].start - times[piece].end) < link
            let lower = times[piece].start + gap
            let upper = linked ? times[piece + 1].end - gap : piece + 1 < times.count ? times[piece + 1].start : base.upperBound
            guard lower <= upper else { return self }
            let value = min(max(time, lower), upper)
            times[piece].end = value
            if linked { times[piece + 1].start = value }
        }
        var line = self
        line.setRuby(LyricsDraft.Ruby.relative(times, start: base.lowerBound, end: base.upperBound) ?? [], of: annotation)
        return line
    }

    /// Later syllable starts, normalized to the annotation's span (0…1).
    public func syllableFractions(of annotation: LyricsDraft.RubyAnnotation) -> [Double]? {
        let members = syllables[annotation.syllables]
        guard members.count > 1, let base = rubyBase(of: annotation), members.allSatisfy({ $0.start != nil }) else { return nil }
        let length = base.upperBound - base.lowerBound
        return members.dropFirst().map { min(max(($0.start! - base.lowerBound) / length, 0), 1) }
    }

    /// Missing piece ends use the next start. Shared syllables split by reading, then
    /// fallback fractions, then text length.
    public func timingRuby(_ annotation: LyricsDraft.RubyAnnotation, starts: [TimeInterval], ends: [TimeInterval?], end: TimeInterval,
                           fallback: [Double]? = nil) -> Self {
        let pieces = ruby(of: annotation)
        guard syllables.indices.contains(annotation.syllables.upperBound), !pieces.isEmpty, starts.count == pieces.count,
              let first = starts.first, end > first else { return self }
        var times: [LyricRuby] = []
        for (k, piece) in pieces.enumerated() {
            let next = k + 1 < starts.count ? starts[k + 1] : end
            let start = max(starts[k], times.last?.end ?? first)
            let explicit = k < ends.count ? ends[k] : nil
            let stop = max(min(explicit ?? next, next), start)
            times.append(LyricRuby(start: start, end: stop, text: piece.text))
        }
        var line = self
        let head = annotation.syllables.lowerBound, tail = annotation.syllables.upperBound
        line.syllables[head].start = first
        line.syllables[tail].end = end
        let timed = LyricsDraft.Ruby.relative(times, start: first, end: end) ?? pieces
        line.setRuby(timed, of: annotation)
        guard annotation.syllables.count > 1 else { return line }
        let members = annotation.syllables.map { syllables[$0].text.trimmingCharacters(in: .whitespaces) }
        let fractions: [Double]
        if let parts = LyricsDraft.readingParts(timed, over: members) {
            fractions = parts.dropFirst().map(\.span.lowerBound)
        } else if let fallback, fallback.count == members.count - 1 {
            fractions = fallback
        } else {
            let weights = members.map { Double(max($0.count, 1)) }
            let total = weights.reduce(0, +)
            var offset = 0.0
            fractions = weights.dropLast().map { offset += $0; return offset / total }
        }
        var previous = 0.0
        for (k, fraction) in fractions.enumerated() {
            let value = min(max(fraction, previous), 1)
            previous = value
            let boundary = first + (end - first) * value
            line.syllables[head + k].end = boundary
            line.syllables[head + k + 1].start = boundary
        }
        return line
    }

    /// Stretching keeps inner ruby boundaries at their absolute times, unless a piece would
    /// collapse; in that case its timing stays proportional to the syllable.
    public func keepingRubyTiming(from original: Self) -> Self {
        var result = self
        var old: [UUID: LyricsDraft.Syllable] = [:]
        for syllable in original.syllables where old[syllable.id] == nil { old[syllable.id] = syllable }
        for annotation in rubyAnnotations {
            let head = syllables[annotation.syllables.lowerBound], tail = syllables[annotation.syllables.upperBound]
            guard let oldHead = old[head.id], let oldTail = old[tail.id],
                  ((annotation.isShared ? oldHead.groupRuby : oldHead.ruby) ?? []) == ruby(of: annotation),
                  let os = oldHead.start, let oe = oldTail.end, oe > os,
                  let ns = head.start, let ne = tail.end, ne > ns else { continue }
            let movedStart = ns - os, movedEnd = ne - oe
            guard abs(movedStart) > 1e-9 || abs(movedEnd) > 1e-9, abs(movedStart - movedEnd) > 1e-9 else { continue }
            guard let kept = LyricsDraft.Ruby.restretched(ruby(of: annotation), from: os...oe, to: ns...ne) else { continue }
            result.setRuby(kept, of: annotation)
        }
        return result
    }
}

extension LyricsDraft.Ruby {
    public static let smallKana: Set<Character> = Set("ぁぃぅぇぉゃゅょゎゕゖァィゥェォャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ")

    public static func isTimed(_ pieces: [Self]?) -> Bool {
        guard let pieces, !pieces.isEmpty else { return false }
        return pieces.allSatisfy { $0.span != nil }
    }

    static func characters(of pieces: [Self]) -> [Character] {
        pieces.flatMap { $0.text.filter { !$0.isWhitespace } }
    }

    static func weight(_ character: Character) -> Double {
        smallKana.contains(character) ? 0 : 1
    }

    static func characterSpans(_ pieces: [Self]) -> [ClosedRange<Double>]? {
        guard isTimed(pieces) else { return nil }
        var result: [ClosedRange<Double>] = []
        for piece in pieces {
            let span = piece.span!
            var weights = piece.text.filter { !$0.isWhitespace }.map(weight)
            if weights.reduce(0, +) == 0 { weights = weights.map { _ in 1 } }
            let total = weights.reduce(0, +)
            var offset = 0.0
            for weight in weights {
                let lo = span.lowerBound + (span.upperBound - span.lowerBound) * offset / total
                offset += weight
                let hi = span.lowerBound + (span.upperBound - span.lowerBound) * offset / total
                result.append(lo...max(lo, hi))
            }
        }
        return result
    }

    static func timedOrSpread(_ pieces: [Self]) -> [Self] {
        guard !isTimed(pieces) else { return pieces }
        return relative(absolute(pieces, start: 0, end: 1), start: 0, end: 1) ?? pieces
    }

    /// The same reading keeps character timing. A changed reading keeps spans only when
    /// the piece count matches; otherwise timing is cleared.
    public static func resegmented(_ texts: [String], from old: [Self]) -> [Self] {
        let reading = texts.flatMap { $0.filter { !$0.isWhitespace } }
        if let spans = characterSpans(old), !reading.isEmpty, reading == characters(of: old) {
            var index = 0
            var result: [Self] = []
            for text in texts {
                let count = text.filter { !$0.isWhitespace }.count
                guard count > 0 else { result.append(Self(text: text)); continue }
                result.append(Self(text: text, span: spans[index].lowerBound...spans[index + count - 1].upperBound))
                index += count
            }
            if result.allSatisfy({ $0.span != nil }) { return result }
        }
        if texts.count == old.count { return zip(texts, old).map { Self(text: $0, span: $1.span) } }
        return texts.map { Self(text: $0) }
    }

    static func restretched(_ pieces: [Self], from old: ClosedRange<Double>, to new: ClosedRange<Double>) -> [Self]? {
        guard isTimed(pieces) else { return nil }
        let oldLength = old.upperBound - old.lowerBound, newLength = new.upperBound - new.lowerBound
        guard oldLength > 0, newLength > 0 else { return nil }
        func map(_ fraction: Double) -> Double {
            if fraction <= 1e-9 { return 0 }
            if fraction >= 1 - 1e-9 { return 1 }
            return min(max((old.lowerBound + fraction * oldLength - new.lowerBound) / newLength, 0), 1)
        }
        let result = pieces.map { piece -> Self in
            let lo = map(piece.span!.lowerBound)
            return Self(text: piece.text, span: lo...max(lo, map(piece.span!.upperBound)))
        }
        for (before, after) in zip(pieces, result) {
            let had = (before.span!.upperBound - before.span!.lowerBound) * oldLength
            let has = (after.span!.upperBound - after.span!.lowerBound) * newLength
            if had > 0.001 && has < min(0.005, had) { return nil }
        }
        return result
    }

    public static func morae(of text: String) -> [String]? {
        let body = text.trimmingCharacters(in: .whitespaces)
        guard JapaneseReadingAlignment.kana(body) != nil else { return nil }
        var result: [String] = []
        for character in body where !character.isWhitespace {
            if smallKana.contains(character), !result.isEmpty { result[result.count - 1].append(character) }
            else { result.append(String(character)) }
        }
        return result
    }
}

// MARK: - Editing timed ruby

extension LyricsDraft {
    @discardableResult
    public mutating func splitRubyIntoMorae(at positions: [Position]) -> Int {
        var changed = 0
        var done = Set<[Int]>()
        for position in Set(positions).filter(contains).sorted() {
            guard let annotation = lines[position.line].rubyAnnotation(containing: position.syllable),
                  done.insert([position.line, annotation.syllables.lowerBound]).inserted else { continue }
            let pieces = lines[position.line].ruby(of: annotation)
            let texts = pieces.flatMap { piece -> [String] in
                guard var morae = Ruby.morae(of: piece.text) else { return [piece.text] }
                if piece.text.last?.isWhitespace == true, let last = morae.indices.last { morae[last] += " " }
                return morae
            }
            guard texts != pieces.map(\.text) else { continue }
            lines[position.line].setRuby(Ruby.resegmented(texts, from: pieces), of: annotation)
            changed += 1
        }
        return changed
    }

    /// Keeps timing and leaves kana syllables without ruby. Returns false if the reading
    /// cannot be aligned to the syllables.
    @discardableResult
    public mutating func splitSharedRuby(at position: Position) -> Bool {
        guard let group = rubyGroup(at: position) else { return false }
        let line = position.line
        let members = Array(lines[line].syllables[group])
        let pieces = members[0].groupRuby ?? []
        guard let readings = Self.readingParts(pieces, over: members.map { $0.text.trimmingCharacters(in: .whitespaces) }) else { return false }
        let timed = Ruby.isTimed(pieces)
        let hull: ClosedRange<TimeInterval>? = members.first?.start.flatMap { start in members.last?.end.flatMap { $0 > start ? start...$0 : nil } }
        for (offset, reading) in readings.enumerated() {
            let index = group.lowerBound + offset
            lines[line].syllables[index].groupRuby = nil
            lines[line].syllables[index].joinsRubyGroup = false
            let member = members[offset]
            lines[line].syllables[index].ruby = reading.slices.isEmpty ? nil : reading.slices.map { slice in
                guard timed, let hull, let start = member.start, let end = member.end, end > start else { return Ruby(text: slice.text) }
                let length = hull.upperBound - hull.lowerBound
                let lo = hull.lowerBound + length * slice.span.lowerBound, hi = hull.lowerBound + length * slice.span.upperBound
                return Ruby(text: slice.text, span: Ruby.clamped((lo - start) / (end - start), (hi - start) / (end - start)))
            }
        }
        normalizeRubyGroups(inLine: line)
        return true
    }

    /// Spans are relative to the full annotation (0…1).
    struct ReadingPart {
        var slices: [(text: String, span: ClosedRange<Double>)]
        var span: ClosedRange<Double>
    }

    static func readingParts(_ pieces: [Ruby], over bases: [String]) -> [ReadingPart]? {
        let reading = Ruby.characters(of: pieces)
        guard bases.count > 1, !reading.isEmpty,
              let aligned = JapaneseReadingAlignment.align(reading: String(reading), to: bases),
              aligned.count == bases.count, aligned.map(\.reading.count).reduce(0, +) == reading.count,
              let spans = Ruby.characterSpans(Ruby.timedOrSpread(pieces)), spans.count == reading.count else { return nil }
        let owners = pieces.enumerated().flatMap { index, piece in Array(repeating: index, count: piece.text.filter { !$0.isWhitespace }.count) }
        var result: [ReadingPart] = []
        var cursor = 0
        for (base, part) in zip(bases, aligned) {
            let range = cursor..<(cursor + part.reading.count)
            cursor = range.upperBound
            guard let first = range.first, let last = range.last else { return nil }
            var slices: [(text: String, span: ClosedRange<Double>)] = []
            if JapaneseReadingAlignment.kana(base) == nil {
                var owner = -1
                for index in range {
                    if owners[index] == owner, let previous = slices.last {
                        slices[slices.count - 1] = (previous.text + String(reading[index]), previous.span.lowerBound...spans[index].upperBound)
                    } else {
                        slices.append((String(reading[index]), spans[index]))
                        owner = owners[index]
                    }
                }
            }
            result.append(ReadingPart(slices: slices, span: spans[first].lowerBound...spans[last].upperBound))
        }
        return result
    }

    public func ownRubyText(over positions: [Position]) -> String {
        guard let first = positions.min(), let last = positions.max(), first.line == last.line,
              contains(first), contains(last) else { return "" }
        return ownRubyAsShared(inLine: first.line, range: first.syllable...last.syllable).map(\.text).joined(separator: "|")
    }

    func ownRubyAsShared(inLine line: Int, range: ClosedRange<Int>) -> [Ruby] {
        let members = Array(lines[line].syllables[range])
        guard members.contains(where: { !($0.ruby ?? []).isEmpty }) else { return [] }
        let owns = members.map { member -> [Ruby] in
            if let ruby = member.ruby, !ruby.isEmpty { return ruby }
            let text = member.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? [] : [Ruby(text: text, span: 0...1)]
        }
        guard members.contains(where: { Ruby.isTimed($0.ruby) }),
              members.allSatisfy({ $0.start != nil && $0.end != nil }),
              let start = members.first?.start, let end = members.last?.end, end > start else {
            return owns.flatMap { $0.map { Ruby(text: $0.text) } }
        }
        return zip(members, owns).flatMap { member, own in
            Ruby.absolute(own, start: member.start!, end: max(member.end!, member.start!)).map {
                Ruby(text: $0.text, span: Ruby.clamped(($0.start - start) / (end - start), ($0.end - start) / (end - start)))
            }
        }
    }
}
