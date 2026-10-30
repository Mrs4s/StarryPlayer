import AudioProcessing
import CoreML
import CryptoKit
import Foundation
import Testing

@Suite(.serialized) struct BundledVocalModelTests {
    @Test func bundledVocalWeightsMatchTheirProvenance() throws {
        let model = try #require(VocalSeparationModelLocator.bundledModel(in: .main))
        let directory = try #require(model.directory)
        let metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("provenance.json"))) as? [String: Any])
        #expect(metadata["model"] as? String == model.name)
        #expect((metadata["revision"] as? String)?.isEmpty == false)
        let file = try #require(metadata["weights_file"] as? String)
        #expect(file == "weights/vi-nnet.weight.bin")
        let weights = try Data(contentsOf: directory.appendingPathComponent(file), options: .mappedIfSafe)
        #expect(weights.count == metadata["weights_bytes"] as? Int)
        let digest = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        #expect(digest == metadata["weights_sha256"] as? String)
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
