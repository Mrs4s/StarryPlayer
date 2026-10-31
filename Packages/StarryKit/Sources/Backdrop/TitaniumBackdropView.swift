import AppKit
import Metal
import MetalKit
import os
import QuartzCore
import simd

/// Ported from AMLL's TitaniumRenderer (AGPL-3.0):
/// https://github.com/Steve-xmh/applemusic-like-lyrics
@MainActor
public final class TitaniumBackdropView: MTKView {
    public struct Parameters: Sendable, Equatable {
        public enum Motion: Sendable, Equatable { case auto, subdued, exciting }
        public var motion: Motion = .auto
        public var speed: Float = 1
        public var brightness: Float = 1
        public var blackScrim: Float = BackdropLook.blackScrimDark
        public var audioReactivity: Float = 1
        public var framesPerSecond: Int = 30
        public var options = TitaniumOptions()

        public init() {}
    }

    /// Unsmoothed, log-spaced 40 Hz–16 kHz bands (0...1), peaking since the previous call.
    public var spectrumProvider: (@MainActor () -> [Float])?
    public var isBehindLyrics = false {
        didSet { if isBehindLyrics != oldValue { wake() } }
    }
    public var isBehindText = false {
        didSet { if isBehindText != oldValue { wake() } }
    }
    public var isPlaying = true {
        didSet { if isPlaying != oldValue { wake() } }
    }
    public private(set) var isHolding = false

    public var parameters = Parameters() {
        didSet {
            preferredFramesPerSecond = max(10, parameters.framesPerSecond)
            state.crestDuration = max(0, parameters.options.crestShift)
            if parameters.options.highDynamicRange != oldValue.options.highDynamicRange { updateOutputFormat() }
            if isHolding, parameters != oldValue { needsDisplay = true }
        }
    }

    public var palette: CoverPalette = .fallback {
        didSet { if palette != oldValue, coverIsPlaceholder { applyColors(Self.colors(of: palette), seed: nil, fromCover: false) } }
    }

    public private(set) var frameCount = 0
    public private(set) var outputBits = 8
    public private(set) var isEDR = false

    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var glintNoise: MTLTexture?
    private var glintSampler: MTLSamplerState?
    private var setupFailed = false
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var state: TitaniumState
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var hasCover = false
    private var coverIsPlaceholder = true
    private var lastCoverSeed: String?

    struct Uniforms {
        var frame: SIMD4<Float>
        var grid: SIMD4<Float>
        var look: SIMD4<Float>
        var pulse: SIMD4<Float>
        var edr: SIMD4<Float>
        var metal: SIMD4<Float>
        var seed: SIMD4<Float>
        var crest: SIMD4<Float>
        var grainOffset: SIMD4<Float>
        var phase: SIMD4<Float>
        var lightDir: SIMD4<Float>
        var halfDir: SIMD4<Float>
        var coarseFlow: SIMD4<Float>
        var fineFlow: SIMD4<Float>
        var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

        var vertexCount: Int { Int(grid.x) * Int(grid.y) * 6 }
    }

