import AppKit
import Metal
import MetalKit
import MetalPerformanceShaders
import os
import QuartzCore
import simd

@MainActor
public final class ArtworkBackdropView: MTKView {
    public struct Parameters: Sendable, Equatable {
        public enum Motion: Sendable, Equatable { case auto, subdued, exciting }
        /// `auto` = exciting while `isBehindLyrics`, subdued otherwise.
        public var motion: Motion = .auto
        /// Rotation / warp clock multiplier (1 = a 60 Hz reference clock in real time).
        public var speed: Float = 1
        public var blurScale: Float = 1
        public var saturationScale: Float = 1
        public var brightness: Float = 1
        public var blackScrim: Float = BackdropLook.blackScrimDark
        /// White scrim applied before the colour grade (default 0.1).
        public var whiteScrim: Float = BackdropLook.whiteScrim
        public var audioReactivity: Float = 1
        /// Amplitude of the mesh warp while exciting, 0…1 (1 = the grids as authored, which already
        /// sit at the fold limit; 0 disables the pinch pass).
        public var pinchStrength: Float = 1
        public var colorGrade: Bool = true
        public var framesPerSecond: Int = 30
        /// Drawable resolution relative to the backing scale (0.1…1). The output is a heavily
        /// blurred image, so half resolution looks the same at a quarter of the fill rate and
        /// drawable memory.
        public var renderScale: Float = 0.5

        public init() {}
    }

    /// Energies 0…1 (low, mid, high, overall) sampled every frame.
    public var energyProvider: (@MainActor () -> SIMD4<Float>)?
    /// Set while the lyrics page shows lyrics (whether playing or not); `Motion.auto` switches to
    /// exciting then.
    public var isBehindLyrics = false

    public var parameters = Parameters() {
        didSet {
            preferredFramesPerSecond = max(10, parameters.framesPerSecond)
            if parameters.pinchStrength != oldValue.pinchStrength { meshDirty = true }
            if parameters.renderScale != oldValue.renderScale { updateDrawableSize() }
        }
    }

    public var palette: CoverPalette = .fallback {
        didSet { if palette != oldValue, currentIsPlaceholder { setPlaceholder() } }
    }

    /// Frames rendered so far (debugging).
    public private(set) var frameCount = 0
    public private(set) var blurRadius: Float = 0
    /// Bits per channel of the drawable: 10 when the window's screen has more than 8 bits per
    /// sample (`outputBitsOverride` forces one), 8 otherwise. Both formats are 4 bytes per
    /// pixel, so the deeper one costs no memory or bandwidth.
    public private(set) var outputBits = 8

    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var blendPipeline: MTLRenderPipelineState?
    private var rotatePipeline: MTLRenderPipelineState?
    private var pinchPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var linearSampler: MTLSamplerState?
    /// `BackdropLUT` as a 32³ texture, or a 1³ stand-in (`hasLUT` false) so the shader always has
    /// a texture bound.
    private var lutTexture: MTLTexture?
    private var hasLUT = false
    /// Blur kernels by sigma in half-texel steps (`MPSImageGaussianBlur.sigma` is immutable and
    /// the radius ramps between the subdued and exciting tables, so the same few dozen values
    /// come back every transition).
    private var blurKernels: [Int: MPSImageGaussianBlur] = [:]
    private var supportsMPS = false
    private var setupFailed = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private struct Intermediates {
        var size: (Int, Int)
        var rotation: MTLTexture
        var blurred: MTLTexture
    }

    private var liveIntermediates: Intermediates?
    private var captureIntermediates: Intermediates?
    private var blendTexture: MTLTexture?
    private var holdTexture: MTLTexture?
    private var currentArtwork: MTLTexture?
    private var previousArtwork: MTLTexture?
    private var incomingArtwork: MTLTexture?
    private var pendingHold = false
    private var blendRendered = false
    private var blendDirty = true
    private var currentIsPlaceholder = true

