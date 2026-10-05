import Accelerate
import AudioProcessing
import Foundation
import LyricsCore

/// Offset convention: audio time = lyric time + offset.
public struct LyricsOffsetEstimate: Sendable, Equatable {
    public enum Method: String, Sendable {
        case words
        case lines
    }

    public var method: Method
    public var offset: TimeInterval
    /// Peak height in standard deviations above the correlation median.
    public var score: Double
    /// Ratio to the best competing peak more than 0.35 s away.
    public var peakRatio: Double

    /// Word annotations lead vocal energy by about 60 ms; phrase onsets add about 80 ms.
    public static func bias(for method: Method) -> TimeInterval {
        method == .words ? 0.06 : 0.14
    }

    /// Positive offsets display lyrics later.
    public var calibratedOffset: TimeInterval { offset - Self.bias(for: method) }

    public var isConfident: Bool { score >= 3.5 && peakRatio >= 1.3 }
}

/// Correlates the lyric timing with `VocalActivity` over the analysed frames (Pearson per shift,
/// so stretches of different lengths weigh fairly), searching ±`searchRange`.
public enum LyricsOffsetEstimator {
    public static func estimate(_ activity: VocalActivity, document: LyricsDocument, valid: [Bool]? = nil, searchRange: TimeInterval = 5) -> LyricsOffsetEstimate? {
        let valid = valid ?? activity.valid
        let n = activity.frameCount
        guard valid.count == n, valid.lazy.filter({ $0 }).count >= Int(5 * VocalActivity.frameRate) else { return nil }
        let template = LyricsTemplate(document: document, frameCount: n)
        guard template.lineCount >= 3 else { return nil }
        let maxLag = Int(searchRange * VocalActivity.frameRate)

        // Activity 0…1 between the 10th and 95th percentile of the analysed frames.
        var activityLevel = Signal.movingAverage(activity.energy, width: 5)
        let levels = zip(activityLevel, valid).compactMap { $1 ? $0 : nil }.sorted()
        let low = levels[levels.count / 10], high = levels[min(levels.count - 1, levels.count * 95 / 100)]
        let span = max(high - low, 1e-6)
        activityLevel = activityLevel.map { min(max(($0 - low) / span, 0), 1) }

        var curves: [[Double]] = []
        switch template.method {
        case .words:
            curves.append(correlation(template.coverage, activityLevel, valid: valid, maxLag: maxLag))
            let onsets = Signal.gaussianBlur(template.onsets, sigma: 4)
            curves.append(correlation(onsets, Signal.movingAverage(activity.flux, width: 3), valid: valid, maxLag: maxLag))
        case .lines:
            let ahead = Signal.trailingMean(activityLevel, width: 10, ahead: true)
            let behind = Signal.trailingMean(activityLevel, width: 30, ahead: false)
            let phrase = zip(ahead, behind).map { max(0, $0 - $1) }
            curves.append(correlation(Signal.gaussianBlur(template.onsets, sigma: 6), phrase, valid: valid, maxLag: maxLag))
        }
        let normalized = curves.map { curve -> [Double] in
            let deviation = Signal.standardDeviation(curve)
            return curve.map { $0 / max(deviation, 1e-12) }
        }
        let curve = (0..<normalized[0].count).map { i in normalized.reduce(0) { $0 + $1[i] } / Double(normalized.count) }
        return peak(of: curve, maxLag: maxLag, method: template.method)
    }

    static func correlation(_ target: [Float], _ feature: [Float], valid: [Bool], maxLag: Int) -> [Double] {
        let n = feature.count
        let runs = Signal.runs(valid)
        let count = Double(runs.reduce(0) { $0 + $1.count })
        var mean = 0.0
        for run in runs { for t in run { mean += Double(feature[t]) } }
        mean /= count
        var centered = [Float](repeating: 0, count: n)
        var featureNorm = 0.0
        for run in runs {
            for t in run {
                let v = Double(feature[t]) - mean
                centered[t] = Float(v)
                featureNorm += v * v
            }
        }
        featureNorm = featureNorm.squareRoot()
        var curve = [Double](repeating: 0, count: 2 * maxLag + 1)
        target.withUnsafeBufferPointer { target in
            centered.withUnsafeBufferPointer { centered in
                for (index, lag) in (-maxLag...maxLag).enumerated() {
                    var sum = 0.0, sumSquares = 0.0, product = 0.0
                    for run in runs {
                        let from = max(run.lowerBound, lag), to = min(run.upperBound, n + lag)
                        guard to > from else { continue }
                        let length = vDSP_Length(to - from)
                        let shifted = target.baseAddress! + (from - lag)
                        var s: Float = 0, s2: Float = 0, p: Float = 0
                        vDSP_sve(shifted, 1, &s, length)
                        vDSP_svesq(shifted, 1, &s2, length)
                        vDSP_dotpr(shifted, 1, centered.baseAddress! + from, 1, &p, length)
                        sum += Double(s); sumSquares += Double(s2); product += Double(p)
                    }
                    let variance = sumSquares - sum * sum / count
                    curve[index] = variance > 1e-9 && featureNorm > 0 ? product / (variance.squareRoot() * featureNorm) : 0
                }
            }
        }
        return curve
    }

