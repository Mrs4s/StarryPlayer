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

    public init(frameCount: Int) {
        energy = Array(repeating: 0, count: frameCount)
        flux = Array(repeating: 0, count: frameCount)
        valid = Array(repeating: false, count: frameCount)
    }

    public var frameCount: Int { energy.count }
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
    public init(file url: URL, model: VocalSeparationModel?) throws {
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
        spectrum = BandSpectrum(sampleRate: format.sampleRate)
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
        let frameRate = VocalActivity.frameRate
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
            let (energy, flux) = vocals.withUnsafeBufferPointer { spectrum.measure($0.baseAddress! + offset) }
            activity.energy[frame] = energy
            activity.flux[frame] = flux
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

/// Short-time spectrum of the 200–5000 Hz band: a Hann-windowed FFT of about 46 ms every 10 ms.
/// Magnitudes are scaled to a 1024-point transform so levels match across sample rates.
final class BandSpectrum {
    let size: Int
    let hop: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let band: Range<Int>
    private let magnitudeScale: Float
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var history: [[Float]]
    private var measured = 0

    init(sampleRate: Double) {
        size = sampleRate > 60000 ? 4096 : 2048
        hop = Int((sampleRate / VocalActivity.frameRate).rounded())
        log2Size = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = window
        let binWidth = sampleRate / Double(size)
        band = Int((200 / binWidth).rounded(.up))..<Int((5000 / binWidth).rounded(.up))
        // vDSP_fft_zrip doubles the transform; normalize to the 1024-point reference scale.
        magnitudeScale = 0.5 * 1024 / Float(size)
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        history = [[Float](repeating: 0, count: band.count), [Float](repeating: 0, count: band.count)]
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() { measured = 0 }

    /// Band energy (dB) and onset strength of the `size` samples at `samples`.
    func measure(_ samples: UnsafePointer<Float>) -> (energy: Float, flux: Float) {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
        var power: Float = 0
        var rise: Float = 0
        let older = history[0]
        var current = [Float](repeating: 0, count: band.count)
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
                    let level = log(magnitude + 1e-4)
                    current[i] = level
                    if measured >= 2 { rise += max(0, level - older[i]) }
                }
            }
        }
        history[0] = history[1]
        history[1] = current
        measured += 1
        return (10 * log10(power + 1e-10), rise / Float(band.count))
    }
}
