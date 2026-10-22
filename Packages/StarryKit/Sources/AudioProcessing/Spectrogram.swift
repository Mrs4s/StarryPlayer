import Accelerate
import CoreGraphics
import Foundation

/// Computes only FFT frames visible in pixel columns, keeping cost proportional to image width.
public enum Spectrogram {
    public static let fftSize = 1024
    private static let hop = 64
    private static let maxFrequency: Float = 20_000
    public static let defaultGain: Float = 3

    /// Renders `samples` (mono, at `sampleRate`) as a `width` × `height` picture. The first FFT
    /// frame starts at the first sample: to line column x up with time `start + x · span /
    /// width`, pass samples from half an FFT before `start` to half an FFT after the end.
    /// Nil when there is not one frame's worth of samples.
    public static func image(samples: [Float], sampleRate: Double, width: Int, height: Int, gain: Float = defaultGain, palette: SpectrogramPalette = .icyBlue) -> CGImage? {
        guard let pixels = pixels(samples: samples, sampleRate: sampleRate, width: width, height: height, gain: gain, palette: palette) else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The picture as RGBA bytes, top row first.
    static func pixels(samples: [Float], sampleRate: Double, width: Int, height: Int, gain: Float, palette: SpectrogramPalette) -> [UInt8]? {
        let n = fftSize
        guard !Task.isCancelled, width > 0, height > 0, sampleRate > 0, samples.count >= n else { return nil }
        let timeBins = (samples.count - n) / hop + 1
        let resolution = Float(sampleRate) / Float(n)
        let freqBins = min(Int((maxFrequency / resolution).rounded()), n / 2)
        guard freqBins > 1 else { return nil }

        let ratio = Float(timeBins - 1) / Float(width)
        let columnFrames = (0..<width).map { min(Int(Float($0) * ratio + 0.5), timeBins - 1) }
        var frameRow = [Int: Int]()
        var frames: [Int] = []
        for frame in columnFrames where frameRow[frame] == nil {
            frameRow[frame] = frames.count
            frames.append(frame)
        }
        let values = magnitudes(samples: samples, frames: frames, freqBins: freqBins, gain: gain)
        guard !Task.isCancelled, values.count == frames.count * freqBins else { return nil }

        let logRatio = logRatio(sampleRate: sampleRate, freqBins: freqBins)
        let minBin: Float = 1, maxBin = Float(freqBins)
        let scaleLog = log(maxBin / minBin)
        func bin(_ y: Int) -> Float {
            let pos = Float(y) / Float(height)
            let linear = pos * (maxBin - minBin) + minBin
            let logarithmic = minBin * exp(pos * scaleLog)
            return logRatio * (logarithmic - linear) + linear
        }
        let rowBins: [(start: Int, end: Int)] = (0..<height).map { y in
            let start = min(Int(bin(y).rounded(.down)), freqBins - 1)
            let end = min(Int(bin(y + 1).rounded(.down)), freqBins)
            return (start, end)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let lut = palette.lut
        for yPixel in 0..<height {
            guard !Task.isCancelled else { return nil }
            let (start, end) = rowBins[height - 1 - yPixel]
            let rowStart = yPixel * width * 4
            for x in 0..<width {
                let base = frameRow[columnFrames[x]]! * freqBins
                var value: Float
                if start >= end {
                    value = values[base + start]
                } else {
                    value = -.infinity
                    for b in start..<end { value = max(value, values[base + b]) }
                }
                let index = Int(min(max(value, 0), 1) * 255 + 0.5) * 4
                let pixel = rowStart + x * 4
                pixels[pixel] = lut[index]
                pixels[pixel + 1] = lut[index + 1]
                pixels[pixel + 2] = lut[index + 2]
                pixels[pixel + 3] = 255
            }
        }
        return pixels
    }

    /// Mapped magnitudes of `frames` (frame k starts at sample k · hop), `freqBins` each.
    static func magnitudes(samples: [Float], frames: [Int], freqBins: Int, gain: Float) -> [Float] {
        let n = fftSize
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n / 2)
        var imaginary = [Float](repeating: 0, count: n / 2)
        var magnitude = [Float](repeating: 0, count: n / 2)
        var values = [Float](repeating: 0, count: frames.count * freqBins)
        // Aegisub's scale, and vDSP's real FFT giving twice the plain DFT.
        let scale = 9 / sqrt(2 * Float(n)) / 2
        samples.withUnsafeBufferPointer { input in
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    for (row, frame) in frames.enumerated() {
                        if Task.isCancelled { return }
                        let start = input.baseAddress! + frame * hop
                        start.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { pairs in
                            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(n / 2))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        // Bin 0 holds DC and Nyquist packed together; DC alone is |re[0]|.
                        let dc = abs(re[0])
                        vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(n / 2))
                        magnitude[0] = dc
                        let base = row * freqBins
                        for k in 0..<freqBins {
                            values[base + k] = log10(magnitude[k] * scale + 1) * gain
                        }
                    }
                }
            }
        }
        return values
    }

    /// How far the frequency axis leans from linear (0) to logarithmic (1): as far as puts
    /// 1 kHz a thousandth of the way up, as Aegisub's does.
    static func logRatio(sampleRate: Double, freqBins: Int) -> Float {
        let minBin: Float = 1, maxBin = Float(freqBins)
        guard maxBin > minBin else { return 0 }
        let position: Float = 0.001
        let reference = min(max(1000 / (Float(sampleRate) / Float(fftSize)), minBin), maxBin - 1)
        let linear = (maxBin - minBin) * position + minBin
        let logarithmic = minBin * exp(position * log(maxBin / minBin))
        let denominator = logarithmic - linear
        guard abs(denominator) > 1e-6 else { return 0.5 }
        return min(max((reference - linear) / denominator, 0), 1)
    }
}

/// 256 colours from quiet to loud, RGBA.
public struct SpectrogramPalette: Sendable {
    public let lut: [UInt8]

    public init(_ color: (Float) -> (UInt8, UInt8, UInt8)) {
        var lut = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            let (r, g, b) = color(Float(i) / 255)
            lut[i * 4] = r
            lut[i * 4 + 1] = g
            lut[i * 4 + 2] = b
        }
        self.lut = lut
    }

    public static let icyBlue = SpectrogramPalette { v in
        let v = min(max(v, 0), 1)
        let hue = ((-128 * v + 191).truncatingRemainder(dividingBy: 256) + 256).truncatingRemainder(dividingBy: 256) * (360 / 255)
        let saturation = min(max(128 * v + 127, 0), 255) / 255
        let lightness = min(max(255 * v, 0), 255) / 255
        return hsl(hue, saturation, lightness)
    }

    static func hsl(_ h: Float, _ s: Float, _ l: Float) -> (UInt8, UInt8, UInt8) {
        guard s > 0 else {
            let gray = UInt8(l * 255)
            return (gray, gray, gray)
        }
        let chroma = (1 - abs(2 * l - 1)) * s
        let hPrime = h / 60
        let second = chroma * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let (r, g, b): (Float, Float, Float) = switch hPrime {
        case 0..<1: (chroma, second, 0)
        case 1..<2: (second, chroma, 0)
        case 2..<3: (0, chroma, second)
        case 3..<4: (0, second, chroma)
        case 4..<5: (second, 0, chroma)
        case 5..<6: (chroma, 0, second)
        default: (0, 0, 0)
        }
        return (UInt8(min(max((r + m) * 255, 0), 255)), UInt8(min(max((g + m) * 255, 0), 255)), UInt8(min(max((b + m) * 255, 0), 255)))
    }
}
