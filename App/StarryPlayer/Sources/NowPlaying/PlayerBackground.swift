import AppKit
import Backdrop
import Library
import StarryCore
import SwiftUI

struct PlayerBackground: View {
    var track: Track?
    var image: NSImage?
    var accent: Color?
    var settings: AppSettings.Background
    var fullscreen: Bool
    var behindLyrics: Bool
    var energyProvider: @MainActor () -> SIMD4<Float>
    @State private var largeImage: NSImage?
    @State private var largeSettled = false

    private var largeURL: URL? { track?.artwork?.sized(800) }
    private var coverPending: Bool { largeImage == nil && image == nil && largeURL != nil && !largeSettled }

    var body: some View {
        ZStack {
            switch settings.style {
            case .artwork:
                ArtworkBackdropRepresentable(image: largeImage ?? image, coverPending: coverPending, seed: track?.artwork?.seed ?? track?.id.id ?? "starry", accent: accent, settings: settings, fullscreen: fullscreen, behindLyrics: behindLyrics, energyProvider: energyProvider)
            case .blur:
                if let image = largeImage ?? image {
                    Color.clear
                        .overlay {
                            Image(nsImage: image).resizable().scaledToFill().scaleEffect(1.5).blur(radius: 45).saturation(1.2)
                        }
                        .clipped()
                        .id(track?.id)
                        .transition(.opacity)
                } else {
                    BackdropRepresentable(seed: track?.artwork?.seed ?? "starry", accent: accent).id(track?.id).transition(.opacity)
                }
                Color.black.opacity(settings.scrim)
            case .gradient:
                BackdropRepresentable(seed: track?.artwork?.seed ?? "starry", accent: accent).id(track?.id).transition(.opacity)
                Color.black.opacity(settings.scrim * 0.6)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: track?.id)
        .ignoresSafeArea()
        .task(id: largeURL) {
            largeImage = nil
            largeSettled = false
            guard let largeURL else { return }
            let loaded = await ImageStore.shared.load(largeURL, maxPixelSize: 800)
            guard !Task.isCancelled else { return }
            largeImage = loaded
            largeSettled = true
        }
    }
}

struct ArtworkBackdropRepresentable: NSViewRepresentable {
    var image: NSImage?
    var coverPending = false
    var seed: String
    var accent: Color?
    var settings: AppSettings.Background
    var fullscreen: Bool
    var behindLyrics: Bool
    var energyProvider: @MainActor () -> SIMD4<Float>

    final class Coordinator {
        var lastImage: NSImage?
        var lastSeed: String?
        var paletteKey: (seed: String, accent: Color?)?
        var palette: CoverPalette = .fallback
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ArtworkBackdropView {
        let view = ArtworkBackdropView(frame: .zero)
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ view: ArtworkBackdropView, context: Context) {
        apply(to: view, context: context)
    }

    private func apply(to view: ArtworkBackdropView, context: Context) {
        var p = ArtworkBackdropView.Parameters()
        switch settings.motion {
        case .auto: p.motion = .auto
        case .calm: p.motion = .subdued
        case .lively: p.motion = .exciting
        }
        p.speed = Float(settings.speed)
        p.blurScale = Float(settings.blurScale)
        p.saturationScale = Float(settings.saturationScale)
        p.brightness = Float(settings.brightness)
        p.blackScrim = Float(settings.scrim)
        p.whiteScrim = Float(settings.whiteScrim)
        p.audioReactivity = Float(settings.audioReactivity)
        p.pinchStrength = Float(settings.pinchStrength)
        p.colorGrade = settings.colorGrade
        p.framesPerSecond = fullscreen ? settings.fullscreenFramesPerSecond : settings.framesPerSecond
        if view.parameters != p { view.parameters = p }
        view.isBehindLyrics = behindLyrics
        view.energyProvider = energyProvider
        if context.coordinator.paletteKey?.seed != seed || context.coordinator.paletteKey?.accent != accent {
            context.coordinator.paletteKey = (seed, accent)
            context.coordinator.palette = BackdropRepresentable.palette(seed: seed, accent: accent)
        }
        view.palette = context.coordinator.palette
        // While a new song's cover loads, the previous cover stays and then crossfades straight
        // into the new one. Falling back to the palette in between would crossfade to a made-up
        // colour first and then again to the real cover.
        let holding = image == nil && coverPending && context.coordinator.lastImage != nil
        if !holding, context.coordinator.lastImage !== image || context.coordinator.lastSeed != seed {
            context.coordinator.lastImage = image
            context.coordinator.lastSeed = seed
            let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            view.setCover(cg, seed: seed)
        }
    }
}

struct BackdropRepresentable: NSViewRepresentable {
    var seed: String
    var accent: Color?

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView(frame: .zero)
        view.palette = Self.palette(seed: seed, accent: accent)
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.palette = Self.palette(seed: seed, accent: accent)
    }

    static func palette(seed: String, accent: Color?) -> CoverPalette {
        var colors = PlaceholderArt.colors(for: seed)
        if let accent { colors.insert(accent, at: 0) }
        let rgb = colors.compactMap { NSColor($0).usingColorSpace(.deviceRGB) }.map { CoverPalette.RGB(r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent)) }
        guard let dominant = rgb.last else { return .fallback }
        return CoverPalette(dominant: dominant, accents: Array(rgb.prefix(2)))
    }
}
