import Foundation

extension LyricsDraft.Line {
    /// Preserves text; ruby that cannot map to whole new syllables is discarded.
    public mutating func resplitSyllables() {
        var result: [LyricsDraft.Syllable] = []
        var first = 0
        while first < syllables.count {
            let source = syllables[first]
            if source.isRest || source.checkpoints != nil || source.hasRelease {
                result.append(source)
                first += 1
                continue
            }
            var end = first + 1
            while end < syllables.count {
                let next = syllables[end]
                guard next.agentIDs == source.agentIDs, !next.isRest,
                      next.checkpoints == nil, !next.hasRelease else { break }
                end += 1
            }
            let originals = Array(syllables[first..<end])
            var offset = 0
            let ranges = originals.map { syllable -> NSRange in
                let range = NSRange(location: offset, length: syllable.text.utf16.count)
                offset += range.length
                return range
            }
            var parts = LyricsDraftImport.syllables(in: originals.map(\.text).joined(), explicitBoundaries: false,
                                                    preservesWhitespace: true)
            offset = 0
            for index in parts.indices {
                let range = NSRange(location: offset, length: parts[index].text.utf16.count)
                offset += range.length
                let overlaps = originals.indices.filter { NSIntersectionRange(range, ranges[$0]).length > 0 }
                if let original = overlaps.first, overlaps.count == 1, range == ranges[original] {
                    parts[index] = originals[original]
                    continue
                }
                parts[index].agentIDs = source.agentIDs
                if !overlaps.isEmpty, overlaps.allSatisfy({
                    NSIntersectionRange(range, ranges[$0]) == ranges[$0] && !(originals[$0].ruby ?? []).isEmpty
                }) {
                    parts[index].ruby = overlaps.flatMap { originals[$0].ruby ?? [] }.map { .init(text: $0.text) }
                }
            }
            result += parts
            first = end
        }
        syllables = result
    }
}
