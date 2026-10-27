import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

public struct VocalActivity: Sendable {
    public static let frameRate: Double = 100

    /// Energy of the separated vocals in the 200–5000 Hz band, dB.
    public var energy: [Float]
    public var flux: [Float]
    public var valid: [Bool]

    /// Separate high-band features for editor onsets. Kept out of the calibration
    /// features so quiet unvoiced consonants do not compete with vowel harmonics.
    var fricativeEnergy: [Float]
    var fricativeFlux: [Float]
    /// Changes in the broad spectral envelope, excluding its overall level.
    var shapeFlux: [Float]

    public init(frameCount: Int) {
        energy = Array(repeating: 0, count: frameCount)
        flux = Array(repeating: 0, count: frameCount)
        valid = Array(repeating: false, count: frameCount)
        fricativeEnergy = Array(repeating: -100, count: frameCount)
        fricativeFlux = Array(repeating: 0, count: frameCount)
        shapeFlux = Array(repeating: 0, count: frameCount)
    }

    public var frameCount: Int { energy.count }

    /// Boundary analysis includes quiet high-band consonants such as /s/. Keep the
    /// original low-band energy unchanged for whole-song offset calibration.
    public var boundaryEnergy: [Float] {
        guard fricativeEnergy.count == energy.count else { return energy }
        return zip(energy, fricativeEnergy).map { low, high in high.isFinite ? max(low, high) : low }
    }
}

public enum VocalActivityError: Error, Equatable {
    /// The file cannot be decoded.
    case unreadable
    case unsupportedFormat
    case separationUnavailable
}

/// Separates the vocals of stretches of an audio file with AUSoundIsolation (the network the
/// sing-along mode uses) and measures them into `activity`. Stretches can be analysed in any order; each one
/// resets the network and runs `preroll` seconds of audio through it first, since its output
/// needs that long to settle. Runs synchronously: call it off the main thread.
public final class VocalActivityAnalyzer {
    /// Audio run through the network before a stretch but not measured.
    public static let preroll: TimeInterval = 2
    /// Measured around a stretch but left invalid, so smoothing near its edges has data.
    static let leadMargin: TimeInterval = 0.5
    static let tailMargin: TimeInterval = 0.25

    public let duration: TimeInterval
    /// Analysis frames are timestamped at their centres when used as editor hints.
    public var frameCenterOffset: TimeInterval { Double(spectrum.size) / (2 * sampleRate) }
    public var frameDuration: TimeInterval { Double(spectrum.hop) / sampleRate }
    public private(set) var activity: VocalActivity
    /// Network in use (after fallbacks); nil when measuring the mix itself.
    public let model: VocalSeparationModel?
    /// Seconds of audio run through the network so far, pre-roll included.
    public private(set) var separatedDuration: TimeInterval = 0

    private let file: AVAudioFile
    private let sampleRate: Double
    private let channels: Int
    private let length: Int64
    private let unit: IsolationUnit?
    private let block = 4096
    private let input: AVAudioPCMBuffer
    private let output: [UnsafeMutablePointer<Float>]
    private let spectrum: BandSpectrum

    /// `model` nil measures the mix without separating it (tests, and a fallback).
    public init(file url: URL, model: VocalSeparationModel?, suppressVibrato: Bool = false) throws {
        guard let file = try? AVAudioFile(forReading: url) else { throw VocalActivityError.unreadable }
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw VocalActivityError.unreadable }
        guard (1...2).contains(Int(format.channelCount)) else { throw VocalActivityError.unsupportedFormat }
        self.file = file
        sampleRate = format.sampleRate
        channels = Int(format.channelCount)
        length = file.length
        duration = Double(file.length) / format.sampleRate
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else { throw VocalActivityError.unreadable }
        self.input = input
        output = (0..<channels).map { _ in .allocate(capacity: 4096) }
        spectrum = BandSpectrum(sampleRate: format.sampleRate, suppressVibrato: suppressVibrato)
        activity = VocalActivity(frameCount: Int(Double(file.length) / Double(spectrum.hop)) + 1)