    public init(frame: CGRect = .zero, seed: UInt64 = 0x7469_7461_6E69_756D) {
        state = TitaniumState(seed: seed, colors: Self.colors(of: .fallback))
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
        state = TitaniumState(seed: 0x7469_7461_6E69_756D, colors: Self.colors(of: .fallback))
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        guard let device else { setupFailed = true; return }
        commandQueue = device.makeCommandQueue()
        commandQueue?.label = "titanium"
        if let cached = Self.libraries[device.registryID] {
            library = cached
        } else {
            do {
                let compiled = try device.makeLibrary(source: TitaniumShader.source, options: nil)
                Self.libraries[device.registryID] = compiled
                library = compiled
            } catch {
                NSLog("[titanium] shader compile failed: %@", String(describing: error))
                setupFailed = true
            }
        }
        let side = TitaniumLook.glintNoiseSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        if let texture = device.makeTexture(descriptor: descriptor) {
            texture.label = "titanium.glints"
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: TitaniumLook.glintNoise, bytesPerRow: side * 2)
            glintNoise = texture
        }
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .repeat
        sampler.tAddressMode = .repeat
        glintSampler = device.makeSamplerState(descriptor: sampler)
        if glintNoise == nil || glintSampler == nil { setupFailed = true }
    }

    private static var libraries: [UInt64: MTLLibrary] = [:]

    /// Renders rest and beat previews; size is in points and pixels is the output resolution.
    public static func previewFrames(cover: CGImage?, palette: CoverPalette, seed: String, options: TitaniumOptions = TitaniumOptions(),
                                     size: CGSize, pixels: CGSize) -> (rest: CGImage, beat: CGImage)? {
        let view = TitaniumBackdropView(frame: CGRect(origin: .zero, size: size), seed: PinchMesh.seed(from: seed))
        view.parameters.options = options
        view.palette = palette
        view.setCover(cover, seed: seed)
        for _ in 0..<90 { view.advance(dt: 1 / 60) }
        guard let rest = view.captureFrame(size: pixels, heightPoints: size.height) else { return nil }
        view.state.reactivity = 1
        view.state.kick.value = 1
        view.state.shimmer.value = 1
        guard let beat = view.captureFrame(size: pixels, heightPoints: size.height) else { return nil }
        return (rest, beat)
    }

    private func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = pipelines[format] { return cached }
        guard let library else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "titanium_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "titanium_fragment")
        descriptor.colorAttachments[0].pixelFormat = format
        do {
            let pipeline = try library.device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[format] = pipeline
            return pipeline
        } catch {
            NSLog("[titanium] pipeline for format %lu failed: %@", format.rawValue, String(describing: error))
            return nil
        }
    }

    // MARK: Covers

    /// Reusing seed preserves the gradient corners when a larger cover arrives.
    public func setCover(_ image: CGImage?, seed: String? = nil) {
        var colors = image.map { ThemePalette.extract(from: $0, count: TitaniumLook.colorCount) } ?? []
        coverIsPlaceholder = colors.isEmpty
        if colors.isEmpty { colors = Self.colors(of: palette) }
        applyColors(colors, seed: seed, fromCover: true)
    }

    private func applyColors(_ colors: [SIMD3<Float>], seed: String?, fromCover: Bool) {
        wake()
        let immediate = !hasCover
        if fromCover { hasCover = true }
        let newSong = seed != nil && seed != lastCoverSeed
        var next = TitaniumState.normalised(colors)
        if newSong, let seed {
            lastCoverSeed = seed
            var rng = SplitMix64(state: PinchMesh.seed(from: seed))
            next.shuffle(using: &rng)
            state.shiftCrest(seed: rng.next(), immediate: immediate || reduceMotion)
        } else {
            next = ThemePalette.matched(next, to: state.targetColors)
        }
        state.setColors(next, immediate: immediate)
    }

    static func colors(of palette: CoverPalette) -> [SIMD3<Float>] {
        ([palette.dominant] + palette.accents).prefix(TitaniumLook.colorCount).map {
            ThemePalette.srgbToOkLab(SIMD3(Float($0.r), Float($0.g), Float($0.b)))
        }
    }

    // MARK: View lifecycle

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
        if isHolding { needsDisplay = true }
    }

    @objc private func accessibilityOptionsChanged(_ note: Notification) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Keep EDR colours consistent with the unmanaged Display P3 SDR output.
    private func updateOutputFormat() {
        guard let screen = window?.screen else { return }
        let edr = parameters.options.highDynamicRange && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        let bits = edr ? 16 : (ArtworkBackdropView.outputBitsOverride ?? screen.depth.bitsPerSample) > 8 ? 10 : 8
        guard bits != outputBits || edr != isEDR else { return }
        outputBits = bits
        isEDR = edr
        colorPixelFormat = edr ? .rgba16Float : bits > 8 ? .bgr10a2Unorm : .bgra8Unorm
        if let layer = layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = edr
            layer.colorspace = edr ? CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) : nil
        }
        if isHolding { needsDisplay = true }
    }

    private func updateDrawableSize() {
        let backing = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(1, (bounds.width * backing).rounded()), height: max(1, (bounds.height * backing).rounded()))
        guard drawableSize != size else { return }
        drawableSize = size
        if isHolding { needsDisplay = true }
    }

    private func updatePaused() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let running = visible && !isHolding
        if running, isPaused { lastFrameTime = CACurrentMediaTime() }
        isPaused = !running
        enableSetNeedsDisplay = visible && isHolding
    }

    private func wake() {
        guard isHolding else { return }
        isHolding = false
        updatePaused()
    }

    // MARK: Frames

    private static let signposter = OSSignposter(subsystem: "moe.mrs4s.starry-player", category: .pointsOfInterest)

    public override func draw(_ dirtyRect: NSRect) {
        let signpost = Self.signposter.beginInterval("Titanium frame", id: Self.signposter.makeSignpostID(),
                                                     "\(Int(self.drawableSize.width))×\(Int(self.drawableSize.height)) px")
        defer { Self.signposter.endInterval("Titanium frame", signpost) }
        guard !setupFailed, let commandQueue, let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer() else { return }
        buffer.label = "titanium.frame"
        let now = CACurrentMediaTime()
        let dt = isHolding ? 0 : max(0, now - lastFrameTime)
        lastFrameTime = now
        advance(dt: dt)
        pass.colorAttachments[0].loadAction = .dontCare
        let headroom = Float(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        encode(into: buffer, target: pass, size: drawableSize, heightPoints: bounds.height, headroom: headroom)
        buffer.present(drawable)
        buffer.commit()
        frameCount += 1
        holdIfIdle()
    }

    func holdIfIdle() {
        guard !isHolding, !isPlaying, state.canHold else { return }
        isHolding = true
        updatePaused()
    }

    private var intensity: BackdropIntensity {
        switch parameters.motion {
        case .auto: isBehindLyrics ? .exciting : .subdued
        case .subdued: .subdued
        case .exciting: .exciting
        }
    }

    func advance(dt: CFTimeInterval) {
        state.levels = TitaniumLook.levels(fromBands: spectrumProvider?() ?? [])
        state.reactivity = reduceMotion ? 0 : max(0, parameters.audioReactivity * intensity.power)
        state.lyricScrimTarget = isBehindLyrics || isBehindText ? 1 : 0
        state.textCalmTarget = isBehindText ? 1 : 0
        state.advance(dt: dt, speed: Double(parameters.speed) * (reduceMotion ? 0.1 : 1))
    }

    func uniforms(size: CGSize, heightPoints: CGFloat, ditherStep: Float, linearOutput: Bool = false, headroom: Float = 1) -> Uniforms {
        let width = Float(max(1, size.width)), height = Float(max(1, size.height))
        let aspect = width / height
        let grainScale = TitaniumLook.grainScale(heightPoints: heightPoints)
        let colors = state.colors.map { SIMD4($0, 0) }
        let options = parameters.options
        let phase = state.colorPhase * 2 * Float.pi
        let light = TitaniumLook.light(phase: phase)
        let tangent = TitaniumLook.flowTangent(seed: state.seed)
        func flow(scale: Double, speed: Double) -> SIMD4<Float> {
            let cells = TitaniumLook.flowCells(seconds: state.flowTime, scale: scale, speed: speed)
            return SIMD4(lowHalf: TitaniumLook.wrappedShift(tangent * cells), highHalf: TitaniumLook.wrappedShift(-tangent * cells))
        }
        return Uniforms(
            frame: SIMD4(width, height, aspect, grainScale),
            grid: SIMD4(Float(TitaniumLook.gridColumns(aspect: aspect)), Float(TitaniumLook.gridRows), 0, 0),
            look: SIMD4(state.lyricScrim, ditherStep, TitaniumLook.gain(blackScrim: parameters.blackScrim, brightness: parameters.brightness), options.softGlints ? 1 : 0),
            pulse: SIMD4(state.pulse, state.burst, state.textCalm, state.beatLift),
            edr: SIMD4(linearOutput ? 1 : 0, TitaniumLook.glintPeak(headroom: headroom), 0, 0),
            metal: simd_clamp(SIMD4(options.grain, options.sparkle, options.sheen, options.metalness), .zero, SIMD4(repeating: 1)),
            seed: SIMD4(state.seed, 0),
            crest: SIMD4(state.crest, 0),
            grainOffset: SIMD4(lowHalf: state.grainOffset, highHalf: .zero),
            phase: SIMD4(phase, 0, 0, 0),
            lightDir: SIMD4(light.direction, 0),
            halfDir: SIMD4(light.half, 0),
            coarseFlow: flow(scale: 0.9, speed: 1),
            fineFlow: flow(scale: 2.9, speed: TitaniumLook.fineFlowSpeed),
            colors: (colors[0], colors[1], colors[2], colors[3])
        )
    }

    private func encode(into buffer: MTLCommandBuffer, target: MTLRenderPassDescriptor, size: CGSize, heightPoints: CGFloat, headroom: Float = 1) {
        guard let format = target.colorAttachments[0].texture?.pixelFormat, let pipeline = pipeline(for: format),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: target) else { return }
        encoder.label = "titanium"
        var uniforms = uniforms(size: size, heightPoints: heightPoints, ditherStep: format == .bgr10a2Unorm ? 1 / 1023 : 1 / 255,
                                linearOutput: format == .rgba16Float, headroom: headroom)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(glintNoise, index: 0)
        encoder.setFragmentSamplerState(glintSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: uniforms.vertexCount)
        encoder.endEncoding()
    }

    /// Offscreen capture; Metal drawables cannot be read with cacheDisplay.
    /// `size` is in pixels; `heightPoints` controls the grain size in points.
    public func captureFrame(size: CGSize, heightPoints: CGFloat? = nil) -> CGImage? {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let bytes = renderFrame(size: size, format: .bgra8Unorm, heightPoints: heightPoints) else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func renderFrame(size: CGSize, format: MTLPixelFormat, heightPoints: CGFloat? = nil, headroom: Float = 1) -> [UInt8]? {
        guard !setupFailed, let device, let commandQueue else { return nil }
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = commandQueue.makeCommandBuffer() else { return nil }
        buffer.label = "titanium.capture"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encode(into: buffer, target: pass, size: size, heightPoints: heightPoints ?? (bounds.height > 0 ? bounds.height : size.height / 2), headroom: headroom)
        buffer.commit()
        buffer.waitUntilCompleted()
        let bytesPerRow = width * (format == .rgba16Float ? 8 : 4)
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }
}