    static func peak(of curve: [Double], maxLag: Int, method: LyricsOffsetEstimate.Method) -> LyricsOffsetEstimate {
        let frameRate = VocalActivity.frameRate
        let best = curve.indices.max { curve[$0] < curve[$1] }!
        var fraction = 0.0
        if best > 0, best < curve.count - 1 {
            let a = curve[best - 1], b = curve[best], c = curve[best + 1]
            let denominator = a - 2 * b + c
            if denominator != 0 { fraction = 0.5 * (a - c) / denominator }
        }
        let exclusion = Int(0.35 * frameRate)
        let rival = curve.indices.filter { abs($0 - best) > exclusion }.map { curve[$0] }.max() ?? -.infinity
        let sorted = curve.sorted()
        let median = sorted[sorted.count / 2]
        let score = (curve[best] - median) / max(Signal.standardDeviation(curve), 1e-12)
        return LyricsOffsetEstimate(
            method: method,
            offset: (Double(best - maxLag) + fraction) / frameRate,
            score: score,
            peakRatio: rival > 0 ? curve[best] / rival : .infinity
        )
    }
}

struct LyricsTemplate {
    var method: LyricsOffsetEstimate.Method
    var coverage: [Float]
    var onsets: [Float]
    var lineCount: Int

    init(document: LyricsDocument, frameCount n: Int) {
        let sung = document.lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        method = sung.contains { $0.words.count > 1 } ? .words : .lines
        lineCount = sung.count
        coverage = [Float](repeating: 0, count: n)
        onsets = [Float](repeating: 0, count: n)
        func frame(_ time: TimeInterval) -> Int { Int((time * VocalActivity.frameRate).rounded(.down)) }
        for line in sung {
            if method == .words, line.words.count > 1 {
                for word in line.words + (line.background?.words ?? []) {
                    let a = frame(word.start), b = frame(word.end)
                    guard a >= 0, a < n else { continue }
                    for t in a..<max(a + 1, min(b, n)) { coverage[t] = 1 }
                    onsets[a] = 1
                }
            } else {
                let a = frame(line.start)
                if a >= 0, a < n { onsets[a] = 1 }
            }
        }
    }
}

enum Signal {
    static func movingAverage(_ x: [Float], width: Int) -> [Float] {
        guard width > 1 else { return x }
        let half = width / 2
        var prefix = [Float](repeating: 0, count: x.count + 1)
        for i in x.indices { prefix[i + 1] = prefix[i] + x[i] }
        return x.indices.map { i in
            let a = max(0, i - half), b = min(x.count, i - half + width)
            return (prefix[b] - prefix[a]) / Float(width)
        }
    }

    static func trailingMean(_ x: [Float], width: Int, ahead: Bool) -> [Float] {
        var prefix = [Float](repeating: 0, count: x.count + 1)
        for i in x.indices { prefix[i + 1] = prefix[i] + x[i] }
        return x.indices.map { t in
            if ahead {
                return (prefix[min(x.count, t + width)] - prefix[t]) / Float(width)
            }
            guard t >= width else { return 0 }
            return (prefix[t] - prefix[t - width]) / Float(width)
        }
    }

    static func gaussianBlur(_ x: [Float], sigma: Double) -> [Float] {
        let radius = Int(4 * sigma)
        let kernel = (-radius...radius).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
        var out = [Float](repeating: 0, count: x.count)
        for (i, value) in x.enumerated() where value != 0 {
            for (k, weight) in kernel.enumerated() {
                let t = i + k - radius
                if t >= 0, t < out.count { out[t] += value * weight }
            }
        }
        return out
    }

    static func standardDeviation(_ x: [Double]) -> Double {
        let mean = x.reduce(0, +) / Double(x.count)
        return (x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count)).squareRoot()
    }

    static func runs(_ mask: [Bool]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, on) in mask.enumerated() {
            if on, start == nil { start = i }
            if !on, let s = start { runs.append(s..<i); start = nil }
        }
        if let s = start { runs.append(s..<mask.count) }
        return runs
    }
}