        if let model {
            let processing = ProcessingFormat(sampleRate: sampleRate, channelCount: channels, maxFrames: block)
            let feed = InputFeed(channels: channels, maxFrames: block)
            var unit = model.accepts(channelCount: channels) ? IsolationUnit(format: processing, model: model, feed: feed) : nil
            if unit == nil, model != .systemVoice, VocalSeparationModel.systemVoice.accepts(channelCount: channels) {
                unit = IsolationUnit(format: processing, model: .systemVoice, feed: feed)
            }
            guard let unit else { throw VocalActivityError.separationUnavailable }
            // The vocals alone: a music model isolates the accompaniment, so −100 % leaves
            // dry − accompaniment; a voice model isolates the voice itself.
            let wetDry: AudioUnitParameterValue = unit.model.output == .accompaniment ? -100 : 100
            AudioUnitSetParameter(unit.unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, wetDry, 0)
            self.unit = unit
            self.model = unit.model
        } else {
            unit = nil
            self.model = nil
        }
    }

    deinit {
        output.forEach { $0.deallocate() }
    }

    /// Separates and measures `range` (seconds; clipped to the file).
    public func analyze(_ range: ClosedRange<TimeInterval>) throws {
        let hop = spectrum.hop, size = spectrum.size
        let frameRate = 1 / frameDuration
        let firstFrame = max(0, Int(((range.lowerBound - Self.leadMargin) * frameRate).rounded(.up)))
        let lastFrame = min(activity.frameCount - 1, Int(((range.upperBound + Self.tailMargin) * sampleRate - Double(size)) / Double(hop)))
        guard lastFrame >= firstFrame else { return }
        let start = Int64(firstFrame * hop)
        let end = min(length, Int64(lastFrame * hop + size))
        var vocals = [Float](repeating: 0, count: Int(end - start))
        try separate(from: start, to: end, into: &vocals)

        spectrum.reset()
        for frame in firstFrame...lastFrame {
            let offset = frame * hop - Int(start)
            guard offset + size <= vocals.count else { break }
            let measured = vocals.withUnsafeBufferPointer { spectrum.measure($0.baseAddress! + offset) }
            // Overlapping chunks warm up two frames of spectral history. Preserve earlier
            // valid measurements there instead of replacing their flux with reset zeros.
            if frame < firstFrame + 2, activity.valid[frame] { continue }
            activity.energy[frame] = measured.energy
            activity.flux[frame] = measured.flux
            activity.fricativeEnergy[frame] = measured.fricativeEnergy
            activity.fricativeFlux[frame] = measured.fricativeFlux
            activity.shapeFlux[frame] = measured.shapeFlux
        }
        let validFrom = max(firstFrame + 2, Int((range.lowerBound * frameRate).rounded(.up)))
        let validTo = min(lastFrame, Int((range.upperBound * frameRate).rounded(.down)) - 1)
        if validTo >= validFrom {
            for frame in validFrom...validTo { activity.valid[frame] = true }
        }
    }

    private func separate(from start: Int64, to end: Int64, into vocals: inout [Float]) throws {
        guard let unit else {
            try read(from: start, count: Int(end - start)) { position, frames in
                self.mix(frames: frames, at: Int(position - start), into: &vocals)
            }
            return
        }
        let latency = Int64(unit.latencyFrames)
        let from = max(0, start - Int64((Self.preroll * sampleRate).rounded()))
        AudioUnitReset(unit.unit, kAudioUnitScope_Global, 0)
        let buffers = AudioBufferList.allocate(maximumBuffers: channels)
        defer { buffers.unsafeMutablePointer.deallocate() }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        try read(from: from, count: Int(end + latency - from)) { position, frames in
            let feed = unit.feed
            for channel in 0..<channels {
                (feed.samples + channel * feed.maxFrames).update(from: input.floatChannelData![channel], count: frames)
                buffers[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: output[channel])
            }
            timestamp.mSampleTime = Float64(position - from)
            let status = AudioUnitRender(unit.unit, &flags, &timestamp, 0, UInt32(frames), buffers.unsafeMutablePointer)
            guard status == noErr else { throw VocalActivityError.separationUnavailable }
            let source = position - latency
            let skip = Int(max(0, start - source))
            guard skip < frames else { return }
            let destination = Int(source - start) + skip
            let count = min(frames - skip, vocals.count - destination)
            guard count > 0 else { return }
            vocals.withUnsafeMutableBufferPointer { out in
                let scale: Float = 1 / Float(channels)
                for channel in 0..<channels {
                    let samples = output[channel] + skip
                    for i in 0..<count { out[destination + i] += samples[i] * scale }
                }
            }
        }
        separatedDuration += Double(end + latency - from) / sampleRate
    }

    private func read(from position: Int64, count: Int, _ body: (Int64, Int) throws -> Void) throws {
        var position = position
        let stop = position + Int64(count)
        while position < stop {
            let frames = min(block, Int(stop - position))
            input.frameLength = 0
            if position < length {
                file.framePosition = position
                do {
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(frames), length - position)))
                } catch {
                    throw VocalActivityError.unreadable
                }
            }
            let got = Int(input.frameLength)
            if got < frames {
                for channel in 0..<channels { (input.floatChannelData![channel] + got).update(repeating: 0, count: frames - got) }
            }
            input.frameLength = AVAudioFrameCount(frames)
            try body(position, frames)
            position += Int64(frames)
        }
    }

    private func mix(frames: Int, at offset: Int, into vocals: inout [Float]) {
        let scale: Float = 1 / Float(channels)
        vocals.withUnsafeMutableBufferPointer { out in
            for channel in 0..<channels {
                let samples = input.floatChannelData![channel]
                for i in 0..<frames where offset + i < out.count { out[offset + i] += samples[i] * scale }
            }
        }
    }
}

