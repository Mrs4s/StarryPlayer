import Accelerate
import AVFoundation
import Foundation

/// Read-only stage: Hann-windowed vDSP FFT → log-spaced band energies.
/// Buffers are allocated in `prepare`; `process` runs on the audio thread without allocation.
public final class SpectrumAnalyzer: AudioProcessor {
    public struct Snapshot: Sendable, Equatable {
        public var bands: [Float]
        /// Average energies of 40–250 Hz, 250–2000 Hz and 2–8 kHz, plus the overall level (0…1).
        public var low: Float
        public var mid: Float
        public var high: Float
        public var overall: Float
        public static let silent = Snapshot(bands: [], low: 0, mid: 0, high: 0, overall: 0)
    }

    public var isEnabled = true
    public let latencyFrames = 0
    public let bandCount: Int

    private let fftSize = 2048
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var ring: [Float]
    private var ringHead = 0
    private var framesSinceFFT = 0
    private var real: [Float]
    private var imag: [Float]
    private var scratch: [Float]
    private var magnitudes: [Float]
    private var bandEdges: [Int] = []
    private var sampleRate: Double = 44100

    private let lock = NSLock()
    private var latest: Snapshot
    private var smoothed: [Float]

    public init(bandCount: Int = 48) {
        self.bandCount = bandCount
        log2n = vDSP_Length(log2(Double(fftSize)))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        scratch = [Float](repeating: 0, count: fftSize)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        smoothed = [Float](repeating: 0, count: bandCount)
        latest = Snapshot(bands: Array(repeating: 0, count: bandCount), low: 0, mid: 0, high: 0, overall: 0)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        computeBandEdges()
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    public func prepare(format: ProcessingFormat) {
        sampleRate = format.sampleRate
        computeBandEdges()
        reset()
    }

    private func computeBandEdges() {
        let nyquist = sampleRate / 2
        let binHz = nyquist / Double(fftSize / 2)
        let lowHz = 40.0, highHz = min(16000.0, nyquist)
        bandEdges = (0...bandCount).map { i in
            let f = lowHz * pow(highHz / lowHz, Double(i) / Double(bandCount))
            return min(fftSize / 2 - 1, max(1, Int(f / binHz)))
        }
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0, let fftSetup else { return }
        let channels = buffers.count
        guard channels > 0 else { return }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                guard let data = buffers[channel].mData else { continue }
                sum += data.assumingMemoryBound(to: Float.self)[frame]
            }
            ring[ringHead] = sum / Float(channels)
            ringHead = (ringHead + 1) % fftSize
        }
        framesSinceFFT += frameCount
        guard framesSinceFFT >= fftSize / 4 else { return }
        framesSinceFFT = 0

        let tail = fftSize - ringHead
        scratch.withUnsafeMutableBufferPointer { dst in
            ring.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + ringHead, count: tail)
                if ringHead > 0 { (dst.baseAddress! + tail).update(from: src.baseAddress!, count: ringHead) }
            }
        }
        vDSP_vmul(scratch, 1, window, 1, &scratch, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                scratch.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        // Magnitude (power) → normalised dB scale per band.
        let norm = 1 / Float(fftSize * fftSize / 4)
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lo = bandEdges[b], hi = max(lo + 1, bandEdges[b + 1])
            var power: Float = 0
            for i in lo..<hi { power += magnitudes[i] }
            power = power / Float(hi - lo) * norm
            let db = 10 * log10(max(power, 1e-12))
            let value = min(1, max(0, (db + 66) / 66))
            smoothed[b] = value > smoothed[b] ? value : smoothed[b] * 0.82 + value * 0.18
            bands[b] = smoothed[b]
        }
        func average(_ range: Range<Int>) -> Float {
            guard !range.isEmpty else { return 0 }
            return bands[range].reduce(0, +) / Float(range.count)
        }
        let n = bandCount
        let low = average(0..<max(1, n * 30 / 100))
        let mid = average(max(1, n * 30 / 100)..<max(2, n * 63 / 100))
        let high = average(max(2, n * 63 / 100)..<n)
        let overall = (low * 0.5 + mid * 0.35 + high * 0.15)
        lock.lock()
        latest = Snapshot(bands: bands, low: low, mid: mid, high: high, overall: overall)
        lock.unlock()
    }

    public func reset() {
        ringHead = 0
        framesSinceFFT = 0
        for i in ring.indices { ring[i] = 0 }
        for i in smoothed.indices { smoothed[i] = 0 }
        lock.lock()
        latest = Snapshot(bands: Array(repeating: 0, count: bandCount), low: 0, mid: 0, high: 0, overall: 0)
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
