import CoreGraphics
import Foundation

public struct CoverPalette: Sendable, Hashable {
    public struct RGB: Sendable, Hashable {
        public var r: Double, g: Double, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

        public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        public var saturation: Double {
            let maxC = max(r, g, b), minC = min(r, g, b)
            return maxC == 0 ? 0 : (maxC - minC) / maxC
        }
    }

    public var dominant: RGB
    public var accents: [RGB]

    public init(dominant: RGB, accents: [RGB]) {
        self.dominant = dominant
        self.accents = accents
    }

    public static let fallback = CoverPalette(dominant: RGB(r: 0.078, g: 0.078, b: 0.11), accents: [RGB(r: 0.996, g: 0.475, b: 0.443)])

    public static func extract(from image: CGImage, sampleSide: Int = 32) -> CoverPalette {
        let width = sampleSide, height = sampleSide
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .fallback
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var histogram: [UInt16: (count: Double, sum: (Double, Double, Double))] = [:]
        let centre = Double(sampleSide) / 2
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let dx = (Double(x) - centre) / centre, dy = (Double(y) - centre) / centre
                let weight = 1.5 - min(1, sqrt(dx * dx + dy * dy)) // centre-weighted
                let key = UInt16(pixels[i] >> 4) << 8 | UInt16(pixels[i + 1] >> 4) << 4 | UInt16(pixels[i + 2] >> 4)
                var bucket = histogram[key] ?? (0, (0, 0, 0))
                bucket.count += weight
                bucket.sum.0 += r * weight
                bucket.sum.1 += g * weight
                bucket.sum.2 += b * weight
                histogram[key] = bucket
            }
        }
        let colours = histogram.values
            .sorted { $0.count > $1.count }
            .map { RGB(r: $0.sum.0 / $0.count, g: $0.sum.1 / $0.count, b: $0.sum.2 / $0.count) }
        guard let first = colours.first else { return .fallback }
        let accents = colours.filter { $0.saturation > 0.25 && $0.luminance > 0.15 && $0.luminance < 0.85 }.prefix(3)
        return CoverPalette(dominant: first, accents: accents.isEmpty ? [first] : Array(accents))
    }
}