/// Short-time spectrum of the vocal band, with an optional 4–12 kHz consonant band:
/// a Hann-windowed FFT of about 46 ms every 10 ms.
/// Magnitudes are scaled to a 1024-point transform so levels match across sample rates.
final class BandSpectrum {
    let size: Int
    let hop: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let band: Range<Int>
    private let fricativeBand: Range<Int>
    private let magnitudeScale: Float
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var history: [[Float]]
    private var fricativeHistory: [Float] = [0, 0]
    private var fricativeSpectra: [[Float]]
    private var measured = 0
    private let comparisonBands: [Range<Int>]
    private let fricativeComparisons: [Range<Int>]
    private let suppressVibrato: Bool
    private struct ShapeBand {
        var bins: [Int]
        var weights: [Float]
    }
    private let shapeBands: [ShapeBand]
    private let shapeCosines: [[Float]]
    private var shapeHistory = [[Float](repeating: 0, count: 13), [Float](repeating: 0, count: 13)]

    init(sampleRate: Double, suppressVibrato: Bool = false) {
        self.suppressVibrato = suppressVibrato
        size = suppressVibrato ? 1 << min(13, max(8, Int(log2(sampleRate * 0.046).rounded()))) : (sampleRate > 60000 ? 4096 : 2048)
        hop = Int((sampleRate / VocalActivity.frameRate).rounded())
        log2Size = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = window
        let binWidth = sampleRate / Double(size)
        band = min(Int((200 / binWidth).rounded(.up)), size / 2 - 1)..<min(Int((5000 / binWidth).rounded(.up)), size / 2)
        // /s/ and similar unvoiced consonants can concentrate above 5 kHz. Measure
        // their band energy before frequency max filtering, which suppresses noise
        // as well as vibrato. Clip at Nyquist for lower-rate audio.
        fricativeBand = suppressVibrato
            ? min(Int((4000 / binWidth).rounded(.up)), size / 2)..<min(Int((12000 / binWidth).rounded(.up)), size / 2)
            : 0..<0
        // A frequency maximum filter tolerates small harmonic movements (vibrato).
        // Keep the original flux unchanged for whole-song offset calibration.
        let bandCount = band.count
        comparisonBands = band.enumerated().map { i, bin in
            let radius = suppressVibrato ? max(1, Int((Double(bin) * 0.03).rounded())) : 0
            return max(0, i - radius)..<min(bandCount, i + radius + 1)
        }
        let fricativeCount = fricativeBand.count
        fricativeComparisons = fricativeBand.enumerated().map { i, bin in
            let radius = max(1, Int((Double(bin) * 0.03).rounded()))
            return max(0, i - radius)..<min(fricativeCount, i + radius + 1)
        }
        // vDSP_fft_zrip doubles the transform; normalize to the 1024-point reference scale.
        magnitudeScale = 0.5 * 1024 / Float(size)
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        history = [[Float](repeating: 0, count: band.count), [Float](repeating: 0, count: band.count)]
        fricativeSpectra = [[Float](repeating: 0, count: fricativeCount), [Float](repeating: 0, count: fricativeCount)]
        shapeBands = suppressVibrato ? Self.makeShapeBands(sampleRate: sampleRate, size: size) : []
        shapeCosines = suppressVibrato ? (1...13).map { coefficient in
            (0..<64).map { band in
                Float(sqrt(2.0 / 64) * cos(.pi * Double(coefficient) * (Double(band) + 0.5) / 64))
            }
        } : []
    }

