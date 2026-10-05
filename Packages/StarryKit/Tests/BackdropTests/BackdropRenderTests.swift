import AppKit
import simd
import Testing
@testable import Backdrop

@MainActor
@Suite struct BackdropRenderTests {
    private func solidCover(_ rgb: SIMD3<Float>) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let data = image.dataProvider!.data! as Data
        let o = y * image.bytesPerRow + x * 4
        // BGRA little-endian.
        return SIMD3(Float(data[o + 2]), Float(data[o + 1]), Float(data[o])) / 255
    }

    @Test func zeroEdgeBlurIsUnpremultipliedToTheBorder() throws {
        // A one-colour cover must come out as one colour, rim included: the zero-edge blur dims
        // the border and the pinch pass has to divide that back out.
        let view = ArtworkBackdropView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.isBehindLyrics = true
        view.setCover(solidCover(SIMD3(0.8, 0.45, 0.2)), seed: "solid")
        for _ in 0..<60 { view.advance(dt: 1 / 60, landscape: true) }
        let frame = try #require(view.captureFrame(size: CGSize(width: 320, height: 200)))
        let centre = pixel(frame, 160, 100)
        #expect(centre.x > 0.1, "frame is black: \(centre)")
        for (x, y) in [(0, 0), (319, 0), (0, 199), (319, 199), (160, 0), (0, 100)] {
            let p = pixel(frame, x, y)
            #expect(simd_distance(p, centre) < 8 / 255, "(\(x), \(y)) \(p) vs centre \(centre)")
        }
    }

    @Test func tenBitTargetShowsTheSamePictureWithFinerSteps() throws {
        let view = ArtworkBackdropView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.isBehindLyrics = true
        view.setCover(solidCover(SIMD3(0.8, 0.45, 0.2)), seed: "solid")
        for _ in 0..<60 { view.advance(dt: 1 / 60, landscape: true) }
        let size = CGSize(width: 320, height: 200)
        let eight = try #require(view.renderFrame(size: size, format: .bgra8Unorm))
        let ten = try #require(view.renderFrame(size: size, format: .bgr10a2Unorm))
        func word(_ bytes: [UInt8], _ i: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[i * 4 + $1]) << ($1 * 8) }
        }
        func rgb8(_ i: Int) -> SIMD3<Float> {
            SIMD3(Float(eight[i * 4 + 2]), Float(eight[i * 4 + 1]), Float(eight[i * 4])) / 255
        }
        func rgb10(_ i: Int) -> SIMD3<Float> {
            let w = word(ten, i)
            return SIMD3(Float(w >> 20 & 0x3ff), Float(w >> 10 & 0x3ff), Float(w & 0x3ff)) / 1023
        }
        // Over the heavily blurred centre, neighbouring pixels differ almost only by dither plus
        // rounding, about half a step of the target RMS: a 10-bit target that only carried 8-bit
        // values would come out as noisy as the 8-bit one.
        var mean8 = SIMD3<Float>.zero, mean10 = SIMD3<Float>.zero
        var noise8: Float = 0, noise10: Float = 0, count: Float = 0
        for y in 80..<120 {
            for x in 120..<200 {
                let i = y * 320 + x
                mean8 += rgb8(i)
                mean10 += rgb10(i)
                noise8 += simd_length_squared(rgb8(i) - rgb8(i + 1))
                noise10 += simd_length_squared(rgb10(i) - rgb10(i + 1))
                count += 1
            }
        }
        #expect(mean8.x > 0.1, "frame is black: \(mean8 / count)")
        #expect(simd_distance(mean8 / count, mean10 / count) < 1 / 255, "\(mean8 / count) vs \(mean10 / count)")
        let rms8 = (noise8 / count / 3).squareRoot() * 255, rms10 = (noise10 / count / 3).squareRoot() * 255
        #expect(rms10 < rms8 / 2, "neighbour RMS in 8-bit steps: 8-bit \(rms8), 10-bit \(rms10)")
    }
}
