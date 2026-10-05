import Backdrop
import StarryCore
import SwiftUI

/// Page colour wash shared with the header. Only its layer observes scroll fade
/// to avoid updating the page or shell on every scroll.
@MainActor @Observable
final class PageBackdrop {
    var tint: Color?
    /// 0…1: how far the page has scrolled through its header. The wash is gone at 1.
    var fade: Double = 0
}

extension PageBackdrop {
    /// Tints the wash with the cover's colour, read from the bitmap the page's cover shows
    /// (`pixels` wide, so the image store decodes it once).
    func tint(from artwork: Artwork?, pixels: Int) async {
        guard let artwork else { return }
        guard let url = artwork.sized(pixels) else {
            setTint(PlaceholderArt.accent(for: artwork.seed))
            return
        }
        guard let image = await ImageStore.shared.load(url, maxPixelSize: pixels),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let palette = CoverPalette.extract(from: cgImage)
        let color = palette.accents.first ?? palette.dominant
        setTint(Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: 1))
    }

    private func setTint(_ color: Color) {
        if tint != color { tint = color }
    }
}

extension PageBackdrop: Equatable {
    nonisolated static func == (a: PageBackdrop, b: PageBackdrop) -> Bool { a === b }
}

struct PageBackdropKey: PreferenceKey {
    static var defaultValue: PageBackdrop? { nil }

    static func reduce(value: inout PageBackdrop?, nextValue: () -> PageBackdrop?) {
        value = value ?? nextValue()
    }
}

struct PageBackdropLayer: View {
    var backdrop: PageBackdrop?
    @Environment(\.theme) private var theme

    static let height: CGFloat = 460

    var body: some View {
        let tint = backdrop?.tint.map(wash)
        ZStack {
            if let tint {
                LinearGradient(stops: [
                    .init(color: tint.opacity(theme.isDark ? 0.55 : 0.5), location: 0),
                    .init(color: tint.opacity(theme.isDark ? 0.24 : 0.2), location: 0.55),
                    .init(color: tint.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .opacity(1 - (backdrop?.fade ?? 0))
                .transition(.opacity)
            }
        }
        .frame(height: Self.height)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.5), value: tint)
        .allowsHitTesting(false)
    }

    private func wash(_ color: Color) -> Color { theme.wash(color) }
}

extension Theme {
    /// A muted, mid-dark (dark mode) or pastel (light mode) version of a cover colour, so text
    /// on top keeps its contrast whatever the cover.
    func wash(_ color: Color) -> Color {
        guard let hsb = color.hsb else { return color }
        return isDark
            ? .hsb(hsb.hue, min(hsb.saturation, 0.62), 0.46)
            : .hsb(hsb.hue, min(hsb.saturation, 0.5) * 0.8, 0.93)
    }
}
