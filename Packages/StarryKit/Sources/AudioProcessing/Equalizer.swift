import Foundation
import os

public enum EqualizerBands {
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    public static let count = 10
    /// About two octaves between the half-gain points: wide enough that the solved curve
    /// (`EqualizerResponse.filterGains(for:)`) has no dips between bands (all at +6 dB stays
    /// within ±0.3 dB), while one band alone stays an octave wide — its neighbours are solved
    /// slightly negative.
    public static let q = 0.7
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let preampRange: ClosedRange<Double> = -12...12
    static let filterGainLimit = 24.0
}

public struct EqualizerPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    /// dB per band.
    public let gains: [Double]

    public init(id: String, name: String, gains: [Double]) {
        self.id = id
        self.name = name
        self.gains = gains
    }

    public static let customID = "custom"
    public static let flat = EqualizerPreset(id: "flat", name: "平直", gains: Array(repeating: 0, count: EqualizerBands.count))

    public static let all: [EqualizerPreset] = [
        flat,
        EqualizerPreset(id: "pop", name: "流行", gains: [-1, 0, 1.5, 3, 3.5, 2.5, 1, 0, 0.5, 1]),
        EqualizerPreset(id: "rock", name: "摇滚", gains: [4.5, 3.5, 2, 0.5, -1, -1, 0.5, 2.5, 3.5, 4]),
        EqualizerPreset(id: "classical", name: "古典", gains: [3, 2.5, 1.5, 1, -0.5, -0.5, 0, 1.5, 2.5, 3]),
        EqualizerPreset(id: "jazz", name: "爵士", gains: [3, 2, 1, 1.5, -1, -1, 0, 1.5, 2.5, 3]),
        EqualizerPreset(id: "electronic", name: "电子", gains: [5, 4, 1.5, 0, -1.5, 1, 0.5, 1.5, 3.5, 4.5]),
        EqualizerPreset(id: "hiphop", name: "嘻哈", gains: [5, 4, 2, 2.5, -0.5, -0.5, 1, 0, 1.5, 2.5]),
        EqualizerPreset(id: "acoustic", name: "原声", gains: [3.5, 3, 2.5, 1, 1, 1, 2, 2.5, 2, 1.5]),
        EqualizerPreset(id: "piano", name: "钢琴", gains: [2, 1.5, 0, 1.5, 2, 1, 2.5, 3, 2, 2.5]),
        EqualizerPreset(id: "vocal", name: "人声", gains: [-2, -2.5, -2, 1, 3, 3.5, 3, 1.5, 0, -1.5]),
        EqualizerPreset(id: "bassBoost", name: "低音增强", gains: [6, 5, 3.5, 2, 0.5, 0, 0, 0, 0, 0]),
        EqualizerPreset(id: "trebleBoost", name: "高音增强", gains: [0, 0, 0, 0, 0, 0.5, 2, 3.5, 5, 6]),
        EqualizerPreset(id: "loudness", name: "响度", gains: [5, 3.5, 1, 0, -1, -1, 0, 1, 3, 4]),
        EqualizerPreset(id: "smallSpeakers", name: "小音箱", gains: [4.5, 4, 3, 1.5, 0.5, 0, -0.5, -1, -1.5, -2]),
        EqualizerPreset(id: "soft", name: "柔和", gains: [1, 1, 1, 1, 1, 0.5, -0.5, -2, -3, -4]),
    ]

    public static func preset(id: String) -> EqualizerPreset? {
        all.first { $0.id == id }
    }
}

public struct EqualizerSettings: Codable, Sendable, Equatable {
    public var isEnabled = false
    public var presetID = EqualizerPreset.flat.id
    /// dB per band, in `EqualizerBands.gainRange`.
    public var gains: [Double] = Array(repeating: 0, count: EqualizerBands.count)
    public var customGains: [Double] = Array(repeating: 0, count: EqualizerBands.count)
    /// dB before the bands, in `EqualizerBands.preampRange`.
    public var preamp: Double = 0
    public var clipGuard = true

    public init() {}

    public var presetName: String {
        presetID == EqualizerPreset.customID ? "自定义" : EqualizerPreset.preset(id: presetID)?.name ?? "自定义"
    }

