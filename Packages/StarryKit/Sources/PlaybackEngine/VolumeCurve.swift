import Foundation

/// Volume slider position → `AVPlayer.volume`. The player's volume is a linear amplitude factor,
/// so a linear slider spends its whole top half within −6 dB. A cubic taper (the curve PulseAudio
/// uses for software volume) spreads loudness over the travel: 50 % ≈ −18 dB, 20 % ≈ −42 dB.
public enum VolumeCurve {
    public static func gain(forLevel level: Double) -> Float {
        let level = min(max(level, 0), 1)
        return Float(level * level * level)
    }
}
