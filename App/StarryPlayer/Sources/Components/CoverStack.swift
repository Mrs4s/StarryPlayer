import StarryCore
import SwiftUI

struct CoverStack<Cover: View>: View {
    /// The cover's own image, never used as a sleeve (a playlist's automatic cover is often its
    /// first song's cover).
    var artwork: Artwork?
    var tracks: [Track]?
    var context: PlaybackContext
    var size: CGFloat
    var glow: Color?
    var appeared: Bool
    var onPlay: () -> Void
    @ViewBuilder var cover: (_ playing: Bool) -> Cover
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let isCurrent = model.player.isQueue(from: context)
        let sleeves = CoverSleeves.sleeves(tracks: tracks, current: isCurrent ? model.player.current : nil, excluding: artwork)
        ZStack(alignment: .leading) {
            ForEach(Array(sleeves.enumerated()), id: \.element.key) { slot, sleeve in
                sleeveView(sleeve.artwork, slot: slot)
                    .zIndex(-Double(slot))
            }
            front(isPlaying: isCurrent && model.player.isPlaying)
                .zIndex(1)
        }
        // Wide enough for the sleeves fanned out, so they never reach into the text beside it.
        .frame(width: (0..<CoverSleeves.scales.count).map { extent(slot: $0, fanned: true) }.max()!.rounded(.up), height: size, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.lift, value: hovering)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.deal, value: sleeves.map(\.key))
    }

    private func front(isPlaying: Bool) -> some View {
        cover(isPlaying)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                CoverPlayButton(isPlaying: isPlaying, visible: hovering, action: onPlay)
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: theme.coverShadow(glow), radius: hovering ? 26 : 18, y: hovering ? 14 : 9)
            .reveal(appeared, distance: 0, scale: 0.94)
    }

    private func offset(slot: Int, fanned: Bool) -> CGFloat {
        size * (1 + (fanned ? CoverSleeves.reach[slot].fanned : CoverSleeves.reach[slot].rest)) - size * CoverSleeves.scales[slot]
    }

    private func extent(slot: Int, fanned: Bool) -> CGFloat {
        let side = size * CoverSleeves.scales[slot]
        let angle = (fanned ? CoverSleeves.tilt[slot].fanned : CoverSleeves.tilt[slot].rest) * .pi / 180
        return offset(slot: slot, fanned: fanned) + side / 2 + side / 2 * cos(angle) + side * sin(angle)
    }

    private func sleeveView(_ artwork: Artwork, slot: Int) -> some View {
        let side = size * CoverSleeves.scales[slot]
        let x = offset(slot: slot, fanned: hovering)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ArtworkView(artwork: artwork, radius: 8, pixelSize: CoverSleeves.sleevePixels)
            .frame(width: side, height: side)
            .overlay(shape.fill(Color.black.opacity(slot == 0 ? 0.05 : 0.16)))
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.18), radius: 7, x: 2, y: 3)
            .rotationEffect(.degrees(reduceMotion ? 0 : (hovering ? CoverSleeves.tilt[slot].fanned : CoverSleeves.tilt[slot].rest)), anchor: .bottom)
            .offset(x: x)
            .transition(tucked(x: x, slot: slot))
    }

    private func tucked(x: CGFloat, slot: Int) -> AnyTransition {
        let tucked = AnyTransition.offset(x: reduceMotion ? 0 : -x).combined(with: .opacity)
        return .asymmetric(
            insertion: tucked.animation((reduceMotion ? .easeOut(duration: 0.2) : Motion.deal).delay(0.12 + 0.07 * Double(slot))),
            removal: tucked.animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.deal)
        )
    }
}

enum CoverSleeves {
    static let scales: [CGFloat] = [0.86, 0.74]
    static let reach: [(rest: CGFloat, fanned: CGFloat)] = [(0.08, 0.12), (0.16, 0.22)]
    static let tilt: [(rest: Double, fanned: Double)] = [(4, 6), (8, 10)]
    static let sleevePixels = 360

    struct Sleeve {
        var artwork: Artwork
        var key: String
    }

    /// Up to two sleeves: the playing song's cover first while the list plays, then the first
    /// songs' covers; each image once, and never the list's own cover.
    static func sleeves(tracks: [Track]?, current: Track?, excluding own: Artwork?) -> [Sleeve] {
        guard let tracks, !tracks.isEmpty else { return [] }
        var seen: Set<String> = own.map { [key($0)] } ?? []
        var result: [Sleeve] = []
        for artwork in ([current?.artwork] + tracks.prefix(16).map(\.artwork)).compactMap({ $0 }) {
            guard result.count < 2 else { break }
            let key = key(artwork)
            if seen.insert(key).inserted { result.append(Sleeve(artwork: artwork, key: key)) }
        }
        return result
    }

    private static func key(_ artwork: Artwork) -> String { artwork.url?.path ?? artwork.seed }
}

struct ListPlayButton: View {
    var context: PlaybackContext
    var busy: Bool
    var action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let isCurrent = model.player.isQueue(from: context)
        let playing = isCurrent && model.player.isPlaying
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .environment(\.colorScheme, theme.isDark ? .light : .dark)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .contentTransition(.symbolEffect(.replace.downUp))
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                .frame(width: 14, height: 14)
                Text(playing ? "暂停" : (isCurrent ? "继续播放" : "播放全部"))
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(theme.onPrimary)
            .padding(.horizontal, 20)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .filled, isPill: true))
        .animation(Motion.hover, value: playing)
        .animation(Motion.hover, value: isCurrent)
        .animation(Motion.hover, value: busy)
    }
}
