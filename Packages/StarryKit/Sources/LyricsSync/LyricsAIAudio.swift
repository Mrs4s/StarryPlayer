import Accelerate
import AVFoundation
import Foundation

enum LyricsAIAudio {
    static let sampleRate = 16_000
    static let maximumSamples = sampleRate * 60 * 30

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = file.processingFormat
        guard source.sampleRate.isFinite, source.sampleRate > 0, (1...8).contains(source.channelCount), file.length > 0,
              Double(file.length) / source.sampleRate * Double(sampleRate) <= Double(maximumSamples) else {
            throw LyricsAIError.invalidAudio
        }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { throw LyricsAIError.invalidAudio }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var result: [Float] = []
        result.reserveCapacity(min(maximumSamples, Int(Double(file.length) / source.sampleRate * Double(sampleRate)) + 1024))
        var readError: Error?
        var finished = false
        while !finished {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { wanted, inputStatus in
                if Task.isCancelled { inputStatus.pointee = .noDataNow; return nil }
                if file.framePosition >= file.length { inputStatus.pointee = .endOfStream; return nil }
                let frames = AVAudioFrameCount(min(Int64(wanted), file.length - file.framePosition))
                guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames),
                      let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames) else {
                    readError = LyricsAIError.invalidAudio; inputStatus.pointee = .endOfStream; return nil
                }
                do { try file.read(into: input, frameCount: frames) }
                catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
                guard let channels = input.floatChannelData, let samples = mixed.floatChannelData?[0] else {
                    readError = LyricsAIError.invalidAudio; inputStatus.pointee = .endOfStream; return nil
                }
                let count = Int(input.frameLength)
                mixed.frameLength = input.frameLength
                for i in 0..<count {
                    var value: Float = 0
                    for c in 0..<Int(source.channelCount) { value += channels[c][i] }
                    samples[i] = value / Float(source.channelCount)
                }
                inputStatus.pointee = .haveData
                return mixed
            }
            try Task.checkCancellation()
            if let readError { throw readError }
            if let error { throw error }
            guard status != .error else { throw LyricsAIError.invalidAudio }
            if let values = output.floatChannelData?[0], output.frameLength > 0 {
                guard result.count + Int(output.frameLength) <= maximumSamples else { throw LyricsAIError.tooLarge }
                result.append(contentsOf: UnsafeBufferPointer(start: values, count: Int(output.frameLength)))
            }
            finished = status == .endOfStream
            if status == .inputRanDry, output.frameLength == 0, file.framePosition >= file.length { finished = true }
        }
        guard result.count >= 400, result.allSatisfy(\.isFinite) else { throw LyricsAIError.invalidAudio }
        return result
    }
}

/// Exact 400-point STFT as five interleaved 80-point DFTs. Accelerate supports 80 but
/// not 400; padding to 512 would change the learned filter bank.
enum LyricsAIMel {
    static let samples = 480_000
    static let frames = 3_000
    static let bins = 201
    static let bands = 128

    private struct Basis: Sendable {
        var real: [Float]
        var imaginary: [Float]
        init() {
            real = [Float](repeating: 0, count: 5 * bins)
            imaginary = real
            for sample in 0..<5 {
                for bin in 0..<bins {
                    let phase = 2 * Double.pi * Double(sample * bin) / 400
                    real[sample * bins + bin] = Float(cos(phase))
                    imaginary[sample * bins + bin] = Float(-sin(phase))
                }
            }
        }
    }
    private static let basis = Basis()

    static func encode(_ audio: ArraySlice<Float>, filters: [Float], hann: [Float]) throws -> [Float] {
        guard (400...480_080).contains(audio.count), filters.count == bins * bands, hann.count == 400 else {
            throw LyricsAIError.invalidAudio
        }
        try Task.checkCancellation()
        var centered = [Float](repeating: 0, count: audio.count)
        var mean: Float = 0, variance: Float = 0
        audio.withUnsafeBufferPointer { source in
            vDSP_meanv(source.baseAddress!, 1, &mean, vDSP_Length(audio.count))
            var negative = -mean
            vDSP_vsadd(source.baseAddress!, 1, &negative, &centered, 1, vDSP_Length(audio.count))
        }
        vDSP_measqv(centered, 1, &variance, vDSP_Length(centered.count))
        guard mean.isFinite, variance.isFinite, variance >= 0 else { throw LyricsAIError.invalidAudio }
        let deviation = sqrt(variance + 1e-7)
        var wave = [Float](repeating: 0, count: samples)
        for i in 0..<min(samples, centered.count) { wave[i] = centered[i] / deviation * 0.1 }
        guard let fft = vDSP_DFT_zop_CreateSetup(nil, 80, .FORWARD) else { throw LyricsAIError.invalidAudio }
        defer { vDSP_DFT_DestroySetup(fft) }
        var input = [Float](repeating: 0, count: 80)
        let zero = input
        var real = input, imaginary = input
        var partsReal = [Float](repeating: 0, count: 400)
        var partsImaginary = partsReal
        var power = [Float](repeating: 0, count: frames * bins)
        for frame in 0..<frames {
            if frame.isMultiple(of: 256) { try Task.checkCancellation() }
            for part in 0..<5 {
                for i in 0..<80 {
                    let offset = 5 * i + part
                    var index = frame * 160 + offset - 200
                    if index < 0 { index = -index }
                    if index >= samples { index = 2 * samples - 2 - index }
                    input[i] = wave[index] * hann[offset]
                }
                vDSP_DFT_Execute(fft, input, zero, &real, &imaginary)
                for i in 0..<80 {
                    partsReal[part * 80 + i] = real[i]
                    partsImaginary[part * 80 + i] = imaginary[i]
                }
            }
            for bin in 0..<bins {
                var real: Float = 0, imaginary: Float = 0
                for part in 0..<5 {
                    let a = partsReal[part * 80 + bin % 80], b = partsImaginary[part * 80 + bin % 80]
                    let c = basis.real[part * bins + bin], d = basis.imaginary[part * bins + bin]
                    real += a * c - b * d
                    imaginary += a * d + b * c
                }
                power[frame * bins + bin] = real * real + imaginary * imaginary
            }
        }
        try Task.checkCancellation()
        var mel = multiply(power, filters, rows: frames, inner: bins, columns: bands)
        var top = -Float.infinity
        for i in mel.indices {
            mel[i] = log10(max(mel[i], 1e-10))
            top = max(top, mel[i])
        }
        var result = [Float](repeating: 0, count: mel.count)
        for frame in 0..<frames {
            for band in 0..<bands {
                let value = (max(mel[frame * bands + band], top - 8) + 4) / 4
                result[band * frames + frame] = roundedBFloat16(value)
            }
        }
        return result
    }

    static func roundedBFloat16(_ value: Float) -> Float {
        let bits = value.bitPattern
        let rounded = bits &+ 0x7fff &+ ((bits >> 16) & 1)
        return Float(bitPattern: rounded & 0xffff0000)
    }

    private static func multiply(_ a: [Float], _ b: [Float], rows: Int, inner: Int, columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: rows * columns)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                result.withUnsafeMutableBufferPointer { rp in
                    vDSP_mmul(ap.baseAddress!, 1, bp.baseAddress!, 1, rp.baseAddress!, 1,
                              vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
                }
            }
        }
        return result
    }
}
