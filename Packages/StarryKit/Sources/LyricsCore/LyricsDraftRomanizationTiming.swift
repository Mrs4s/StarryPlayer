import Foundation

extension LyricsDraft {
    /// Seconds relative to the voice's start; a nil end remains unreleased.
    public struct RomanizationSegment: Sendable, Hashable, Codable {
        public var text: String
        public var start: Double
        public var end: Double?

        public init(text: String, start: Double, end: Double?) {
            self.text = text
            self.start = start
            self.end = end
        }

        static func relative(_ words: [LyricWord]?, start: TimeInterval, end _: TimeInterval) -> [Self]? {
            guard let words, !words.isEmpty else { return nil }
            return words.flatMap(\.syllables).map { Self(text: $0.text, start: $0.start - start, end: $0.end - start) }
        }

        static func absolute(_ segments: [Self]?, start: TimeInterval, end: TimeInterval) -> [LyricWord]? {
            guard let segments, !segments.isEmpty else { return nil }
            return LyricWordGrouping.words(from: segments.map {
                let begin = max(0, start + $0.start)
                return LyricSyllable(start: begin, end: max(begin, $0.end.map { start + $0 } ?? end), text: $0.text)
            })
        }
    }
}
