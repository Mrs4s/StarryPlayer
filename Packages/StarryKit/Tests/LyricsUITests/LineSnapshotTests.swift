import AppKit
import LyricsCore
@testable import LyricsUI
import Metal
import QuartzCore
import Testing

/// The image `LineSnapshotRenderer` makes of a blurred line must be what Core Animation draws
/// for the live, filtered layer: both are rendered through `CARenderer` here and compared.
@MainActor
struct LineSnapshotTests {
    private func line(_ id: Int, _ text: String, start: Double, per: Double = 0.3, emphasize: Bool = false, translation: String? = nil) -> LyricLine {
        let syllables = Array(text).enumerated().map { i, c in
            LyricSyllable(start: start + Double(i) * per, end: start + Double(i + 1) * per + (emphasize && i == text.count - 1 ? 1.5 : 0), text: String(c))
        }
        var l = LyricLine(id: id, start: start, end: syllables.last!.end, words: LyricWordGrouping.words(from: syllables))
        l.translation = translation
        return l
    }

    private func makeLine(_ l: LyricLine, specs: LyricsSpecs, state: LineLayer.State, width: CGFloat, scale: CGFloat, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> LineLayer {
        let layout = LineTextLayout.layout(line: l, font: specs.font, width: width, leading: specs.fontLeading, alignment: .left, perSyllable: true)
        let translation = l.translation.map { TextBlockLayout.layout(text: $0, font: specs.translationFont, width: width, alignment: .left) }
        let layer = LineLayer(lineIndex: l.id, line: l, main: VoiceLayout(voice: l, text: layout, translation: translation), background: nil, alignment: .left)
        layer.build(width: width, specs: specs, tint: .white, scale: scale, colorSpace: colorSpace, translationTint: .white)
        layer.apply(state: state, specs: specs, scrolling: false, animated: false)
        return layer
    }

    private func render(_ root: CALayer, size: CGSize, scale: CGFloat, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: desc))
        let queue = try #require(device.makeCommandQueue())
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: colorSpace, kCARendererMetalCommandQueue: queue])
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: w, height: h)
        root.isGeometryFlipped = true
        root.anchorPoint = .zero
        root.position = .zero
        root.bounds = CGRect(origin: .zero, size: size)
        root.transform = CATransform3DMakeScale(scale, scale, 1)
        host.addSublayer(root)
        renderer.layer = host
        renderer.bounds = host.frame
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime() + 5, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let sync = try #require(queue.makeCommandBuffer())
        sync.commit()
        sync.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        root.removeFromSuperlayer()
        return bytes
    }

    /// Animation end-time check independent of the production visibility threshold. Finished
    /// animations may remain attached until the next commit, so animationKeys alone is not enough.
    private func hasRunningAnimations(_ layer: CALayer, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        if let keys = layer.animationKeys(), !keys.isEmpty {
            let t = layer.convertTime(now, from: nil)
            for key in keys {
                guard let animation = layer.animation(forKey: key) else { continue }
                if animation.beginTime == 0 || t < animation.beginTime + animation.duration / Double(max(animation.speed, 0.001)) { return true }
            }
        }
        if let mask = layer.mask, hasRunningAnimations(mask, now: now) { return true }
        return layer.sublayers?.contains { hasRunningAnimations($0, now: now) } ?? false
    }

    /// Leaving the selected state fades the colours over 0.4 s and blurs over 0.12 s; the image
    /// must wait for the colour fade and internal motion to settle.
    @Test func lineFreezesOnlyAfterItsAnimationsSettled() throws {
        let renderer = try #require(LineSnapshotRenderer.shared)
        let specs = LyricsSpecs.windowed.scaled()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: window.contentView!.bounds)
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        window.contentView?.addSubview(view)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layer!.isGeometryFlipped = true
        // One-character words, so no word is emphasised: an emphasis settle spring alone would
        // rightly keep the line live for seconds.
        let layer = makeLine(line(1, "薄汚れた白い背中を", start: 10), specs: specs, state: .selected, width: 700, scale: 2)
        layer.position = CGPoint(x: 40, y: 80)
        view.layer!.addSublayer(layer)
        layer.setBlurRadius(0, animated: false)
        layer.updateSyllables(time: 20, specs: specs)
        // Skip the syllable lifts (1/14/7 springs, 2.3 s); they are not what is tested.
        func settle(_ l: CALayer) {
            l.removeAllAnimations()
            l.mask.map(settle)
            l.sublayers?.forEach(settle)
        }
        settle(layer)
        CATransaction.flush()
        #expect(hasRunningAnimations(layer.containerLayer) == false)
        var installedAfter: CFTimeInterval?
        let start = CACurrentMediaTime()
        layer.snapshotRequest = { l in
            guard let s = renderer.render(l, radius: l.appliedBlur, scale: 2) else { return }
            l.install(s)
            if l.isShowingSnapshot { installedAfter = CACurrentMediaTime() - start }
        }
        layer.apply(state: .past, specs: specs, scrolling: false, animated: true, spring: specs.lineChangeSpring)
        layer.setBlurRadius(3, animated: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        #expect(layer.isShowingSnapshot == false, "frozen while the colour fade still runs")
        #expect(abs((layer.rows.first?.progressLayer.presentation()?.opacity ?? 1) - 0) > 0.01)
        let deadline = Date(timeIntervalSinceNow: 1.5)
        while !layer.isShowingSnapshot, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        #expect(layer.isShowingSnapshot)
        #expect(layer.filters == nil)
        #expect(layer.shouldRasterize == false)
        #expect((installedAfter ?? 0) >= 0.4, "frozen after \(installedAfter ?? 0) s")
        #expect(hasRunningAnimations(layer.containerLayer) == false)
        layer.apply(state: .selected, specs: specs, scrolling: false, animated: true)
        layer.setBlurRadius(0, animated: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        #expect(layer.isShowingSnapshot == false)
        #expect(layer.filters == nil)
        #expect(layer.shouldRasterize == false)
    }

    @Test(arguments: [(LineLayer.State.upcoming, CGFloat(3), false), (.past, 4, true), (.upcoming, 2, true)])
    func snapshotMatchesLiveFilter(state: LineLayer.State, radius: CGFloat, translated: Bool) throws {
        let renderer = try #require(LineSnapshotRenderer.shared)
        let specs = LyricsSpecs.windowed.scaled()
        let width: CGFloat = 700
        let scale: CGFloat = 2
        let text = state == .past ? "我们一起走过的那些日子" : "Hello darkness, forever"
        let l = line(1, text, start: 10, emphasize: true, translation: translated ? "这是一句翻译" : nil)
        let layer = makeLine(l, specs: specs, state: state, width: width, scale: scale)
        layer.setBlurRadius(radius, animated: false)
        let size = CGSize(width: width + 80, height: layer.contentHeight + 80)
        let root = CALayer()
        layer.position = CGPoint(x: 40, y: 40 + layer.contentHeight / 2)
        root.addSublayer(layer)

        let live = try render(root, size: size, scale: scale)
        #expect(layer.isShowingSnapshot == false)
        #expect(layer.filters?.isEmpty == false)

        let snapshot = try #require(renderer.render(layer, radius: radius, scale: scale))
        #expect(snapshot.image.width == Int(snapshot.rect.width * scale))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) // becomeStatic fires (holdFor 0)
        #expect(layer.wantsSnapshot)
        layer.install(snapshot)
        #expect(layer.isShowingSnapshot)
        #expect(layer.filters == nil)
        let frozen = try render(root, size: size, scale: scale)
        expectSamePixels(live: live, frozen: frozen)
    }

    /// In a Display P3 window the rows are drawn in P3 and so is the image (Core Animation
    /// would keep a converted copy of either in another space); it must still look like the
    /// live filter there. Released targets come back on the next render.
    @Test func snapshotIsDrawnInTheSpaceOfTheLine() throws {
        let renderer = try #require(LineSnapshotRenderer.shared)
        renderer.releaseTargets()
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let specs = LyricsSpecs.windowed.scaled()
        let width: CGFloat = 700
        let scale: CGFloat = 2
        let layer = makeLine(line(1, "我们一起走过的那些日子", start: 10, translation: "这是一句翻译"), specs: specs, state: .upcoming, width: width, scale: scale, colorSpace: p3)
        layer.setBlurRadius(3, animated: false)
        let size = CGSize(width: width + 80, height: layer.contentHeight + 80)
        let root = CALayer()
        layer.position = CGPoint(x: 40, y: 40 + layer.contentHeight / 2)
        root.addSublayer(layer)
        let live = try render(root, size: size, scale: scale, colorSpace: p3)
        let snapshot = try #require(renderer.render(layer, radius: 3, scale: scale))
        #expect(snapshot.image.colorSpace == p3)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) // becomeStatic fires
        layer.install(snapshot)
        #expect(layer.isShowingSnapshot)
        let frozen = try render(root, size: size, scale: scale, colorSpace: p3)
        expectSamePixels(live: live, frozen: frozen)
    }

    /// Freezing must preserve position even away from device-pixel boundaries. An un-rasterized
    /// live filter samples on a different grid and can jump by up to a pixel on a 1x display.
    @Test(arguments: zip([CGFloat(1), 2], [CGFloat(0.5), 0.25]))
    func snapshotPreservesPositionAtFractionalOrigins(scale: CGFloat, phase: CGFloat) throws {
        let renderer = try #require(LineSnapshotRenderer.shared)
        let specs = LyricsSpecs.windowed.scaled()
        let width: CGFloat = 700
        let layer = makeLine(line(1, "薄汚れた白い背中を", start: 10), specs: specs, state: .past, width: width, scale: scale)
        for syllable in layer.syllables { syllable.setLifted(true, lift: specs.syllableLift, spring: nil) }
        layer.setBlurRadius(3, animated: false)
        let size = CGSize(width: width + 80, height: ceil(layer.contentHeight + 80))
        let root = CALayer()
        layer.position = CGPoint(x: 40 + phase, y: 40 + layer.contentHeight / 2 + phase)
        root.addSublayer(layer)
        let live = try render(root, size: size, scale: scale)
        let snapshot = try #require(renderer.render(layer, radius: 3, scale: scale))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        layer.install(snapshot)
        #expect(layer.isShowingSnapshot)
        let frozen = try render(root, size: size, scale: scale)
        func centroid(_ bytes: [UInt8]) -> CGPoint {
            let w = Int(size.width * scale)
            var mass = 0.0, x = 0.0, y = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = Double(bytes[i + 3])
                mass += a
                x += Double((i / 4) % w) * a
                y += Double((i / 4) / w) * a
            }
            return CGPoint(x: x / mass, y: y / mass)
        }
        let a = centroid(live), b = centroid(frozen)
        #expect(abs(a.y - b.y) < 0.1, "vertical jump: \(b.y - a.y) pixels")
        #expect(abs(a.x - b.x) < 0.1, "horizontal jump: \(b.x - a.x) pixels")
        expectSamePixels(live: live, frozen: frozen)
    }

    /// The image goes through one extra 8-bit quantisation, so single-step differences are
    /// expected on a few pixels; anything larger would be a real mismatch.
    private func expectSamePixels(live: [UInt8], frozen: [UInt8]) {
        var painted = 0, differing = 0, maxDiff = 0
        for i in stride(from: 0, to: live.count, by: 4) {
            if live[i + 3] > 0 { painted += 1 }
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(live[i + c]) - Int(frozen[i + c]))) }
            maxDiff = max(maxDiff, d)
            if d > 3 { differing += 1 }
        }
        #expect(painted > 500, "the live render is empty")
        #expect(maxDiff <= 6, "max pixel difference \(maxDiff)")
        #expect(differing < painted / 50, "\(differing) of \(painted) painted pixels differ by more than 3, max \(maxDiff)")
    }

    /// Every line change moves the neighbours' blur radius one step. A frozen line must not go
    /// live for that: it keeps its image, asks for one at the new radius and crossfades, and
    /// ends up looking like the live filter at that radius.
    @Test func frozenLineChangesRadiusWithoutAFilter() throws {
        let renderer = try #require(LineSnapshotRenderer.shared)
        let specs = LyricsSpecs.windowed.scaled()
        let width: CGFloat = 700
        let scale: CGFloat = 2
        let l = line(1, "我们一起走过的那些日子", start: 10, emphasize: true, translation: "这是一句翻译")
        let layer = makeLine(l, specs: specs, state: .upcoming, width: width, scale: scale)
        layer.setBlurRadius(3, animated: false)
        let size = CGSize(width: width + 80, height: layer.contentHeight + 80)
        let root = CALayer()
        layer.position = CGPoint(x: 40, y: 40 + layer.contentHeight / 2)
        root.addSublayer(layer)
        var requested: [CGFloat] = []
        layer.snapshotRequest = { requested.append($0.appliedBlur) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) // becomeStatic fires
        #expect(requested == [3])
        layer.install(try #require(renderer.render(layer, radius: 3, scale: scale)))
        #expect(layer.isShowingSnapshot)
        #expect(layer.installedRadius == 3)

        layer.setBlurRadius(4, animated: true)
        #expect(layer.isShowingSnapshot, "went live for a radius change")
        #expect(layer.filters == nil)
        #expect(layer.wantsSnapshot)
        #expect(requested == [3, 4])
        let snapshot = try #require(renderer.render(layer, radius: 4, scale: scale))
        #expect(snapshot.image.width > 100, "an image of the hidden container is empty")
        layer.install(snapshot)
        #expect(layer.installedRadius == 4)
        #expect(layer.filters == nil)
        #expect(layer.wantsSnapshot == false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) // the crossfade ends
        let frozen = try render(root, size: size, scale: scale)

        let reference = makeLine(l, specs: specs, state: .upcoming, width: width, scale: scale)
        reference.setBlurRadius(4, animated: false)
        let referenceRoot = CALayer()
        reference.position = layer.position
        referenceRoot.addSublayer(reference)
        let live = try render(referenceRoot, size: size, scale: scale)
        #expect(reference.filters?.isEmpty == false)
        expectSamePixels(live: live, frozen: frozen)
    }
}