    private var meshVertexBuffer: MTLBuffer?
    private var meshIndexBuffer: MTLBuffer?
    private var meshIndexCount = 0
    private var meshDirty = true
    private var meshSeed: UInt64 = 1
    private var meshLandscape: Bool?

    private var time: Float = 0
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var spectrum = SpectrumPower()
    private var power = SIMD4<Float>(repeating: 0)
    private var crossfadeProgress: Float = 1
    private var pinchProgress: Float = 0
    private var saturation: Float = 0
    private var stateInitialised = false

    private struct RotateUniforms {
        var models: (float4x4, float4x4, float4x4)
        var blackScrim: Float
        var contrast: Float
        var saturation: Float
        var instanceStep: Float
    }

    private struct BlendUniforms {
        var mix: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    private struct PinchUniforms {
        var pinchMix: Float
        var warpMix: Float
        var whiteScrim: Float
        var brightness: Float
        var grade: Float
        var ditherStep: Float
        var pad1: Float = 0
        var pad2: Float = 0
    }

    private static let blendSize = 512

    public init(frame: CGRect = .zero) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = parameters.framesPerSecond
        layer?.isOpaque = true
        autoResizeDrawable = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        setup()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        guard let device else { setupFailed = true; return }
        commandQueue = device.makeCommandQueue()
        commandQueue?.label = "backdrop"
        supportsMPS = MPSSupportsMTLDevice(device)
        do {
            let library = try device.makeLibrary(source: BackdropShader.source, options: nil)
            self.library = library
            blendPipeline = try Self.pipeline(library, "fullscreen_vertex", "blend_fragment", .bgra8Unorm)
            rotatePipeline = try Self.pipeline(library, "rotate_vertex", "rotate_fragment", .rgba16Float)
        } catch {
            NSLog("[backdrop] shader compile failed: %@", String(describing: error))
            setupFailed = true
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: samplerDescriptor)
        makeLUTTexture(device: device)
        let blendDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.blendSize, height: Self.blendSize, mipmapped: false)
        blendDescriptor.usage = [.shaderRead, .renderTarget]
        blendDescriptor.storageMode = .private
        blendTexture = device.makeTexture(descriptor: blendDescriptor)
        holdTexture = device.makeTexture(descriptor: blendDescriptor)
        setPlaceholder()
    }

    private static func pipeline(_ library: MTLLibrary, _ vertex: String, _ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = format
        return try library.device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The pinch pass writes the target, so it needs one pipeline per target format; built on
    /// first use (most screens only ever need the one).
    private func pinchPipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = pinchPipelines[format] { return cached }
        guard let library else { return nil }
        do {
            let pipeline = try Self.pipeline(library, "pinch_vertex", "pinch_fragment", format)
            pinchPipelines[format] = pipeline
            return pipeline
        } catch {
            NSLog("[backdrop] pinch pipeline for format %lu failed: %@", format.rawValue, String(describing: error))
            return nil
        }
    }

    private func makeLUTTexture(device: MTLDevice) {
        let table = BackdropLUT.table
        let side = table == nil ? 1 : BackdropLUT.size
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = side
        descriptor.height = side
        descriptor.depth = side
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        texture.label = "backdrop.lut"
        let bytes = table ?? [0, 0, 0, 255]
        texture.replace(region: MTLRegionMake3D(0, 0, 0, side, side, side), mipmapLevel: 0, slice: 0, withBytes: bytes, bytesPerRow: side * 4, bytesPerImage: side * side * 4)
        lutTexture = texture
        hasLUT = table != nil
    }

    /// Swaps the cover art in with a crossfade. Pass nil to fall back to a palette gradient.
    public func setCover(_ image: CGImage?, seed newSeed: String? = nil) {
        if let newSeed {
            let seed = PinchMesh.seed(from: newSeed)
            if seed != meshSeed { meshSeed = seed; meshDirty = true }
        }
        guard let image, let texture = makeTexture(from: image) else {
            setPlaceholder()
            return
        }
        currentIsPlaceholder = false
        enqueue(texture)
    }

    private func setPlaceholder() {
        currentIsPlaceholder = true
        guard let image = Self.paletteImage(palette), let texture = makeTexture(from: image) else { return }
        enqueue(texture)
    }

    private func enqueue(_ texture: MTLTexture) {
        incomingArtwork = texture
        pendingHold = true
        blendDirty = true
    }

    /// Upload BGRA explicitly: MTKTextureLoader can interpret ARGB bytes as BGRA and swap red/blue.
    private func makeTexture(from image: CGImage) -> MTLTexture? {
        guard let device else { return nil }
        let side = min(Self.blendSize, max(image.width, image.height, 1))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: info.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        // Aspect-fill a non-square cover into the square texture (centre crop) instead of squashing it.
        let scale = CGFloat(side) / CGFloat(max(min(image.width, image.height), 1))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - drawSize.width) / 2, y: (CGFloat(side) - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.shaderRead]
        // Unified memory needs no extra CPU copy from managed textures.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "backdrop.artwork"
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: data, bytesPerRow: side * 4)
        return texture
    }

    private static func paletteImage(_ palette: CoverPalette) -> CGImage? {
        let side = 64
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let stops = ([palette.dominant] + palette.accents).prefix(3)
        let colors = stops.map { CGColor(colorSpace: space, components: [CGFloat($0.r), CGFloat($0.g), CGFloat($0.b), 1])! }
        let locations: [CGFloat] = colors.count == 1 ? [0] : (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return ctx.makeImage()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        }
        updateOutputFormat()
        updatePaused()
    }

    @objc private func occlusionChanged(_ note: Notification) {
        updatePaused()
    }

    @objc private func screenChanged(_ note: Notification) {
        updateOutputFormat()
    }

    /// Draws at this many bits per sample (8 or 10) on every screen; nil follows each screen.
    public static var outputBitsOverride: Int?

    /// 10-bit drawable on screens deeper than 8 bits per sample, 8-bit otherwise, where a 10-bit
    /// drawable would only be truncated again and its finer dither lost.
    private func updateOutputFormat() {
        guard let screen = window?.screen else { return }
        let bits = (Self.outputBitsOverride ?? screen.depth.bitsPerSample) > 8 ? 10 : 8
        guard bits != outputBits else { return }
        outputBits = bits
        colorPixelFormat = bits > 8 ? .bgr10a2Unorm : .bgra8Unorm
        NSLog("[backdrop] %d-bit output (%@: %d bits per sample)", bits, screen.localizedName, screen.depth.bitsPerSample)
    }

    @objc private func accessibilityOptionsChanged(_ note: Notification) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateDrawableSize() {
        let backing = window?.backingScaleFactor ?? 2
        let scale = CGFloat(min(max(parameters.renderScale, 0.1), 1)) * backing
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != size { drawableSize = size }
    }

    private func updatePaused() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible, isPaused { lastFrameTime = CACurrentMediaTime() }
        isPaused = !visible
    }

    private static let signposter = OSSignposter(subsystem: "moe.mrs4s.starry-player", category: .pointsOfInterest)

    public override func draw(_ dirtyRect: NSRect) {
        let signpost = Self.signposter.beginInterval("Backdrop frame", id: Self.signposter.makeSignpostID(),
                                                     "\(Int(self.drawableSize.width))×\(Int(self.drawableSize.height)) px")
        defer { Self.signposter.endInterval("Backdrop frame", signpost) }
        guard !setupFailed, let commandQueue, let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer() else { return }
        buffer.label = "backdrop.frame"
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastFrameTime))
        lastFrameTime = now
        let size = drawableSize
        advance(dt: dt, landscape: size.width > size.height)
        let scale = bounds.width > 0 ? Float(size.width / bounds.width) : 2
        var intermediates = liveIntermediates
        encode(into: buffer, target: pass, size: size, scale: scale, intermediates: &intermediates)
        liveIntermediates = intermediates
        buffer.present(drawable)
        buffer.commit()
        frameCount += 1
    }

    /// Renders one frame into an offscreen texture, for snapshots: `cacheDisplay` cannot read
    /// Metal drawables.
    public func captureFrame(size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let bytes = renderFrame(size: size, format: .bgra8Unorm) else { return nil }
        let bytesPerRow = width * 4
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func renderFrame(size: CGSize, format: MTLPixelFormat) -> [UInt8]? {
        guard !setupFailed, let device, let commandQueue else { return nil }
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = commandQueue.makeCommandBuffer() else { return nil }
        buffer.label = "backdrop.capture"
        if !stateInitialised { advance(dt: 0, landscape: width > height) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        var intermediates = captureIntermediates
        encode(into: buffer, target: pass, size: size, scale: 1, intermediates: &intermediates)
        captureIntermediates = intermediates
        buffer.commit()
        buffer.waitUntilCompleted()
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    private var resolvedIntensity: BackdropIntensity {
        switch parameters.motion {
        case .auto: isBehindLyrics ? .exciting : .subdued
        case .subdued: .subdued
        case .exciting: .exciting
        }
    }

    /// Per-frame state update: clock, spectrum, transitions.
    /// Internal so tests can step the state before `captureFrame`.
    func advance(dt: CFTimeInterval, landscape: Bool) {
        let dt = Float(dt)
        time += dt * (reduceMotion ? 0.1 : 1) * parameters.speed

        let energy = energyProvider?() ?? SIMD4(repeating: 0)
        let input = SIMD4(energy.x, energy.y, energy.w, energy.z) * parameters.audioReactivity
        spectrum.update(input: input, dt: dt)
        let intensity = resolvedIntensity
        power = spectrum.power(intensity: intensity.power)

        let rate = dt / (BackdropLook.transitionDuration / 2)
        crossfadeProgress = min(1, crossfadeProgress + rate)
        let pinching = intensity == .exciting && parameters.pinchStrength > 0
        pinchProgress = pinching ? min(1, pinchProgress + rate) : max(0, pinchProgress - rate)

        let blurTarget = BackdropLook.blurRadius(landscape: landscape, intensity: intensity) * parameters.blurScale
        let saturationTarget = BackdropLook.saturation(landscape: landscape, intensity: intensity) * parameters.saturationScale
        if !stateInitialised {
            blurRadius = blurTarget
            saturation = saturationTarget
            stateInitialised = true
        } else {
            let step = BackdropLook.blurRadiusPointsPerSecond * dt * max(0.25, parameters.blurScale)
            blurRadius += min(step, max(-step, blurTarget - blurRadius))
            saturation += (saturationTarget - saturation) * min(1, rate)
        }
    }

    private func makeIntermediates(width: Int, height: Int) -> Intermediates? {
        guard let device else { return nil }
        let w = max(1, width / BackdropLook.blurDownsample), h = max(1, height / BackdropLook.blurDownsample)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let rotation = device.makeTexture(descriptor: descriptor), let blurred = device.makeTexture(descriptor: descriptor) else { return nil }
        rotation.label = "backdrop.rotation"
        blurred.label = "backdrop.blurred"
        return Intermediates(size: (width, height), rotation: rotation, blurred: blurred)
    }

    private func rebuildMeshIfNeeded(landscape: Bool) {
        guard meshDirty || meshLandscape != landscape, let device else { return }
        meshDirty = false
        meshLandscape = landscape
        let mesh = PinchMesh.make(landscape: landscape, seed: meshSeed, strength: parameters.pinchStrength)
        meshVertexBuffer = mesh.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        meshIndexBuffer = mesh.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        meshIndexCount = mesh.indices.count
    }

    private func encode(into buffer: MTLCommandBuffer, target: MTLRenderPassDescriptor, size: CGSize, scale: Float, intermediates: inout Intermediates?) {
        guard let blendPipeline, let rotatePipeline, let linearSampler, let blendTexture,
              let targetFormat = target.colorAttachments[0].texture?.pixelFormat,
              let pinchPipeline = pinchPipeline(for: targetFormat) else { return }
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        if intermediates == nil || intermediates!.size != (width, height) {
            intermediates = makeIntermediates(width: width, height: height)
        }
        guard let intermediates else { return }
        rebuildMeshIfNeeded(landscape: width > height)

        // 1. Artwork crossfade. A pending cover first snapshots the current blend so a transition
        //    interrupted mid-way starts from what is on screen.
        if pendingHold, let incomingArtwork {
            if blendRendered, let holdTexture, let blit = buffer.makeBlitCommandEncoder() {
                blit.copy(from: blendTexture, to: holdTexture)
                blit.endEncoding()
                previousArtwork = holdTexture
                crossfadeProgress = 0
            } else {
                previousArtwork = nil
                crossfadeProgress = 1
            }
            currentArtwork = incomingArtwork
            self.incomingArtwork = nil
            pendingHold = false
            blendDirty = true
        }
        guard let currentArtwork else { return }
        if blendDirty || crossfadeProgress < 1 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = blendTexture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "backdrop.blend"
                encoder.setRenderPipelineState(blendPipeline)
                var uniforms = BlendUniforms(mix: previousArtwork == nil ? 1 : CubicBezier.easeOut.solve(crossfadeProgress))
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlendUniforms>.stride, index: 0)
                encoder.setFragmentTexture(previousArtwork ?? currentArtwork, index: 0)
                encoder.setFragmentTexture(currentArtwork, index: 1)
                encoder.setFragmentSamplerState(linearSampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            blendRendered = true
            blendDirty = crossfadeProgress < 1
        }

        let aspect = Float(width) / Float(height)
        let models = (0..<3).map { BackdropLook.instanceMatrix(index: $0, time: time, aspect: aspect, power: power) }
        var rotateUniforms = RotateUniforms(
            models: (models[0], models[1], models[2]),
            blackScrim: parameters.blackScrim,
            contrast: 1 + power.x * 0.076,
            saturation: saturation + power.z * 0.166,
            instanceStep: BackdropLook.instanceScrimStep
        )
        let rotatePass = MTLRenderPassDescriptor()
        rotatePass.colorAttachments[0].texture = intermediates.rotation
        rotatePass.colorAttachments[0].loadAction = .clear
        rotatePass.colorAttachments[0].storeAction = .store
        rotatePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: rotatePass) {
            encoder.label = "backdrop.rotate"
            encoder.setRenderPipelineState(rotatePipeline)
            encoder.setVertexBytes(&rotateUniforms, length: MemoryLayout<RotateUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&rotateUniforms, length: MemoryLayout<RotateUniforms>.stride, index: 0)
            encoder.setFragmentTexture(blendTexture, index: 0)
            encoder.setFragmentSamplerState(linearSampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 3)
            encoder.endEncoding()
        }

        let sigmaKey = Int((blurRadius * scale / Float(BackdropLook.blurDownsample) * 2).rounded())
        if supportsMPS, sigmaKey >= 1, let device {
            let kernel: MPSImageGaussianBlur
            if let cached = blurKernels[sigmaKey] {
                kernel = cached
            } else {
                if blurKernels.count >= 96 { blurKernels.removeAll() }
                // MPS's default zero edge mode: the rim loses alpha along with colour, and the
                // unpremultiply in `pinch_fragment` turns that into a mean of the pixels inside
                // (clamping would smear the border pixels inwards).
                kernel = MPSImageGaussianBlur(device: device, sigma: Float(sigmaKey) / 2)
                blurKernels[sigmaKey] = kernel
            }
            kernel.encode(commandBuffer: buffer, sourceTexture: intermediates.rotation, destinationTexture: intermediates.blurred)
        } else if let blit = buffer.makeBlitCommandEncoder() {
            blit.copy(from: intermediates.rotation, to: intermediates.blurred)
            blit.endEncoding()
        }

        guard let meshVertexBuffer, let meshIndexBuffer, let encoder = buffer.makeRenderCommandEncoder(descriptor: target) else { return }
        encoder.label = "backdrop.pinch"
        encoder.setRenderPipelineState(pinchPipeline)
        var pinchUniforms = PinchUniforms(
            pinchMix: CubicBezier.easeInOut.solve(pinchProgress),
            warpMix: (sin(time / BackdropLook.warpPeriodDivisor) + 1) * 0.5,
            whiteScrim: parameters.whiteScrim,
            brightness: parameters.brightness,
            grade: parameters.colorGrade ? (hasLUT ? 2 : 1) : 0,
            ditherStep: targetFormat == .bgr10a2Unorm ? 1 / 1023 : 1 / 255
        )
        encoder.setVertexBuffer(meshVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&pinchUniforms, length: MemoryLayout<PinchUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&pinchUniforms, length: MemoryLayout<PinchUniforms>.stride, index: 1)
        encoder.setFragmentTexture(intermediates.blurred, index: 0)
        encoder.setFragmentTexture(lutTexture, index: 1)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: meshIndexCount, indexType: .uint16, indexBuffer: meshIndexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
    }
}

