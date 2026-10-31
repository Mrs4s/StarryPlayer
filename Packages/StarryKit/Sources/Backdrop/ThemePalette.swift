import CoreGraphics
import Foundation
import simd

/// Extracts cover colours using weighted k-means in OkLab.
public enum ThemePalette {
    public static let sampleSide = 48
    static let iterations = 24

    /// OkLab colours, ordered by cluster weight; empty if the image cannot be drawn.
    public static func extract(from image: CGImage, count: Int = 4) -> [SIMD3<Float>] {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return palette(rgba: pixels, count: count)
    }

    /// Input pixels are premultiplied RGBA8.
    static func palette(rgba: [UInt8], count: Int) -> [SIMD3<Float>] {
        var buckets: [UInt16: (weight: Float, sum: SIMD3<Float>)] = [:]
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            let alpha = rgba[i + 3]
            guard alpha >= 128 else { continue }
            let rgb = simd_clamp(SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / Float(alpha), .zero, SIMD3(repeating: 1))
            let q = SIMD3<UInt16>(UInt16(rgb.x * 31.99), UInt16(rgb.y * 31.99), UInt16(rgb.z * 31.99))
            let key = q.x << 10 | q.y << 5 | q.z
            var bucket = buckets[key] ?? (0, .zero)
            bucket.weight += 1
            bucket.sum += rgb
            buckets[key] = bucket
        }
        // Stable ordering keeps seeded clustering deterministic across launches.
        let entries = buckets.sorted { $0.key < $1.key }
        let points = entries.map { srgbToOkLab($0.value.sum / $0.value.weight) }
        let weights = entries.map(\.value.weight)
        var seed: UInt64 = 14695981039346656037
        for entry in entries {
            seed = (seed ^ UInt64(entry.key)) &* 1099511628211
            seed = (seed ^ UInt64(entry.value.weight)) &* 1099511628211
        }
        return cluster(points, weights: weights, count: count, seed: seed)
    }

    static func cluster(_ points: [SIMD3<Float>], weights: [Float], count: Int, seed: UInt64) -> [SIMD3<Float>] {
        guard count > 0, !points.isEmpty, points.count == weights.count else { return [] }
        var rng = SplitMix64(state: seed)
        let heaviest = weights.indices.max { weights[$0] < weights[$1] } ?? 0
        var centres = [points[heaviest]]
        var nearest = points.map { simd_distance_squared($0, centres[0]) }
        while centres.count < count {
            var total: Float = 0
            for k in points.indices { total += nearest[k] * weights[k] }
            guard total > 0 else { break }
            var target = rng.unit() * total
            var pick = points.count - 1
            for k in points.indices {
                target -= nearest[k] * weights[k]
                if target <= 0 { pick = k; break }
            }
            centres.append(points[pick])
            for k in points.indices { nearest[k] = min(nearest[k], simd_distance_squared(points[k], points[pick])) }
        }

        var assignment = [Int](repeating: -1, count: points.count)
        var mass = [Float](repeating: 0, count: centres.count)
        for _ in 0..<iterations {
            var changed = false
            var sums = [SIMD3<Float>](repeating: .zero, count: centres.count)
            mass = [Float](repeating: 0, count: centres.count)
            for k in points.indices {
                var best = 0, bestDistance = Float.infinity
                for (c, centre) in centres.enumerated() {
                    let d = simd_distance_squared(points[k], centre)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                if assignment[k] != best { assignment[k] = best; changed = true }
                sums[best] += points[k] * weights[k]
                mass[best] += weights[k]
            }
            for c in centres.indices where mass[c] > 0 { centres[c] = sums[c] / mass[c] }
            if !changed { break }
        }
        let ordered = centres.indices.sorted { mass[$0] != mass[$1] ? mass[$0] > mass[$1] : $0 < $1 }.map { centres[$0] }
        return (0..<count).map { ordered[$0 % ordered.count] }
    }

    /// Matches OkLab colours to existing gradient corners to avoid reshuffling on cover resize.
    public static func matched(_ next: [SIMD3<Float>], to current: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard next.count == current.count, next.count <= 6 else { return next }
        var best = next, bestCost = Float.infinity
        func permute(_ items: [SIMD3<Float>], _ prefix: [SIMD3<Float>]) {
            if items.isEmpty {
                let cost = zip(prefix, current).reduce(0) { $0 + simd_distance_squared($1.0, $1.1) }
                if cost < bestCost { bestCost = cost; best = prefix }
                return
            }
            for i in items.indices {
                var rest = items
                let item = rest.remove(at: i)
                permute(rest, prefix + [item])
            }
        }
        permute(next, [])
        return best
    }

    // MARK: OkLab

    static func linear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ c: Float) -> Float {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
    }

    /// Gamma-encoded sRGB (0...1) to OkLab.
    public static func srgbToOkLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let r = linear(c.x), g = linear(c.y), b = linear(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// OkLab to gamma-encoded sRGB; output is not clamped.
    public static func okLabToSrgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z
        let m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z
        let s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return SIMD3(
            encoded(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            encoded(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            encoded(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
        )
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}
