import AppKit
import Library
import LyricsCore
import LyricsUI
import QuartzCore
import SwiftUI

enum NowPlayingSample {
    private typealias Piece = (text: String, ruby: String?, duration: TimeInterval)

    static let agents = [
        LyricAgent(id: "mina", names: [.init("ミナ")], color: LyricColor.performerPalette[6]),
        LyricAgent(id: "sora", names: [.init("ソラ")], color: LyricColor.performerPalette[1]),
    ]

    static let document: LyricsDocument = {
        let script: [(words: [[Piece]], translation: String, romanization: String, agents: [String], singer: LyricSinger)] = [
            ([[("夜空", "よぞら", 0.7), ("に", nil, 0.25)], [("星", "ほし", 0.45), ("を", nil, 0.2)], [("探", "さが", 0.4), ("し", nil, 0.25), ("て", nil, 1.3)]],
             "在夜空里寻找星星", "yozora ni hoshi wo sagashite", ["mina"], .primary),
            ([[("君", "きみ", 0.45), ("の", nil, 0.25)], [("声", "こえ", 0.45), ("が", nil, 0.25)], [("聞", "き", 0.3), ("こ", nil, 0.25), ("え", nil, 0.25), ("た", nil, 1.3)]],
             "我听见了你的声音", "kimi no koe ga kikoeta", ["sora"], .secondary),
            ([[("ふ", nil, 0.25), ("た", nil, 0.25), ("り", nil, 0.25), ("で", nil, 0.3)], [("歌", "うた", 0.5), ("お", nil, 0.3), ("う", nil, 1.4)]],
             "我们一起唱吧", "futari de utaou", ["mina", "sora"], .duet),
            ([[("明日", "あした", 0.75), ("へ", nil, 0.3)], [("続", "つづ", 0.45), ("く", nil, 0.3)], [("光", "ひかり", 1.6)]],
             "通往明天的光", "ashita e tsuzuku hikari", ["mina"], .primary),
        ]
        var lines: [LyricLine] = []
        var time: TimeInterval = 0.8
        for (index, entry) in script.enumerated() {
            let start = time
            let words = entry.words.map { pieces -> LyricWord in
                let wordStart = time
                let syllables = pieces.map { piece -> LyricSyllable in
                    defer { time += piece.duration }
                    let ruby = piece.ruby.map { [LyricRuby(start: time, end: time + piece.duration, text: $0)] } ?? []
                    return LyricSyllable(start: time, end: time + piece.duration, text: piece.text, ruby: ruby)
                }
                return LyricWord(start: wordStart, end: time, text: pieces.map(\.text).joined(), syllables: syllables)
            }
            lines.append(LyricLine(id: index, start: start, end: time, words: words, translation: entry.translation, romanization: entry.romanization, singer: entry.singer, agentIDs: entry.agents))
            time += 0.35
        }
        return LyricsDocument(format: .ttml, lines: lines, agents: agents)
    }()

    static let period: TimeInterval = (document.lines.last?.end ?? 0) + 1.6
}

@MainActor
final class SampleLyricsClock {
    private let period: TimeInterval
    private var origin = CACurrentMediaTime()

    init(period: TimeInterval) {
        self.period = period
    }

    func sample() -> (time: TimeInterval, rate: Double) {
        ((CACurrentMediaTime() - origin).truncatingRemainder(dividingBy: period), 1)
    }

    func seek(to time: TimeInterval) {
        origin = CACurrentMediaTime() - min(max(time, 0), period)
    }
}

struct NowPlayingPreview: View {
    static let height: CGFloat = 220
    static let zoom: CGFloat = 0.45

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var clock = SampleLyricsClock(period: NowPlayingSample.period)

    var body: some View {
        let player = model.player
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(spacing: 0) {
            artwork(player.coverImage)
                .frame(width: 128, height: 128)
                .padding(.leading, 30)
            lyrics(tint: (player.accentColor ?? Color(hex: "#FE7971")).lightTint)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background {
            PlayerBackground(track: player.current, image: player.coverImage, accent: player.accentColor, settings: model.settings.settings.background, fullscreen: false, behindLyrics: true, playing: player.isPlaying, energyProvider: { [player] in player.energies() }, spectrum: { [player] after in player.audibleSpectrum(lead: PlayerController.displayLead, after: after) })
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.onSurface.opacity(theme.isDark ? 0.1 : 0.08), lineWidth: 1))
        .overlay(alignment: .topLeading) { badge }
        .environment(\.colorScheme, .dark)
    }

    private func lyrics(tint: Color) -> some View {
        let settings = model.settings.settings.lyrics
        let artworkRect = CGRect(x: 0, y: Self.height / 2, width: 0, height: 0)
        var specs = LyricsSpecs.make(from: settings, fullscreen: false, viewHeight: LyricsSpecs.Preset.windowed.referenceHeight, artworkRect: artworkRect)
        specs.scale *= Self.zoom
        specs.horizontalInset = 20
        return LyricsHost(document: NowPlayingSample.document, specs: specs, rate: 1, color: tint, timeOffset: 0, scrubTime: nil, alignment: settings.alignment == .center ? .center : .left, clock: { [clock] in clock.sample() }) { time in
            clock.seek(to: time)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private func artwork(_ image: NSImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: PlaceholderArt.colors(for: "starry"), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "music.note").font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private var badge: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye").font(.system(size: 9.5, weight: .semibold))
            Text("预览 · 示例歌词").font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.28), in: Capsule())
        .padding(10)
        .allowsHitTesting(false)
    }
}
