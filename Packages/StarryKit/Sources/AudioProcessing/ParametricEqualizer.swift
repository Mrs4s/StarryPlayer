import Foundation

public enum EqualizerMode: String, Codable, Sendable {
    /// Ten fixed bands whose sliders the curve passes through (`EqualizerResponse.filterGains(for:)`).
    case graphic
    /// Up to `ParametricEqualizer.maxBands` filters of any type, frequency and width.
    case parametric
}

/// A parametric band's filter, from the Audio EQ Cookbook (Robert Bristow-Johnson) as Equalizer
/// APO and AutoEQ compute it, so their settings sound the same here.
public enum ParametricFilter: String, Codable, Sendable, CaseIterable {
    case peak, lowShelf, highShelf, lowPass, highPass, bandPass, notch, allPass

    /// Whether `gain` applies; the others pass, cut or shift phase by their type alone.
    public var hasGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: true
        case .lowPass, .highPass, .bandPass, .notch, .allPass: false
        }
    }

    public var name: String {
        switch self {
        case .peak: "峰值"
        case .lowShelf: "低架"
        case .highShelf: "高架"
        case .lowPass: "低通"
        case .highPass: "高通"
        case .bandPass: "带通"
        case .notch: "陷波"
        case .allPass: "全通"
        }
    }

    /// Its lane value in `EqualizerControl.State`, 0 being no filter. A switch rather than an
    /// array lookup: the audio thread reads it.
    var code: UInt8 {
        switch self {
        case .peak: 1
        case .lowShelf: 2
        case .highShelf: 3
        case .lowPass: 4
        case .highPass: 5
        case .bandPass: 6
        case .notch: 7
        case .allPass: 8
        }
    }

    init?(code: UInt8) {
        switch code {
        case 1: self = .peak
        case 2: self = .lowShelf
        case 3: self = .highShelf
        case 4: self = .lowPass
        case 5: self = .highPass
        case 6: self = .bandPass
        case 7: self = .notch
        case 8: self = .allPass
        default: return nil
        }
    }
}

public struct ParametricBand: Codable, Sendable, Equatable, Identifiable {
    /// Where the processor keeps this band's filter, for the band's life: removing or editing
    /// others never hands its filter state to another band. Filters in series commute, so the
    /// order of the bands does not matter.
    public var slot: Int
    public var isOn: Bool
    public var filter: ParametricFilter
    /// Centre frequency (corner for the passes), Hz.
    public var frequency: Double
    /// dB, used when `filter.hasGain`.
    public var gain: Double
    public var q: Double

    public var id: Int { slot }

    public init(slot: Int, filter: ParametricFilter = .peak, frequency: Double, gain: Double = 0, q: Double = ParametricEqualizer.defaultQ, isOn: Bool = true) {
        self.slot = slot
        self.isOn = isOn
        self.filter = filter
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }

    /// Whether it changes the sound.
    public var isAudible: Bool { isOn && (!filter.hasGain || gain != 0) }

    /// Within the parametric ranges (non-finite values become the defaults).
    public var clamped: ParametricBand {
        var band = self
        band.frequency = ParametricEqualizer.clamp(frequency, to: ParametricEqualizer.frequencyRange, otherwise: 1000)
        band.gain = ParametricEqualizer.clamp(gain, to: ParametricEqualizer.gainRange, otherwise: 0)
        band.q = ParametricEqualizer.clamp(q, to: ParametricEqualizer.qRange, otherwise: ParametricEqualizer.defaultQ)
        return band
    }

    private enum CodingKeys: String, CodingKey { case slot, isOn, filter, frequency, gain, q }

    /// Throws on an unknown filter or a missing slot; other missing values take the defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(Int.self, forKey: .slot)
        filter = try c.decode(ParametricFilter.self, forKey: .filter)
        isOn = (try? c.decodeIfPresent(Bool.self, forKey: .isOn)) ?? true
        frequency = (try? c.decodeIfPresent(Double.self, forKey: .frequency)) ?? 1000
        gain = (try? c.decodeIfPresent(Double.self, forKey: .gain)) ?? 0
        q = (try? c.decodeIfPresent(Double.self, forKey: .q)) ?? ParametricEqualizer.defaultQ
        self = clamped
    }
}

public enum ParametricEqualizer {
    public static let maxBands = 16
    /// What a band may have (imported settings go below and above what the graph shows).
    public static let frequencyRange: ClosedRange<Double> = 10...22000
    /// The graph's axis, which dragging stays within.
    public static let displayRange: ClosedRange<Double> = 20...20000
    /// Wide enough for the ten-band curve's solved filter gains (`EqualizerBands.filterGainLimit`),
    /// so switching to parametric keeps its sound.
    public static let gainRange: ClosedRange<Double> = -24...24
    public static let qRange: ClosedRange<Double> = 0.1...40
    public static let defaultQ = 1.0

    static func clamp(_ value: Double, to range: ClosedRange<Double>, otherwise fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Three significant figures (0.1 Hz below 100 Hz, 10 Hz above 1 kHz), as a drag sets it.
    public static func rounded(frequency: Double) -> Double {
        let step = frequency < 100 ? 0.1 : (frequency < 1000 ? 1 : (frequency < 10000 ? 10 : 100))
        return (frequency / step).rounded() * step
    }

    // MARK: Text

    /// "62.5 Hz", "2153 Hz", "12.5 kHz".
    public static func frequencyText(_ frequency: Double) -> String {
        if frequency >= 10000 { return trimmed(frequency / 1000, decimals: 2) + " kHz" }
        return trimmed(frequency, decimals: frequency < 100 ? 1 : 0) + " Hz"
    }

    /// "+2.6 dB", "0 dB".
    public static func gainText(_ gain: Double) -> String {
        let value = (gain * 10).rounded() / 10
        return value == 0 ? "0 dB" : String(format: "%+.1f dB", value)
    }

    /// "0.70", "0.707", "12.00".
    public static func qText(_ q: Double) -> String {
        var text = String(format: "%.3f", q)
        if text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// The number in `value` with at most `decimals` places and no trailing zeros.
    static func trimmed(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Hz from what was typed: "1000", "1k", "1.2 kHz", "62.5hz", full-width characters as well.
    public static func frequency(from text: String) -> Double? {
        var number = normalized(text)
        for unit in ["khz", "千赫兹", "千赫", "hz", "赫兹", "赫"] where number.hasSuffix(unit) {
            number.removeLast(unit.count)
            if unit.hasPrefix("k") || unit.hasPrefix("千") { number += "k" }
            break
        }
        var scale = 1.0
        if number.hasSuffix("k") || number.hasSuffix("千") {
            number.removeLast()
            scale = 1000
        }
        guard let value = Double(number), value.isFinite, value > 0 else { return nil }
        return value * scale
    }

    /// dB from what was typed: "+3", "-2.5", "3db".
    public static func gain(from text: String) -> Double? {
        var number = normalized(text)
        for unit in ["db", "分贝"] where number.hasSuffix(unit) {
            number.removeLast(unit.count)
            break
        }
        if number.hasPrefix("+") { number.removeFirst() }
        guard let value = Double(number), value.isFinite else { return nil }
        return value
    }

    /// Q from what was typed: "0.7", "q 1.41".
    public static func q(from text: String) -> Double? {
        var number = normalized(text)
        if number.hasPrefix("q") { number.removeFirst() }
        guard let value = Double(number), value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func normalized(_ text: String) -> String {
        // `。` first: the transform turns it into a half-width `｡`, not a full stop.
        let text = text.replacingOccurrences(of: "。", with: ".")
        return (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
