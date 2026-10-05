import Foundation

public enum LyricRomanizationGrouping {
    public struct Group: Sendable, Hashable {
        public var words: ClosedRange<Int>
        public var romanization: [Int]

        public init(words: ClosedRange<Int>, romanization: [Int]) {
            self.words = words
            self.romanization = romanization
        }
    }

    /// Groups in line order. Groups whose word ranges would interleave (out-of-order timing) are
    /// merged so every group covers a contiguous, disjoint run of words.
    public static func groups(words: [LyricWord], romanization: [LyricWord]) -> [Group] {
        var claimed = [Bool](repeating: false, count: words.count)
        var lastClaimed: Int?
        var raw: [(words: [Int], romanization: [Int])] = []
        for (ri, r) in romanization.enumerated() {
            let rStart = r.start
            let rEnd = r.syllables.last?.end ?? r.end
            let hits = words.indices.filter { !claimed[$0] && overlaps(rStart, rEnd, words[$0].start, words[$0].end) }
            if !hits.isEmpty {
                hits.forEach { claimed[$0] = true }
                lastClaimed = hits.last
                raw.append((hits, [ri]))
            } else if let last = lastClaimed, overlaps(rStart, rEnd, words[last].start, words[last].end),
                      let gi = raw.lastIndex(where: { $0.words.contains(last) }) {
                raw[gi].romanization.append(ri)
            }
        }
        let groups = raw
            .map { Group(words: $0.words.min()!...$0.words.max()!, romanization: $0.romanization) }
            .sorted { $0.words.lowerBound < $1.words.lowerBound }
        var merged: [Group] = []
        for group in groups {
            if let last = merged.last, group.words.lowerBound <= last.words.upperBound {
                merged[merged.count - 1] = Group(words: last.words.lowerBound...max(last.words.upperBound, group.words.upperBound),
                                                 romanization: (last.romanization + group.romanization).sorted())
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    static func overlaps(_ aStart: TimeInterval, _ aEnd: TimeInterval, _ bStart: TimeInterval, _ bEnd: TimeInterval) -> Bool {
        aStart < aEnd && bStart < bEnd && aStart < bEnd && bStart < aEnd
    }
}
