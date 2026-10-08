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
    public var mode = EqualizerMode.graphic
    public var presetID = EqualizerPreset.flat.id
    /// dB per band, in `EqualizerBands.gainRange`.
    public var gains: [Double] = Array(repeating: 0, count: EqualizerBands.count)
    public var customGains: [Double] = Array(repeating: 0, count: EqualizerBands.count)
    /// dB before the ten bands, in `EqualizerBands.preampRange`.
    public var preamp: Double = 0
    /// The parametric equalizer's bands, in no particular order (each in its own slot).
    public var bands: [ParametricBand] = []
    /// dB before the parametric bands, in `EqualizerBands.preampRange`.
    public var parametricPreamp: Double = 0
    /// Where the parametric bands came from (an imported file's name); empty for one's own.
    public var parametricName = ""
    public var clipGuard = true

    public init() {}

    public var presetName: String {
        if mode == .parametric { return parametricName.isEmpty ? "参数均衡" : parametricName }
        return presetID == EqualizerPreset.customID ? "自定义" : EqualizerPreset.preset(id: presetID)?.name ?? "自定义"
    }

    /// The preamp of the mode in use.
    public var activePreamp: Double { mode == .parametric ? parametricPreamp : preamp }

    public var isFlat: Bool {
        guard activePreamp == 0 else { return false }
        return mode == .parametric ? !bands.contains(where: \.isAudible) : gains.allSatisfy { $0 == 0 }
    }

    /// Picks a ten-band preset (and the ten bands).
    public mutating func select(_ preset: EqualizerPreset) {
        mode = .graphic
        presetID = preset.id
        gains = preset.gains
    }

    public mutating func selectCustom() {
        mode = .graphic
        presetID = EqualizerPreset.customID
        gains = customGains
    }

    public mutating func setGain(_ gain: Double, at band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = Self.clamp(gain, to: EqualizerBands.gainRange)
        presetID = EqualizerPreset.customID
        customGains = gains
    }

    /// Sets the preamp of the mode in use.
    public mutating func setPreamp(_ value: Double) {
        let value = Self.clamp(value, to: EqualizerBands.preampRange)
        if mode == .parametric { parametricPreamp = value } else { preamp = value }
    }

    /// Ten bands: back to flat with the preamp at 0 (the custom curve stays). Parametric: no
    /// bands, the preamp at 0.
    public mutating func reset() {
        if mode == .parametric {
            bands = []
            parametricPreamp = 0
            parametricName = ""
        } else {
            select(.flat)
            preamp = 0
        }
    }

    /// Switching to parametric with no bands yet starts from the ten-band curve, as the
    /// filters that play it (so it sounds the same).
    public mutating func setMode(_ mode: EqualizerMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        if mode == .parametric, bands.isEmpty, !gains.allSatisfy({ $0 == 0 }) { useGraphicCurve() }
    }

    /// Replaces the parametric bands and preamp with the ten-band curve's.
    public mutating func useGraphicCurve() {
        bands = graphicBands
        parametricPreamp = preamp
        parametricName = ""
    }

    /// The ten-band curve as parametric bands: its peaking filters at their solved gains (the
    /// bands at 0 dB left out).
    public var graphicBands: [ParametricBand] {
        EqualizerResponse.filterGains(for: gains).enumerated().compactMap { band, gain in
            gain == 0 ? nil : ParametricBand(slot: band, frequency: EqualizerBands.frequencies[band], gain: gain, q: EqualizerBands.q).clamped
        }
    }

    public func band(slot: Int) -> ParametricBand? {
        bands.first { $0.slot == slot }
    }

    /// Adds a band in the first free slot (nil when all are taken), and returns that slot.
    @discardableResult
    public mutating func addBand(_ band: ParametricBand) -> Int? {
        let taken = Set(bands.map(\.slot))
        guard let slot = (0..<ParametricEqualizer.maxBands).first(where: { !taken.contains($0) }) else { return nil }
        var band = band.clamped
        band.slot = slot
        bands.append(band)
        return slot
    }

    public mutating func updateBand(slot: Int, _ change: (inout ParametricBand) -> Void) {
        guard let index = bands.firstIndex(where: { $0.slot == slot }) else { return }
        var band = bands[index]
        change(&band)
        band.slot = slot
        bands[index] = band.clamped
    }

    public mutating func removeBand(slot: Int) {
        bands.removeAll { $0.slot == slot }
    }

    /// Replaces the parametric bands and preamp (an imported file's), and switches to them.
    public mutating func setParametric(_ profile: EqualizerAPOText.Profile, name: String) {
        mode = .parametric
        bands = Self.sanitized(profile.bands)
        parametricPreamp = Self.clamp(profile.preamp, to: EqualizerBands.preampRange)
        parametricName = name
    }

    /// The curve's highest point in dB (0 when it only cuts): its negative as the preamp keeps
    /// the bands from clipping.
    public var peakGain: Double {
        var frequencies = (0...240).map { 20 * pow(1000, Double($0) / 240) }
        if mode == .parametric { frequencies += bands.map(\.frequency) }
        let sampler = ResponseSampler(frequencies: frequencies)
        let response = mode == .parametric ? sampler.response(bands: bands) : sampler.response(filterGains: EqualizerResponse.filterGains(for: gains))
        return max(response.max() ?? 0, 0)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(value, range.lowerBound), range.upperBound) * 10).rounded() / 10
    }

    /// Each band in its own slot (a taken or out-of-range one moves to a free slot), at most
    /// `ParametricEqualizer.maxBands`.
    static func sanitized(_ bands: [ParametricBand]) -> [ParametricBand] {
        var taken = Set<Int>()
        var kept: [ParametricBand] = []
        var homeless: [ParametricBand] = []
        for band in bands {
            if (0..<ParametricEqualizer.maxBands).contains(band.slot), taken.insert(band.slot).inserted {
                kept.append(band.clamped)
            } else {
                homeless.append(band.clamped)
            }
        }
        var free = (0..<ParametricEqualizer.maxBands).filter { !taken.contains($0) }.makeIterator()
        for var band in homeless {
            guard let slot = free.next() else { break }
            band.slot = slot
            kept.append(band)
        }
        return kept
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, mode, presetID, gains, customGains, preamp, bands, parametricPreamp, parametricName, clipGuard }

    /// Skips a band that does not decode rather than losing them all.
    private struct LossyBand: Decodable {
        let band: ParametricBand?
        init(from decoder: any Decoder) throws { band = try? ParametricBand(from: decoder) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EqualizerSettings()
        func curve(_ key: CodingKeys) -> [Double] {
            guard let values = try? c.decodeIfPresent([Double].self, forKey: key), values.count == EqualizerBands.count else { return d.gains }
            return values.map { Self.clamp($0, to: EqualizerBands.gainRange) }
        }
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        mode = (try? c.decodeIfPresent(EqualizerMode.self, forKey: .mode)) ?? d.mode
        presetID = (try? c.decodeIfPresent(String.self, forKey: .presetID)) ?? d.presetID
        gains = curve(.gains)
        customGains = curve(.customGains)
        preamp = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .preamp)) ?? d.preamp, to: EqualizerBands.preampRange)
        bands = Self.sanitized(((try? c.decodeIfPresent([LossyBand].self, forKey: .bands)) ?? []).compactMap(\.band))
        parametricPreamp = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .parametricPreamp)) ?? d.parametricPreamp, to: EqualizerBands.preampRange)
        parametricName = (try? c.decodeIfPresent(String.self, forKey: .parametricName)) ?? d.parametricName
        clipGuard = (try? c.decodeIfPresent(Bool.self, forKey: .clipGuard)) ?? d.clipGuard
        if presetID != EqualizerPreset.customID, EqualizerPreset.preset(id: presetID) == nil { presetID = EqualizerPreset.customID }
    }
}

