import Foundation
import simd

/// Spectrum intensity: subdued = 0.2, exciting = 1.0.
public enum BackdropIntensity: Sendable, Equatable {
    case subdued
    case exciting

    public var power: Float { self == .exciting ? 1.0 : 0.2 }
}

public enum BackdropLook {
    public static func saturation(landscape: Bool, intensity: BackdropIntensity) -> Float {
        switch (landscape, intensity) {
        case (true, .exciting): 2.4
        case (true, .subdued): 2.9
        case (false, .exciting): 2.0
        case (false, .subdued): 2.4
        }
    }

    public static func blurRadius(landscape: Bool, intensity: BackdropIntensity) -> Float {
        switch (landscape, intensity) {
        case (true, .exciting): 120
        case (true, .subdued): 200
        case (false, .exciting): 85
        case (false, .subdued): 160
        }
    }

    public static let blurDownsample = 4
    public static let blackScrimDark: Float = 0.5
    public static let instanceScrimStep: Float = 0.0075
    public static let whiteScrim: Float = 0.1
    public static let warpPeriodDivisor: Float = 3.5
    public static let transitionDuration: Float = 0.8
    /// Blur radius moves 1 pt per frame at the 60 Hz reference clock.
    public static let blurRadiusPointsPerSecond: Float = 60

    /// Rotating artwork copies: base matrix (square space normalised to the longer side), parent
    /// instance whose rotation is inherited, and rotation period in seconds.
    public struct Model: Sendable, Equatable {
        public var matrix: float4x4
        public var parent: Int?
        public var period: Float
    }

    public static let models: [Model] = [
        Model(matrix: float4x4(diagonal: SIMD4(1.4, 1.4, 1, 1)), parent: nil, period: 120),
        Model(matrix: translation(-0.25, 0.15) * float4x4(diagonal: SIMD4(0.7, 0.7, 1, 1)), parent: nil, period: 70),
        Model(matrix: translation(0.7, 0.7) * float4x4(diagonal: SIMD4(0.7, 0.7, 1, 1)), parent: 0, period: 90),
    ]