    public var isFlat: Bool { preamp == 0 && gains.allSatisfy { $0 == 0 } }

    public mutating func select(_ preset: EqualizerPreset) {
        presetID = preset.id
        gains = preset.gains
    }

    public mutating func selectCustom() {
        presetID = EqualizerPreset.customID
        gains = customGains
    }

    public mutating func setGain(_ gain: Double, at band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = Self.clamp(gain, to: EqualizerBands.gainRange)
        presetID = EqualizerPreset.customID
        customGains = gains
    }

    public mutating func setPreamp(_ value: Double) {
        preamp = Self.clamp(value, to: EqualizerBands.preampRange)
    }

    public mutating func reset() {
        select(.flat)
        preamp = 0
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(value, range.lowerBound), range.upperBound) * 10).rounded() / 10
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, presetID, gains, customGains, preamp, clipGuard }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EqualizerSettings()
        func curve(_ key: CodingKeys) -> [Double] {
            guard let values = try? c.decodeIfPresent([Double].self, forKey: key), values.count == EqualizerBands.count else { return d.gains }
            return values.map { Self.clamp($0, to: EqualizerBands.gainRange) }
        }
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        presetID = (try? c.decodeIfPresent(String.self, forKey: .presetID)) ?? d.presetID
        gains = curve(.gains)
        customGains = curve(.customGains)
        preamp = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .preamp)) ?? d.preamp, to: EqualizerBands.preampRange)
        clipGuard = (try? c.decodeIfPresent(Bool.self, forKey: .clipGuard)) ?? d.clipGuard
        if presetID != EqualizerPreset.customID, EqualizerPreset.preset(id: presetID) == nil { presetID = EqualizerPreset.customID }
    }
}

struct Biquad: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = Biquad()

    static func peaking(frequency: Double, q: Double, gain: Double, sampleRate: Double) -> Biquad {
        guard gain != 0, sampleRate > 0, frequency < sampleRate * 0.48 else { return .identity }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0, a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }

    /// dB at the angular frequency whose cosines are given (ω and 2ω).
    func decibels(cos1: Double, cos2: Double) -> Double {
        let numerator = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * cos1 + 2 * b0 * b2 * cos2
        let denominator = 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * cos1 + 2 * a2 * cos2
        return 10 * log10(max(numerator, 1e-30) / max(denominator, 1e-30))
    }
}

public enum EqualizerResponse {
    /// The rate the filter gains are solved and the curve drawn at; the processor uses the same
    /// gains at its own rate (only 16 kHz differs noticeably, by well under 1 dB at 44.1 kHz).
    public static let referenceRate = 48000.0

    /// Filter gains whose combined response passes through `gains` at the band centres.
    /// Neighbouring bands overlap (all ten at +6 dB would give about +11 dB), so the gains are
    /// solved for: a few Newton steps with the bands' interaction matrix, clamped to
    /// ±`filterGainLimit` where a curve is steeper than octave-wide filters can follow.
    public static func filterGains(for gains: [Double], sampleRate: Double = referenceRate) -> [Double] {
        let n = EqualizerBands.count
        guard gains.count == n else { return Array(repeating: 0, count: n) }
        if gains.allSatisfy({ $0 == 0 }) { return gains }
        let sampler = ResponseSampler(frequencies: EqualizerBands.frequencies, sampleRate: sampleRate)
        let inverse = interactionInverse
        var filter = gains
        for _ in 0..<6 {
            let response = sampler.response(filterGains: filter)
            var error = 0.0
            var residual = [Double](repeating: 0, count: n)
            for i in 0..<n {
                residual[i] = gains[i] - response[i]
                error = max(error, abs(residual[i]))
            }
            if error < 0.01 { break }
            for i in 0..<n {
                var step = 0.0
                for j in 0..<n { step += inverse[i * n + j] * residual[j] }
                filter[i] = min(max(filter[i] + step, -EqualizerBands.filterGainLimit), EqualizerBands.filterGainLimit)
            }
        }
        return filter
    }