struct Biquad: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = Biquad()

    static func peaking(frequency: Double, q: Double, gain: Double, sampleRate: Double) -> Biquad {
        make(.peak, frequency: frequency, q: q, gain: gain, sampleRate: sampleRate)
    }

    /// The Audio EQ Cookbook's filters, as Equalizer APO computes them (`gain` applies to the
    /// peak and the shelves). A frequency at or past Nyquist is taken just below it.
    static func make(_ filter: ParametricFilter, frequency: Double, q: Double, gain: Double, sampleRate: Double) -> Biquad {
        guard sampleRate > 0, frequency > 0, q > 0, !(filter.hasGain && gain == 0) else { return .identity }
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a = pow(10, gain / 40)
        let beta = 2 * a.squareRoot() * alpha
        let b0, b1, b2, a0, a1, a2: Double
        switch filter {
        case .peak:
            (b0, b1, b2) = (1 + alpha * a, -2 * cosw, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * cosw, 1 - alpha / a)
        case .lowShelf:
            (b0, b1, b2) = (a * ((a + 1) - (a - 1) * cosw + beta), 2 * a * ((a - 1) - (a + 1) * cosw), a * ((a + 1) - (a - 1) * cosw - beta))
            (a0, a1, a2) = ((a + 1) + (a - 1) * cosw + beta, -2 * ((a - 1) + (a + 1) * cosw), (a + 1) + (a - 1) * cosw - beta)
        case .highShelf:
            (b0, b1, b2) = (a * ((a + 1) + (a - 1) * cosw + beta), -2 * a * ((a - 1) + (a + 1) * cosw), a * ((a + 1) + (a - 1) * cosw - beta))
            (a0, a1, a2) = ((a + 1) - (a - 1) * cosw + beta, 2 * ((a - 1) - (a + 1) * cosw), (a + 1) - (a - 1) * cosw - beta)
        case .lowPass:
            (b0, b1, b2) = ((1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * cosw, 1 - alpha)
        case .highPass:
            (b0, b1, b2) = ((1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * cosw, 1 - alpha)
        case .bandPass:
            (b0, b1, b2) = (alpha, 0, -alpha)
            (a0, a1, a2) = (1 + alpha, -2 * cosw, 1 - alpha)
        case .notch:
            (b0, b1, b2) = (1, -2 * cosw, 1)
            (a0, a1, a2) = (1 + alpha, -2 * cosw, 1 - alpha)
        case .allPass:
            (b0, b1, b2) = (1 - alpha, -2 * cosw, 1 + alpha)
            (a0, a1, a2) = (1 + alpha, -2 * cosw, 1 - alpha)
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// `amount` of this filter mixed with the dry signal: still one biquad (the numerator
    /// moves towards the denominator), and the identity at 0.
    func blended(_ amount: Double) -> Biquad {
        let dry = 1 - amount
        return Biquad(b0: dry + amount * b0, b1: dry * a1 + amount * b1, b2: dry * a2 + amount * b2, a1: a1, a2: a2)
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
            add(Biquad.peaking(frequency: EqualizerBands.frequencies[band], q: EqualizerBands.q, gain: gain, sampleRate: sampleRate), to: &total)
        }
        return total
    }

    /// dB at every frequency with these parametric bands (those that are on).
    public func response(bands: [ParametricBand]) -> [Double] {
        var total = [Double](repeating: 0, count: frequencies.count)
        for band in bands where band.isAudible {
            add(Biquad.make(band.filter, frequency: band.frequency, q: band.q, gain: band.gain, sampleRate: sampleRate), to: &total)
        }
        return total
    }

    private func add(_ filter: Biquad, to total: inout [Double]) {
        guard filter != .identity else { return }
        for i in total.indices { total[i] += filter.decibels(cos1: cos1[i], cos2: cos2[i]) }
    }
}

/// What every item's equalizer follows. Written on the main thread, read at the start of each
/// audio block under an unfair lock (uncontended, fixed size, no allocation).
public final class EqualizerControl: Sendable {
    public struct State: Sendable, Equatable {
        public var enabled = false
        /// Each slot's filter (`ParametricFilter.code`, 0 for none), frequency (Hz), gain (dB)
        /// and Q. The ten bands take the first ten slots, as peaking filters at their solved
        /// gains (`EqualizerResponse.filterGains(for:)`).
        public var filters = SIMD16<UInt8>(repeating: 0)
        public var frequencies = SIMD16<Double>(repeating: 1000)
        public var gains = SIMD16<Double>(repeating: 0)
        public var qs = SIMD16<Double>(repeating: ParametricEqualizer.defaultQ)
        public var preamp: Double = 0
        public var clipGuard = true
        public init() {}

        public mutating func set(_ slot: Int, _ filter: ParametricFilter, frequency: Double, gain: Double, q: Double) {
            filters[slot] = filter.code
            frequencies[slot] = frequency
            gains[slot] = gain
            qs[slot] = q
        }
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
        switch settings.mode {
        case .graphic:
            for (band, gain) in EqualizerResponse.filterGains(for: settings.gains).enumerated() {
                state.set(band, .peak, frequency: EqualizerBands.frequencies[band], gain: gain, q: EqualizerBands.q)
            }
        case .parametric:
            for band in settings.bands where band.isOn && band.slot >= 0 && band.slot < ParametricEqualizer.maxBands {
                state.set(band.slot, band.filter, frequency: band.frequency, gain: band.gain, q: band.q)
            }
        }
        state.preamp = settings.activePreamp
        state.clipGuard = settings.clipGuard
        return state
    }
}
