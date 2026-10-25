import Accelerate
import Foundation

/// The UNMIXX spectral contract: unnormalized complex FFT, periodic Hann, centered
/// reflection padding. Kept separate from Core ML so FFTs do not enter the model.
final class DuetSpectrum {
    static let fftSize = 960
    static let hop = 240
    static let bins = fftSize / 2 + 1
    let sampleCount: Int
    let frames: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let window: [Float]
    private let normalization: [Float]

    init(sampleCount: Int) throws {
        guard sampleCount > 0,
              let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)
        else { throw VocalDuetSeparator.Failure.unsupportedAudio }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw VocalDuetSeparator.Failure.unsupportedAudio
        }
        self.forward = forward
        self.inverse = inverse
        self.sampleCount = sampleCount
        frames = sampleCount / Self.hop + 1
        window = (0..<Self.fftSize).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(Self.fftSize))) }
        var normalization = [Float](repeating: 0, count: sampleCount)
        for frame in 0..<frames {
            let start = frame * Self.hop - Self.fftSize / 2
            for j in max(0, -start)..<min(Self.fftSize, sampleCount - start) {
                normalization[start + j] += window[j] * window[j]
            }
        }
        self.normalization = normalization
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    func encode(_ samples: [Float]) throws -> [Float] {
        precondition(samples.count == sampleCount)
        var result = [Float](repeating: 0, count: 2 * Self.bins * frames)
        var input = [Float](repeating: 0, count: Self.fftSize)
        let zero = [Float](repeating: 0, count: Self.fftSize)
        var real = zero, imaginary = zero
        for frame in 0..<frames {
            if frame % 32 == 0 { try Task.checkCancellation() }
            let start = frame * Self.hop - Self.fftSize / 2
            for j in 0..<Self.fftSize {
                input[j] = samples[Self.reflected(start + j, count: sampleCount)] * window[j]
            }
            vDSP_DFT_Execute(forward, input, zero, &real, &imaginary)
            for bin in 0..<Self.bins {
                result[bin * frames + frame] = real[bin]
                result[(Self.bins + bin) * frames + frame] = imaginary[bin]
            }
        }
        return result
    }

    func decode(_ values: UnsafePointer<Float>, realOffset: Int, imaginaryOffset: Int,
                binStride: Int, frameStride: Int) throws -> [Float] {
        var result = [Float](repeating: 0, count: sampleCount)
        var real = [Float](repeating: 0, count: Self.fftSize)
        var imaginary = real, decodedReal = real, decodedImaginary = real
        for frame in 0..<frames {
            if frame % 32 == 0 { try Task.checkCancellation() }
            for bin in 0..<Self.bins {
                let offset = bin * binStride + frame * frameStride
                real[bin] = values[realOffset + offset]
                imaginary[bin] = values[imaginaryOffset + offset]
            }
            for bin in Self.bins..<Self.fftSize {
                real[bin] = real[Self.fftSize - bin]
                imaginary[bin] = -imaginary[Self.fftSize - bin]
            }
            vDSP_DFT_Execute(inverse, real, imaginary, &decodedReal, &decodedImaginary)
            let start = frame * Self.hop - Self.fftSize / 2
            for j in max(0, -start)..<min(Self.fftSize, sampleCount - start) {
                result[start + j] += decodedReal[j] * window[j] / Float(Self.fftSize)
            }
        }
        for i in result.indices { result[i] /= max(normalization[i], 1e-10) }
        return result
    }

    private static func reflected(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * (count - 1)
        let wrapped = ((index % period) + period) % period
        return wrapped < count ? wrapped : period - wrapped
    }
}

enum DuetOverlap {
    struct Match: Equatable {
        var swap: Bool
        var uncertain: Bool
    }

    /// Energy-weighted correlation: a quiet source's leakage cannot outweigh an
    /// active source simply because its normalized correlation happens to be high.
    static func match(previous: [[Float]], current: [[Float]]) -> Match {
        let count = previous[0].count
        precondition(count > 0 && previous.count == 2 && current.count == 2)
        precondition(previous[1].count == count && current.allSatisfy { $0.count >= count })
        let meanA = previous.map { $0.reduce(0.0) { $0 + Double($1) } / Double(count) }
        let meanB = current.map { $0.prefix(count).reduce(0.0) { $0 + Double($1) } / Double(count) }
        var aa = 0.0, bb = 0.0, direct = 0.0, swapped = 0.0, energy = 0.0
        for i in 0..<count {
            let a = Double(previous[0][i]) - meanA[0], b = Double(previous[1][i]) - meanA[1]
            let c = Double(current[0][i]) - meanB[0], d = Double(current[1][i]) - meanB[1]
            aa += a*a + b*b; bb += c*c + d*d
            direct += a*c + b*d; swapped += a*d + b*c
            energy += Double(previous[0][i]) * Double(previous[0][i]) + Double(previous[1][i]) * Double(previous[1][i])
        }
        let norm = max(sqrt(aa * bb), 1e-15)
        direct /= norm; swapped /= norm
        return Match(swap: swapped > direct,
                     uncertain: max(direct, swapped) < 0.35 || abs(direct - swapped) < 0.1 || sqrt(energy / Double(2 * count)) < 0.0001)
    }

    static func blend(previous: [[Float]], into current: inout [[Float]]) {
        let count = previous[0].count
        guard count > 0 else { return }
        for i in 0..<count {
            let weight = Float(0.5 - 0.5 * cos(.pi * Double(i) / Double(max(1, count - 1))))
            for source in 0..<2 { current[source][i] = previous[source][i] * (1 - weight) + current[source][i] * weight }
        }
    }
}
