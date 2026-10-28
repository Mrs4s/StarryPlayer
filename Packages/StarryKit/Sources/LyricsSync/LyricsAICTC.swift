import Foundation

enum LyricsAICTC {
    struct Evidence: Sendable {
        var frames: Int
        var width: Int
        var blank: Int
        var logProbabilities: [Float]
        var sustain: [Float] // frame-major: rest, a, i, u, e, o, N, Q
        var silent: [Bool]
        var duration: Double
        var frameSeconds: Double = 0.02
    }

    struct Token: Sendable, Equatable {
        var label: Int
        var sustainClass: Int
        var endsLine: Bool = false
        var isStandaloneVowel: Bool = false
    }

    struct Span: Sendable, Equatable {
        var start: Double
        var end: Double
    }

    static func align(_ evidence: Evidence, tokens: [Token], maximumCells: Int = 160_000_000,
                      progress: @Sendable (Double) -> Void = { _ in }) throws -> [Span] {
        let frames = evidence.frames, states = tokens.count * 2 + 1
        let (cells, overflow) = frames.multipliedReportingOverflow(by: states)
        guard !overflow, cells <= maximumCells else { throw LyricsAIError.tooLarge }
        guard frames > 0, !tokens.isEmpty, evidence.width > 0,
              (0..<evidence.width).contains(evidence.blank),
              evidence.logProbabilities.count == frames * evidence.width,
              evidence.sustain.count == frames * 8, evidence.silent.count == frames,
              evidence.duration.isFinite, evidence.duration > 0,
              evidence.frameSeconds.isFinite, evidence.frameSeconds > 0,
              evidence.logProbabilities.allSatisfy(\.isFinite), evidence.sustain.allSatisfy(\.isFinite),
              tokens.allSatisfy({ (0..<evidence.width).contains($0.label) && $0.label != evidence.blank && (-1..<8).contains($0.sustainClass) && $0.sustainClass != 0 }) else {
            throw LyricsAIError.alignment("模型输出或歌词读音无效")
        }
        let repeats = zip(tokens, tokens.dropFirst()).filter { $0.label == $1.label }.count
        guard frames >= tokens.count + repeats else { throw LyricsAIError.alignment("音频长度不足以容纳这些歌词") }
        var labels = [Int](repeating: evidence.blank, count: states)
        for i in tokens.indices { labels[2 * i + 1] = tokens[i].label }
        var previous = [Float](repeating: -.infinity, count: states)
        var current = previous
        var back = [UInt8](repeating: 0, count: cells)
        previous[0] = evidence.logProbabilities[evidence.blank]
        previous[1] = evidence.logProbabilities[tokens[0].label]
        if frames > 1 {
            for frame in 1..<frames {
                if frame.isMultiple(of: 128) {
                    try Task.checkCancellation()
                    progress(Double(frame) / Double(frames) * 0.75)
                }
                let row = frame * evidence.width, backRow = frame * states
                for state in 0..<states {
                    var best = previous[state]
                    var step: UInt8 = 0
                    if state >= 1, previous[state - 1] > best { best = previous[state - 1]; step = 1 }
                    if state >= 2, state % 2 == 1, labels[state] != labels[state - 2], previous[state - 2] > best {
                        best = previous[state - 2]; step = 2
                    }
                    var value = best + evidence.logProbabilities[row + labels[state]]
                    if evidence.silent[frame], state % 2 == 0, state > 0, state < states - 1,
                       !tokens[state / 2 - 1].endsLine { value -= 0.1 }
                    current[state] = value
                    back[backRow + state] = step
                }
                swap(&previous, &current)
            }
        }
        var state = previous[states - 1] > previous[states - 2] ? states - 1 : states - 2
        guard previous[state].isFinite else { throw LyricsAIError.alignment("未找到完整的歌词顺序") }
        var path = [Int](repeating: 0, count: frames)
        for frame in (0..<frames).reversed() {
            path[frame] = state
            if frame > 0 { state -= Int(back[frame * states + state]) }
        }
        try Task.checkCancellation()
        fill(&path, evidence: evidence, tokens: tokens)
        var starts = [Int](repeating: -1, count: tokens.count)
        var ends = starts
        for (frame, state) in path.enumerated() where state % 2 == 1 {
            let token = state / 2
            if starts[token] < 0 { starts[token] = frame }
            ends[token] = frame + 1
        }
        guard starts.allSatisfy({ $0 >= 0 }) else { throw LyricsAIError.alignment("对齐结果缺少部分歌词") }
        progress(1)
        return tokens.indices.map {
            Span(start: Double(starts[$0]) * evidence.frameSeconds,
                 end: min(evidence.duration, Double(ends[$0]) * evidence.frameSeconds))
        }
    }

    private static func fill(_ path: inout [Int], evidence: Evidence, tokens: [Token]) {
        let cap = max(1, Int(4 / evidence.frameSeconds))
        var lo = 0
        while lo < path.count {
            let state = path[lo]
            var hi = lo + 1
            while hi < path.count, path[hi] == state { hi += 1 }
            defer { lo = hi }
            guard state % 2 == 0 else { continue }
            let count = hi - lo, rightIndex = state / 2
            let left: Token? = rightIndex > 0 ? tokens[rightIndex - 1] : nil
            let right: Token? = rightIndex < tokens.count ? tokens[rightIndex] : nil
            var blank = [Double](repeating: 0, count: count + 1)
            var taken = [Double](repeating: -.infinity, count: count + 1)
            var kept = taken
            taken[0] = 0
            kept[count] = 0
            for j in 0..<count {
                let frame = lo + j
                let b = Double(evidence.logProbabilities[frame * evidence.width + evidence.blank])
                blank[j + 1] = blank[j] + b + Double(evidence.sustain[frame * 8])
                if let left, j < cap { taken[j + 1] = taken[j] + owned(left, frame: frame, blank: b, evidence: evidence) }
            }
            if let right {
                for j in (max(0, count - cap)..<count).reversed() {
                    let frame = lo + j
                    let b = Double(evidence.logProbabilities[frame * evidence.width + evidence.blank])
                    kept[j] = kept[j + 1] + owned(right, frame: frame, blank: b, evidence: evidence)
                }
            }
            let repeated = left != nil && right != nil && left!.label == right!.label
            var bestPrefix = -Double.infinity, bestU = 0
            var total = -Double.infinity, selectedU = 0, selectedV = count
            for v in 0...count {
                let u = v - (repeated ? 1 : 0)
                if u >= 0 {
                    let gain = taken[u] - blank[u]
                    // Break ties toward the latest prefix and earliest suffix.
                    if gain >= bestPrefix { bestPrefix = gain; bestU = u }
                    let candidate = bestPrefix + blank[v] + kept[v]
                    if candidate > total { total = candidate; selectedU = bestU; selectedV = v }
                }
            }
            if selectedU > 0 { for i in lo..<(lo + selectedU) { path[i] = state - 1 } }
            if selectedV < count { for i in (lo + selectedV)..<hi { path[i] = state + 1 } }
        }
    }

    private static func owned(_ token: Token, frame: Int, blank: Double, evidence: Evidence) -> Double {
        let score = Double(evidence.logProbabilities[frame * evidence.width + token.label])
        guard token.sustainClass >= 0 else { return score }
        let held = blank + Double(evidence.sustain[frame * 8 + token.sustainClass])
        let top = max(score, held)
        return top + log1p(exp(min(score, held) - top))
    }
}
