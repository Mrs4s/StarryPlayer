import AudioProcessing
import Foundation
import LyricsCore

public struct LyricsCalibration: Sendable {
    /// The estimate over everything analysed (nil when there was too little to measure).
    public var estimate: LyricsOffsetEstimate?
    /// The offset to apply (`+` = show the lyrics later), or nil when the result is not reliable.
    public var offset: TimeInterval?
    /// Stretches analysed, in seconds of the song.
    public var windows: [ClosedRange<TimeInterval>]
    public var separatedDuration: TimeInterval
    public var songDuration: TimeInterval
    /// Network used; nil when the mix was measured without separation.
    public var model: VocalSeparationModel?

    /// Why there is no `offset` (nil when there is one).
    public var failure: Failure? {
        guard offset == nil else { return nil }
        guard let estimate else { return .tooLittle }
        return estimate.isConfident ? .inconsistent : .noClearMatch
    }

    public enum Failure: Sendable, Equatable {
        case tooLittle
        case noClearMatch
        /// A clear shift overall, but parts of the song disagree on it (lyrics that drift or
        /// jump): one offset cannot fix them.
        case inconsistent
    }
}

public struct LyricsCalibrator: Sendable {
    public var windowLength: TimeInterval = 20
    public var sections = 5
    public var minimumWindows = 2
    public var agreement: TimeInterval = 0.08
    public var searchRange: TimeInterval = 5

    public init() {}

    /// Runs synchronously; call it off the main thread. `isCancelled` is checked between windows
    /// (throws `CancellationError`), `progress` gets the fraction of the planned windows done.
    public func calibrate(
        audio url: URL,
        document: LyricsDocument,
        model: VocalSeparationModel?,
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> LyricsCalibration {
        let analyzer = try VocalActivityAnalyzer(file: url, model: model)
        let windows = plan(document, duration: analyzer.duration)
        var result = LyricsCalibration(estimate: nil, offset: nil, windows: [], separatedDuration: 0, songDuration: analyzer.duration, model: analyzer.model)
        for (index, window) in windows.enumerated() {
            if isCancelled() { throw CancellationError() }
            try analyzer.analyze(window)
            result.windows.append(window)
            result.separatedDuration = analyzer.separatedDuration
            progress(Double(index + 1) / Double(windows.count))
            guard result.windows.count >= min(minimumWindows, windows.count) else { continue }
            let activity = analyzer.activity
            guard let estimate = LyricsOffsetEstimator.estimate(activity, document: document, valid: mask(result.windows, activity), searchRange: searchRange) else { continue }
            result.estimate = estimate
            guard estimate.isConfident else { continue }
            if isStable(estimate, windows: result.windows, activity: activity, document: document) {
                result.offset = estimate.calibratedOffset
                return result
            }
        }
        return result
    }

    private func isStable(_ estimate: LyricsOffsetEstimate, windows: [ClosedRange<TimeInterval>], activity: VocalActivity, document: LyricsDocument) -> Bool {
        guard windows.count > 1 else { return true }
        for skipped in windows.indices {
            var others = windows
            others.remove(at: skipped)
            guard let partial = LyricsOffsetEstimator.estimate(activity, document: document, valid: mask(others, activity), searchRange: searchRange),
                  abs(partial.offset - estimate.offset) <= agreement
            else { return false }
        }
        return true
    }

    func mask(_ windows: [ClosedRange<TimeInterval>], _ activity: VocalActivity) -> [Bool] {
        var mask = [Bool](repeating: false, count: activity.frameCount)
        for window in windows {
            let from = max(0, Int((window.lowerBound * VocalActivity.frameRate).rounded(.up)))
            let to = min(activity.frameCount, Int((window.upperBound * VocalActivity.frameRate).rounded(.down)))
            guard to > from else { continue }
            for t in from..<to where activity.valid[t] { mask[t] = true }
        }
        return mask
    }

    public func plan(_ document: LyricsDocument, duration: TimeInterval) -> [ClosedRange<TimeInterval>] {
        let sung = document.lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = sung.first, let last = sung.last, duration > 0 else { return [] }
        var weights: [(start: TimeInterval, weight: Double)] = []
        var previousEnd = -TimeInterval.infinity
        for line in sung {
            weights.append((line.start, line.start - previousEnd >= 0.3 ? 2 : 1))
            previousEnd = line.end
        }
        let low = max(0, first.start - 2), high = min(duration, last.end + 2)
        guard high > low else { return [] }
        if high - low <= windowLength * 1.5 { return [low...high] }

        let candidates = Array(stride(from: low, through: high - windowLength, by: 2.5))
        let scores = candidates.map { start in
            weights.reduce(0) { $0 + ($1.start >= start + 0.5 && $1.start < start + windowLength - 1 ? $1.weight : 0) }
        }
        let step = (high - windowLength - low) / Double(sections)
        let order = Self.visitingOrder(sections)
        var windows: [ClosedRange<TimeInterval>] = []
        for section in order {
            let from = low + Double(section) * step, to = from + step
            let best = candidates.indices
                .filter { candidates[$0] >= from - 1e-9 && candidates[$0] <= to + 1e-9 }
                .max { scores[$0] < scores[$1] }
            guard let best, scores[best] > 0 else { continue }
            let window = candidates[best]...(candidates[best] + windowLength)
            if !windows.contains(window) { windows.append(window) }
        }
        return windows
    }

    static func visitingOrder(_ count: Int) -> [Int] {
        Array(stride(from: 0, to: count, by: 2)) + Array(stride(from: 1, to: count, by: 2))
    }
}
