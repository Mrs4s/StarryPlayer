import AudioProcessing
import Foundation
import Testing

struct BundledVocalModelTests {
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
