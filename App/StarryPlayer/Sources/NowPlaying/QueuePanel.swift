import AppKit
import StarryCore
import SwiftUI

struct QueuePanel: View {
    var tint: Color
    var k: CGFloat
    var leading: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * k) {
                Text("播放队列")
                    .font(.system(size: 26 * k, weight: .bold))
                    .foregroundStyle(tint)
                Text(player.isEndless ? "无限播放" : "\(player.queue.count) 首")
                    .font(.system(size: 14 * k, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint.opacity(0.5))
                Spacer(minLength: 12 * k)
                if let context = player.context, let name = context.originName, !name.isEmpty {
                    QueueOriginLink(name: name, tint: tint, k: k, action: model.canOpenPlaybackOrigin(context) ? { model.openPlaybackOrigin(context) } : nil)
                }
            }
            .padding(.leading, leading)
            .padding(.trailing, 8 * k)
            if player.queue.isEmpty {
                Text("队列里没有歌曲")
                    .font(.system(size: 15 * k, weight: .medium))
                    .foregroundStyle(tint.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2 * k) {
                            ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                                NowPlayingQueueRow(track: track, index: index, current: player.current == track, tint: tint, k: k)
                                    .id(track.id)
                            }
                        }
                        .padding(.leading, leading - 10 * k)
                        .padding(.trailing, 8 * k)
                        .padding(.vertical, 14 * k)
                    }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.035), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .onAppear {
                        if let id = player.current?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }
}

private struct NowPlayingQueueRow: View {
    var track: Track
    var index: Int
    var current: Bool
    var tint: Color
    var k: CGFloat
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let player = model.player
        HStack(spacing: 12 * k) {
            ArtworkView(artwork: track.artwork, radius: 6 * k, pixelSize: 120)
                .frame(width: 42 * k, height: 42 * k)
                .overlay {
                    if current || hovering {
                        RoundedRectangle(cornerRadius: 6 * k, style: .continuous).fill(.black.opacity(0.4))
                        if current && player.isPlaying && !hovering {
                            PlayingBars(color: .white, animating: true).frame(width: 14 * k, height: 12 * k)
                        } else {
                            Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13 * k, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .onTapGesture { current ? player.togglePlayPause() : player.play(track) }
            VStack(alignment: .leading, spacing: 3 * k) {
                Text(track.title)
                    .font(.system(size: 14.5 * k, weight: current ? .bold : .medium))
                    .foregroundStyle(tint.opacity(current ? 1 : 0.88))
                    .lineLimit(1)
                Text(track.artistText)
                    .font(.system(size: 12.5 * k))
                    .foregroundStyle(tint.opacity(0.52))
                    .lineLimit(1)
            }
            Spacer(minLength: 8 * k)
            Text(TimeFormatting.clock(track.duration))
                .font(.system(size: 12 * k, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint.opacity(0.45))
        }
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 7 * k)
        .background(
            RoundedRectangle(cornerRadius: 12 * k, style: .continuous)
                .fill(tint.opacity(current ? 0.13 : (hovering ? 0.06 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .onTapGesture(count: 2) { player.play(track) }
        .contextMenu {
            Button("播放", systemImage: "play") { player.play(track) }
            if !current {
                Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(track) }
            }
            AddToPlaylistMenu(tracks: [track], systemImage: "text.badge.plus")
            Divider()
            if track.album?.isLinkable == true {
                Button("查看专辑", systemImage: "square.stack") { model.showAlbum(of: track) }
            }
            ForEach(track.artists.filter(\.isLinkable)) { artist in
                Button("查看歌手：\(artist.name)", systemImage: "music.mic") { model.showArtist(artist, of: track) }
            }
            if let path = track.localPath {
                Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }
}

/// `来自 <origin>`: the name underlines and brightens on hover and opens the page, with a
/// chevron saying so; an origin with no page stays plain text.
private struct QueueOriginLink: View {
    var name: String
    var tint: Color
    var k: CGFloat
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let label = HStack(spacing: 4 * k) {
            Text("来自")
            Text(name)
                .underline(hovering)
                .foregroundStyle(tint.opacity(hovering ? 0.95 : 0.6))
                .lineLimit(1)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5 * k, weight: .bold))
                    .foregroundStyle(tint.opacity(hovering ? 0.95 : 0.45))
            }
        }
        .font(.system(size: 12.5 * k, weight: .medium))
        .foregroundStyle(tint.opacity(0.45))
        if let action {
            Button(action: action) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
                .linkPointer()
                .help("打开「\(name)」")
        } else {
            label
        }
    }
}