    private static func makeShapeBands(sampleRate: Double, size: Int) -> [ShapeBand] {
        func mel(_ frequency: Double) -> Double { 2595 * log10(1 + frequency / 700) }
        let upper = min(8000, sampleRate / 2)
        let lower = min(100, upper / 2)
        let edges = (0..<66).map { i in
            700 * (pow(10, (mel(lower) + Double(i) / 65 * (mel(upper) - mel(lower))) / 2595) - 1)
        }
        return (0..<64).map { i in
            let first = max(1, Int((edges[i] * Double(size) / sampleRate).rounded(.up)))
            let last = min(size / 2 - 1, Int((edges[i + 2] * Double(size) / sampleRate).rounded(.down)))
            guard first <= last else { return ShapeBand(bins: [], weights: []) }
            let bins = Array(first...last)
            let weights = bins.map { bin -> Float in
                let frequency = Double(bin) * sampleRate / Double(size)
                return Float(max(0, min((frequency - edges[i]) / (edges[i + 1] - edges[i]),
                                        (edges[i + 2] - frequency) / (edges[i + 2] - edges[i + 1]))))
            }
            let sum = max(1e-8, weights.reduce(0, +))
            return ShapeBand(bins: bins, weights: weights.map { $0 / sum })
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() { measured = 0 }

    /// Band energy (dB) and onset strength of the `size` samples at `samples`.
    func measure(_ samples: UnsafePointer<Float>) -> (energy: Float, flux: Float, fricativeEnergy: Float, fricativeFlux: Float, shapeFlux: Float) {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
        var power: Float = 0
        var rise: Float = 0
        var fricativePower: Float = 0
        var fricativeRise: Float = 0
        let older = history[0]
        var current = [Float](repeating: 0, count: band.count)
        var fricativeSpectrum = [Float](repeating: 0, count: fricativeBand.count)
        var shape = [Float](repeating: 0, count: 13)
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                for (i, bin) in band.enumerated() {
                    let magnitude = (re[bin] * re[bin] + im[bin] * im[bin]).squareRoot() * magnitudeScale
                    power += magnitude * magnitude
                    // log1p avoids promoting vanishing FFT leakage at a fading note's
                    // tail into a loud onset. Calibration retains its original feature.
                    let level = suppressVibrato ? log1p(magnitude * 10) : log(magnitude + 1e-4)
                    current[i] = level
                    if measured >= 2 {
                        let reference = comparisonBands[i].reduce(-Float.infinity) { max($0, older[$1]) }
                        rise += max(0, level - reference)
                    }
                }
                for (i, bin) in fricativeBand.enumerated() {
                    let power = (re[bin] * re[bin] + im[bin] * im[bin]) * magnitudeScale * magnitudeScale
                    fricativePower += power
                    let level = log1p(power.squareRoot() * 10)
                    fricativeSpectrum[i] = level
                    if measured >= 2 {
                        let reference = fricativeComparisons[i].reduce(-Float.infinity) { max($0, fricativeSpectra[0][$1]) }
                        fricativeRise += max(0, level - reference)
                    }
                }
                if !shapeBands.isEmpty {
                    let levels = shapeBands.map { band -> Float in
                        var magnitude: Float = 0
                        for (bin, weight) in zip(band.bins, band.weights) {
                            magnitude += (re[bin] * re[bin] + im[bin] * im[bin]).squareRoot() * magnitudeScale * weight
                        }
                        return log1p(magnitude * 3)
                    }
                    for coefficient in shape.indices {
                        shape[coefficient] = zip(levels, shapeCosines[coefficient]).reduce(0) { $0 + $1.0 * $1.1 }
                    }
                }
            }
        }
        history[0] = history[1]
        history[1] = current
        // Band energy catches noise rises that the frequency max filter suppresses;
        // spectral flux also catches a vowel harmonic giving way to broadband /s/
        // without increasing total high-band energy.
        let fricativeLevel = log1p(fricativePower.squareRoot() * 10)
        let fricativeFlux = measured >= 2
            ? max(fricativeRise / Float(max(1, fricativeBand.count)), max(0, fricativeLevel - fricativeHistory[0])) : 0
        fricativeHistory[0] = fricativeHistory[1]
        fricativeHistory[1] = fricativeLevel
        fricativeSpectra[0] = fricativeSpectra[1]
        fricativeSpectra[1] = fricativeSpectrum
        // Low-order coefficients retain broad formant changes while removing the
        // overall level (coefficient zero). This is an acoustic cue, not recognition.
        let shapeFlux: Float = measured >= 2 && !shapeBands.isEmpty
            ? zip(shape, shapeHistory[0]).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot() / 8 : 0
        shapeHistory[0] = shapeHistory[1]
        shapeHistory[1] = shape
        measured += 1
        return (10 * log10(power + 1e-10), rise / Float(band.count),
                10 * log10(fricativePower + 1e-10), fricativeFlux, shapeFlux)
    }
}
