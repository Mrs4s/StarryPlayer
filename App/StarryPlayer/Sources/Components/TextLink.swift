import StarryCore
import SwiftUI

struct TextLink: View {
    var text: String
    var color: Color
    var hoverColor: Color
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) {
                Text(text)
                    .underline(hovering)
                    .foregroundStyle(hovering ? hoverColor : color)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .linkPointer()
        } else {
            Text(text).foregroundStyle(color).lineLimit(1)
        }
    }
}

struct ArtistLinks: View {
    var track: Track
    var color: Color
    var hoverColor: Color
    @Environment(AppModel.self) private var model

    var body: some View {
        TruncatingRow {
            ForEach(Array(track.artists.enumerated()), id: \.offset) { index, artist in
                HStack(spacing: 0) {
                    if index > 0 { Text(" / ").foregroundStyle(color).fixedSize() }
                    TextLink(text: artist.name, color: color, hoverColor: hoverColor, action: artist.isLinkable ? { model.showArtist(artist, of: track) } : nil)
                }
            }
        }
    }
}

/// Lays items out on one line like a single run of text: the item crossing the trailing edge is
/// proposed what is left (so its text truncates) and the ones after it are parked out of sight.
struct TruncatingRow: Layout {
    var minTruncatedWidth: CGFloat = 28

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.map(\.width).reduce(0, +)
        return CGSize(width: min(proposal.width ?? ideal, ideal), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var full = false
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let remaining = bounds.maxX - x
            if !full, ideal.width <= remaining + 0.5 {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(ideal))
                x += ideal.width
            } else if !full, remaining >= minTruncatedWidth {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: remaining, height: ideal.height))
                full = true
            } else {
                full = true
                subview.place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(ideal))
            }
        }
    }
}

extension ArtistRef {
    var isLinkable: Bool { !id.isEmpty }
}

extension AlbumRef {
    var isLinkable: Bool { !id.isEmpty && !name.isEmpty }
}

extension View {
    /// The pointing hand over something that opens a page (macOS 15+).
    @ViewBuilder func linkPointer() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
}
