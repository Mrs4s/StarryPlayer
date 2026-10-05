import AppKit
import Metal
import QuartzCore

struct LineSnapshot {
    /// Rect the image covers, in the line layer's coordinates.
    let rect: CGRect
    let radius: CGFloat
    let scale: CGFloat
    let image: CGImage
}

/// Snapshot settled blurred lines with CARenderer. Plain images avoid the render
/// server revisiting filtered layers on every commit; preserve local-coordinate sampling.
@MainActor
final class LineSnapshotRenderer {
    static let shared: LineSnapshotRenderer? = LineSnapshotRenderer()

    private struct Target {
        let texture: MTLTexture
        let renderer: CARenderer
        let host: CALayer
        let stage: CALayer
        var lastUsed: Int
    }

    private struct TargetKey: Hashable {
        let width: Int
        let height: Int
        let colorSpace: CGColorSpace
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var targets: [TargetKey: Target] = [:]
    private var useCount = 0
    private static let maxTargets = 4

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        queue.label = "lyrics.snapshot"
        self.device = device
        self.queue = queue
    }

    /// The line as the render server would draw it at `radius`, `scale` pixels per point, in
    /// the space of its bitmaps (the window's): Core Animation would keep a converted copy of
    /// images in any other, here of the line's rows and in the window of the result.
    func render(_ line: LineLayer, radius: CGFloat, scale: CGFloat) -> LineSnapshot? {
        let rect = line.snapshotExtent(radius: radius, scale: scale)
        let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
        let colorSpace = line.renderColorSpace
        guard w > 0, h > 0, w <= 8192, h <= 8192, let target = target(width: w, height: h, colorSpace: colorSpace) else { return nil }
        let signposter = LyricsSignposts.poi
        let signpost = signposter.beginInterval("Line snapshot", id: signposter.makeSignpostID(), "\(w)×\(h) px, radius \(Double(radius))")
        defer { signposter.endInterval("Line snapshot", signpost) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let standIn = CALayer()
        standIn.anchorPoint = .zero
        standIn.position = CGPoint(x: -rect.minX, y: -rect.minY)
        standIn.bounds = line.bounds
        standIn.shouldRasterize = true
        standIn.rasterizationScale = scale
        if let container = LayerCloning.clone(line.containerLayer, ignoringHidden: true) {
            standIn.addSublayer(container)
        }
        if radius > 0, let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            standIn.filters = [filter]
        }
        target.stage.bounds = CGRect(origin: .zero, size: rect.size)
        target.stage.transform = CATransform3DMakeScale(scale, scale, 1)
        target.stage.sublayers = [standIn]
        CATransaction.commit()
        CATransaction.flush()

        // Clear, render, wait: everything goes through one queue, so it runs in order.
        if let buffer = queue.makeCommandBuffer() {
            buffer.label = "lyrics.snapshot.clear"
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            buffer.commit()
        }
        let renderer = target.renderer
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let sync = queue.makeCommandBuffer() else { return nil }
        sync.label = "lyrics.snapshot.wait"
        sync.commit()
        sync.waitUntilCompleted()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.stage.sublayers = nil
        CATransaction.commit()

        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        target.texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var flipped = Data(count: bytesPerRow * h)
        flipped.withUnsafeMutableBytes { dst in
            bytes.withUnsafeBytes { src in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                for row in 0..<h {
                    memcpy(d + row * bytesPerRow, s + (h - 1 - row) * bytesPerRow, bytesPerRow)
                }
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: flipped as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return LineSnapshot(rect: rect, radius: radius, scale: scale, image: image)
    }

    func releaseTargets() {
        targets.removeAll()
    }

    /// Texture + renderer for one pixel size; lines share a few sizes, so a handful is kept.
    private func target(width: Int, height: Int, colorSpace: CGColorSpace) -> Target? {
        useCount += 1
        let key = TargetKey(width: width, height: height, colorSpace: colorSpace)
        if var target = targets[key] {
            target.lastUsed = useCount
            targets[key] = target
            return target
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: colorSpace, kCARendererMetalCommandQueue: queue])
        let host = CALayer()
        let stage = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        stage.isGeometryFlipped = true
        stage.anchorPoint = .zero
        stage.position = .zero
        host.addSublayer(stage)
        CATransaction.commit()
        renderer.layer = host
        renderer.bounds = host.frame
        if targets.count >= Self.maxTargets, let oldest = targets.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            targets[oldest.key] = nil
        }
        let target = Target(texture: texture, renderer: renderer, host: host, stage: stage, lastUsed: useCount)
        targets[key] = target
        return target
    }
}

enum LayerCloning {
    /// Nil when the layer draws nothing (hidden or fully transparent, subtree included);
    /// `ignoringHidden` copies a hidden root anyway.
    static func clone(_ layer: CALayer, ignoringHidden: Bool = false) -> CALayer? {
        guard ignoringHidden || !layer.isHidden, layer.opacity > 0 else { return nil }
        let copy: CALayer
        if let gradient = layer as? CAGradientLayer {
            let g = CAGradientLayer()
            g.colors = gradient.colors
            g.locations = gradient.locations
            g.startPoint = gradient.startPoint
            g.endPoint = gradient.endPoint
            g.type = gradient.type
            copy = g
        } else {
            copy = CALayer()
        }
        copy.bounds = layer.bounds
        copy.position = layer.position
        copy.anchorPoint = layer.anchorPoint
        copy.anchorPointZ = layer.anchorPointZ
        copy.transform = layer.transform
        copy.sublayerTransform = layer.sublayerTransform
        copy.opacity = layer.opacity
        copy.isGeometryFlipped = layer.isGeometryFlipped
        copy.isDoubleSided = layer.isDoubleSided
        copy.masksToBounds = layer.masksToBounds
        copy.cornerRadius = layer.cornerRadius
        copy.backgroundColor = layer.backgroundColor
        copy.borderColor = layer.borderColor
        copy.borderWidth = layer.borderWidth
        copy.contents = layer.contents
        copy.contentsRect = layer.contentsRect
        copy.contentsCenter = layer.contentsCenter
        copy.contentsScale = layer.contentsScale
        copy.contentsGravity = layer.contentsGravity
        copy.minificationFilter = layer.minificationFilter
        copy.magnificationFilter = layer.magnificationFilter
        copy.shadowColor = layer.shadowColor
        copy.shadowOpacity = layer.shadowOpacity
        copy.shadowRadius = layer.shadowRadius
        copy.shadowOffset = layer.shadowOffset
        copy.shadowPath = layer.shadowPath
        copy.shouldRasterize = layer.shouldRasterize
        copy.rasterizationScale = layer.rasterizationScale
        if let mask = layer.mask {
            // A mask that draws nothing hides everything, so keep an empty one in that case.
            copy.mask = clone(mask) ?? CALayer()
        }
        for sublayer in layer.sublayers ?? [] {
            if let c = clone(sublayer) { copy.addSublayer(c) }
        }
        return copy
    }
}