    static func translation(_ x: Float, _ y: Float) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, y, 0, 1)
        return m
    }

    static func rotation(_ angle: Float) -> float4x4 {
        let c = cos(angle), s = sin(angle)
        return float4x4(columns: (SIMD4(c, -s, 0, 0), SIMD4(s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }

    public static func viewMatrix(aspect: Float) -> float4x4 {
        aspect >= 1 ? float4x4(diagonal: SIMD4(1, aspect, 1, 1)) : float4x4(diagonal: SIMD4(1 / aspect, 1, 1, 1))
    }

    /// Spectrum zoom `1 + mix(p.x, p.y, 0.1)² × 0.33`.
    public static func spectrumScale(power p: SIMD4<Float>) -> Float {
        let m = p.x + (p.y - p.x) * 0.1
        return 1 + m * m * 0.33
    }

    public static func instanceMatrix(index: Int, time: Float, aspect: Float, power: SIMD4<Float>) -> float4x4 {
        let model = models[index]
        let angle = 2 * Float.pi * time
        let s = spectrumScale(power: power)
        var m = float4x4(diagonal: SIMD4(s, s, 1, 1)) * viewMatrix(aspect: aspect)
        if let parent = model.parent {
            m = m * rotation(angle / models[parent].period)
        }
        return m * model.matrix * rotation(angle / model.period)
    }
}

/// Spectrum power: per-lane decay with peak hold, half-way smoothing, then
/// smootherstep. Lanes: x drives contrast/zoom, y is mixed 10 % into the zoom, z drives
/// saturation. Decay constants are per frame at 60 Hz (50, 100, 1000, instant).
public struct SpectrumPower: Sendable, Equatable {
    public private(set) var levels = SIMD4<Float>(repeating: 0)
    public private(set) var smoothed = SIMD4<Float>(repeating: 0)

    public init() {}

    public mutating func update(input: SIMD4<Float>, dt: Float) {
        let frames = max(0, dt) * 60
        let decay = SIMD4<Float>(pow(1 - 1 / 50, frames), pow(1 - 1 / 100, frames), pow(1 - 1 / 1000, frames), 0)
        let clamped = simd_clamp(input, SIMD4(repeating: 0), SIMD4(repeating: 1))
        levels = simd_max(levels * decay, clamped)
        let k = 1 - pow(0.5, frames)
        smoothed += (levels - smoothed) * k
    }

    public mutating func reset() {
        levels = .zero
        smoothed = .zero
    }

    public func power(intensity: Float) -> SIMD4<Float> {
        let x = simd_clamp(smoothed * intensity, SIMD4(repeating: 0), SIMD4(repeating: 1))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

public struct CubicBezier: Sendable, Equatable {
    public var p1: SIMD2<Float>
    public var p2: SIMD2<Float>

    public init(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        p1 = SIMD2(x1, y1)
        p2 = SIMD2(x2, y2)
    }

    public static let easeOut = CubicBezier(0, 0, 0.3, 1)
    public static let easeInOut = CubicBezier(0.42, 0, 0.58, 1)

    private func bezier(_ t: Float, _ a: Float, _ b: Float) -> Float {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    public func solve(_ x: Float) -> Float {
        let x = min(1, max(0, x))
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let cx = bezier(t, p1.x, p2.x) - x
            let u = 1 - t
            let dx = 3 * u * u * p1.x + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (1 - p2.x)
            if abs(cx) < 1e-5 || dx == 0 { break }
            t -= cx / dx
            t = min(1, max(0, t))
        }
        return bezier(t, p1.y, p2.y)
    }
}

/// Pinch mesh from landscape or portrait control grids. Two Catmull-Clark
/// subdivisions keep the warped surface smooth and unfolded.
public enum PinchMesh {
    public struct Vertex: Sendable, Equatable {
        public var uv: SIMD2<Float>
        public var from: SIMD2<Float>
        public var to: SIMD2<Float>
    }

    public static let subdivisionLevels = 2
    public static let pairCount = 5

    public static func pairIndex(seed: UInt64) -> Int {
        Int(seed % UInt64(pairCount))
    }

    /// Cap strength at 1: the control grids are already at the fold limit.
    public static func make(landscape: Bool, seed: UInt64, strength: Float = 1) -> (vertices: [Vertex], indices: [UInt16]) {
        let pair = (landscape ? landscapeGridData : portraitGridData)[pairIndex(seed: seed)]
        let cells = landscape ? 8 : 5
        let s = min(1, max(0, strength))
        func controlPoints(_ data: [Float]) -> [SIMD2<Float>] {
            (0..<(cells + 1) * (cells + 1)).map { k in
                let flat = SIMD2(Float(k % (cells + 1)), Float(k / (cells + 1))) / Float(cells)
                let p = SIMD2(data[2 * k], data[2 * k + 1])
                return (flat + (p - flat) * s) * 2 - 1
            }
        }
        var from = controlPoints(pair.from), to = controlPoints(pair.to)
        var n = cells
        for _ in 0..<subdivisionLevels {
            from = subdivide(from, cells: n)
            to = subdivide(to, cells: n)
            n *= 2
        }
        precondition((n + 1) * (n + 1) < 65536)
        let width = n + 1
        var vertices: [Vertex] = []
        vertices.reserveCapacity(width * width)
        for k in 0..<width * width {
            let uv = SIMD2(Float(k % width), Float(k / width)) / Float(n)
            vertices.append(Vertex(uv: uv, from: from[k], to: to[k]))
        }
        var indices: [UInt16] = []
        indices.reserveCapacity(n * n * 6)
        for j in 0..<n {
            for i in 0..<n {
                let a = UInt16(j * width + i), b = a + 1
                let d = a + UInt16(width), c = d + 1
                indices += [a, c, d, a, b, c]
            }
        }
        return (vertices, indices)
    }

    static func subdivide(_ p: [SIMD2<Float>], cells n: Int) -> [SIMD2<Float>] {
        let w = 2 * n + 1
        func point(_ i: Int, _ j: Int) -> SIMD2<Float> { p[j * (n + 1) + i] }
        func face(_ i: Int, _ j: Int) -> SIMD2<Float> {
            (point(i, j) + point(i + 1, j) + point(i, j + 1) + point(i + 1, j + 1)) / 4
        }
        var q = [SIMD2<Float>](repeating: .zero, count: w * w)
        for j in 0..<n {
            for i in 0..<n {
                q[(2 * j + 1) * w + 2 * i + 1] = face(i, j)
            }
        }
        for j in 0...n {
            for i in 0..<n {
                let ends = point(i, j) + point(i + 1, j)
                q[2 * j * w + 2 * i + 1] = j == 0 || j == n ? ends / 2 : (ends + face(i, j - 1) + face(i, j)) / 4
            }
        }
        for j in 0..<n {
            for i in 0...n {
                let ends = point(i, j) + point(i, j + 1)
                q[(2 * j + 1) * w + 2 * i] = i == 0 || i == n ? ends / 2 : (ends + face(i - 1, j) + face(i, j)) / 4
            }
        }
        for j in 0...n {
            for i in 0...n {
                let v = point(i, j)
                let result: SIMD2<Float>
                switch (j == 0 || j == n, i == 0 || i == n) {
                case (true, true):
                    result = v
                case (true, false):
                    result = (point(i - 1, j) + 6 * v + point(i + 1, j)) / 8
                case (false, true):
                    result = (point(i, j - 1) + 6 * v + point(i, j + 1)) / 8
                case (false, false):
                    let faces = (face(i - 1, j - 1) + face(i, j - 1) + face(i - 1, j) + face(i, j)) / 4
                    let neighbours = (point(i - 1, j) + point(i + 1, j) + point(i, j - 1) + point(i, j + 1)) / 4
                    result = (faces + neighbours + 2 * v) / 4
                }
                q[2 * j * w + 2 * i] = result
            }
        }
        return q
    }

    public static func seed(from string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return hash
    }
}

/// Closed-form approximation of `BackdropLUT`; keep in sync with the shader's `grade`.
public enum BackdropGrade {
    public struct Window: Sendable {
        public var centre: Float
        public var halfWidth: Float
        public var value: Float
        public var saturation: Float
    }

    public static let red = Window(centre: 0, halfWidth: 56, value: 0.336, saturation: 0.473)
    public static let blue = Window(centre: 241, halfWidth: 57, value: 0.312, saturation: 0.397)
    public static let saturationSlope: Float = 0.828

    public static func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let chroma = mx - mn
        guard chroma > 1e-4, mx > 1e-4 else { return c }
        let s = chroma / mx
        var h: Float
        if mx == c.x { h = ((c.y - c.z) / chroma).truncatingRemainder(dividingBy: 6); if h < 0 { h += 6 } }
        else if mx == c.y { h = (c.z - c.x) / chroma + 2 }
        else { h = (c.x - c.y) / chroma + 4 }
        h *= 60
        let wr = weight(h, red), wb = weight(h, blue)
        let value = mx * (1 - s * (red.value * wr + blue.value * wb))
        let saturation = s * (1 - (1 - saturationSlope * s) * (red.saturation * wr + blue.saturation * wb))
        let t = (c - SIMD3(repeating: mn)) / chroma
        return value * (SIMD3(repeating: 1) - saturation * (SIMD3(repeating: 1) - t))
    }

    static func weight(_ h: Float, _ window: Window) -> Float {
        var d = abs(h - window.centre).truncatingRemainder(dividingBy: 360)
        d = min(d, 360 - d)
        guard d < window.halfWidth else { return 0 }
        return 0.5 * (1 + cos(Float.pi * d / window.halfWidth))
    }
}
