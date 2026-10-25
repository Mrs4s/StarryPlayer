import AudioProcessing
import CoreML
import AVFoundation
import Foundation
import Testing

@Suite(.serialized) struct BundledVocalModelTests {
    @Test func duetServiceWritesCompleteReadableTracksOnItsBackgroundActor() async throws {
        let model = try #require(VocalDuetSeparator.bundledModel(in: .main))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("duet-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let samples = (0..<480_000).map { i in Float(0.1*sin(2 * .pi * 700 * Double(i)/24000)) }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        let result = try await VocalDuetSeparator().separate(file: source,
            first: folder.appendingPathComponent("a.caf"), second: folder.appendingPathComponent("b.caf"), model: model)
        var sum = [Float](repeating: 0, count: samples.count)
        for url in [result.first, result.second] {
            let file = try AVAudioFile(forReading: url)
            #expect(file.length == 480_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            var offset = 0
            while offset < sum.count {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, sum.count-offset)))
                let count = Int(buffer.frameLength)
                try #require(count > 0)
                for i in 0..<count { sum[offset+i] += buffer.floatChannelData![0][i] }
                offset += count
            }
        }
        let error = zip(sum,samples).reduce(0.0) { $0 + pow(Double($1.0-$1.1),2) }
        let energy = samples.reduce(0.0) { $0 + Double($1*$1) }
        #expect(sqrt(error/energy) < 0.001)
    }

    @Test func duetModelIsBundledWithTheValidatedSpectralContract() throws {
        let url = try #require(VocalDuetSeparator.bundledModel(in: .main))
        let compiled = try MLModel.compileModel(at: url)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        #expect(model.modelDescription.inputDescriptionsByName["spectrum"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,2,481,2001])
        #expect(model.modelDescription.outputDescriptionsByName["separated"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,2,2,481,2001])
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        #expect(metadata?["nearest_resize"]?.contains("explicit") == true)
    }

    /// Runs in the built app so flattened/missing resources and unusable weights are caught.
    @Test func defaultModelLoadsFromTheAppBundle() throws {
        let model = VocalSeparationModelLocator.locate(in: [], bundle: .main)
        let resources = try #require(Bundle.main.resourceURL)
        let directory = resources.appending(path: "Models/starry-karaoke-zh", directoryHint: .isDirectory)
        #expect(model.directory?.absoluteURL == directory.absoluteURL)
        #expect(model.name == "starry-karaoke-zh")
        #expect(model.output == .accompaniment)
        #expect(model.channels == 2)
        #expect(model.sampleRate == 44100)
        #expect(model.residual == VocalResidual(decibels: -13.2, correlation: 0.10))
        for file in ["aufx-nnet-appl.plist", "vi-nnet.mil", "weights/vi-nnet.weight.bin"] {
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: file).path))
        }

        let control = VocalAttenuationControl()
        control.update { $0.model = model; $0.enabled = true }
        let attenuator = SoundIsolationAttenuator(control: control)
        attenuator.prepare(format: ProcessingFormat(sampleRate: 44100, channelCount: 2, maxFrames: 4096))
        // A fallback to the system network must not make this test pass.
        #expect(attenuator.status.model == model)
        #expect(!attenuator.status.unsupportedFormat)
        #expect(attenuator.status.latencyFrames > 0)
    }
}
