import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalOnsetDetectorTests {
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
