import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite struct EqualizerTests {

    @Test func filterGainsPassThroughTheSliders() {
        for preset in EqualizerPreset.all {
            let filter = EqualizerResponse.filterGains(for: preset.gains)
            let response = EqualizerResponse.response(filterGains: filter, at: EqualizerBands.frequencies)
            for (band, gain) in preset.gains.enumerated() {
                #expect(abs(response[band] - gain) < 0.1, "\(preset.name) \(EqualizerBands.labels[band]): \(response[band]) vs \(gain)")
            }
        }
    }

    /// Ten bands at +6 dB lift everything by about 6 dB, not the 11 dB the overlapping filters
    /// would add up to on their own.
    @Test func allBandsUpIsAnEvenLift() {
        let gains = Array(repeating: 6.0, count: EqualizerBands.count)
        let naive = EqualizerResponse.response(filterGains: gains, at: [1000])[0]
        #expect(naive > 9)
        let filter = EqualizerResponse.filterGains(for: gains)
        // Between the centres from 64 Hz to 8 kHz (outside them the curve returns to 0 dB).
        let between = (1..<7).map { sqrt(EqualizerBands.frequencies[$0] * EqualizerBands.frequencies[$0 + 1]) }
        for value in EqualizerResponse.response(filterGains: filter, at: between + [1000]) {
            #expect(abs(value - 6) < 0.4, "\(value)")
        }
    }

    @Test func flatNeedsNoFilters() {
        #expect(EqualizerResponse.filterGains(for: EqualizerPreset.flat.gains) == EqualizerPreset.flat.gains)
    }

    @Test func movingASliderMakesTheCurveCustom() {
        var settings = EqualizerSettings()
        settings.select(EqualizerPreset.preset(id: "rock")!)
        settings.setGain(20, at: 3)
        #expect(settings.presetID == EqualizerPreset.customID)
        #expect(settings.gains[3] == 12)
        #expect(settings.customGains == settings.gains)
        settings.select(.flat)
        settings.selectCustom()
        #expect(settings.gains[3] == 12)
        settings.reset()
        #expect(settings.isFlat && settings.presetID == "flat")
        #expect(settings.customGains[3] == 12)
    }

    @Test func decodingToleratesOldOrBrokenValues() throws {
        let json = #"{"isEnabled":true,"presetID":"gone","gains":[1,2],"preamp":40}"#
        let settings = try JSONDecoder().decode(EqualizerSettings.self, from: Data(json.utf8))
        #expect(settings.isEnabled)
        #expect(settings.presetID == EqualizerPreset.customID)
        #expect(settings.gains == EqualizerPreset.flat.gains)
        #expect(settings.preamp == 12)
        #expect(settings.clipGuard)
    }

    @Test func offIsBitExact() {
        let processor = Self.processor(EqualizerControl())
        let input = Self.sine(frequency: 440, amplitude: 0.5, frames: 4096)
        #expect(Self.run(processor, input) == input)
    }

    @Test func outputFollowsTheCurve() {
        var settings = EqualizerSettings()
        settings.isEnabled = true
        settings.select(EqualizerPreset.preset(id: "rock")!)
        let filter = EqualizerResponse.filterGains(for: settings.gains)
        for frequency in [1000.0, 100, 6000] {
            let processor = Self.processor(Self.control(settings))
            let input = Self.sine(frequency: frequency, amplitude: 0.1, frames: 44100)
            let output = Self.run(processor, input)
            let measured = 20 * log10(Self.rms(output.suffix(8192)) / Self.rms(input.suffix(8192)))
            let expected = EqualizerResponse.response(filterGains: filter, at: [frequency], sampleRate: Self.sampleRate)[0]
            #expect(abs(measured - expected) < 0.1, "\(frequency) Hz: \(measured) vs \(expected)")
        }
    }

    @Test func switchingOffReturnsToBypass() {
        var settings = EqualizerSettings()
        settings.isEnabled = true
        settings.select(EqualizerPreset.preset(id: "bassBoost")!)
        settings.preamp = -3
        let control = Self.control(settings)
        let processor = Self.processor(control)
        let input = Self.sine(frequency: 64, amplitude: 0.3, frames: 8192)
        #expect(Self.run(processor, input) != input)
        control.update { $0.enabled = false }
        _ = Self.run(processor, Self.sine(frequency: 64, amplitude: 0.3, frames: 44100))
        #expect(Self.run(processor, input) == input)
    }

    @Test func clipGuardHoldsPeaks() {
        var settings = EqualizerSettings()
        settings.isEnabled = true
        settings.preamp = 12
        let input = Self.sine(frequency: 440, amplitude: 0.9, frames: 16384)
        for guarded in [true, false] {
            settings.clipGuard = guarded
            let peak = Self.run(Self.processor(Self.control(settings)), input).map(abs).max() ?? 0
            if guarded {
                #expect(peak <= 1.0001)
                #expect(peak > 0.95)
            } else {
                #expect(peak > 3)
            }
        }
    }

    static let sampleRate = 44100.0

    static func sine(frequency: Double, amplitude: Float, frames: Int) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    static func control(_ settings: EqualizerSettings) -> EqualizerControl {
        let control = EqualizerControl()
        let state = EqualizerControl.state(for: settings)
        control.update { $0 = state }
        return control
    }

    static func processor(_ control: EqualizerControl) -> EqualizerProcessor {
        let processor = EqualizerProcessor(control: control)
        processor.prepare(format: ProcessingFormat(sampleRate: sampleRate, channelCount: 2, maxFrames: 4096))
        return processor
    }

    static func run(_ processor: EqualizerProcessor, _ input: [Float]) -> [Float] {
        let frames = input.count
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer {
            left.deallocate()
            right.deallocate()
            list.unsafeMutablePointer.deallocate()
        }
        var output = input
        input.withUnsafeBufferPointer { source in
            for chunk in stride(from: 0, to: frames, by: 512) {
                let count = min(512, frames - chunk)
                left.update(from: source.baseAddress! + chunk, count: count)
                right.update(from: left, count: count)
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: left)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: right)
                processor.process(list, frameCount: count)
                for i in 0..<count { output[chunk + i] = left[i] }
            }
        }
        return output
    }
}
