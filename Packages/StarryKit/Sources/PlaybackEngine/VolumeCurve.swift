import Foundation

/// Map slider position to linear amplitude with a cubic taper:
/// 50% is about −18 dB and 20% about −42 dB.
public enum VolumeCurve {
    public static func gain(forLevel level: Double) -> Float {
        let level = min(max(level, 0), 1)
        return Float(level * level * level)
    }
}
