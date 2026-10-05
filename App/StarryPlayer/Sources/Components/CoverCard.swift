import StarryCore
import SwiftUI

struct CoverCard: View {
    var title: String
    var subtitle: String? = nil
    var artwork: Artwork?
    var circle = false
    var onTap: () -> Void
    var onPlay: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: circle ? .center : .leading, spacing: 9) {
            cover
            VStack(alignment: circle ? .center : .leading, spacing: 3) {
                // Two lines reserved, so cards in a row line up and a shelf keeps its height.
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(circle ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: circle ? .center : .leading)
                if let subtitle {
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.lift, value: hovering)
        .onTapGesture(perform: onTap)
    }

    private var shape: AnyShape {
        circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(ArtworkView(artwork: artwork, circle: circle, zoom: hovering ? 1.06 : 1).brightness(hovering ? -0.05 : 0))
            .clipShape(shape)
            // A hairline edge, so pale covers do not melt into a light page.
            .overlay(shape.stroke(theme.onSurface.opacity(0.07), lineWidth: 1))
            .overlay(alignment: circle ? .bottom : .bottomTrailing) {
                if let onPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.94), in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    }
                    .buttonStyle(PressScaleStyle())
                    .padding(circle ? 6 : 10)
                    .opacity(hovering ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.7)
                    .offset(y: hovering ? 0 : 8)
                    .allowsHitTesting(hovering)
                    .help("播放")
                }
            }
            .shadow(color: .black.opacity(hovering ? (theme.isDark ? 0.5 : 0.2) : 0), radius: hovering ? 16 : 0, y: hovering ? 10 : 0)
            .offset(y: hovering ? -3 : 0)
    }
}

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func playlistCard(_ playlist: Playlist, model: AppModel) -> some View {
        CoverCard(title: playlist.name, subtitle: playlist.creatorName ?? "", artwork: playlist.artwork) {
            model.navigate(.collection(playlist))
        } onPlay: {
            Task {
                do {
                    let detail = try await model.catalog(playlist.source).playlist(id: playlist.id)
                    model.player.play(detail.tracks, context: PlaybackContext(source: playlist.source, originType: .playlist, originID: playlist.id, originName: playlist.name))
                } catch {
                    model.showToast(ErrorText.describe(error))
                }
            }
        }
    }
}
