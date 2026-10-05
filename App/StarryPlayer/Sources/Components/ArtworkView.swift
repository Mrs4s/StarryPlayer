import AppKit
import StarryCore
import SwiftUI

struct ArtworkView: View {
    var artwork: Artwork?
    var radius: CGFloat = Radius.card
    var circle = false
    var zoom: CGFloat = 1
    var pixelSize: Int = 300
    /// Asks for a `pixelSize` × `pixelHeight` image instead of a square one (a photo that is
    /// not square, shown whole).
    var pixelHeight: Int? = nil
    /// A flat placeholder in the theme's tone with this symbol instead of the seeded gradient,
    /// while there is no picture or it is loading: a person's picture should not flash a colour
    /// of its own first (it changed colour when the seed came with the details). A seed with no
    /// picture to load keeps its gradient.
    var neutralPlaceholder: String? = nil
    /// Shown while the picture loads, instead of the placeholder (a smaller copy already in
    /// memory, like the player's cover).
    var fallback: NSImage? = nil
    @Environment(\.theme) private var theme
    @State private var image: NSImage?

    private var url: URL? {
        guard let pixelHeight else { return artwork?.sized(pixelSize) }
        return artwork?.sized(width: pixelSize, height: pixelHeight)
    }

    var body: some View {
        // The gradient sizes the view; the cover sits in an overlay so a non-square image, which
        // `scaledToFill` makes larger than the frame, is cropped instead of growing the view.
        placeholderFill
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if let fallback {
                    Image(nsImage: fallback)
                        .resizable()
                        .scaledToFill()
                } else if let symbol = neutralSymbol {
                    GeometryReader { geo in
                        Image(systemName: symbol)
                            .font(.system(size: min(geo.size.width, geo.size.height) * 0.36, weight: .light))
                            .foregroundStyle(theme.onSurfaceVariant.opacity(0.45))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        .scaleEffect(zoom)
        .clipShape(shape)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ImageStore.shared.image(for: url, maxPixelSize: pixelSize) { image = cached; return }
            let loaded = await ImageStore.shared.load(url, maxPixelSize: pixelSize)
            withAnimation(.easeOut(duration: 0.35)) { image = loaded }
        }
    }

    private var neutralSymbol: String? {
        artwork == nil || artwork?.url != nil ? neutralPlaceholder : nil
    }

    @ViewBuilder private var placeholderFill: some View {
        if neutralSymbol != nil {
            theme.onSurface.opacity(theme.isDark ? 0.08 : 0.07)
        } else {
            LinearGradient(colors: PlaceholderArt.colors(for: artwork?.seed ?? "starry"), startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var shape: AnyShape {
        circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct AvatarView: View {
    var artwork: Artwork?
    var size: CGFloat = 32
    var body: some View {
        ArtworkView(artwork: artwork ?? Artwork(seed: "avatar"), circle: true, pixelSize: 100)
            .frame(width: size, height: size)
    }
}
