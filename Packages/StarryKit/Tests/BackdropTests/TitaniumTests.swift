import AppKit
import simd
import Testing
@testable import Backdrop

@Suite struct ThemePaletteTests {
    static func quadrants(_ colors: [SIMD3<Float>], side: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let half = CGFloat(side / 2)
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i % 2) * half, y: CGFloat(i / 2) * half, width: half, height: half))
        }
        return ctx.makeImage()!
    }

    @Test func okLabRoundTrips() {
        for c in [SIMD3<Float>(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.8, 0.2, 0.1), SIMD3(0.1, 0.5, 0.9)] {
            let back = ThemePalette.okLabToSrgb(ThemePalette.srgbToOkLab(c))
            #expect(simd_distance(back, c) < 1e-3, "\(c) -> \(back)")
        }
        let white = ThemePalette.srgbToOkLab(SIMD3(1, 1, 1))
        #expect(abs(white.x - 1) < 1e-3 && abs(white.y) < 1e-3 && abs(white.z) < 1e-3)
    }

    @Test func fourRegionsGiveFourColours() {
        let colors: [SIMD3<Float>] = [SIMD3(0.85, 0.15, 0.1), SIMD3(0.1, 0.6, 0.2), SIMD3(0.15, 0.2, 0.8), SIMD3(0.95, 0.85, 0.2)]
        let palette = ThemePalette.extract(from: Self.quadrants(colors))
        #expect(palette.count == 4)
        for c in colors {
            let lab = ThemePalette.srgbToOkLab(c)
            let nearest = palette.map { simd_distance($0, lab) }.min() ?? .infinity
            #expect(nearest < 0.02, "\(c) has no match in \(palette)")
        }
    }

    @Test func matchingKeepsCornersInPlace() {
        let current: [SIMD3<Float>] = [SIMD3(0.2, 0, 0), SIMD3(0.4, 0, 0), SIMD3(0.6, 0, 0), SIMD3(0.8, 0, 0)]
        let shuffled = [current[2], current[0], current[3], current[1]].map { $0 + SIMD3(0.01, 0, 0) }
        let matched = ThemePalette.matched(shuffled, to: current)
        for (m, c) in zip(matched, current) { #expect(abs(m.x - c.x - 0.01) < 1e-6) }
    }
}

@Suite struct TitaniumStateTests {
    private let red = [SIMD3<Float>](repeating: SIMD3(0.6, 0.2, 0.1), count: 4)
    private let blue = [SIMD3<Float>](repeating: SIMD3(0.5, -0.05, -0.2), count: 4)

    @Test func paletteCrossfadesOverItsDuration() {
        var state = TitaniumState(seed: 1, colors: red)
        state.setColors(blue, immediate: false)
        #expect(state.colors == red)
        for _ in 0..<42 { state.advance(dt: 1 / 60, speed: 1) }
        let mid = state.colors[0]
        #expect(mid != red[0] && mid != blue[0])
        for _ in 0..<60 { state.advance(dt: 1 / 60, speed: 1) }
        #expect(state.colors == blue)
    }

    @Test func aChangeMidwayStartsFromThePictureOnScreen() {
        var state = TitaniumState(seed: 1, colors: red)
        state.setColors(blue, immediate: false)
        for _ in 0..<30 { state.advance(dt: 1 / 60, speed: 1) }
        let onScreen = state.colors
        state.setColors(red, immediate: false)
        #expect(state.colors == onScreen)
    }

