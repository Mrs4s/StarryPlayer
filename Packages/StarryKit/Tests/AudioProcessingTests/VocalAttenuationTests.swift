import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalAttenuationTests {
    static let musicModel = VocalResidual(decibels: -13.1, correlation: 0.10)

    @Test func wetDryFollowsTheModelOutput() {
        for residual in [nil, VocalResidual.systemVoice, Self.musicModel] {
            let low = VocalAttenuationCurve.gain(forSlider: 5, residual: residual)
            #expect(abs(VocalAttenuationCurve.wetDryPercent(voiceGain: low, isolates: .accompaniment) - 95) < 1e-4)
            #expect(abs(VocalAttenuationCurve.wetDryPercent(voiceGain: low, isolates: .voice) + 95) < 1e-4)
            #expect(VocalAttenuationCurve.gain(forSlider: 100, residual: residual) == 1)
        }
        #expect(VocalAttenuationCurve.wetDryPercent(voiceGain: 1, isolates: .accompaniment) == 0)
        #expect(VocalAttenuationCurve.wetDryPercent(voiceGain: 1, isolates: .voice) == 0)
    }

    @Test func levelCurveIsLinearInTheHeardVoice() {
        for residual in [VocalResidual.systemVoice, Self.musicModel, .perfect] {
            let floor = 10 * log10(residual.heardPower(gain: VocalAttenuationCurve.minimumGain))
            var previous = 0.0
            for level in stride(from: 5.0, through: 100, by: 2.5) {
                let gain = VocalAttenuationCurve.gain(forSlider: level, residual: residual)
                let heard = 10 * log10(residual.heardPower(gain: gain))
                #expect(abs(heard - floor * (1 - (level - 5) / 95)) < 1e-9)
                #expect(gain >= previous)
                previous = gain
            }
        }
        let plain = VocalAttenuationCurve.gain(forSlider: 35, residual: nil)
        #expect(abs(20 * log10(plain) - 20 * log10(0.05) * (1 - 30.0 / 95)) < 1e-9)
        // The measured models leave far more than −26 dB, so the same setting keeps more voice
        // gain: the slider spends its travel where the heard level actually changes.
        #expect(VocalAttenuationCurve.gain(forSlider: 35, residual: Self.musicModel) > 0.25)
        #expect(VocalAttenuationCurve.gain(forSlider: 35, residual: .systemVoice) > 0.28)
        #expect(VocalAttenuationCurve.heardDecibels(forSlider: 5, residual: .systemVoice) > -10)
        #expect(VocalAttenuationCurve.heardDecibels(forSlider: 5, residual: Self.musicModel) < -12)
    }

    @Test func defaultKeepsTheVoiceOfTheFormerDefault() {
        let former = pow(10, 20 * log10(0.05) * (1 - 30.0 / 95) / 20)
        for residual in [VocalResidual.systemVoice, Self.musicModel] {
            let now = VocalAttenuationCurve.gain(forSlider: VocalAttenuationCurve.defaultLevel, residual: residual)
            #expect(abs(10 * log10(residual.heardPower(gain: now) / residual.heardPower(gain: former))) < 0.2)
        }
    }

    @Test func residualCorrelationStaysInItsBounds() {
        let high = VocalResidual(decibels: -10, correlation: 0.9)
        #expect(abs(high.correlation - 0.1.squareRoot()) < 1e-12)
        let low = VocalResidual(decibels: -10, correlation: 0)
        #expect(abs(low.correlation - 0.1) < 1e-12)
        #expect(VocalResidual.perfect.power == 0 && VocalResidual.perfect.correlation == 0)
    }

    @Test func overrunCounterTripsAfterLimit() {
        var counter = OverrunCounter()
        for i in 0..<4 {
            #expect(counter.record(blockDuration: 0.1, elapsed: 0.09, now: Double(i) * 0.1) == false)
        }
        #expect(counter.record(blockDuration: 0.1, elapsed: 0.09, now: 0.5) == true)
        #expect(counter.record(blockDuration: 0.1, elapsed: 0.01, now: 0.6) == false)
    }

    @Test func locatorReadsSideLoadedModelsAndFallsBack() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "starry-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appending(path: "old"), newer = root.appending(path: "new")
        for (directory, id) in [(older, "oldtask"), (newer, "newtask")] {
            try FileManager.default.createDirectory(at: directory.appending(path: "weights"), withIntermediateDirectories: true)
            try Data("program(1.0)".utf8).write(to: directory.appending(path: "net.mil"))
            let plist: [String: Any] = [
                "ModelNetPath": "net.mil", "NumberOfInputChannels": 2, "NumberOfOutputChannels": 2,
                "SampleRate": 44100, "TaskID": id, "NeuralNetImplementationType": "MIL2BNNS",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: directory.appending(path: "aufx-nnet-appl.plist"))
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

        let direct = try #require(VocalSeparationModelLocator.model(at: older))
        #expect(direct.name == "oldtask")
        #expect(direct.output == .accompaniment)
        #expect(direct.channels == 2)
        #expect(direct.accepts(channelCount: 2) && !direct.accepts(channelCount: 1))
        #expect(direct.residual == nil)
        #expect(VocalSeparationModel.systemVoice.residual == .systemVoice)

        #expect(VocalSeparationModelLocator.locate(in: [root]).name == "newtask")
        #expect(VocalSeparationModelLocator.locate(in: [root.appending(path: "missing")]) == .systemVoice)
        try FileManager.default.removeItem(at: newer.appending(path: "net.mil"))
        #expect(VocalSeparationModelLocator.locate(in: [root]).name == "oldtask")
    }

    @Test func locatorAttachesResiduals() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "starry-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func model(_ name: String, _ extra: [String: Any]) throws -> VocalSeparationModel? {
            let directory = root.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("program(1.0)".utf8).write(to: directory.appending(path: "net.mil"))
            let plist = ["ModelNetPath": "net.mil", "NumberOfInputChannels": 2, "NumberOfOutputChannels": 2].merging(extra) { $1 }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: directory.appending(path: "aufx-nnet-appl.plist"))
            return VocalSeparationModelLocator.model(at: directory)
        }
        #expect(try model("unmeasured", ["TaskID": "task"])?.residual == nil)
        let stated = try #require(try model("stated", ["TaskID": "task", "StarryResidualDecibels": -16, "StarryResidualCorrelation": 0.08])?.residual)
        #expect(stated == VocalResidual(decibels: -16, correlation: 0.08))
        let halfway = try #require(try model("halfway", ["StarryResidualDecibels": -20])?.residual)
        #expect(abs(halfway.power - 0.01) < 1e-12 && abs(halfway.correlation - 0.05) < 1e-12)
    }
}
