import Foundation

extension LyricsAICTC {
    // Compare candidates on the same frame window; scores depend on window length.
    static func sequenceLogProbability(_ evidence: Evidence, labels: [Int], frames: Range<Int>) throws -> Double? {
        try Task.checkCancellation()
        let (values, overflow) = evidence.frames.multipliedReportingOverflow(by: evidence.width)
        guard !overflow, evidence.width > 0, evidence.logProbabilities.count == values,
              (0..<evidence.width).contains(evidence.blank), !labels.isEmpty,
              labels.allSatisfy({ (0..<evidence.width).contains($0) && $0 != evidence.blank }),
              frames.lowerBound >= 0, frames.upperBound <= evidence.frames, !frames.isEmpty else { return nil }
        let repeats = zip(labels, labels.dropFirst()).filter { $0 == $1 }.count
        guard frames.count >= labels.count + repeats else { return -.infinity }
        var states = [Int](repeating: evidence.blank, count: labels.count * 2 + 1)
        for i in labels.indices { states[i * 2 + 1] = labels[i] }
        var previous = [Double](repeating: -.infinity, count: states.count)
        var current = previous
        previous[0] = 0
        for frame in frames {
            if frame.isMultiple(of: 128) { try Task.checkCancellation() }
            for state in states.indices {
                let value = evidence.logProbabilities[frame * evidence.width + states[state]]
                guard value.isFinite else { return nil }
                var paths = previous[state]
                if state > 0 { paths = logAdd(paths, previous[state - 1]) }
                if state > 1, state % 2 == 1, states[state] != states[state - 2] {
                    paths = logAdd(paths, previous[state - 2])
                }
                current[state] = paths + Double(value)
            }
            swap(&previous, &current)
        }
        return logAdd(previous[states.count - 1], previous[states.count - 2])
    }

    private static func logAdd(_ a: Double, _ b: Double) -> Double {
        if a == -.infinity { return b }
        if b == -.infinity { return a }
        let top = max(a, b)
        return top + log1p(exp(min(a, b) - top))
    }
}
