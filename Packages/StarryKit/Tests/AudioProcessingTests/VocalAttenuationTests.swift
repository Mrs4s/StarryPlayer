import AudioToolbox
import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalAttenuationTests {
    static let musicModel = VocalResidual(decibels: -13.1, correlation: 0.10)

    /// Music models output the accompaniment (p = 100·(1 − g), 0…95); voice models output the
    /// voice, subtracted with the negative range.
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

    /// The voice heard (by the model's residual) is linear in dB along the slider, from what the
    /// lowest setting leaves up to 0 dB; an unmeasured model gets the plain −26…0 dB gain curve.
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

    /// The default (15) leaves the voice where 35 did on the plain −26…0 dB gain curve.
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

    @Test func envelopeFadesOutThenPrimesAndFadesIn() {
        let (list, channel) = Self.bufferList(frames: 100, value: 1)
        defer { list.unsafeMutablePointer.deallocate(); channel.deallocate() }
        var envelope = GainEnvelope()
        envelope.fade(to: 0, over: 50)
        envelope.apply(list, frameCount: 100)
        #expect(envelope.isSilent)
        #expect(abs(channel[24] - 0.5) < 0.03)
        #expect(channel[60] == 0)

        channel.update(repeating: 1, count: 100)
        envelope.mute(frames: 40, thenFadeInOver: 20)
        envelope.apply(list, frameCount: 100)
        #expect(channel[39] == 0)
        #expect(channel[49] > 0.4 && channel[49] < 0.6)
        #expect(channel[80] == 1)
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

    /// With the switch on before the item starts, the unit is built in `prepare`: the output is
    /// silent while it primes, then (vocals at 100, WetDry 0) it is exactly the input delayed by
    /// the reported latency.
    @Test func startsPrimedAndDelaysByTheReportedLatency() throws {
        guard #available(macOS 15, *) else { return }
        let control = VocalAttenuationControl()
        control.update { $0.enabled = true; $0.vocalLevel = 100 }
        let attenuator = SoundIsolationAttenuator(control: control)
        let run = Run(attenuator: attenuator)
        let status = attenuator.status
        #expect(status.model == .systemVoice)
        #expect(status.latencyFrames > 1000)

        run.process(blocks: 30)
        #expect(attenuator.status.isProcessing)
        let latency = status.latencyFrames
        #expect(run.output[0..<latency].allSatisfy { $0 == 0 })
        let start = latency + 44100 / 10 + 10
        var error: Float = 0
        for n in start..<(start + 20000) { error = max(error, abs(run.output[n] - run.input[n - latency])) }
        #expect(error < 1e-4, "max deviation \(error)")
        #expect(abs(attenuator.status.latency - Double(latency) / 44100) < 1e-9)
    }

    /// A jump in the source position (a seek) resets the unit: silent while it primes again.
    @Test func seekResetsAndPrimesAgain() throws {
        guard #available(macOS 15, *) else { return }
        let control = VocalAttenuationControl()
        control.update { $0.enabled = true; $0.vocalLevel = 100 }
        let attenuator = SoundIsolationAttenuator(control: control)
        let run = Run(attenuator: attenuator)
        run.process(blocks: 20)
        let latency = attenuator.status.latencyFrames
        let seekAt = run.position
        run.process(blocks: 5, sourceOffset: 200_000)
        #expect(run.output[seekAt..<(seekAt + latency)].allSatisfy { $0 == 0 })
        #expect(run.output[(seekAt + latency + 44100 / 5)..<run.position].contains { $0 != 0 })
    }

    /// Switched off right as a seek lands, then AVPlayer's preroll delivers a block at an odd
    /// offset: the seek must not revive the fade-out it interrupts.
    @Test func switchingOffAcrossASeekStillSwitches() throws {
        guard #available(macOS 15, *) else { return }
        let control = VocalAttenuationControl()
        control.update { $0.enabled = true; $0.vocalLevel = 100 }
        let attenuator = SoundIsolationAttenuator(control: control)
        let run = Run(attenuator: attenuator)
        run.process(blocks: 20)
        control.update { $0.enabled = false }
        run.process(blocks: 1)
        run.process(blocks: 1, sourceOffset: 180_000)
        run.process(blocks: 1, sourceOffset: 180_000 - 1024)
        let settled = run.position + 44100 / 10
        run.process(blocks: 6, sourceOffset: 180_000 - 1024)
        #expect(!attenuator.status.isProcessing)
        #expect((settled..<run.position).allSatisfy { run.output[$0] == run.input[$0] })
    }

    /// Switched on mid-item: the unit is built in the background, then the output fades out,
    /// primes and fades back in, processing from then on.
    @Test func switchingOnMidItemBuildsInTheBackground() async throws {
        guard #available(macOS 15, *) else { return }
        let control = VocalAttenuationControl()
        let attenuator = SoundIsolationAttenuator(control: control)
        let run = Run(attenuator: attenuator)
        run.process(blocks: 5)
        #expect(Array(run.output[0..<run.position]) == Array(run.input[0..<run.position]))

        control.update { $0.enabled = true; $0.vocalLevel = 100 }
        attenuator.prepareUnitIfNeeded()
        for _ in 0..<100 where attenuator.status.model == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(attenuator.status.model != nil)
        run.process(blocks: 30)
        #expect(attenuator.status.isProcessing)
        #expect(attenuator.latencyFrames == attenuator.status.latencyFrames)
    }

    final class Run {
        let attenuator: SoundIsolationAttenuator
        let sampleRate = 44100.0
        let block = 4096
        private(set) var input: [Float] = []
        private(set) var output: [Float] = []
        private(set) var position = 0

        init(attenuator: SoundIsolationAttenuator) {
            self.attenuator = attenuator
            attenuator.prepare(format: ProcessingFormat(sampleRate: sampleRate, channelCount: 2, maxFrames: block))
        }

        func signal(_ n: Int) -> Float {
            let t = Double(n) / sampleRate
            return Float(0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 1375 * t) + 0.1 * sin(2 * .pi * 5100 * t))
        }

        func process(blocks: Int, sourceOffset: Int64 = 0) {
            let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { left.deallocate(); right.deallocate(); list.unsafeMutablePointer.deallocate() }
            for _ in 0..<blocks {
                for i in 0..<block {
                    let value = signal(position + i)
                    left[i] = value
                    right[i] = value * 0.8
                    input.append(value)
                }
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: left)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: right)
                attenuator.process(list, frameCount: block, sampleIndex: Int64(position) + sourceOffset)
                output.append(contentsOf: UnsafeBufferPointer(start: left, count: block))
                position += block
            }
        }
    }

    static func bufferList(frames: Int, value: Float) -> (UnsafeMutableAudioBufferListPointer, UnsafeMutablePointer<Float>) {
        let channel = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        channel.initialize(repeating: value, count: frames)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: channel)
        return (list, channel)
    }
}
