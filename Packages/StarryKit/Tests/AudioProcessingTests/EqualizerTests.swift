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
}
