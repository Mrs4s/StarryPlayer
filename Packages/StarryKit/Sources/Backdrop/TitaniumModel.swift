import CoreGraphics
import Foundation
import simd

// Ported from AMLL's TitaniumRenderer (AGPL-3.0):
// https://github.com/Steve-xmh/applemusic-like-lyrics

public enum TitaniumLook {
    public static let colorCount = 4
    public static let paletteTransition: Double = 1.4
    public static let colorCycleSeconds: Double = 8
    public static let flowCycleSeconds: Double = 4
    public static let flowLength: Double = 0.04
    public static let crestShiftY: Float = 0.12
    /// Reference height in points; grain size and flow speed stay constant across view sizes.
    public static let referenceHeight: Float = 900

    public static func grainScale(heightPoints: CGFloat) -> Float {
        max(Float(heightPoints), 1) / referenceHeight
    }

    public static let glintNoiseSize = 256

    static let glintNoise: [UInt8] = {
        var rng = SplitMix64(state: 0x676C_696E_7473)
        return (0..<glintNoiseSize * glintNoiseSize * 2).map { _ in UInt8(truncatingIfNeeded: rng.next() >> 56) }
    }()

    /// Peak EDR brightness, in multiples of SDR white.
    public static let glintPeakCap: Float = 3

    public static func glintPeak(headroom: Float) -> Float {
        min(max(headroom, 1), glintPeakCap)
    }

    /// Maximum default beat lift in linear light, as a fraction of SDR white.
    public static let beatLift: Float = 0.02

    /// Scrim easing time constant, in seconds.
    public static let lyricScrimTime: Double = 0.34

    public static let fineFlowSpeed: Double = 1.35
    /// Cell hash period, shared with the shader.
    public static let hashPeriod: Double = 256

    /// Low (40–100 Hz) and high (about 4 kHz+) levels from log-spaced 40 Hz–16 kHz bands.
    public static func levels(fromBands bands: [Float]) -> SIMD2<Float> {
        let n = bands.count
        guard n >= 8 else { return .zero }
        func average(_ range: Range<Int>) -> Float {
            range.isEmpty ? 0 : range.reduce(0) { $0 + bands[$1] } / Float(range.count)
        }
        return SIMD2(average(0..<max(1, n / 6)), average(n * 30 / 48..<n))
    }

    public static func flowCells(seconds: Double, scale: Double, speed: Double) -> Double {
        seconds * flowLength / flowCycleSeconds * scale * 256 * speed
    }

    /// Wrap in Double before converting to Float to preserve precision during long playback.
    public static func wrappedShift(_ shift: SIMD2<Double>) -> SIMD2<Float> {
        let wrapped = shift - hashPeriod * (shift / hashPeriod).rounded(.down)
        return SIMD2<Float>(simd_clamp(wrapped, .zero, SIMD2(repeating: hashPeriod.nextDown)))
    }

    /// A single tangent avoids shearing the grains over time.
    public static func flowTangent(seed: SIMD3<Float>) -> SIMD2<Double> {
        let centreSlope = -0.45 * 1.6 * cos(Double(seed.x)) - 0.10 * 3.4 * cos(Double(seed.y))
        return simd_normalize(SIMD2(1, -centreSlope))
    }

    public static func light(phase: Float) -> (direction: SIMD3<Float>, half: SIMD3<Float>) {
        let direction = simd_normalize(SIMD3<Float>(0.18 + 0.3 * sin(phase), 0.8, 0.55))
        return (direction, simd_normalize(direction + SIMD3(0, 0, 1)))
    }

    public static let gridRows = 40

    public static func gridColumns(aspect: Float) -> Int {
        min(256, max(4, Int((Float(gridRows) * aspect).rounded(.up))))
    }

    public static func gain(blackScrim: Float, brightness: Float) -> Float {
        let scrim = min(max(blackScrim, 0), 0.95)
        return min(2, (1 - scrim) / (1 - BackdropLook.blackScrimDark)) * max(brightness, 0)
    }
}

