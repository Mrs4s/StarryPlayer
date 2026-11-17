import AppKit
import StarryCore
import SwiftUI

struct SongListHeader: View {
    var showAlbum = true
    var showPopularity = false
    @Environment(\.theme) private var theme

    var body: some View {
        SongColumns {
            Text("#").frame(width: SongColumns.indexWidth)
            DisplayTextView(text: .localized(LocalizedStringResource("songs.title", defaultValue: "标题")))
                .frame(maxWidth: .infinity, alignment: .leading).columnWeight(3)
            if showAlbum {
                DisplayTextView(text: .localized(LocalizedStringResource("songs.album", defaultValue: "专辑")))
                    .frame(maxWidth: .infinity, alignment: .leading).columnWeight(2)
            }
            Color.clear.frame(width: SongColumns.likeWidth, height: 1)
            DisplayTextView(text: .localized(LocalizedStringResource("songs.duration", defaultValue: "时长")))
                .frame(width: SongColumns.durationWidth, alignment: .leading)
            if showPopularity {
                DisplayTextView(text: .localized(LocalizedStringResource("songs.popularity", defaultValue: "热度")))
                    .frame(width: SongColumns.popularityWidth, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.outlineVariant).frame(height: 1) }
        .padding(.bottom, 6)
    }
}

struct SongColumns: Layout {
    static let indexWidth: CGFloat = 36
    static let likeWidth: CGFloat = 32
    static let durationWidth: CGFloat = 44
    static let popularityWidth: CGFloat = 64
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.map(\.width).reduce(spacing * CGFloat(max(subviews.count - 1, 0)), +)
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = subviews.map { $0[ColumnWeight.self] > 0 ? 0 : $0.sizeThatFits(.unspecified).width }
        let totalWeight = subviews.map { $0[ColumnWeight.self] }.reduce(0, +)
        let free = max(0, bounds.width - widths.reduce(0, +) - spacing * CGFloat(max(subviews.count - 1, 0)))
        var x = bounds.minX
        for (subview, fixed) in zip(subviews, widths) {
            let weight = subview[ColumnWeight.self]
            let width = weight > 0 ? free * weight / totalWeight : fixed
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

private struct ColumnWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

private extension View {
    func columnWeight(_ weight: CGFloat) -> some View { layoutValue(key: ColumnWeight.self, value: weight) }
}

struct HeartButton: View {
    var track: Track
    var size: CGFloat = 28
    var tint: Color? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if model.canLike(track) {
            button
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private var button: some View {
        let liked = model.player.isLiked(track)
        return IconButton(systemName: liked ? "heart.fill" : "heart", size: size, iconSize: size * 0.5, tint: liked ? Color(hex: "#FE7971") : (tint ?? theme.onSurfaceVariant), help: liked ? "取消喜欢" : "喜欢") {
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { model.toggleLike(track) }
        }
        .symbolEffect(.bounce, value: liked)
    }
}
