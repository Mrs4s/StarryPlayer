import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalOnsetDetectorTests {
    private func analyze(seconds: Double, rate: Double = 44_100, signal: (Double) -> Float) throws -> [VocalOnset] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocal-onsets-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = signal(Double(i) / rate) }
            try file.write(from: buffer)
        }
        return try VocalOnsetDetector.analyze(file: url)
    }

    private func pulse(_ t: Double, start: Double, frequency: Double = 700, amplitude: Double = 0.3) -> Float {
        let elapsed = t - start
        guard elapsed >= 0, elapsed < 0.35 else { return 0 }
        let envelope = min(elapsed / 0.015, 1) * min((0.35 - elapsed) / 0.06, 1)
        return Float(amplitude * envelope * sin(2 * .pi * frequency * t))
    }

    // Deterministic, noise-like energy above the old 5 kHz cutoff. Multiple carriers
    // exercise fluctuations within a fricative, rather than just a high sine wave.
    private func frication(_ t: Double, start: Double, duration: Double = 0.16, amplitude: Double = 0.015) -> Float {
        let elapsed = t - start
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let envelope = min(elapsed / 0.025, 1) * min((duration - elapsed) / 0.015, 1)
        let noise = (0..<24).reduce(0.0) { value, i in
            let frequency = 5500 + Double((i * 1777) % 5000)
            return value + sin(2 * .pi * frequency * t + Double(i * i))
        } / sqrt(12)
        return Float(amplitude * envelope * noise)
    }

    @Test func silenceHasNoSuggestions() throws {
        #expect(try analyze(seconds: 1) { _ in 0 }.isEmpty)
    }

    @Test func rangeAnalysisKeepsAbsoluteTimesAndActivityForPhraseEndings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocal-range-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 5)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let time = Double(i) / 44_100
            buffer.floatChannelData![0][i] = pulse(time, start: 0.5) + pulse(time, start: 3)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let result = try VocalOnsetDetector.analysis(file: url, range: 2.8...4)
        #expect(result.onsets.contains { abs($0.time - 3) < 0.045 })
        #expect(!result.onsets.contains { abs($0.time - 0.5) < 0.1 })
        #expect(result.activity.valid[310])
        #expect(!result.activity.valid[50])
        #expect(result.activity.energy[310] > result.activity.energy[390] + 20)
    }

    @Test func boundaryActivityIncludesAQuietConsonantBeforeItsVowel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocal-consonant-activity-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                let time = Double(i) / 44_100
                buffer.floatChannelData![0][i] = frication(time, start: 0.5, amplitude: 0.008) + pulse(time, start: 0.65)
            }
            try file.write(from: buffer)
        }
        let result = try VocalOnsetDetector.analysis(file: url)
        #expect(result.activity.boundaryEnergy[54] > result.activity.energy[54] + 15)
        #expect(result.onsets.contains { abs($0.time - 0.5) < 0.045 })
    }

    @Test(arguments: [22_050.0, 44_100.0, 48_000.0, 96_000.0])
    func isolatedAttacksKeepTheirAudioTimesAcrossSampleRates(rate: Double) throws {
        let starts = [0.5, 1.2, 2.0]
        let result = try analyze(seconds: 3, rate: rate) { t in
            starts.reduce(0) { $0 + pulse(t, start: $1) }
        }
        #expect(result.count == starts.count, "\(result)")
        for start in starts { #expect(result.contains { abs($0.time - start) < 0.045 }, "\(result)") }
        #expect(result.allSatisfy { $0.strength >= 0.5 && $0.strength <= 1 })
    }

    @Test func quietAttacksAndChunkBoundariesAreNotLostOrDuplicated() throws {
        let starts = [0.5, 9.5, 9.95, 10.1, 11.2]
        let result = try analyze(seconds: 12) { t in
            starts.reduce(0) { $0 + pulse(t, start: $1, frequency: $1 == 10.1 ? 1300 : 700, amplitude: $1 < 1 ? 0.3 : 0.025) }
        }
        for start in starts { #expect(result.filter { abs($0.time - start) < 0.045 }.count == 1, "\(result)") }
    }

    @Test func vibratoDoesNotMarkEveryPitchOscillationAsANewSyllable() throws {
        let result = try analyze(seconds: 3) { t in
            guard t >= 0.5 else { return 0 }
            let envelope = min((t - 0.5) / 0.02, 1)
            // +/- 20 Hz at 700 Hz, 6 cycles per second, with a second harmonic.
            let phase = 2 * Double.pi * 700 * t - 20.0 / 6 * cos(2 * .pi * 6 * t)
            return Float(envelope * (0.3 * sin(phase) + 0.1 * sin(2 * phase)))
        }
        let prominent = result.filter { $0.strength >= VocalOnsetDetector.Sensitivity.medium.minimumStrength }
        #expect(prominent.contains { abs($0.time - 0.5) < 0.045 }, "\(result)")
        #expect(prominent.filter { $0.time > 0.65 }.isEmpty, "\(result)")
    }

    @Test func closePeaksMergeAndInvalidFramesCannotBecomeHints() {
        var activity = VocalActivity(frameCount: 100)
        activity.energy = .init(repeating: 10, count: 100)
        activity.valid = .init(repeating: true, count: 100)
        activity.flux[20] = 1
        activity.flux[25] = 2
        activity.flux[60] = 3
        for i in 57...63 { activity.valid[i] = false }
        let result = VocalOnsetDetector.candidates(in: activity, frameDuration: 0.01, centerOffset: 0.02, duration: 1)
        #expect(result.count == 1)
        #expect(abs((result.first?.time ?? 0) - 0.26) < 0.001)
    }

    @Test func spectralChangesCanSuggestABoundaryWithoutASilentGap() throws {
        let result = try analyze(seconds: 2) { t in
            guard t >= 0.2 else { return 0 }
            let frequency = t < 1 ? 700.0 : 1300.0
            return Float(0.3 * min((t - 0.2) / 0.02, 1) * sin(2 * .pi * frequency * t))
        }
        #expect(result.contains { abs($0.time - 1) < 0.045 }, "\(result)")
    }

    @Test func spectralShapeCanReinforceAQuietBoundaryWithoutAnEnergyGap() {
        var activity = VocalActivity(frameCount: 150)
        activity.energy = .init(repeating: 10, count: 150)
        activity.valid = .init(repeating: true, count: 150)
        activity.flux[30] = 1
        activity.flux[100] = 0.05
        activity.shapeFlux[30] = 1
        activity.shapeFlux[100] = 1
        let result = VocalOnsetDetector.candidates(in: activity, frameDuration: 0.01, centerOffset: 0.02, duration: 1.5)
        let prominent = result.filter { $0.strength >= VocalOnsetDetector.Sensitivity.medium.minimumStrength }
        #expect(prominent.contains { abs($0.time - 1.01) < 0.02 }, "\(result)")
    }

    @Test func invalidShapeMeasurementsDoNotHideAnOtherwiseValidAttack() {
        var activity = VocalActivity(frameCount: 150)
        activity.energy = .init(repeating: 10, count: 150)
        activity.valid = .init(repeating: true, count: 150)
        for frame in [30, 100] {
            activity.flux[frame] = 1
            activity.shapeFlux[frame] = 1
        }
        activity.shapeFlux[100] = .nan
        let result = VocalOnsetDetector.candidates(in: activity, frameDuration: 0.01, centerOffset: 0.02, duration: 1.5)
        #expect(result.contains { abs($0.time - 1.01) < 0.02 }, "\(result)")
        #expect(result.allSatisfy { $0.strength.isFinite })
    }

    @Test(arguments: [44_100.0, 48_000.0], [0.09, 0.12])
    func consonantMergingPreservesTheNextVowelAttack(rate: Double, interval: Double) throws {
        let secondStart = 0.58 + interval
        let result = try analyze(seconds: 1.2, rate: rate) { t in
            let consonant = frication(t, start: 0.5, duration: 0.24, amplitude: 0.008)
            let first = pulse(t, start: 0.58, frequency: 700)
            let second = pulse(t, start: secondStart, frequency: 1900)
            return consonant + first + second
        }
        let prominent = result.filter { $0.strength >= VocalOnsetDetector.Sensitivity.medium.minimumStrength }
        for start in [0.5, secondStart] {
            #expect(prominent.contains { abs($0.time - start) < 0.045 }, "\(result)")
        }
        #expect(!prominent.contains { abs($0.time - 0.58) < 0.03 }, "\(result)")
    }

    @Test func aSustainedHarmonicVowelWithVibratoDoesNotProduceRepeatedHints() throws {
        let fundamental = 220.0
        var harmonics: [(Double, Double)] = (1...20).map { index in
            let frequency = fundamental * Double(index)
            let first = exp(-0.5 * pow((frequency - 650) / 150, 2))
            let second = 0.5 * exp(-0.5 * pow((frequency - 1500) / 250, 2))
            return (Double(index), (0.2 + first + second) / Double(index))
        }
        let level = sqrt(harmonics.reduce(0) { $0 + $1.1 * $1.1 })
        harmonics = harmonics.map { ($0.0, $0.1 * 0.25 / level) }
        let result = try analyze(seconds: 3) { t in
            guard t >= 0.5 else { return 0 }
            let phase = 2 * Double.pi * fundamental * t - fundamental * 0.02 / 6 * cos(2 * .pi * 6 * t)
            let envelope = min((t - 0.5) / 0.02, 1)
            return Float(envelope * harmonics.reduce(0) { $0 + $1.1 * sin($1.0 * phase) })
        }
        let prominent = result.filter { $0.strength >= VocalOnsetDetector.Sensitivity.medium.minimumStrength }
        #expect(prominent.count == 1, "\(result)")
        #expect(prominent.contains { abs($0.time - 0.5) < 0.045 }, "\(result)")
    }

    @Test func distinctAttacksOneHundredMillisecondsApartStaySeparate() throws {
        let starts = [0.5, 0.6, 0.7]
        let result = try analyze(seconds: 1.2) { t in
            starts.enumerated().reduce(0) { value, entry in
                let elapsed = t - entry.element
                guard elapsed >= 0, elapsed < 0.06 else { return value }
                let envelope = min(elapsed / 0.005, 1) * min((0.06 - elapsed) / 0.01, 1)
                return value + Float(0.3 * envelope * sin(2 * .pi * (700 + Double(entry.offset) * 600) * t))
            }
        }
        let prominent = result.filter { $0.strength >= VocalOnsetDetector.Sensitivity.medium.minimumStrength }
        for start in starts { #expect(prominent.contains { abs($0.time - start) < 0.035 }, "\(result)") }
    }

    @Test(arguments: [22_050.0, 44_100.0, 48_000.0, 96_000.0])
    func unvoicedFricativesHaveHintsWithoutAVowel(rate: Double) throws {
        let result = try analyze(seconds: 1, rate: rate) { frication($0, start: 0.5) }
        let prominent = result.filter { $0.strength >= VocalOnsetDetector.Sensitivity.medium.minimumStrength }
        #expect(prominent.count == 1, "\(result)")
        #expect(prominent.contains { abs($0.time - 0.5) < 0.045 }, "\(result)")
    }

    @Test(arguments: [0.05, 0.12, 0.18])
    func consonantAndLouderVowelShareTheEarlierHint(consonantDuration: Double) throws {
        let result = try analyze(seconds: 1.2) { t in
            frication(t, start: 0.5, duration: consonantDuration, amplitude: 0.008)
                + pulse(t, start: 0.5 + consonantDuration - 0.01)
        }
        #expect(result.count == 1, "\(result)")
        #expect(result.contains { abs($0.time - 0.5) < 0.045 }, "\(result)")
        #expect(result.first.map { $0.strength >= VocalOnsetDetector.Sensitivity.medium.minimumStrength } == true)
    }

    @Test func sustainedFricationAndItsFadeDoNotProduceRepeatedHints() throws {
        let result = try analyze(seconds: 2) { t in
            let fade = max(0, min(1, (1.8 - t) / 0.5))
            return frication(t, start: 0.2, duration: 1.6) * Float(fade)
        }
        #expect(result.count == 1, "\(result)")
        #expect(result.contains { abs($0.time - 0.2) < 0.045 }, "\(result)")
    }

    @Test func separateFricativesAndVowelsAcrossAGapStaySeparate() throws {
        let result = try analyze(seconds: 1.4) { t in
            frication(t, start: 0.5, duration: 0.06) + pulse(t, start: 0.68)
        }
        #expect(result.count == 2, "\(result)")
        for start in [0.5, 0.68] { #expect(result.contains { abs($0.time - start) < 0.045 }, "\(result)") }
    }

    @Test func fricativesNearTheBeginningAndChunkBoundaryKeepTheirTimes() throws {
        let starts = [0.08, 9.98, 10.3]
        let result = try analyze(seconds: 11) { t in
            starts.reduce(0) { $0 + frication(t, start: $1) }
        }
        #expect(result.count == starts.count, "\(result)")
        for start in starts { #expect(result.contains { abs($0.time - start) < 0.045 }, "\(result)") }
    }

    @Test func fricativeAfterAVowelWithUpperHarmonicsKeepsTheConsonantStart() throws {
        let result = try analyze(seconds: 1.2) { t in
            pulse(t, start: 0.2) + pulse(t, start: 0.2, frequency: 8000, amplitude: 0.04)
                + frication(t, start: 0.5, amplitude: 0.015) + pulse(t, start: 0.65)
        }
        #expect(result.count == 2, "\(result)")
        for start in [0.2, 0.5] { #expect(result.contains { abs($0.time - start) < 0.045 }, "\(result)") }
    }

    @Test func lowLevelHighFrequencyResidueDoesNotBecomeAProminentHint() throws {
        let result = try analyze(seconds: 1) { frication($0, start: 0.5, amplitude: 0.00001) }
        #expect(result.isEmpty, "\(result)")
    }

    @Test func cancellationStopsBeforeOpeningTheAudio() async {
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try VocalOnsetDetector.analyze(file: URL(fileURLWithPath: "/missing-audio.caf"))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(cancelled)
    }
}