    @Test func crestMovesSmoothlyAndSettlesWithinOneTurn() {
        var state = TitaniumState(seed: 1, colors: red)
        let start = state.crest
        state.shiftCrest(seed: 99, immediate: false)
        #expect(state.crest == start)
        // Compare phases on the circle so wrapping at 2π does not look like a jump.
        func onCircle(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4(cos(c.x), sin(c.x), cos(c.y), sin(c.y)) }
        var previous = state.crest
        var largestStep: Float = 0
        for _ in 0..<150 {
            state.advance(dt: 1 / 60, speed: 1)
            largestStep = max(largestStep, simd_length(onCircle(state.crest) - onCircle(previous)), abs(state.crest.z - previous.z))
            previous = state.crest
        }
        #expect(largestStep < 0.1, "crest jumped by \(largestStep)")
        #expect(state.crestElapsed >= state.crestDuration)
        for i in 0..<2 { #expect(state.crest[i] >= 0 && state.crest[i] < 2 * Float.pi) }
        #expect(abs(state.crest.z) <= TitaniumLook.crestShiftY)
        #expect(state.isSettled)
    }

    @Test func lengtheningTheCrestShiftKeepsAFinishedMoveFinished() {
        var state = TitaniumState(seed: 1, colors: red)
        state.shiftCrest(seed: 5, immediate: true)
        let settled = state.crest
        state.crestDuration = 6
        state.advance(dt: 1 / 60, speed: 1)
        #expect(state.crest == settled)
    }

    @Test func aSustainedLevelGivesNoPulseAndAKickDoes() {
        var pulse = BandPulse.kick
        for _ in 0..<180 { pulse.update(level: 0.75, dt: 1 / 60) }
        #expect(pulse.value < 0.01)
        for _ in 0..<3 { pulse.update(level: 0.95, dt: 1 / 60) }
        #expect(pulse.value > 0.4, "\(pulse.value)")
        for _ in 0..<36 { pulse.update(level: 0.75, dt: 1 / 60) }
        #expect(pulse.value < 0.1, "\(pulse.value)")
    }

    @Test func pulsesStayAtTwoASecondAtMost() {
        for fps in [30, 60, 120] {
            var pulse = BandPulse.kick
            let dt = 1 / Double(fps)
            var values: [Float] = []
            for frame in 0..<(fps * 6) {
                let t = Double(frame) * dt
                let kicking = t > 2 && (t * 8).truncatingRemainder(dividingBy: 1) < 0.4
                pulse.update(level: kicking ? 0.95 : 0.7, dt: dt)
                values.append(pulse.value)
            }
            // Count peaks that rise at least 0.1 above the preceding trough.
            var peaks: [Double] = []
            var low = values[0], armed = false
            for (i, v) in values.enumerated() {
                if !armed, v < low { low = v }
                if !armed, v - low >= 0.1 { armed = true }
                if armed, i > 0, v < values[i - 1] { armed = false; peaks.append(Double(i - 1) * dt); low = v }
            }
            let busiest = peaks.indices.map { i in peaks[i...].prefix { $0 - peaks[i] < 1 }.count }.max() ?? 0
            #expect(busiest <= 2, "\(fps) fps: \(busiest) pulses in one second")
            #expect(peaks.count >= 4, "\(fps) fps: the beat should still show (\(peaks.count) pulses)")
        }
    }

    @Test func pulsesDoNotDependOnTheFrameRate() {
        func run(fps: Int) -> Float {
            var pulse = BandPulse.kick
            let dt = 1 / Double(fps)
            for _ in 0..<(fps * 2) { pulse.update(level: 0.7, dt: dt) }
            for _ in 0..<(fps / 10) { pulse.update(level: 0.9, dt: dt) }
            for _ in 0..<(fps / 10) { pulse.update(level: 0.7, dt: dt) }
            return pulse.value
        }
        let at30 = run(fps: 30), at60 = run(fps: 60), at120 = run(fps: 120)
        #expect(abs(at30 - at120) < 0.08 && abs(at60 - at120) < 0.04, "\(at30) \(at60) \(at120)")
    }

    @Test func startingOrResumingIsNotABeat() {
        var pulse = BandPulse.kick
        for _ in 0..<5 { pulse.update(level: 0.8, dt: 1 / 60) }
        #expect(pulse.value < 0.01)
        for _ in 0..<120 { pulse.update(level: 0, dt: 1 / 60) }
        for _ in 0..<5 { pulse.update(level: 0.8, dt: 1 / 60) }
        #expect(pulse.value < 0.01)
    }

    @Test func theMusicMovesTheLightNotTheClocks() {
        var quiet = TitaniumState(seed: 1, colors: red)
        var loud = quiet
        for i in 0..<120 {
            quiet.levels = SIMD2(0.7, 0.4)
            loud.levels = i % 30 < 3 ? SIMD2(0.95, 0.6) : SIMD2(0.7, 0.4)
            quiet.advance(dt: 1 / 60, speed: 1)
            loud.advance(dt: 1 / 60, speed: 1)
        }
        #expect(loud.colorTime == quiet.colorTime && loud.flowTime == quiet.flowTime)
        loud.levels = SIMD2(0.7, 0.4)
        for _ in 0..<30 { loud.advance(dt: 1 / 60, speed: 1) }
        loud.levels = SIMD2(0.95, 0.65)
        for _ in 0..<3 { loud.advance(dt: 1 / 60, speed: 1) }
        #expect(loud.pulse > 0.4 && loud.burst > 0.5)
        loud.reactivity = 3
        #expect(loud.beatLift == 2 * TitaniumLook.beatLift)
        loud.reactivity = 0
        #expect(loud.pulse == 0 && loud.burst == 0 && loud.beatLift == 0)
    }

    @Test func flowShiftsWrapWithoutJumpsAfterHoursOfPlay() {
        let tangent = TitaniumLook.flowTangent(seed: SIMD3(1, 2, 3))
        #expect(abs(simd_length(tangent) - 1) < 1e-12)
        func step(at seconds: Double) -> SIMD2<Float> {
            let a = TitaniumLook.wrappedShift(tangent * TitaniumLook.flowCells(seconds: seconds, scale: 2.9, speed: 1.35))
            let b = TitaniumLook.wrappedShift(tangent * TitaniumLook.flowCells(seconds: seconds + 1 / 60, scale: 2.9, speed: 1.35))
            var d = b - a
            d -= 256 * (d / 256).rounded(.toNearestOrAwayFromZero)
            return d
        }
        let early = step(at: 1), late = step(at: 36_000)
        #expect(simd_distance(early, late) < 1e-4, "\(early) vs \(late)")
        for seconds in [0.0, 12.5, 36_000, 1e7] {
            for sign in [1.0, -1.0] {
                let s = TitaniumLook.wrappedShift(sign * tangent * TitaniumLook.flowCells(seconds: seconds, scale: 0.9, speed: 1))
                #expect(s.x >= 0 && s.x < 256 && s.y >= 0 && s.y < 256)
            }
        }
    }
}

@MainActor
@Suite struct TitaniumRenderTests {
    private func view() -> TitaniumBackdropView {
        let view = TitaniumBackdropView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), seed: 7)
        view.setCover(ThemePaletteTests.quadrants([SIMD3(0.8, 0.3, 0.2), SIMD3(0.2, 0.4, 0.7), SIMD3(0.6, 0.6, 0.3), SIMD3(0.3, 0.2, 0.4)]), seed: "song")
        for _ in 0..<90 { view.advance(dt: 1 / 60) }
        return view
    }

    @Test func pausedPlaybackHoldsOnceTransitionsFinish() {
        let v = TitaniumBackdropView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), seed: 7)
        v.setCover(ThemePaletteTests.quadrants([SIMD3(0.8, 0.3, 0.2), SIMD3(0.2, 0.4, 0.7), SIMD3(0.6, 0.6, 0.3), SIMD3(0.3, 0.2, 0.4)]), seed: "a")
        for _ in 0..<10 { v.advance(dt: 1 / 60) }
        v.holdIfIdle()
        #expect(!v.isHolding)
        v.isPlaying = false
        v.setCover(ThemePaletteTests.quadrants([SIMD3(0.1, 0.1, 0.6), SIMD3(0.5, 0.5, 0.5), SIMD3(0.9, 0.2, 0.6), SIMD3(0.2, 0.7, 0.3)]), seed: "b")
        v.advance(dt: 1 / 60)
        v.holdIfIdle()
        #expect(!v.isHolding)
        for _ in 0..<150 { v.advance(dt: 1 / 60) }
        v.holdIfIdle()
        #expect(v.isHolding)
        let flow = v.state.flowTime
        v.advance(dt: 0)
        #expect(v.state.flowTime == flow)
        v.isBehindLyrics = true
        #expect(!v.isHolding)
        for _ in 0..<200 { v.advance(dt: 1 / 60) }
        v.holdIfIdle()
        #expect(v.isHolding)
        v.isPlaying = true
        #expect(!v.isHolding)
    }

    @Test func aBeatStillDyingDownKeepsItRunning() {
        var state = TitaniumState(seed: 1, colors: [SIMD3(0.5, 0, 0)])
        state.levels = SIMD2(0.7, 0.4)
        for _ in 0..<60 { state.advance(dt: 1 / 60, speed: 1) }
        state.levels = SIMD2(0.95, 0.7)
        for _ in 0..<3 { state.advance(dt: 1 / 60, speed: 1) }
        state.levels = .zero
        state.advance(dt: 1 / 60, speed: 1)
        #expect(!state.canHold)
        for _ in 0..<150 { state.advance(dt: 1 / 60, speed: 1) }
        #expect(state.canHold)
    }

    @Test func theBeatLiftsTheCrestWithinTheFlashLimit() throws {
        // Average over 16-pixel blocks to exclude individual glints from the area brightness change.
        let size = CGSize(width: 640, height: 400)
        let v = TitaniumBackdropView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), seed: 7)
        v.parameters.audioReactivity = 3
        v.parameters.motion = .exciting
        v.setCover(ThemePaletteTests.quadrants([SIMD3(0.95, 0.9, 0.8), SIMD3(0.9, 0.75, 0.6), SIMD3(0.85, 0.85, 0.9), SIMD3(0.7, 0.8, 0.9)]), seed: "light")
        for _ in 0..<60 { v.advance(dt: 1 / 60) }
        func luminance(_ bytes: [UInt8]) -> [Float] {
            func lin(_ b: UInt8) -> Float { let c = Float(b) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return stride(from: 0, to: bytes.count, by: 4).map { 0.2126 * lin(bytes[$0 + 2]) + 0.7152 * lin(bytes[$0 + 1]) + 0.0722 * lin(bytes[$0]) }
        }
        func blockRise(_ a: [Float], _ b: [Float]) -> (largest: Float, total: Float) {
            var largest: Float = 0, total: Float = 0
            for by in 0..<(400 / 16) {
                for bx in 0..<(640 / 16) {
                    var d: Float = 0
                    for y in 0..<16 { for x in 0..<16 { let i = (by * 16 + y) * 640 + bx * 16 + x; d += b[i] - a[i] } }
                    largest = max(largest, d / 256)
                    total += d
                }
            }
            return (largest, total)
        }
        let still = luminance(try #require(v.renderFrame(size: size, format: .bgra8Unorm, heightPoints: 400)))
        // Allow 10% for the shader's gamma approximation.
        v.state.kick.value = 1
        let kick = blockRise(still, luminance(try #require(v.renderFrame(size: size, format: .bgra8Unorm, heightPoints: 400))))
        #expect(kick.total > 0)
        #expect(kick.largest <= 2 * TitaniumLook.beatLift * 1.1 + 0.003, "largest block rise \(kick.largest)")
        v.state.shimmer.value = 1
        let both = blockRise(still, luminance(try #require(v.renderFrame(size: size, format: .bgra8Unorm, heightPoints: 400))))
        #expect(both.largest < 0.08, "largest block rise with glints \(both.largest)")
    }

    @Test func reduceMotionStopsTheFlashesAndTheSweep() {
        let v = TitaniumBackdropView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), seed: 7)
        v.reduceMotion = true
        v.setCover(ThemePaletteTests.quadrants([SIMD3(0.8, 0.3, 0.2), SIMD3(0.2, 0.4, 0.7), SIMD3(0.6, 0.6, 0.3), SIMD3(0.3, 0.2, 0.4)]), seed: "a")
        v.spectrumProvider = {
            (0..<48).map { $0 < 8 ? 0.6 : 0.4 }
        }
        for _ in 0..<60 { v.advance(dt: 1 / 60) }
        v.spectrumProvider = {
            (0..<48).map { $0 < 8 ? 0.95 : 0.4 }
        }
        for _ in 0..<3 { v.advance(dt: 1 / 60) }
        #expect(v.state.pulse == 0 && v.state.burst == 0)
        v.setCover(ThemePaletteTests.quadrants([SIMD3(0.1, 0.1, 0.6), SIMD3(0.5, 0.5, 0.5), SIMD3(0.9, 0.2, 0.6), SIMD3(0.2, 0.7, 0.3)]), seed: "b")
        #expect(v.state.crestElapsed >= v.state.crestDuration)
    }

    @Test func previewFramesShowTheRestAndTheBeat() throws {
        let frames = try #require(TitaniumBackdropView.previewFrames(cover: ThemePaletteTests.quadrants([SIMD3(0.8, 0.3, 0.2), SIMD3(0.2, 0.4, 0.7), SIMD3(0.6, 0.6, 0.3), SIMD3(0.3, 0.2, 0.4)]),
                                                                     palette: .fallback, seed: "preview", size: CGSize(width: 800, height: 500), pixels: CGSize(width: 416, height: 260)))
        #expect(frames.rest.width == 416 && frames.rest.height == 260)
        func mean(_ image: CGImage) -> Float {
            let data = image.dataProvider!.data! as Data
            var sum = 0
            for i in stride(from: 0, to: data.count, by: 4) { sum += Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2]) }
            return Float(sum) / Float(data.count / 4 * 3) / 255
        }
        #expect(mean(frames.rest) > 0.05)
        #expect(mean(frames.beat) > mean(frames.rest))
    }

    // Float16 is unavailable on Intel Macs.
    private func halfPixels(_ bytes: [UInt8]) -> [SIMD3<Float>] {
        func half(_ i: Int) -> Float {
            let bits = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            let sign: Float = bits & 0x8000 != 0 ? -1 : 1
            let exponent = Int(bits >> 10 & 0x1f), fraction = Float(bits & 0x3ff)
            if exponent == 0 { return sign * fraction * pow(2, -24) }
            return sign * (1 + fraction / 1024) * pow(2, Float(exponent - 15))
        }
        return stride(from: 0, to: bytes.count, by: 8).map { SIMD3(half($0), half($0 + 2), half($0 + 4)) }
    }

    @Test func edrKeepsTheSDRPictureAndLiftsOnlyTheGlints() throws {
        let size = CGSize(width: 640, height: 400)
        let v = view()
        func decode(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let sdr = try #require(v.renderFrame(size: size, format: .bgra8Unorm, heightPoints: 400))
        var sdrMean = SIMD3<Float>.zero
        for i in stride(from: 0, to: sdr.count, by: 4) {
            sdrMean += SIMD3(decode(Float(sdr[i + 2]) / 255), decode(Float(sdr[i + 1]) / 255), decode(Float(sdr[i]) / 255))
        }
        sdrMean /= Float(sdr.count / 4)
        let flat = halfPixels(try #require(v.renderFrame(size: size, format: .rgba16Float, heightPoints: 400, headroom: 1)))
        let flatMean = flat.reduce(SIMD3<Float>.zero, +) / Float(flat.count)
        #expect(simd_distance(flatMean, sdrMean) < 0.003, "\(flatMean) vs \(sdrMean)")
        #expect(flat.allSatisfy { $0.max() <= 1.0005 })
        let bright = halfPixels(try #require(v.renderFrame(size: size, format: .rgba16Float, heightPoints: 400, headroom: 8)))
        let above = bright.filter { $0.max() > 1.05 }
        let peak = bright.map { $0.max() }.max() ?? 0
        #expect(peak > 1.5 && peak <= TitaniumLook.glintPeakCap + 0.01, "peak \(peak)")
        #expect(!above.isEmpty && Float(above.count) / Float(bright.count) < 0.01, "\(above.count) of \(bright.count) above white")
        var same = 0
        for (a, b) in zip(flat, bright) where simd_distance(a, b) < 1e-3 { same += 1 }
        #expect(Float(same) / Float(flat.count) > 0.97)
    }

    @Test func panelsCalmThePictureFurtherThanLyrics() throws {
        let size = CGSize(width: 640, height: 400)
        func texture(_ bytes: [UInt8]) -> (mean: Float, roughness: Float) {
            let w = 640
            var luma = [Float](repeating: 0, count: bytes.count / 4)
            for i in luma.indices { luma[i] = 0.2126 * Float(bytes[i * 4 + 2]) + 0.7152 * Float(bytes[i * 4 + 1]) + 0.0722 * Float(bytes[i * 4]) }
            var rough: Float = 0
            for y in 0..<400 { for x in 0..<(w - 1) { rough += abs(luma[y * w + x + 1] - luma[y * w + x]) } }
            return (luma.reduce(0, +) / Float(luma.count), rough / Float(400 * (w - 1)))
        }
        func frame(lyrics: Bool, panel: Bool) throws -> (mean: Float, roughness: Float) {
            let v = view()
            v.isBehindLyrics = lyrics
            v.isBehindText = panel
            for _ in 0..<200 { v.advance(dt: 1 / 60) }
            return texture(try #require(v.renderFrame(size: size, format: .bgra8Unorm, heightPoints: 400)))
        }
        let open = try frame(lyrics: false, panel: false)
        let lyrics = try frame(lyrics: true, panel: false)
        let panel = try frame(lyrics: false, panel: true)
        #expect(panel.mean < open.mean * 0.95 && abs(panel.mean - lyrics.mean) < lyrics.mean * 0.05, "\(open) \(lyrics) \(panel)")
        #expect(panel.roughness < lyrics.roughness && lyrics.roughness < open.roughness, "\(open) \(lyrics) \(panel)")
    }

    @Test func openingAPanelWakesTheHeldPictureAndSettlesAgain() {
        let v = view()
        v.isPlaying = false
        for _ in 0..<60 { v.advance(dt: 1 / 60) }
        v.holdIfIdle()
        #expect(v.isHolding)
        v.isBehindText = true
        #expect(!v.isHolding)
        for _ in 0..<200 { v.advance(dt: 1 / 60) }
        v.holdIfIdle()
        #expect(v.isHolding && v.state.textCalm > 0.99 && v.state.lyricScrim > 0.99)
    }
}