    /// dB at each of `frequencies` with these filter gains.
    public static func response(filterGains: [Double], at frequencies: [Double], sampleRate: Double = referenceRate) -> [Double] {
        ResponseSampler(frequencies: frequencies, sampleRate: sampleRate).response(filterGains: filterGains)
    }

    /// ∂(response at centre i) / ∂(filter gain j) around ±6 dB, inverted (row-major).
    private static let interactionInverse: [Double] = {
        let n = EqualizerBands.count
        let probe = 6.0
        let sampler = ResponseSampler(frequencies: EqualizerBands.frequencies, sampleRate: referenceRate)
        var matrix = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            var single = [Double](repeating: 0, count: n)
            single[j] = probe
            let up = sampler.response(filterGains: single)
            single[j] = -probe
            let down = sampler.response(filterGains: single)
            for i in 0..<n { matrix[i * n + j] = (up[i] - down[i]) / (2 * probe) }
        }
        return invert(matrix, size: n) ?? (0..<n * n).map { $0 / n == $0 % n ? 1 : 0 }
    }()

    /// Gauss–Jordan with partial pivoting; nil when singular.
    static func invert(_ matrix: [Double], size n: Int) -> [Double]? {
        var a = matrix
        var inverse = (0..<n * n).map { $0 / n == $0 % n ? 1.0 : 0.0 }
        for column in 0..<n {
            var pivot = column
            for row in column + 1..<n where abs(a[row * n + column]) > abs(a[pivot * n + column]) { pivot = row }
            guard abs(a[pivot * n + column]) > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<n {
                    a.swapAt(pivot * n + k, column * n + k)
                    inverse.swapAt(pivot * n + k, column * n + k)
                }
            }
            let scale = 1 / a[column * n + column]
            for k in 0..<n {
                a[column * n + k] *= scale
                inverse[column * n + k] *= scale
            }
            for row in 0..<n where row != column {
                let factor = a[row * n + column]
                guard factor != 0 else { continue }
                for k in 0..<n {
                    a[row * n + k] -= factor * a[column * n + k]
                    inverse[row * n + k] -= factor * inverse[column * n + k]
                }
            }
        }
        return inverse
    }
}

public struct ResponseSampler: Sendable {
    public let frequencies: [Double]
    public let sampleRate: Double
    private let cos1: [Double]
    private let cos2: [Double]

    public init(frequencies: [Double], sampleRate: Double = EqualizerResponse.referenceRate) {
        self.frequencies = frequencies
        self.sampleRate = sampleRate
        let omegas = frequencies.map { 2 * Double.pi * min($0, sampleRate / 2) / sampleRate }
        cos1 = omegas.map { cos($0) }
        cos2 = omegas.map { cos(2 * $0) }
    }

    /// dB at every frequency: the sum of the bands' dB (they are in series).
    public func response(filterGains: [Double]) -> [Double] {
        var total = [Double](repeating: 0, count: frequencies.count)
        for (band, gain) in filterGains.enumerated() where gain != 0 && band < EqualizerBands.count {
            let filter = Biquad.peaking(frequency: EqualizerBands.frequencies[band], q: EqualizerBands.q, gain: gain, sampleRate: sampleRate)
            for i in total.indices { total[i] += filter.decibels(cos1: cos1[i], cos2: cos2[i]) }
        }
        return total
    }
}

/// What every item's equalizer follows. Written on the main thread, read at the start of each
/// audio block under an unfair lock (uncontended, fixed size, no allocation).
public final class EqualizerControl: Sendable {
    public struct State: Sendable, Equatable {
        public var enabled = false
        /// Solved filter gains (`EqualizerResponse.filterGains(for:)`), dB; lanes past the
        /// tenth are unused.
        public var filterGains = SIMD16<Double>(repeating: 0)
        public var preamp: Double = 0
        public var clipGuard = true
        public init() {}
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var current: State { state.withLock { $0 } }

    public func update(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    public static func state(for settings: EqualizerSettings) -> State {
        var state = State()
        state.enabled = settings.isEnabled
        for (band, gain) in EqualizerResponse.filterGains(for: settings.gains).enumerated() { state.filterGains[band] = gain }
        state.preamp = settings.preamp
        state.clipGuard = settings.clipGuard
        return state
    }
}
