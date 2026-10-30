import Foundation
import Testing
@testable import AudioProcessing

@Suite struct TransitionEnvelopeTests {
    @Test func fadeInRisesFromSilence() {
        let fades = TransitionFades(fadeIn: 2...4)
        #expect(fades.gain(at: 0) == 0)
        #expect(fades.gain(at: 2) == 0)
        #expect(abs(fades.gain(at: 3) - Float(sin(Double.pi / 4))) < 1e-6)
        #expect(fades.gain(at: 4) == 1)
        #expect(fades.gain(at: 9) == 1)
    }

    @Test func fadeOutFallsToSilence() {
        let fades = TransitionFades(fadeOut: 10...12)
        #expect(fades.gain(at: 0) == 1)
        #expect(fades.gain(at: 10) == 1)
        #expect(fades.gain(at: 12) < 1e-6)
        #expect(fades.gain(at: 20) < 1e-6)
    }

    @Test func overlapKeepsThePower() {
        let incoming = TransitionFades(fadeIn: 0...5)
        let outgoing = TransitionFades(fadeOut: 100...105)
        for step in 0...50 {
            let x = Double(step) / 10
            let power = pow(incoming.gain(at: x), 2) + pow(outgoing.gain(at: 100 + x), 2)
            #expect(abs(power - 1) < 1e-5, "at \(x) s: \(power)")
        }
    }
}