/// Detects attacks relative to a frequency band's recent average.
public struct BandPulse: Sendable, Equatable {
    public var baselineTime: Double
    public var attack: Double
    public var release: Double
    public var floor: Float
    public var ceiling: Float
    /// Peak spacing in seconds, used to limit flash frequency.
    public var minInterval: Double
    /// Maximum pulse rise time, in seconds.
    public var attackWindow: Double
    public private(set) var baseline: Float = 0
    public internal(set) var value: Float = 0
    public private(set) var rising = false
    public private(set) var sinceOnset: Double = .infinity
    public private(set) var sincePeak: Double = .infinity

    public static let kick = BandPulse(baselineTime: 0.4, attack: 0.07, release: 0.3, floor: 0.03, ceiling: 0.14, minInterval: 0.55)
    public static let shimmer = BandPulse(baselineTime: 0.4, attack: 0.05, release: 0.25, floor: 0.02, ceiling: 0.10, minInterval: 0.55)

    public init(baselineTime: Double, attack: Double, release: Double, floor: Float, ceiling: Float,
                minInterval: Double = 0, attackWindow: Double = 0.15) {
        self.baselineTime = baselineTime
        self.attack = attack
        self.release = release
        self.floor = floor
        self.ceiling = ceiling
        self.minInterval = minInterval
        self.attackWindow = attackWindow
    }

    /// Silence preserves the baseline so resuming playback does not create a false attack.
    public mutating func update(level: Float, dt: Double) {
        guard dt > 0 else { return }
        if level > 0, baseline == 0 { baseline = level }
        let excess = max(0, level - baseline)
        let t = min(max((excess - floor) / (ceiling - floor), 0), 1)
        var target = t * t * (3 - 2 * t)
        sinceOnset += dt
        sincePeak += dt
        if rising, target <= value || sinceOnset > attackWindow {
            rising = false
            sincePeak = 0
        } else if !rising, target > value, sincePeak >= minInterval {
            rising = true
            sinceOnset = 0
        }
        if !rising, sincePeak < minInterval { target = min(target, 0) }
        if !rising { target = min(target, value) }
        let time = target > value ? attack : release
        value += (target - value) * Float(1 - exp(-dt / time))
        if level > 0 { baseline += (level - baseline) * Float(1 - exp(-dt / baselineTime)) }
    }
}

public struct TitaniumOptions: Sendable, Equatable {
    public var grain: Float = 0.7
    public var sparkle: Float = 0.75
    public var sheen: Float = 0.5
    public var metalness: Float = 0.35
    /// Crest transition duration in seconds; zero changes the pose immediately.
    public var crestShift: Double = 2
    public var softGlints = true
    public var highDynamicRange = true

    public init() {}
}

struct TitaniumState: Sendable, Equatable {
    var seed: SIMD3<Float>
    var grainOffset: SIMD2<Float>

    var colorTime: Double = 0
    var flowTime: Double = 0

    var levels = SIMD2<Float>(repeating: 0)
    var kick = BandPulse.kick
    var shimmer = BandPulse.shimmer
    var reactivity: Float = 1
    var lyricScrim: Float = 0
    var lyricScrimTarget: Float = 0
    var textCalm: Float = 0
    var textCalmTarget: Float = 0

    private(set) var fromColors: [SIMD3<Float>]
    private(set) var toColors: [SIMD3<Float>]
    private(set) var paletteElapsed = TitaniumLook.paletteTransition

    /// Crest phases in radians (xy) and vertical offset in screen heights (z).
    private(set) var crest = SIMD3<Float>(repeating: 0)
    private var crestFrom = SIMD3<Float>(repeating: 0)
    private var crestTo = SIMD3<Float>(repeating: 0)
    private(set) var crestElapsed: Double = 0
    var crestDuration: Double = TitaniumOptions().crestShift {
        didSet { if crestElapsed >= oldValue { crestElapsed = max(crestElapsed, crestDuration) } }
    }

    init(seed: UInt64, colors: [SIMD3<Float>]) {
        var rng = SplitMix64(state: seed)
        let tau = 2 * Float.pi
        self.seed = SIMD3(rng.unit() * tau, rng.unit() * tau, rng.unit() * tau)
        grainOffset = SIMD2(rng.unit(), rng.unit())
        let start = Self.normalised(colors)
        fromColors = start
        toColors = start
        crestElapsed = crestDuration
    }

