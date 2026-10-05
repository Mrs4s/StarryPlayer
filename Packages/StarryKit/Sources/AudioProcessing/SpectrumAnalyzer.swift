import Accelerate
import AVFoundation
import Foundation

/// Read-only stage: Hann-windowed vDSP FFT → log-spaced band energies.
/// Buffers are allocated in `prepare`; `process` runs on the audio thread without allocation.
///
/// `snapshot()` is the latest block's bands, smoothed. The tap sees each block well before it
/// plays (with AVPlayer, blocks of ~86 ms, the latest ~0.4 s ahead of the item's clock), so for
/// what moves with the sound `snapshot(at:)` and `bands(at:after:)` give the analysis at a time
/// on the item's timeline instead: while either is being asked for, every hop of each block is
/// analysed and kept, smoothed and not, stamped with where its window is centred.
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
    /// The last analysis's bands, unsmoothed.
    private var raw: [Float]

    /// Analyses kept for `snapshot(at:)` and `bands(at:after:)`, oldest overwritten first:
    /// `historyCapacity` rows of `bandCount` (raw and smoothed) and of the four energies, with the
    /// sample each window is centred on: `historySeconds` of hops, well over how far the tap
    /// runs ahead, at any sample rate (sized in `prepare`). Under `lock`.
    private static let historySeconds = 1.5
    private var historyCapacity: Int
    private var history: [Float]
    private var historySmoothed: [Float]
    private var historyEnergies: [Float]
    private var historyStamps: [Int64]
    /// The hops' own smoothing, released over `releaseTime` as the blocks' is at AVPlayer's
    /// pace (0.82 a block of ~86 ms), so what follows the item's clock settles the same way.
    private var hopSmoothed: [Float]
    private var hopRelease: Float = 0.97
    private var kept = false
    private static let releaseTime = 0.43
    private var historyHead = 0
    private var historyCount = 0
    private var historyRate: Double = 44100
    /// When `snapshot(at:)` or `bands(at:after:)` was last called (uptime, ns; 0 never); the hops are analysed only
    /// while it has been in the last second, so the analyser costs nothing more when no one looks.
    private var lastRequest: UInt64 = 0
    private static let requestWindow: UInt64 = 1_000_000_000
    /// Where the next block should start; one starting elsewhere is a seek.
    private var nextSample: Int64?

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
        raw = [Float](repeating: 0, count: bandCount)
        historyCapacity = Self.historyCapacity(sampleRate: 44100, hop: fftSize / 4)
        history = [Float](repeating: 0, count: historyCapacity * bandCount)
        historySmoothed = [Float](repeating: 0, count: historyCapacity * bandCount)
        historyEnergies = [Float](repeating: 0, count: historyCapacity * 4)
        hopSmoothed = [Float](repeating: 0, count: bandCount)
        historyStamps = [Int64](repeating: 0, count: historyCapacity)
        latest = Snapshot(bands: Array(repeating: 0, count: bandCount), low: 0, mid: 0, high: 0, overall: 0)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        computeBandEdges()
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    public func prepare(format: ProcessingFormat) {
        sampleRate = format.sampleRate
        hopRelease = Float(exp(-Double(fftSize / 4) / sampleRate / Self.releaseTime))
        let capacity = Self.historyCapacity(sampleRate: sampleRate, hop: fftSize / 4)
        if capacity != historyCapacity {
            lock.lock()
            historyCapacity = capacity
            history = [Float](repeating: 0, count: capacity * bandCount)
            historySmoothed = [Float](repeating: 0, count: capacity * bandCount)
            historyEnergies = [Float](repeating: 0, count: capacity * 4)
            historyStamps = [Int64](repeating: 0, count: capacity)
            historyHead = 0
            historyCount = 0
            lock.unlock()
        }
        computeBandEdges()
        reset()
    }

    private static func historyCapacity(sampleRate: Double, hop: Int) -> Int {
        Int((historySeconds * sampleRate / Double(hop)).rounded(.up))
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
        process(buffers, frameCount: frameCount, sampleIndex: nil)
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, sampleIndex: Int64?) {
        guard frameCount > 0, fftSetup != nil else { return }
        let channels = buffers.count
        guard channels > 0 else { return }
        lock.lock()
        let keeps = sampleIndex != nil && lastRequest > 0 && DispatchTime.now().uptimeNanoseconds - lastRequest < Self.requestWindow
        if let sampleIndex, let expected = nextSample, sampleIndex != expected { historyCount = 0 }
        lock.unlock()
        nextSample = sampleIndex.map { $0 + Int64(frameCount) }
        // Picking up from the blocks' smoothing, not from wherever it was when last kept.
        if keeps, !kept { for b in 0..<bandCount { hopSmoothed[b] = smoothed[b] } }
        kept = keeps
        let hop = fftSize / 4
        var analysed = false
        var done = 0
        while done < frameCount {
            // Up to the next hop when keeping them all, else the whole block (one analysis at
            // its end, as before anyone asked).
            let run = keeps ? min(frameCount - done, max(hop - framesSinceFFT, 1)) : frameCount - done
            for frame in done..<done + run {
                var sum: Float = 0
                for channel in 0..<channels {
                    guard let data = buffers[channel].mData else { continue }
                    sum += data.assumingMemoryBound(to: Float.self)[frame]
                }
                ring[ringHead] = sum / Float(channels)
                ringHead = (ringHead + 1) % fftSize
            }
            done += run
            framesSinceFFT += run
            guard framesSinceFFT >= hop else { continue }
            framesSinceFFT = 0
            analyse()
            analysed = true
            if keeps, let sampleIndex { keep(centredOn: sampleIndex + Int64(done) - Int64(fftSize / 2)) }
        }
        if analysed { publish() }
    }

    /// The bands of the `fftSize` samples up to `ringHead` into `raw`.
    private func analyse() {
        guard let fftSetup else { return }
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
        for b in 0..<bandCount {
            let lo = bandEdges[b], hi = max(lo + 1, bandEdges[b + 1])
            var power: Float = 0
            for i in lo..<hi { power += magnitudes[i] }
            power = power / Float(hi - lo) * norm
            let db = 10 * log10(max(power, 1e-12))
            raw[b] = min(1, max(0, (db + 66) / 66))
        }
    }

    private func keep(centredOn sample: Int64) {
        for b in 0..<bandCount {
            let value = raw[b]
            hopSmoothed[b] = value > hopSmoothed[b] ? value : hopSmoothed[b] * hopRelease + value * (1 - hopRelease)
        }
        let (low, mid, high, overall) = Self.energies(hopSmoothed)
        lock.lock()
        let row = historyHead * bandCount
        for b in 0..<bandCount {
            history[row + b] = raw[b]
            historySmoothed[row + b] = hopSmoothed[b]
        }
        let energies = historyHead * 4
        historyEnergies[energies] = low
        historyEnergies[energies + 1] = mid
        historyEnergies[energies + 2] = high
        historyEnergies[energies + 3] = overall
        historyStamps[historyHead] = sample
        historyHead = (historyHead + 1) % historyCapacity
        historyCount = min(historyCount + 1, historyCapacity)
        lock.unlock()
    }

    /// The latest analysis, smoothed, as `snapshot()`.
    private func publish() {
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let value = raw[b]
            smoothed[b] = value > smoothed[b] ? value : smoothed[b] * 0.82 + value * 0.18
            bands[b] = smoothed[b]
        }
        let (low, mid, high, overall) = Self.energies(bands)
        lock.lock()
        latest = Snapshot(bands: bands, low: low, mid: mid, high: high, overall: overall)
        lock.unlock()
    }

    /// The averages of 40–250 Hz, 250–2000 Hz and 2–8 kHz (roughly), and the overall level.
    private static func energies(_ bands: [Float]) -> (low: Float, mid: Float, high: Float, overall: Float) {
        func average(_ range: Range<Int>) -> Float {
            guard !range.isEmpty else { return 0 }
            var sum: Float = 0
            for b in range { sum += bands[b] }
            return sum / Float(range.count)
        }
        let n = bands.count
        let low = average(0..<max(1, n * 30 / 100))
        let mid = average(max(1, n * 30 / 100)..<max(2, n * 63 / 100))
        let high = average(max(2, n * 63 / 100)..<n)
        return (low, mid, high, low * 0.5 + mid * 0.35 + high * 0.15)
    }

    public func reset() {
        ringHead = 0
        framesSinceFFT = 0
        nextSample = nil
        for i in ring.indices { ring[i] = 0 }
        for i in smoothed.indices { smoothed[i] = 0 }
        lock.lock()
        latest = Snapshot(bands: Array(repeating: 0, count: bandCount), low: 0, mid: 0, high: 0, overall: 0)
        historyCount = 0
        historyRate = sampleRate
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// `snapshot()` for what plays at `time` (seconds on the item's timeline): the kept hop by
    /// then, smoothed; its bands only if `includesBands` (the energies alone copy nothing big).
    /// Nil when nothing analysed is that recent (just asked for, after a seek, stalled).
    public func snapshot(at time: TimeInterval, includesBands: Bool = true) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        lastRequest = DispatchTime.now().uptimeNanoseconds
        guard let slot = newestSlot(atOrBefore: time) else { return nil }
        let row = slot * bandCount, energies = slot * 4
        return Snapshot(bands: includesBands ? Array(historySmoothed[row..<row + bandCount]) : [],
                        low: historyEnergies[energies], mid: historyEnergies[energies + 1],
                        high: historyEnergies[energies + 2], overall: historyEnergies[energies + 3])
    }

    /// The bands of what plays at `time` (seconds on the item's timeline), unsmoothed: each the
    /// loudest of the analyses centred after `after` (the previous call's time) and by `time`,
    /// so a beat between two calls still shows; with none there, the latest by `time`. Empty
    /// when nothing analysed is that recent.
    public func bands(at time: TimeInterval, after: TimeInterval? = nil) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        lastRequest = DispatchTime.now().uptimeNanoseconds
        if let after {
            let target = Int64((time * historyRate).rounded())
            let since = Int64((after * historyRate).rounded())
            var loudest: [Float] = []
            for age in 0..<historyCount {
                let slot = (historyHead - 1 - age + historyCapacity) % historyCapacity
                let stamp = historyStamps[slot]
                guard stamp <= target, stamp > since else { continue }
                let row = slot * bandCount
                if loudest.isEmpty { loudest = Array(history[row..<row + bandCount]) } else {
                    for b in 0..<bandCount { loudest[b] = max(loudest[b], history[row + b]) }
                }
            }
            if !loudest.isEmpty { return loudest }
        }
        guard let slot = newestSlot(atOrBefore: time) else { return [] }
        let row = slot * bandCount
        return Array(history[row..<row + bandCount])
    }

    /// The kept analysis centred latest by `time`, unless it is older than `stale`. Under `lock`.
    private func newestSlot(atOrBefore time: TimeInterval) -> Int? {
        let target = Int64((time * historyRate).rounded())
        var newest: (slot: Int, stamp: Int64)?
        for age in 0..<historyCount {
            let slot = (historyHead - 1 - age + historyCapacity) % historyCapacity
            let stamp = historyStamps[slot]
            guard stamp <= target, newest.map({ stamp > $0.stamp }) ?? true else { continue }
            newest = (slot, stamp)
        }
        guard let newest, Double(target - newest.stamp) / historyRate < Self.stale else { return nil }
        return newest.slot
    }

    /// How far behind the time asked for an analysis may be and still stand for it.
    private static let stale: TimeInterval = 0.2
}
