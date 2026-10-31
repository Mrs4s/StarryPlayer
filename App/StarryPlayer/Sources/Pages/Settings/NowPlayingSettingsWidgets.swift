import AppKit
import Library
import LyricsCore
import SwiftUI

struct LyricLayerChips: View {
    @Environment(AppModel.self) private var model

    private enum Layer: CaseIterable {
        case translation, romanization, ruby, performers
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Layer.allCases, id: \.self) { layer in
                LyricLayerChip(title: title(layer), help: help(layer), isOn: binding(layer)) { sample(layer) }
            }
        }
    }

    private func binding(_ layer: Layer) -> Binding<Bool> {
        let store = model.settings
        let keyPath: WritableKeyPath<AppSettings.Lyrics, Bool> = switch layer {
        case .translation: \.showTranslation
        case .romanization: \.showRomanization
        case .ruby: \.showRuby
        case .performers: \.performerMarks
        }
        return Binding { store.settings.lyrics[keyPath: keyPath] } set: { store.settings.lyrics[keyPath: keyPath] = $0 }
    }

    private func title(_ layer: Layer) -> String {
        switch layer {
        case .translation: "翻译"
        case .romanization: "音译"
        case .ruby: "注音"
        case .performers: "演唱者"
        }
    }

    private func help(_ layer: Layer) -> String {
        switch layer {
        case .translation: "外文歌词下方显示中文翻译"
        case .romanization: "在歌词下方标出日语、韩语等的整句读音"
        case .ruby: "在汉字上方显示歌词自带的假名、拼音等注音"
        case .performers: "多人演唱时，用颜色标出每位歌手开口的位置（需要歌词带演唱者颜色）"
        }
    }

    private static let rubySample: [(base: String, ruby: String)] = [("君", "きみ"), ("の", " "), ("声", "こえ")]

    @ViewBuilder
    private func sample(_ layer: Layer) -> some View {
        let text = Font.system(size: 12.5, weight: .semibold)
        let small = Font.system(size: 8.5, weight: .medium)
        switch layer {
        case .translation:
            VStack(spacing: 2) {
                Text("君の声").font(text)
                Text("你的声音").font(small).opacity(0.6)
            }
        case .romanization:
            VStack(spacing: 2) {
                Text("君の声").font(text)
                Text("kimi no koe").font(small).opacity(0.6)
            }
        case .ruby:
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Self.rubySample, id: \.base) { piece in
                    VStack(spacing: 0) {
                        Text(piece.ruby).font(small).opacity(0.6)
                        Text(piece.base).font(text)
                    }
                }
            }
        case .performers:
            let first = Color(hex: NowPlayingSample.agents[0].color?.hex ?? "#C2558D")
            let second = Color(hex: NowPlayingSample.agents[1].color?.hex ?? "#4C6FD1")
            HStack(spacing: 2) {
                Capsule().fill(first).frame(width: 2.5, height: 14)
                Text("君の").font(text)
                Capsule().fill(second).frame(width: 2.5, height: 14)
                Text("声").font(text)
            }
        }
    }
}

private struct LyricLayerChip<Sample: View>: View {
    var title: String
    var help: String
    @Binding var isOn: Bool
    @ViewBuilder var sample: Sample
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button { isOn.toggle() } label: {
            VStack(spacing: 7) {
                sample
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                    .frame(height: 30)
                    .opacity(isOn ? 1 : 0.4)
                HStack(spacing: 4) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isOn ? theme.accent : theme.onSurfaceVariant.opacity(0.7))
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isOn ? theme.onSurface : theme.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isOn ? theme.accent.opacity(theme.isDark ? 0.14 : 0.09) : theme.onSurface.opacity(hovering ? 0.07 : 0.04), in: shape)
            .overlay(shape.strokeBorder(isOn ? theme.accent.opacity(0.55) : theme.onSurface.opacity(0.08), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(SettingsPressStyle())
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.selection, value: isOn)
    }
}

enum LyricMotionPreset: Hashable, CaseIterable {
    case minimal, standard, rich, custom

    init(_ lyrics: AppSettings.Lyrics) {
        switch (lyrics.spring, lyrics.lift, lyrics.emphasis, lyrics.glow) {
        case (false, false, false, false): self = .minimal
        case (true, true, false, false): self = .standard
        case (true, true, true, true): self = .rich
        default: self = .custom
        }
    }

    func apply(to lyrics: inout AppSettings.Lyrics) {
        guard self != .custom else { return }
        lyrics.spring = self != .minimal
        lyrics.lift = self != .minimal
        lyrics.emphasis = self == .rich
        lyrics.glow = self == .rich
    }

    var title: String {
        switch self {
        case .minimal: "简洁"
        case .standard: "标准"
        case .rich: "丰富"
        case .custom: "自定义"
        }
    }

    var detail: String {
        switch self {
        case .minimal: "换行和点亮都不加额外动画，最省电"
        case .standard: "换行时轻轻回弹，唱到的字微微上浮"
        case .rich: "在标准之上，拉长的音还会放大并发光"
        case .custom: "已在高级设置里逐项调整"
        }
    }
}

struct BackgroundStylePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        let store = model.settings
        let player = model.player
        var colors = PlaceholderArt.colors(for: player.current?.artwork?.seed ?? "starry")
        if let accent = player.accentColor { colors.insert(accent, at: 0) }
        return VisualPicker(selection: Binding { store.settings.background.style } set: { store.settings.background.style = $0 }, options: AppSettings.Background.Style.allCases.map { style in
            .init(value: style, title: Self.name(style)) { [colors] hovering in AnyView(BackgroundStylePreview(style: style, image: player.coverImage, colors: colors, hovering: hovering)) }
        }, previewSize: compact ? CGSize(width: 92, height: 58) : CGSize(width: 104, height: 66))
    }

    static func name(_ style: AppSettings.Background.Style) -> String {
        switch style {
        case .artwork: "流动封面"
        case .blur: "模糊封面"
        case .gradient: "渐变"
        }
    }
}

private struct BackgroundStylePreview: View {
    var style: AppSettings.Background.Style
    var image: NSImage?
    var colors: [Color]
    var hovering: Bool

    var body: some View {
        ZStack {
            switch style {
            case .artwork: flowing
            case .blur: blurred
            case .gradient:
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.opacity(0.15)
            }
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(.white.opacity(0.9)).frame(width: 40, height: 4)
                Capsule().fill(.white.opacity(0.4)).frame(width: 30, height: 3)
                Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
        }
    }

    private var flowing: some View {
        ZStack {
            colors.last ?? .black
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .scaleEffect(1.8)
                    .rotationEffect(.degrees(hovering ? 70 : 20))
                    .blur(radius: 10)
                    .saturation(1.6)
            } else {
                ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { index, color in
                    Circle().fill(color).frame(width: 56, height: 56)
                        .offset(x: [-26, 24, 6][index], y: [-10, 8, 18][index])
                        .rotationEffect(.degrees(hovering ? 80 : 0))
                }
                .blur(radius: 12)
            }
            Color.black.opacity(0.2)
        }
        .animation(.easeInOut(duration: 1.2), value: hovering)
    }

    private var blurred: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill().scaleEffect(1.4).blur(radius: 7).saturation(1.2)
            } else {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom).blur(radius: 6)
            }
            Color.black.opacity(0.3)
        }
    }
}