    static func normalised(_ colors: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard !colors.isEmpty else { return Array(repeating: SIMD3(0.2, 0, 0), count: TitaniumLook.colorCount) }
        return (0..<TitaniumLook.colorCount).map { colors[$0 % colors.count] }
    }

    var colors: [SIMD3<Float>] {
        guard paletteElapsed < TitaniumLook.paletteTransition else { return toColors }
        let progress = Float(paletteElapsed / TitaniumLook.paletteTransition)
        let eased = 0.5 - 0.5 * cos(Float.pi * progress)
        return zip(fromColors, toColors).map { simd_mix($0, $1, SIMD3(repeating: eased)) }
    }

    var targetColors: [SIMD3<Float>] { toColors }

    mutating func setColors(_ next: [SIMD3<Float>], immediate: Bool) {
        let next = Self.normalised(next)
        fromColors = immediate ? next : colors
        toColors = next
        paletteElapsed = immediate ? TitaniumLook.paletteTransition : 0
    }

    mutating func shiftCrest(seed: UInt64, immediate: Bool) {
        settleCrest()
        crestFrom = crest
        var rng = SplitMix64(state: seed)
        let tau = 2 * Float.pi
        for i in 0..<2 {
            let sweep = (0.25 + rng.unit() * 0.6) * tau
            crestTo[i] = crest[i] + (rng.unit() < 0.5 ? -sweep : sweep)
        }
        crestTo.z = (rng.unit() - 0.5) * 2 * TitaniumLook.crestShiftY
        crestElapsed = 0
        if immediate { crestElapsed = crestDuration }
        settleCrest()
    }

    private mutating func settleCrest() {
        guard crestDuration > 0, crestElapsed < crestDuration else {
            crest = crestTo
            let tau = 2 * Float.pi
            for i in 0..<2 where crest[i] < 0 || crest[i] >= tau {
                crest[i] = (crest[i].truncatingRemainder(dividingBy: tau) + tau).truncatingRemainder(dividingBy: tau)
            }
            crestTo = crest
            crestFrom = crest
            return
        }
        let t = Float(crestElapsed / crestDuration)
        let eased = t * t * t * (t * (t * 6 - 15) + 10)
        crest = simd_mix(crestFrom, crestTo, SIMD3(repeating: eased))
    }

    /// Caps elapsed time to avoid a jump when returning from the background.
    mutating func advance(dt: Double, speed: Double) {
        let dt = min(max(dt, 0), 0.25)
        colorTime += dt * speed
        kick.update(level: levels.x, dt: dt)
        shimmer.update(level: levels.y, dt: dt)
        flowTime += dt * speed
        let scrimStep = Float(1 - exp(-dt / TitaniumLook.lyricScrimTime))
        lyricScrim += (lyricScrimTarget - lyricScrim) * scrimStep
        textCalm += (textCalmTarget - textCalm) * scrimStep
        if paletteElapsed < TitaniumLook.paletteTransition { paletteElapsed += dt }
        if crestElapsed < crestDuration { crestElapsed += dt }
        settleCrest()
    }

    var colorPhase: Float {
        Float((colorTime / TitaniumLook.colorCycleSeconds).truncatingRemainder(dividingBy: 1))
    }

    var isSettled: Bool {
        paletteElapsed >= TitaniumLook.paletteTransition && crestElapsed >= crestDuration
            && abs(lyricScrimTarget - lyricScrim) < 0.001 && abs(textCalmTarget - textCalm) < 0.001
    }

    var pulse: Float { reactivity > 0 ? min(1, kick.value) : 0 }

    var beatLift: Float { TitaniumLook.beatLift * min(max(reactivity, 0), 2) }

    var burst: Float { min(1, 0.7 * shimmer.value + 0.5 * kick.value) * min(max(reactivity, 0), 1) }

    var canHold: Bool {
        isSettled && kick.value < 0.001 && shimmer.value < 0.001
    }
}