enum BackdropShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ---- Artwork crossfade ----------------------------------------------------------------
    struct FullscreenOut { float4 position [[position]]; float2 uv; };

    vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
        const float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        FullscreenOut out;
        out.position = float4(p[vid], 0.0, 1.0);
        out.uv = float2(p[vid].x * 0.5 + 0.5, 0.5 - p[vid].y * 0.5);
        return out;
    }

    struct BlendUniforms { float mixAmount; float pad0; float pad1; float pad2; };

    fragment half4 blend_fragment(FullscreenOut in [[stage_in]],
                                  constant BlendUniforms &u [[buffer(0)]],
                                  texture2d<float> previous [[texture(0)]],
                                  texture2d<float> current [[texture(1)]],
                                  sampler smp [[sampler(0)]]) {
        float4 a = previous.sample(smp, in.uv);
        float4 b = current.sample(smp, in.uv);
        return half4(mix(a, b, u.mixAmount));
    }

    // ---- Rotating artwork ------------------------------------------------------------------
    struct RotateUniforms {
        float4x4 models[3];
        float blackScrim;
        float contrast;
        float saturation;
        float instanceStep;
    };

    struct RotateOut { float4 position [[position]]; float2 uv; uint iid [[flat]]; };

    vertex RotateOut rotate_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant RotateUniforms &u [[buffer(0)]]) {
        const float2 quad[4] = { float2(-1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0), float2(1.0, -1.0) };
        const float2 uvs[4] = { float2(0.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0) };
        const uint order[6] = { 0, 1, 2, 0, 2, 3 };
        uint k = order[vid];
        RotateOut out;
        out.position = u.models[iid] * float4(quad[k], 0.0, 1.0);
        out.uv = uvs[k];
        out.iid = iid;
        return out;
    }

    fragment half4 rotate_fragment(RotateOut in [[stage_in]],
                                   constant RotateUniforms &u [[buffer(0)]],
                                   texture2d<float> artwork [[texture(0)]],
                                   sampler smp [[sampler(0)]]) {
        float3 c = artwork.sample(smp, in.uv).rgb;
        float scrim = u.blackScrim + float(in.iid) * u.instanceStep;
        c = mix(c, float3(0.0), scrim);
        c = (c - 0.5) * u.contrast + 0.5;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(l), c, u.saturation);
        return half4(half3(c), 1.0h);
    }

    // ---- Pinch / mesh warp -----------------------------------------------------------------
    struct PinchVertex { float2 uv; float2 from; float2 to; };
    struct PinchUniforms {
        float pinchMix;
        float warpMix;
        float whiteScrim;
        float brightness;
        float grade;
        float ditherStep;
        float pad1; float pad2;
    };
    struct PinchOut { float4 position [[position]]; float2 uv; };

    vertex PinchOut pinch_vertex(uint vid [[vertex_id]],
                                 const device PinchVertex *vertices [[buffer(0)]],
                                 constant PinchUniforms &u [[buffer(1)]]) {
        PinchVertex v = vertices[vid];
        float2 flat = (v.uv - 0.5) * (2.0 + 0.5 * (1.0 - u.pinchMix));
        float2 warped = mix(v.from, v.to, u.warpMix);
        PinchOut out;
        out.position = float4(mix(flat, warped, u.pinchMix), 0.0, 1.0);
        out.uv = float2(v.uv.x, 1.0 - v.uv.y);
        return out;
    }

    // Closed-form fit of the BackdropLUT table, used when none is set (`BackdropGrade`): the hue
    // stays; around red / orange (0°) and blue (241°) HSV value and saturation drop.
    static float window(float h, float centre, float halfWidth) {
        float d = fmod(abs(h - centre), 360.0);
        d = min(d, 360.0 - d);
        return d < halfWidth ? 0.5 * (1.0 + cos(M_PI_F * d / halfWidth)) : 0.0;
    }

    static float3 grade(float3 c) {
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float chroma = mx - mn;
        if (chroma < 1e-4 || mx < 1e-4) return c;
        float s = chroma / mx;
        float h;
        if (mx == c.r) h = fmod((c.g - c.b) / chroma + 6.0, 6.0);
        else if (mx == c.g) h = (c.b - c.r) / chroma + 2.0;
        else h = (c.r - c.g) / chroma + 4.0;
        h *= 60.0;
        float wr = window(h, 0.0, 56.0);
        float wb = window(h, 241.0, 57.0);
        float value = mx * (1.0 - s * (0.336 * wr + 0.312 * wb));
        float saturation = s * (1.0 - (1.0 - 0.828 * s) * (0.473 * wr + 0.397 * wb));
        float3 t = (c - mn) / chroma;
        return value * (1.0 - saturation * (1.0 - t));
    }

    // Triangular noise of ±1 step (`ditherStep`, 1/255 or 1/1023), fixed per pixel.
    static float dither(float2 position, float step) {
        uint2 p = uint2(position);
        uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u;
        h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
        float a = float(h & 0xffffu) / 65535.0;
        float b = float(h >> 16) / 65535.0;
        return (a + b - 1.0) * step;
    }

    fragment half4 pinch_fragment(PinchOut in [[stage_in]],
                                  constant PinchUniforms &u [[buffer(1)]],
                                  texture2d<float> blurred [[texture(0)]],
                                  texture3d<float> lut [[texture(1)]],
                                  sampler smp [[sampler(0)]]) {
        // Unpremultiply: the zero-edge blur dims colour and alpha together near the rim.
        float4 s = blurred.sample(smp, in.uv);
        float3 c = s.rgb / max(s.a, 1e-3);
        c = mix(c, float3(1.0), u.whiteScrim);
        // The table is sampled at the colour itself (no half-texel remap).
        if (u.grade > 1.5) c = lut.sample(smp, clamp(c, 0.0, 1.0)).rgb;
        else if (u.grade > 0.5) c = grade(c);
        c *= u.brightness;
        c += dither(in.position.xy, u.ditherStep);
        return half4(half3(clamp(c, 0.0, 1.0)), 1.0h);
    }
    """
}
