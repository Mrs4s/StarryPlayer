import AVFoundation
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

    /// Equal power: at every moment of the overlap the two songs' gains square to one, so two
    /// unrelated songs keep their combined loudness.
    @Test func overlapKeepsThePower() {
        let incoming = TransitionFades(fadeIn: 0...5)
        let outgoing = TransitionFades(fadeOut: 100...105)
        for step in 0...50 {
            let x = Double(step) / 10
            let power = pow(incoming.gain(at: x), 2) + pow(outgoing.gain(at: 100 + x), 2)
            #expect(abs(power - 1) < 1e-5, "at \(x) s: \(power)")
        }
    }

    @Test func blocksAreScaledByTheirPosition() {
        let control = TransitionEnvelopeControl()
        control.fades = TransitionFades(fadeIn: 1...2)
        let envelope = TransitionEnvelope(control: control)
        envelope.prepare(format: ProcessingFormat(sampleRate: 1000, channelCount: 2, maxFrames: 512))
        let buffers = Buffers(channels: 2, frames: 512)

        buffers.fill(1)
        envelope.process(buffers.list, frameCount: 512, sampleIndex: 0)
        #expect(buffers.samples(channel: 1).allSatisfy { $0 == 0 }, "before the fade")

        buffers.fill(1)
        envelope.process(buffers.list, frameCount: 512, sampleIndex: 1250)
        let expected = (0..<512).map { Float(sin(min(Double(250 + $0) / 1000, 1) * .pi / 2)) }
        for channel in 0..<2 {
            let got = buffers.samples(channel: channel)
            #expect(zip(got, expected).allSatisfy { abs($0 - $1) < 1e-6 })
        }
    }

    @Test func outsideTheFadesNothingChanges() {
        let control = TransitionEnvelopeControl()
        let envelope = TransitionEnvelope(control: control)
        envelope.prepare(format: ProcessingFormat(sampleRate: 48000, channelCount: 1, maxFrames: 256))
        let buffers = Buffers(channels: 1, frames: 256)
        let noise = (0..<256).map { _ in Float.random(in: -1...1) }

        buffers.set(noise)
        envelope.process(buffers.list, frameCount: 256, sampleIndex: 0)
        #expect(buffers.samples(channel: 0) == noise)

        control.fades = TransitionFades(fadeIn: 0...1, fadeOut: 10...11)
        buffers.set(noise)
        envelope.process(buffers.list, frameCount: 256, sampleIndex: 48000 * 5)
        #expect(buffers.samples(channel: 0) == noise)
    }

    @Test func missingPositionContinuesTheLastBlock() {
        let control = TransitionEnvelopeControl()
        control.fades = TransitionFades(fadeOut: 0.5...1)
        let envelope = TransitionEnvelope(control: control)
        envelope.prepare(format: ProcessingFormat(sampleRate: 1000, channelCount: 1, maxFrames: 600))
        let buffers = Buffers(channels: 1, frames: 600)
        buffers.fill(1)
        envelope.process(buffers.list, frameCount: 600, sampleIndex: 0)
        buffers.fill(1)
        envelope.process(buffers.list, frameCount: 600, sampleIndex: nil)
        #expect(buffers.samples(channel: 0)[450...].allSatisfy { abs($0) < 1e-6 })
        #expect(buffers.samples(channel: 0)[0] > 0.5)
    }
}

private final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private let frames: Int
    private let storage: [UnsafeMutablePointer<Float>]

    init(channels: Int, frames: Int) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channels)
        storage = (0..<channels).map { _ in .allocate(capacity: frames) }
        for (channel, pointer) in storage.enumerated() {
            list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pointer)
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    func fill(_ value: Float) {
        for pointer in storage { pointer.update(repeating: value, count: frames) }
    }

    func set(_ values: [Float]) {
        for pointer in storage { pointer.update(from: values, count: frames) }
    }

    func samples(channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: storage[channel], count: frames))
    }
}
