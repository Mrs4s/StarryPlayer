import AVFoundation
import Foundation
import Testing
@testable import AudioProcessing

@Suite struct ParametricEqualizerTests {

    // MARK: Filters

    @Test func filterShapesFollowTheCookbook() {
        func db(_ filter: ParametricFilter, _ frequency: Double, gain: Double = 0, q: Double = 1 / 2.0.squareRoot(), at probe: Double) -> Double {
            ResponseSampler(frequencies: [probe]).response(bands: [ParametricBand(slot: 0, filter: filter, frequency: frequency, gain: gain, q: q)])[0]
        }
        #expect(abs(db(.peak, 1000, gain: 6, q: 2, at: 1000) - 6) < 0.01)
        #expect(abs(db(.peak, 1000, gain: 6, q: 2, at: 100)) < 0.2)
        #expect(abs(db(.lowShelf, 200, gain: 6, at: 20) - 6) < 0.1)
        #expect(abs(db(.lowShelf, 200, gain: 6, at: 5000)) < 0.1)
        #expect(abs(db(.lowShelf, 200, gain: 6, at: 200) - 3) < 0.1)
        #expect(abs(db(.highShelf, 5000, gain: -6, at: 20000) + 6) < 0.3)
        #expect(abs(db(.highShelf, 5000, gain: -6, at: 100)) < 0.1)
        #expect(abs(db(.lowPass, 1000, at: 1000) + 3.01) < 0.05)
        #expect(db(.lowPass, 1000, at: 8000) < -30)
        #expect(abs(db(.highPass, 100, at: 100) + 3.01) < 0.05)
        #expect(db(.highPass, 100, at: 20) < -25)
        #expect(abs(db(.bandPass, 1000, q: 2, at: 1000)) < 0.01)
        #expect(db(.notch, 1000, q: 5, at: 1000) < -60)
        for probe in [50.0, 1000, 12000] { #expect(abs(db(.allPass, 1000, at: probe)) < 0.001) }
    }

    @Test func aBandAtZeroDecibelsOrOffChangesNothing() {
        let sampler = ResponseSampler(frequencies: [100, 1000, 10000])
        #expect(sampler.response(bands: [ParametricBand(slot: 0, frequency: 1000, gain: 0)]) == [0, 0, 0])
        #expect(sampler.response(bands: [ParametricBand(slot: 0, filter: .lowPass, frequency: 1000, isOn: false)]) == [0, 0, 0])
    }

    // MARK: Settings

    @Test func switchingToParametricKeepsTheTenBandSound() {
        var settings = EqualizerSettings()
        settings.select(EqualizerPreset.preset(id: "rock")!)
        settings.setPreamp(-3)
        let probes = (0...60).map { 20 * pow(1000, Double($0) / 60) }
        let graphic = ResponseSampler(frequencies: probes).response(filterGains: EqualizerResponse.filterGains(for: settings.gains))
        settings.setMode(.parametric)
        #expect(settings.mode == .parametric)
        #expect(settings.bands.count == 10)
        #expect(settings.parametricPreamp == -3)
        let parametric = ResponseSampler(frequencies: probes).response(bands: settings.bands)
        for (a, b) in zip(graphic, parametric) { #expect(abs(a - b) < 1e-9) }

        // Back and forth keeps each mode's own settings.
        settings.setMode(.graphic)
        settings.select(.flat)
        settings.setMode(.parametric)
        #expect(settings.bands.count == 10)
    }

    @Test func flatTenBandsStartParametricEmpty() {
        var settings = EqualizerSettings()
        settings.setMode(.parametric)
        #expect(settings.bands.isEmpty)
        #expect(settings.isFlat)
        #expect(settings.presetName == "参数均衡")
    }

    @Test func bandsKeepTheirSlots() {
        var settings = EqualizerSettings()
        settings.setMode(.parametric)
        let first = settings.addBand(ParametricBand(slot: 9, frequency: 100, gain: 3))
        let second = settings.addBand(ParametricBand(slot: 9, frequency: 1000, gain: -3))
        #expect(first == 0 && second == 1)
        settings.removeBand(slot: 0)
        let third = settings.addBand(ParametricBand(slot: 0, filter: .highShelf, frequency: 8000, gain: 2))
        #expect(third == 0)
        #expect(settings.band(slot: 1)?.frequency == 1000)
        for _ in 0..<20 { settings.addBand(ParametricBand(slot: 0, frequency: 500)) }
        #expect(settings.bands.count == ParametricEqualizer.maxBands)
        #expect(settings.addBand(ParametricBand(slot: 0, frequency: 500)) == nil)

        settings.updateBand(slot: 1) {
            $0.gain = 99
            $0.q = 0
            $0.slot = 7
        }
        #expect(settings.band(slot: 1)?.gain == ParametricEqualizer.gainRange.upperBound)
        #expect(settings.band(slot: 1)?.q == ParametricEqualizer.qRange.lowerBound)
    }

    @Test func presetsAndPreampFollowTheMode() {
        var settings = EqualizerSettings()
        settings.setParametric(EqualizerAPOText.parse("Preamp: -6.4 dB\nFilter 1: ON PK Fc 100 Hz Gain 6 dB Q 1"), name: "HD 600")
        #expect(settings.mode == .parametric)
        #expect(settings.presetName == "HD 600")
        #expect(settings.activePreamp == -6.4)
        settings.setPreamp(-2)
        #expect(settings.parametricPreamp == -2 && settings.preamp == 0)
        settings.select(EqualizerPreset.preset(id: "pop")!)
        #expect(settings.mode == .graphic)
        #expect(settings.activePreamp == 0)
        settings.setMode(.parametric)
        settings.reset()
        #expect(settings.bands.isEmpty && settings.parametricPreamp == 0 && settings.parametricName.isEmpty)
        #expect(settings.gains == EqualizerPreset.preset(id: "pop")!.gains)
    }

    @Test func peakGainIsTheCurvesTop() {
        var settings = EqualizerSettings()
        settings.setParametric(EqualizerAPOText.parse("Filter: ON PK Fc 3000 Hz Gain 5 dB Q 8\nFilter: ON LSC Fc 100 Hz Gain -4 dB Q 0.7"), name: "")
        #expect(abs(settings.peakGain - 5) < 0.05)
        settings.updateBand(slot: 0) { $0.gain = -5 }
        #expect(settings.peakGain < 0.01)
    }

    @Test func decodingKeepsOldSettingsAndSkipsBrokenBands() throws {
        let old = #"{"isEnabled":true,"presetID":"rock","gains":[4.5,3.5,2,0.5,-1,-1,0.5,2.5,3.5,4],"preamp":-2}"#
        let settings = try JSONDecoder().decode(EqualizerSettings.self, from: Data(old.utf8))
        #expect(settings.mode == .graphic && settings.bands.isEmpty && settings.preamp == -2)

        let json = #"""
        {"mode":"parametric","parametricPreamp":-30,"bands":[
          {"slot":3,"filter":"lowShelf","frequency":105,"gain":5.5,"q":0.7},
          {"slot":3,"filter":"peak","frequency":2000,"gain":-2},
          {"slot":1,"filter":"warp","frequency":500},
          {"filter":"peak","frequency":500},
          {"slot":40,"filter":"highPass","frequency":5,"q":0.7,"isOn":false}
        ]}
        """#
        let parametric = try JSONDecoder().decode(EqualizerSettings.self, from: Data(json.utf8))
        #expect(parametric.mode == .parametric)
        #expect(parametric.parametricPreamp == -12)
        #expect(parametric.bands.map(\.slot) == [3, 0, 1])
        #expect(parametric.band(slot: 0)?.frequency == 2000)
        #expect(parametric.band(slot: 0)?.q == ParametricEqualizer.defaultQ)
        #expect(parametric.band(slot: 1)?.frequency == ParametricEqualizer.frequencyRange.lowerBound)
        #expect(parametric.band(slot: 1)?.isOn == false)

        let encoded = try JSONEncoder().encode(parametric)
        let decoded = try JSONDecoder().decode(EqualizerSettings.self, from: encoded)
        #expect(decoded == parametric)
    }

    // MARK: Text

    @Test func readsAutoEQ() {
        let text = """
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 5.6 dB Q 0.70
        Filter 2: ON PK Fc 2153 Hz Gain 2.7 dB Q 1.68
        Filter 3: ON HSC Fc 10000 Hz Gain -2.3 dB Q 0.70
        """
        let profile = EqualizerAPOText.parse(text)
        #expect(profile.preamp == -6.2)
        #expect(profile.bands == [
            ParametricBand(slot: 0, filter: .lowShelf, frequency: 105, gain: 5.6, q: 0.7),
            ParametricBand(slot: 1, filter: .peak, frequency: 2153, gain: 2.7, q: 1.68),
            ParametricBand(slot: 2, filter: .highShelf, frequency: 10000, gain: -2.3, q: 0.7),
        ])
        #expect(profile.skippedCommands.isEmpty && profile.droppedFilters == 0)
    }

    @Test func readsRoomEQWizardAndEqualizerAPOQuirks() {
        let text = """
        Filter Settings file

        Room EQ V5.31
        Dated: 8 Oct 2026

        Equaliser: Generic
        Filter  1: ON  PK       Fc   63,5 Hz  Gain  -5,0 dB  Q  4,00
        Filter  2: ON  PK       Fc   1.000 Hz Gain  2.0 dB  BW Oct 1.0
        Filter  3: OFF None
        Filter  4: OFF PK       Fc   500 Hz  Gain  3 dB  Q  2
        Filter  5: ON  LP       Fc   15000 Hz
        Filter  6: ON  NO       Fc   50 Hz
        Filter  7: ON  LS       Fc   100 Hz  Gain  6 dB  Q 0.7
        Filter  8: ON  HS 6dB   Fc   8000 Hz  Gain  -3 dB
        Filter  9: ON  LS       Fc   80 Hz  Gain  4 dB
        Filter 10: ON  PK       Fc   300 Hz  Gain  2 dB
        # A comment: Filter 11: ON PK Fc 1 Hz Gain 9 dB Q 1
        Channel: L
        GraphicEQ: 25 0; 40 3
        Channel: R
        """
        let profile = EqualizerAPOText.parse(text)
        let bands = profile.bands
        #expect(bands.count == 8)
        #expect(bands[0].frequency == 63.5 && bands[0].gain == -5 && bands[0].q == 4)
        // "1.000" is 1000 Hz; one octave of bandwidth is a Q of about 1.41.
        #expect(bands[1].frequency == 1000)
        #expect(abs(bands[1].q - 1.414) < 0.01)
        #expect(bands[2].isOn == false && bands[2].frequency == 500)
        #expect(bands[3].filter == .lowPass && abs(bands[3].q - 0.7071) < 0.001)
        #expect(bands[4].filter == .notch && bands[4].q == 30)
        // A corner frequency (LS rather than LSC) moves the centre in, as for the DCX2496.
        #expect(bands[5].filter == .lowShelf && abs(bands[5].frequency - 119.2) < 0.1 && bands[5].q == 0.7)
        // A slope of 6 dB/octave: S 0.5.
        #expect(bands[6].filter == .highShelf && bands[6].frequency < 8000)
        let a = pow(10, -3.0 / 40)
        #expect(abs(bands[6].q - 1 / ((a + 1 / a) * (1 / 0.5 - 1) + 2).squareRoot()) < 1e-9)
        // No width: the shelf's default slope, at the centre frequency given.
        #expect(bands[7].frequency == 80)
        // A peak with no width is left out, as Equalizer APO does.
        #expect(!bands.contains { $0.frequency == 300 })
        #expect(profile.skippedCommands == ["Channel", "GraphicEQ"])
    }

    @Test func keepsSixteenFilters() {
        let text = (1...20).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        let profile = EqualizerAPOText.parse(text)
        #expect(profile.bands.count == 16)
        #expect(profile.droppedFilters == 4)
        #expect(profile.bands.map(\.slot) == Array(0..<16))
    }

    @Test func writesWhatItReads() {
        let bands = [
            ParametricBand(slot: 4, filter: .highShelf, frequency: 9500, gain: -2.25, q: 0.707),
            ParametricBand(slot: 1, filter: .lowShelf, frequency: 62.5, gain: 4, q: 0.7),
            ParametricBand(slot: 2, filter: .highPass, frequency: 20, q: 0.5),
            ParametricBand(slot: 3, filter: .notch, frequency: 60, q: 12, isOn: false),
            ParametricBand(slot: 0, filter: .peak, frequency: 1000, gain: -3.5, q: 1.41),
        ]
        let text = EqualizerAPOText.text(preamp: -4.5, bands: bands)
        #expect(text.hasPrefix("Preamp: -4.5 dB\nFilter 1: ON HPQ Fc 20 Hz Q 0.50\nFilter 2: OFF NO Fc 60 Hz Q 12.00\n"))
        #expect(text.contains("Filter 3: ON LSC Fc 62.5 Hz Gain 4 dB Q 0.70\n"))
        let profile = EqualizerAPOText.parse(text)
        #expect(profile.preamp == -4.5)
        let sorted = bands.sorted { $0.frequency < $1.frequency }
        for (read, written) in zip(profile.bands, sorted) {
            #expect(read.filter == written.filter && read.frequency == written.frequency && read.gain == (written.filter.hasGain ? written.gain : 0))
            #expect(read.q == written.q && read.isOn == written.isOn)
        }
    }

    @Test func readsTypedValues() {
        #expect(ParametricEqualizer.frequency(from: "1.2k") == 1200)
        #expect(ParametricEqualizer.frequency(from: "1.2 kHz") == 1200)
        #expect(ParametricEqualizer.frequency(from: "２５０ｈｚ") == 250)
        #expect(ParametricEqualizer.frequency(from: "62.5") == 62.5)
        #expect(ParametricEqualizer.frequency(from: "0") == nil)
        #expect(ParametricEqualizer.gain(from: "+3.5dB") == 3.5)
        #expect(ParametricEqualizer.gain(from: "−2") == -2)
        #expect(ParametricEqualizer.q(from: "Q 1。41") == 1.41)
        #expect(ParametricEqualizer.q(from: "-1") == nil)
        #expect(ParametricEqualizer.frequencyText(62.5) == "62.5 Hz")
        #expect(ParametricEqualizer.frequencyText(2153) == "2153 Hz")
        #expect(ParametricEqualizer.frequencyText(12500) == "12.5 kHz")
        #expect(ParametricEqualizer.gainText(-0.04) == "0 dB")
        #expect(ParametricEqualizer.qText(0.7) == "0.70")
        #expect(ParametricEqualizer.rounded(frequency: 2153.4) == 2150)
    }

    // MARK: Processing

    @Test func outputFollowsTheParametricCurve() {
        var settings = EqualizerSettings()
        settings.isEnabled = true
        settings.setParametric(EqualizerAPOText.parse("""
        Filter: ON LSC Fc 105 Hz Gain 5.6 dB Q 0.7
        Filter: ON PK Fc 2000 Hz Gain -4 dB Q 2
        Filter: ON HPQ Fc 30 Hz Q 0.7
        Filter: ON NO Fc 6000 Hz Q 3
        """), name: "")
        for frequency in [60.0, 1000, 2000, 5000] {
            let processor = EqualizerTests.processor(EqualizerTests.control(settings))
            let input = EqualizerTests.sine(frequency: frequency, amplitude: 0.1, frames: 44100)
            let output = EqualizerTests.run(processor, input)
            let measured = 20 * log10(EqualizerTests.rms(output.suffix(8192)) / EqualizerTests.rms(input.suffix(8192)))
            let expected = ResponseSampler(frequencies: [frequency], sampleRate: EqualizerTests.sampleRate).response(bands: settings.bands)[0]
            #expect(abs(measured - expected) < 0.1, "\(frequency) Hz: \(measured) vs \(expected)")
        }
    }

    /// Changing a band's type, removing one and adding a low-pass while music plays glides or
    /// fades: no step in the output bigger than the sine's own.
    @Test func editsWhilePlayingDoNotClick() {
        var settings = EqualizerSettings()
        settings.isEnabled = true
        settings.setParametric(EqualizerAPOText.parse("""
        Filter: ON PK Fc 440 Hz Gain 9 dB Q 2
        Filter: ON HSC Fc 3000 Hz Gain -6 dB Q 0.7
        """), name: "")
        let control = EqualizerTests.control(settings)
        let processor = EqualizerTests.processor(control)
        let frequency = 440.0, amplitude: Float = 0.2
        let input = EqualizerTests.sine(frequency: frequency, amplitude: amplitude, frames: 4410)
        var output = EqualizerTests.run(processor, input)
        let edits: [(inout EqualizerSettings) -> Void] = [
            { $0.updateBand(slot: 0) { $0.filter = .highPass } },
            { $0.updateBand(slot: 0) { $0.frequency = 2000 } },
            { $0.removeBand(slot: 1) },
            { $0.addBand(ParametricBand(slot: 0, filter: .lowPass, frequency: 300, q: 0.7)) },
            { $0.updateBand(slot: 0) { $0.isOn = false } },
            { $0.isEnabled = false },
        ]
        for edit in edits {
            edit(&settings)
            let state = EqualizerControl.state(for: settings)
            control.update { $0 = state }
            // Continue the sine where it left off.
            let start = output.count
            let next = (0..<4410).map { amplitude * Float(sin(2 * .pi * frequency * Double(start + $0) / EqualizerTests.sampleRate)) }
            output += EqualizerTests.run(processor, next)
        }
        #expect(output.allSatisfy { $0.isFinite })
        let largestStep = zip(output.dropFirst(), output).map { abs($0 - $1) }.max() ?? 0
        let sineStep = Float(2 * .pi * frequency / EqualizerTests.sampleRate) * amplitude
        // The peak lifts the sine up to 9 dB (2.8×); a click would be far beyond.
        #expect(largestStep < sineStep * 3.2, "\(largestStep) vs \(sineStep)")
        // Off is bit-exact again once the filters have rung out.
        let tail = EqualizerTests.sine(frequency: frequency, amplitude: amplitude, frames: 4096)
        _ = EqualizerTests.run(processor, EqualizerTests.sine(frequency: frequency, amplitude: amplitude, frames: 44100))
        #expect(EqualizerTests.run(processor, tail) == tail)
    }

    /// A 0 dB band moved while nothing plays through the equalizer (it is bypassed) is
    /// already where it was moved to when its gain comes up: no sweep from the old frequency.
    @Test func bandsMovedWhileBypassedStartWhereTheyAre() {
        var settings = EqualizerSettings()
        settings.isEnabled = true
        settings.clipGuard = false
        settings.setParametric(EqualizerAPOText.parse("Filter: ON PK Fc 100 Hz Gain 0 dB Q 1"), name: "")
        let control = EqualizerTests.control(settings)
        let processor = EqualizerTests.processor(control)
        let input = EqualizerTests.sine(frequency: 100, amplitude: 0.2, frames: 8820)
        #expect(EqualizerTests.run(processor, input) == input)
        for edit: (inout ParametricBand) -> Void in [{ $0.frequency = 5000 }, { $0.gain = 12 }] {
            settings.updateBand(slot: 0, edit)
            let state = EqualizerControl.state(for: settings)
            control.update { $0 = state }
            let output = EqualizerTests.run(processor, input)
            let peak = output.map(abs).max() ?? 0
            #expect(peak < 0.2 * 1.05, "\(peak)")
        }
    }

    @Test func readsAByteOrderMark() {
        let profile = EqualizerAPOText.parse("\u{FEFF}Preamp: -3 dB\r\nFilter 1: ON PK Fc 100 Hz Gain 2 dB Q 1\r\n")
        #expect(profile.preamp == -3)
        #expect(profile.bands.count == 1)
    }
}
