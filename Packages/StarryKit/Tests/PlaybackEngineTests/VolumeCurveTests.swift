import Foundation
import Testing
@testable import PlaybackEngine

@Suite struct VolumeCurveTests {
    @Test func endpointsAndClamping() {
        #expect(VolumeCurve.gain(forLevel: 0) == 0)
        #expect(VolumeCurve.gain(forLevel: 1) == 1)
        #expect(VolumeCurve.gain(forLevel: -0.3) == 0)
        #expect(VolumeCurve.gain(forLevel: 1.7) == 1)
    }

    /// Cubic taper: half travel is −18 dB, not the −6 dB of a linear slider.
    @Test func halfTravelIsMinus18dB() {
        let dB = 20 * log10(Double(VolumeCurve.gain(forLevel: 0.5)))
        #expect(abs(dB + 18.06) < 0.01)
    }

    @Test func monotonic() {
        let gains = stride(from: 0.0, through: 1.0, by: 0.01).map(VolumeCurve.gain(forLevel:))
        #expect(zip(gains, gains.dropFirst()).allSatisfy { $0 < $1 })
    }
}
