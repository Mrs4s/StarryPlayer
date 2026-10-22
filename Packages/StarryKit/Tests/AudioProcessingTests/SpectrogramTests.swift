import Foundation
import Testing
@testable import AudioProcessing

@Suite struct SpectrogramTests {
    private let rate = 44_100.0

    private func tone(_ frequency: Double, seconds: Double, from onset: Double = 0, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { i in
            let t = Double(i) / rate
            return t < onset ? 0 : amplitude * Float(sin(2 * .pi * frequency * t))
        }
    }

    private func brightness(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Int {
        let i = (y * width + x) * 4
        return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
    }

    @Test func silenceIsBlack() throws {
        let pixels = try #require(Spectrogram.pixels(samples: [Float](repeating: 0, count: 44_100), sampleRate: rate, width: 50, height: 40, gain: 3, palette: .icyBlue))
        #expect(pixels.count == 50 * 40 * 4)
        #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 && pixels[$0 + 1] == 0 && pixels[$0 + 2] == 0 })
    }

    @Test func toneLightsItsFrequencyRow() throws {
        let width = 40, height = 200
        let pixels = try #require(Spectrogram.pixels(samples: tone(1000, seconds: 1), sampleRate: rate, width: width, height: height, gain: 3, palette: .icyBlue))
        let column = width / 2
        let levels = (0..<height).map { brightness(pixels, width: width, x: column, y: $0) }
        // Unwindowed, the tone saturates a band of rows: its middle.
        let band = levels.indices.filter { levels[$0] == levels.max() }
        let brightest = (band.first! + band.last!) / 2
        // Rows count from the top; 1 kHz of 20 kHz is 5 % up from the bottom.
        let expected = Double(height) * (1 - 1000.0 / 20_000)
        #expect(abs(Double(brightest) - expected) <= 2, "row \(brightest), expected about \(expected)")
        #expect(brightness(pixels, width: width, x: column, y: 10) < brightness(pixels, width: width, x: column, y: brightest) / 4)
    }

    @Test func columnsFollowTime() throws {
        let width = 100, height = 100
        let pixels = try #require(Spectrogram.pixels(samples: tone(2000, seconds: 2, from: 1), sampleRate: rate, width: width, height: height, gain: 3, palette: .icyBlue))
        let row = Int(Double(height) * (1 - 2000.0 / 20_000))
        let lit = (0..<width).filter { brightness(pixels, width: width, x: $0, y: row) > 150 }
        let first = try #require(lit.first)
        #expect(abs(first - width / 2) <= 2, "first lit column \(first)")
        #expect(lit.count >= width / 2 - 3)
    }

    @Test func tooShortGivesNothing() {
        #expect(Spectrogram.image(samples: [Float](repeating: 0, count: 100), sampleRate: rate, width: 10, height: 10) == nil)
    }

    @Test func cancelledRenderDoesNotProduceAnImage() async {
        let image = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return Spectrogram.image(samples: [Float](repeating: 0.5, count: 44_100), sampleRate: 44_100, width: 400, height: 200)
        }.value
        #expect(image == nil)
    }

}
