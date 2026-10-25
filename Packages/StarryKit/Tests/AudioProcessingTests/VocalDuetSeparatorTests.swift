import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalDuetSeparatorTests {
    @Test func centeredSpectraRoundTripEdgesAndPreserveFFTScale() throws {
        let count = 2400
        let transform = try DuetSpectrum(sampleCount: count)
        var samples = (0..<count).map { Float(0.3 * sin(2 * .pi * 17 * Double($0) / 960)) }
        let pure = try transform.encode(samples)
        // Frame 2 starts at sample zero. Periodic Hann splits this bin into its
        // center and immediate neighbors; the FFT is not normalized.
        #expect(abs(pure[17 * transform.frames + 2]) < 0.001)
        #expect(abs(pure[(481 + 17) * transform.frames + 2] + 72) < 0.001)
        samples[0] += 0.5
        samples[count - 1] -= 0.4
        let spectrum = try transform.encode(samples)
        let reconstructed = try spectrum.withUnsafeBufferPointer {
            try transform.decode($0.baseAddress!, realOffset: 0, imaginaryOffset: 481 * transform.frames,
                                 binStride: transform.frames, frameStride: 1)
        }
        #expect(zip(samples, reconstructed).allSatisfy { abs($0 - $1) < 0.00002 })
    }

    @Test func swappedVoicesAreAlignedWithoutPromotingQuietLeakage() {
        let a = (0..<1000).map { Float(0.3 * sin(Double($0) * 0.07)) }
        let b = (0..<1000).map { Float(0.01 * sin(Double($0) * 0.13)) }
        let match = DuetOverlap.match(previous: [a,b], current: [b,a])
        #expect(match.swap && !match.uncertain)
        let silence = [[Float]](repeating: [Float](repeating: 0, count: 1000), count: 2)
        #expect(DuetOverlap.match(previous: silence, current: silence).uncertain)
    }

    @Test func crossfadeKeepsIdenticalAudioAndLeavesLaterSamplesUntouched() {
        let a = (0..<1000).map { Float(sin(Double($0) * 0.07)) }
        let b = a.map { $0 * 0.25 }
        var incoming = [a + [0.7,0.8], b + [0.1,0.2]]
        DuetOverlap.blend(previous: [a,b], into: &incoming)
        #expect(zip(a,incoming[0]).allSatisfy { abs($0-$1) < 1e-6 })
        #expect(Array(incoming[0].suffix(2)) == [0.7,0.8])
        #expect(Array(incoming[1].suffix(2)) == [0.1,0.2])
    }

    @Test(arguments: [44_100.0, 48_000.0, 24_000.0])
    func resamplingPreservesAudioTimeAndAveragesStereo(rate: Double) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.caf"), result = folder.appendingPathComponent("mono.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                let t = Double(i)/rate
                let value = t >= 0.5 && t < 0.8 ? Float(sin(2 * .pi * 700 * t)) : 0
                buffer.floatChannelData![0][i] = value * 0.3
                buffer.floatChannelData![1][i] = value * 0.1
            }
            try file.write(from: buffer)
        }
        try DuetPCM.convert(source, to: result, sampleRate: 24000)
        let file = try AVAudioFile(forReading: result)
        #expect(file.length == 24000)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24000)!
        try file.read(into: buffer)
        let values = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let first = try #require(values.firstIndex { abs($0) > 0.02 })
        #expect(abs(Double(first)/24000 - 0.5) < 0.002)
        let rms = sqrt(values[13200..<15600].reduce(0.0) { $0 + Double($1*$1) } / 2400)
        #expect(abs(rms - 0.2/sqrt(2)) < 0.003)
    }

    @Test func cancellationStopsBeforeOpeningAudioOrCompilingTheModel() async {
        let stopped = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await VocalDuetSeparator().separate(file: URL(fileURLWithPath: "/missing.caf"),
                    first: URL(fileURLWithPath: "/missing-a.caf"), second: URL(fileURLWithPath: "/missing-b.caf"),
                    model: URL(fileURLWithPath: "/missing.mlpackage"))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(stopped)
    }
}
