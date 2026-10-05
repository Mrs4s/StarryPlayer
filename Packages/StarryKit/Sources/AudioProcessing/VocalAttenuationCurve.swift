import Foundation

public enum VocalAttenuationCurve {
    public static let sliderRange: ClosedRange<Double> = 5...100
    public static let defaultLevel: Double = 15
    public static let minimumGain = sliderRange.lowerBound / 100

    public static func clamp(_ level: Double) -> Double {
        min(max(level, sliderRange.lowerBound), sliderRange.upperBound)
    }

    /// Voice heard at a slider value, in dB relative to the original voice.
    public static func heardDecibels(forSlider value: Double, residual: VocalResidual?) -> Double {
        let t = (clamp(value) - sliderRange.lowerBound) / (sliderRange.upperBound - sliderRange.lowerBound)
        let floor = 10 * log10((residual ?? .perfect).heardPower(gain: minimumGain))
        return floor * (1 - t)
    }

    public static func gain(forSlider value: Double, residual: VocalResidual?) -> Double {
        let gain = (residual ?? .perfect).gain(heardPower: pow(10, heardDecibels(forSlider: value, residual: residual) / 10))
        return min(max(gain, minimumGain), 1)
    }

    /// WetDry runs from −100 to 100 despite the documented 0…100 range.
    /// Use 100 × (1 − g) for accompaniment models, −100 × (1 − g) for voice isolation.
    public static func wetDryPercent(voiceGain g: Double, isolates kind: VocalSeparationModel.Output) -> Float {
        let amount = 100 * (1 - min(max(g, 0), 1))
        return Float(kind == .accompaniment ? amount : -amount)
    }
}

/// Measured separation residual: voice power is
/// `g² + 2ρ·g(1 − g) + λ·(1 − g)²`, with λ = `power` and ρ = `correlation`.
public struct VocalResidual: Sendable, Equatable {
    public var power: Double
    public var correlation: Double

    /// ρ is kept within [λ, √λ]: √λ is its bound for any measurement, and below λ the heard voice
    /// would not grow with the gain.
    public init(decibels: Double, correlation: Double) {
        let power = min(max(pow(10, decibels / 10), 0), 0.99)
        self.power = power
        self.correlation = min(max(correlation, power), power.squareRoot())
    }

    public static let perfect = VocalResidual(decibels: -.infinity, correlation: 0)

    public static let systemVoice = VocalResidual(decibels: -10.0, correlation: 0.19)

    public func heardPower(gain g: Double) -> Double {
        g * g + 2 * correlation * g * (1 - g) + power * (1 - g) * (1 - g)
    }

    /// The gain in 0…1 at which `heardPower` is `target` (the root of the quadratic; the power
    /// rises with the gain from λ to 1).
    public func gain(heardPower target: Double) -> Double {
        let a = 1 - 2 * correlation + power
        let b = 2 * (correlation - power)
        let c = power - target
        let root = (-b + max(b * b - 4 * a * c, 0).squareRoot()) / (2 * a)
        return min(max(root, 0), 1)
    }
}
