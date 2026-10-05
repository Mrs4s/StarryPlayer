import AppKit
import StarryCore
import SwiftUI

/// Flat song table: a 36 pt column header over a hairline, then
/// 60 pt rows with no card surface — only a soft rounded fill on hover and for the current track.
/// Title and album split the free width 3 : 2 (`SongColumns`), so the header lines up with rows.
struct SongList: View {
    var tracks: [Track]
    var showAlbum = true
    var showPopularity = false
    var showHeader = true
    var context: PlaybackContext? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        LazyVStack(spacing: 0) {
            if showHeader {
                SongColumns {
                    Text("#").frame(width: SongColumns.indexWidth)
                    Text("标题").frame(maxWidth: .infinity, alignment: .leading).columnWeight(3)
                    if showAlbum { Text("专辑").frame(maxWidth: .infinity, alignment: .leading).columnWeight(2) }
                    Color.clear.frame(width: SongColumns.likeWidth, height: 1)
                    Text("时长").frame(width: SongColumns.durationWidth, alignment: .leading)
                    if showPopularity { Text("热度").frame(width: SongColumns.popularityWidth, alignment: .leading) }
                }
                .font(.system(size: 13))
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.outlineVariant).frame(height: 1) }
                .padding(.bottom, 6)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                SongRow(track: track, index: index + 1, showAlbum: showAlbum, showPopularity: showPopularity) {
                    model.player.play(tracks, startAt: index, context: context)
                }
            }
        }
    }
}

struct SongRow: View {
    var track: Track
    var index: Int
    var showAlbum = true
    var showPopularity = false
    /// Off on the album page, where every row would repeat the same cover; the row is then 56 pt.
    var showArtwork = true
    var trailing: AnyView? = nil
    var removeFromPlaylist: (() -> Void)? = nil
    var onPlay: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isCurrent: Bool { model.player.current?.id == track.id }

    var body: some View {
        SongColumns {
            indexCell.frame(width: SongColumns.indexWidth)

            HStack(spacing: 12) {
                if showArtwork {
                    ArtworkView(artwork: track.artwork, radius: 6, pixelSize: 120)
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    HStack(spacing: 4) {
                        tags
                        ArtistLinks(track: track, color: theme.onSurfaceVariant, hoverColor: theme.onSurface)
                            .font(.system(size: 13))
                            .padding(.leading, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .columnWeight(3)

            if showAlbum {
                TextLink(text: track.album?.name ?? "", color: theme.onSurfaceVariant, hoverColor: theme.onSurface, action: track.album?.isLinkable == true ? { model.showAlbum(of: track) } : nil)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .columnWeight(2)
            }

            HeartButton(track: track, size: SongColumns.likeWidth)
                .opacity(hovering || model.player.isLiked(track) ? 1 : 0)

            Text(TimeFormatting.clock(track.duration))
                .font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: SongColumns.durationWidth, alignment: .leading)

            if showPopularity {
                PopularityBar(value: track.popularity)
                    .frame(width: SongColumns.popularityWidth, alignment: .leading)
            }

            if let trailing { trailing }
        }
        .padding(.horizontal, 12)
        .frame(height: showArtwork ? Metrics.songRowHeight : 56)
        .background(rowFill, in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .onTapGesture(count: 2, perform: onPlay)
        .onDrag { model.dragItem(for: [track]) } preview: { SongDragPreview(track: track) }
        .contextMenu {
            Button("立即播放", action: onPlay)
            Button("下一首播放") { model.player.playNext(track) }
            Button("添加到队列") { model.player.addToQueue(track) }
            AddToPlaylistMenu(tracks: [track])
            Divider()
            if model.canLike(track) {
                Button(model.player.isLiked(track) ? "取消喜欢" : "喜欢") { model.toggleLike(track) }
            }
            if track.album?.isLinkable == true {
                Button("查看专辑") { model.showAlbum(of: track) }
            }
            ForEach(track.artists.filter(\.isLinkable)) { artist in
                Button("查看歌手：\(artist.name)") { model.showArtist(artist, of: track) }
            }
            if let path = track.localPath {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if let removeFromPlaylist {
                Divider()
                Button("从歌单中删除", role: .destructive, action: removeFromPlaylist)
            }
        }
    }

    @ViewBuilder private var indexCell: some View {
        ZStack {
            if isCurrent, model.player.isPlaying {
                PlayingBars(color: theme.primary, animating: pageActive && !reduceMotion)
                    .frame(width: 14, height: 12)
            } else if hovering || isCurrent {
                Button(action: onPlay) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
            } else {
                Text(String(format: "%02d", index)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
        }
        .foregroundStyle(isCurrent ? theme.primary : theme.onSurfaceVariant)
    }

    private var titleLine: some View {
        let title = Text(track.title).foregroundStyle(isCurrent ? theme.primary : theme.onSurface)
        let alias = Text(track.alias.map { " (\($0))" } ?? "").foregroundStyle(theme.onSurfaceVariant)
        return Text("\(title)\(alias)")
            .font(.system(size: 15, weight: isCurrent ? .medium : .regular))
            .lineLimit(1)
    }

    @ViewBuilder private var tags: some View {
        let tiers = model.availableTiers(of: track)
        if let badge = tiers.last(where: { !$0.isSpatial && $0.badge != nil })?.badge { Tag(text: badge, style: .amber, soft: true) }
        ForEach(tiers.filter(\.isSpatial)) { tier in
            if let badge = tier.badge { Tag(text: badge, style: .amber, soft: true) }
        }
        if track.fee == .vip { Tag(text: "VIP", style: .red, soft: true) }
        else if track.fee == .purchase { Tag(text: "EP", style: .red, soft: true) }
        if track.hasVideo { Tag(text: "MV", soft: true) }
    }

    private var rowFill: Color {
        if isCurrent { return theme.primary.opacity(hovering ? 0.14 : 0.10) }
        return theme.onSurface.opacity(hovering ? 0.06 : 0)
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

private struct PopularityBar: View {
    var value: Double?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.onSurface.opacity(0.15))
            if let value, value > 0 {
                Capsule().fill(theme.primary).frame(width: max(48 * value, 4))
            }
        }
        .frame(width: 48, height: 4)
        .help(value.map { "热度 \(Int(($0 * 100).rounded()))" } ?? "")
    }
}

private struct ColumnWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

private extension View {
    func columnWeight(_ weight: CGFloat) -> some View { layoutValue(key: ColumnWeight.self, value: weight) }
}

/// Like / unlike in the song's own source. A song whose source keeps no liked songs gets an
/// empty square of the same size, so list columns stay in line.
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