// Metal port of AMLL's titanium.frag.glsl.
enum TitaniumShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct TitaniumUniforms {
        float4 frame;       // width, height, aspect, grain scale
        float4 grid;        // columns, rows
        float4 look;        // lyric scrim, dither step, gain, soft glints (1) or hard (0)
        float4 pulse;       // beat 0…1, glint burst 0…1, calm under panel text 0…1, beat lift (linear, × white)
        float4 edr;         // linear extended-range output (1) or SDR (0), brightest glint × SDR white
        float4 metal;       // grain, sparkle, sheen, metalness
        float4 seed;
        float4 crest;
        float4 grainOffset;
        float4 phase;       // colour phase in radians
        float4 lightDir;
        float4 halfDir;
        float4 coarseFlow;  // flow shift of the coarse layer in cells: xy above the crest, zw below
        float4 fineFlow;
        float4 colors[4];   // OkLab: top left, top right, bottom left, bottom right
    };

    struct TitaniumOut {
        float4 position [[position]];
        float4 albedo;      // rgb: lit-independent colour (sRGB), a: lightness of the base colour
        float4 ridge;       // x: ridge curve, y: its slope, z: ridge height, w: dune dh/dx
        float4 sand;        // x: dune dh/dy, yz: warp of the sand lookup
    };

    constant float3 LUMA_WEIGHT = float3(0.2126, 0.7152, 0.0722);
    constant float3 TITANIUM_TINT = float3(1.02, 1.0, 0.97);
    constant float3 HIGHLIGHT_COLOR = float3(1.0, 0.99, 0.96);
    constant float MICRO_CELLS = 256.0;
    constant float HASH_PERIOD = 256.0;
    constant float GLINT_CELLS = 140.0;
    constant float SPARKLE_THRESHOLD = 0.95;
    constant float BRIGHT_FACE_PARTICLE_GAIN = 0.6;
    constant float BRIGHT_FACE_RAMP_START = 0.3;
    constant float BRIGHT_FACE_RAMP_END = 0.6;
    constant float RIDGE_WIDTH = 0.018;
    // Crossfade half-width in screen heights.
    constant float SEAM_WIDTH = 0.012;
    constant float GLINT_NOISE_SIZE = 256.0;

    static float2 floorMod(float2 x, float y) { return x - y * floor(x / y); }

    static float3 decodeSrgb(float3 c) {
        return select(powr((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    static float encodeSrgb(float c) {
        return c <= 0.0031308 ? 12.92 * c : 1.055 * powr(max(c, 0.0), 1.0 / 2.4) - 0.055;
    }

    static float3 okLabToSrgb(float3 c) {
        float lRoot = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
        float mRoot = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
        float sRoot = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
        float l = lRoot * lRoot * lRoot;
        float m = mRoot * mRoot * mRoot;
        float s = sRoot * sRoot * sRoot;
        float3 linearColor = float3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        );
        return float3(encodeSrgb(linearColor.r), encodeSrgb(linearColor.g), encodeSrgb(linearColor.b));
    }

    static float4 hashGrid(float2 cell) {
        float4 p = fract(float4(cell.xyxy) * float4(0.1031, 0.1030, 0.0973, 0.1099));
        p += dot(p, p.wzxy + 33.33);
        return fract((p.xxyz + p.yzzw) * p.zywx);
    }

    // Triangular noise of ±1 quantization step, fixed per pixel.
    static float dither(float2 position, float step) {
        uint2 p = uint2(position);
        uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u;
        h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
        float a = float(h & 0xffffu) / 65535.0;
        float b = float(h >> 16) / 65535.0;
        return (a + b - 1.0) * step;
    }

    vertex TitaniumOut titanium_vertex(uint vid [[vertex_id]], constant TitaniumUniforms &u [[buffer(0)]]) {
        const uint2 corners[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(0, 1), uint2(1, 0), uint2(1, 1) };
        uint columns = uint(u.grid.x);
        uint cell = vid / 6;
        uint2 c = uint2(cell % columns, cell / columns) + corners[vid % 6];
        // Keep y upward to match the original GLSL coordinate system.
        float2 uv = float2(c) / u.grid.xy;
        float2 point = float2((uv.x - 0.5) * u.frame.z, uv.y - 0.5);
        TitaniumOut out;
        out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);

        float colorPhase = u.phase.x;
        float2 warp = float2(sin(point.y * 1.7 + colorPhase + u.seed.x),
                             cos(point.x * 1.4 - colorPhase * 2.0 + u.seed.y)) * 0.08;
        float2 blended = point + warp;
        float blendX = smoothstep(-0.6, 0.6, blended.x);
        float blendY = smoothstep(-0.6, 0.6, blended.y);
        float3 okLab = mix(mix(u.colors[2].xyz, u.colors[3].xyz, blendX),
                           mix(u.colors[0].xyz, u.colors[1].xyz, blendX), blendY);
        float3 base = okLabToSrgb(okLab);
        float luma = dot(base, LUMA_WEIGHT);
        base += TITANIUM_TINT * 0.02 * u.metal.z;
        out.albedo = float4(mix(base, float3(luma) * TITANIUM_TINT, u.metal.w), luma);

        float a1 = point.x * 1.6 + u.seed.x + u.crest.x;
        float a2 = point.x * 3.4 + u.seed.y + u.crest.y;
        float curve = 0.45 * sin(a1) + 0.10 * sin(a2);
        float slope = -0.45 * 1.6 * cos(a1) - 0.10 * 3.4 * cos(a2);
        float ridgeHeight = 0.55 + 0.15 * sin(point.x * 1.1 + u.seed.z * 4.0);
        float duneX = point.x * 1.8 + u.seed.x * 3.0;
        float duneY = point.y * 2.4 + point.x * 0.6 + u.seed.y * 5.0;
        out.ridge = float4(curve, slope, ridgeHeight, 0.10 * 1.8 * cos(duneX) + 0.10 * 0.6 * cos(duneY));

        float2 grainPoint = point + u.grainOffset.xy;
        float2 sandWarp = 0.08 * float2(sin(grainPoint.y * 2.7 + u.seed.x * 3.0), cos(grainPoint.x * 2.3 + u.seed.y * 2.0));
        out.sand = float4(0.10 * 2.4 * cos(duneY), sandWarp, 0.0);
        return out;
    }

    // Compensate for the variance lost to interpolation to preserve glint density.
    static half2 glintTilt(float2 q, bool soft, texture2d<half> noise, sampler smp) {
        float2 cell = floor(q);
        if (!soft) return half2(hashGrid(cell).xy) - 0.5h;
        float2 f = q - cell;
        f = f * f * (3.0 - 2.0 * f);
        return (noise.sample(smp, (cell + f + 0.5) / GLINT_NOISE_SIZE).xy - 0.5h) * 1.346h;
    }

    // Returns coverage, glint, and grain brightness, weighted by coverage.
    static float4 sampleSandLayer(float2 warped, float2 point, float scale, float2 shift, float2 flow,
                                  float3 surfaceNormal, float3 halfDir, float gate,
                                  constant TitaniumUniforms &u, texture2d<half> noise, sampler smp) {
        float cells = scale * MICRO_CELLS * u.frame.w;
        float2 base = warped * cells;
        base += float2(sin(base.y * 0.11 + u.seed.x), cos(base.x * 0.09 + u.seed.y)) * 0.6;
        float2 grid = base + shift + flow;
        float2 cell = floor(grid);
        half2 local = half2(grid - cell);
        float4 hashed = hashGrid(floorMod(cell, HASH_PERIOD));
        half4 rnd = half4(hashed);
        half brightness = rnd.z;
        half presentRand = rnd.w;
        float sparkleRand = fract(hashed.z * 43.1 + hashed.w * 91.7);

        half gateH = half(gate);
        half threshold = mix(0.73h, 0.37h, gateH);
        half present = smoothstep(threshold, threshold + 0.14h, presentRand);
        half2 offset = (rnd.xy - 0.5h) * 0.6h;
        half radius = (0.3h + 0.3h * brightness) * mix(0.55h, 1.0h, gateH);
        half distanceToCenter = length(local - 0.5h - offset) / max(radius, 1e-3h);
        half pixelsPerCell = half(u.frame.y / cells);
        // A pixel-wide rim prevents shimmer as subpixel grains move.
        half rim = clamp(1.0h / max(radius * pixelsPerCell, 1e-3h), 0.5h, 0.8h);
        half mask = (1.0h - smoothstep(0.75h - 0.5h * rim, 0.75h + 0.5h * rim, distanceToCenter)) * present;
        mask *= clamp(radius * pixelsPerCell, 0.2h, 1.0h);
        if (mask <= 0.0h) return float4(0.0);
        half2 tilt = glintTilt(point * (GLINT_CELLS * u.frame.w) + shift * 97.0, u.look.w > 0.5, noise, smp);
        half3 grainNormal = normalize(half3(surfaceNormal) + half3((rnd.xy - 0.5h) * 0.8h + tilt * 1.4h, 0.0h));
        half sparkle = half(step(SPARKLE_THRESHOLD, sparkleRand));
        half alignment = dot(grainNormal, half3(halfDir));
        half burst = half(u.pulse.y);
        half light = smoothstep(mix(0.74h, 0.42h, sparkle) - 0.06h * burst, mix(0.94h, 0.8h, sparkle) - 0.03h * burst, alignment);
        half glintGain = mix(0.9h, 3.2h, sparkle) * (1.0h + 0.3h * burst);
        return float4(mask, light * mask * glintGain, brightness * mask, 0.0);
    }

    struct Sand { float4 coarse; float4 fine; };

    static Sand sampleSand(float2 warped, float2 point, float2 coarseFlow, float2 fineFlow,
                           float3 surfaceNormal, float3 halfDir, float gate, constant TitaniumUniforms &u,
                           texture2d<half> noise, sampler smp) {
        Sand sand;
        sand.coarse = sampleSandLayer(warped, point, 0.9, float2(0.0), coarseFlow, surfaceNormal, halfDir, gate, u, noise, smp);
        sand.fine = sampleSandLayer(warped, point, 2.9, float2(0.37, 0.61), fineFlow, surfaceNormal, halfDir, gate, u, noise, smp);
        return sand;
    }

    fragment half4 titanium_fragment(TitaniumOut in [[stage_in]], constant TitaniumUniforms &u [[buffer(0)]],
                                     texture2d<half> noise [[texture(0)]], sampler smp [[sampler(0)]]) {
        float2 uv = float2(in.position.x, u.frame.y - in.position.y) / u.frame.xy;
        float2 point = float2((uv.x - 0.5) * u.frame.z, uv.y - 0.5);

        float f1 = point.y - in.ridge.x - u.crest.z;
        float beat = u.pulse.x;
        float crestProximity = exp(-f1 * f1 * 6.0);
        float ridgeSlope = -in.ridge.z * f1 * rsqrt(f1 * f1 + RIDGE_WIDTH * RIDGE_WIDTH);
        float dhdx = ridgeSlope * (-in.ridge.y) + in.ridge.w;
        float dhdy = ridgeSlope + in.sand.x;
        float3 surfaceNormal = normalize(float3(-dhdx, -dhdy, 1.0));

        float3 lightDir = u.lightDir.xyz;
        float diffuse = max(dot(surfaceNormal, lightDir), 0.0);
        float3 color = in.albedo.rgb;
        float luma = in.albedo.a;
        color *= 0.16 + 0.95 * diffuse;
        color *= mix(1.0, mix(0.48, 1.0, crestProximity), diffuse);
        color += TITANIUM_TINT * (diffuse * 0.05 + (1.0 - diffuse) * 0.015) * u.metal.z;
        float lightLevel = clamp(diffuse * mix(0.35, 1.0, crestProximity), 0.0, 1.0);
        float grainGate = 0.1 + 0.9 * lightLevel * lightLevel;
        grainGate *= mix(0.7, 1.0, smoothstep(0.06, 0.45, luma));

        // Crossfade the opposing flows to avoid slicing grains at the crest.
        float side = smoothstep(-SEAM_WIDTH, SEAM_WIDTH, f1);
        float2 grainPoint = point + u.grainOffset.xy;
        float2 warped = grainPoint + in.sand.yz;
        Sand sand;
        if (side >= 1.0) {
            sand = sampleSand(warped, grainPoint, u.coarseFlow.xy, u.fineFlow.xy, surfaceNormal, u.halfDir.xyz, grainGate, u, noise, smp);
        } else if (side <= 0.0) {
            sand = sampleSand(warped, grainPoint, u.coarseFlow.zw, u.fineFlow.zw, surfaceNormal, u.halfDir.xyz, grainGate, u, noise, smp);
        } else {
            Sand above = sampleSand(warped, grainPoint, u.coarseFlow.xy, u.fineFlow.xy, surfaceNormal, u.halfDir.xyz, grainGate, u, noise, smp);
            Sand below = sampleSand(warped, grainPoint, u.coarseFlow.zw, u.fineFlow.zw, surfaceNormal, u.halfDir.xyz, grainGate, u, noise, smp);
            sand.coarse = mix(below.coarse, above.coarse, side);
            sand.fine = mix(below.fine, above.fine, side);
        }
        float4 coarse = sand.coarse, fine = sand.fine;
        float sandMask = max(coarse.x, fine.x);
        float glint = max(coarse.y, fine.y);
        float grainBrightness = (coarse.z + fine.z) / max(coarse.x + fine.x, 1e-3);

        float grainGain = mix(0.34, 1.0, smoothstep(0.0, 0.6, diffuse)) * mix(0.32, 1.0, crestProximity);
        float lyricScrim = u.look.x;
        float textCalm = u.pulse.z;
        grainGain *= mix(1.0, 0.7, lyricScrim) * mix(1.0, 0.55, textCalm);
        float brightFaceGain = mix(1.0, BRIGHT_FACE_PARTICLE_GAIN,
                                   smoothstep(BRIGHT_FACE_RAMP_START, BRIGHT_FACE_RAMP_END, diffuse));

        color += HIGHLIGHT_COLOR * sandMask * (0.015 + 0.04 * grainBrightness) * u.metal.x * grainGain * brightFaceGain;
        float glintTerm = glint * (0.65 + 0.35 * grainBrightness) * (0.35 + 0.65 * diffuse) * u.metal.y * grainGain * brightFaceGain;
        color += HIGHLIGHT_COLOR * glintTerm;
        color *= 1.0 + (grainBrightness - 0.5) * 0.04 * u.metal.x;

        color *= mix(1.0, 0.86, lyricScrim);
        color *= u.look.z;
        color = color / (1.0 + max(color, 0.0) * (0.28 + 0.35 * lyricScrim));
        // Apply the lift after gain, in approximate linear light, to bound luminance changes.
        if (beat > 0.0) {
            float band = exp(-f1 * f1 * 6.0 / (1.0 + 0.4 * beat));
            float3 lifted = max(color, 0.0);
            lifted = lifted * lifted + float3(1.0, 0.99, 0.96) * (u.pulse.w * beat * band * diffuse);
            color = sqrt(lifted);
        }
        if (u.edr.x > 0.5) {
            // Keep the SDR base image and lift only strong glints above white.
            float3 linearColor = decodeSrgb(clamp(color, 0.0, 1.0));
            float strength = smoothstep(0.25, 1.2, glintTerm / (mix(1.0, 0.7, lyricScrim) * mix(1.0, 0.55, textCalm)));
            float lift = (u.edr.y - 1.0) * strength * mix(1.0, 0.6, lyricScrim) * mix(1.0, 0.5, textCalm);
            linearColor = min(linearColor + decodeSrgb(HIGHLIGHT_COLOR) * lift, u.edr.y);
            return half4(half3(linearColor), 1.0h);
        }
        color += dither(in.position.xy, u.look.y);
        return half4(half3(clamp(color, 0.0, 1.0)), 1.0h);
    }
    """
}
