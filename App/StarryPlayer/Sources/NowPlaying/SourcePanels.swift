import LyricsCore
import LyricsProviders
import MusicSources
import StarryCore
import SwiftUI

struct AudioSourcePanel: View {
    var track: Track
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var decoded: AudioStreamInfo?
    @State private var picked: String?

    private var player: PlayerController { model.player }
    private var asset: PlayableAsset? { player.current?.id == track.id ? player.currentAsset : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            details
                .padding(.top, 12)
            if let note = shortfallNote {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            let tiers = model.qualityTiers(for: track)
            if !tiers.isEmpty, model.registry.source(for: track.id.source)?.offersQualityChoice != false {
                Rectangle().fill(theme.onSurface.opacity(0.08)).frame(height: 1).padding(.vertical, 12)
                Text("音质")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                ForEach(tiers.reversed()) { tier in
                    qualityRow(tier)
                }
            }
        }
        .padding(14)
        .frame(width: 310)
        .background(theme.surface)
        .task(id: asset) {
            decoded = nil
            guard asset != nil else { return }
            decoded = await player.engine.currentFormat()
        }
        .onChange(of: player.isLoading) { _, loading in
            if !loading { picked = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(asset.map { model.tierName($0.tier, of: track) } ?? model.availableTiers(of: track).last?.name ?? "未知音质")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(theme.onSurface)
            if let asset {
                if asset.container != .hls { badge(asset.container.rawValue.uppercased(), color: theme.onSurfaceVariant) }
                if asset.isTrial { badge("试听", color: Color(hex: "#F5B94E")) }
            }
            Spacer(minLength: 8)
            Text(providerText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .padding(.horizontal, 6)
    }

    private var details: some View {
        let info = (asset?.info ?? AudioStreamInfo()).filled(from: decoded)
        let decodedInfo = decoded.map { $0.filled(from: asset?.info) } ?? info
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            if asset == nil {
                GridRow {
                    Text("还没有开始播放这首歌，开始后显示音源信息。")
                        .gridCellColumns(2)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            } else {
                row("采样率", decodedInfo.sampleRate.map(Self.sampleRate))
                row("位深", decodedInfo.bitDepth.map { "\($0) bit" })
                // The source's average for the file; the engine's estimate otherwise.
                row("比特率", info.bitrate.map(Self.bitrate))
                row("声道", decodedInfo.channels.map(Self.channels))
                row("大小", info.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                row("来源", model.displayName(of: track.id.source))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(title).foregroundStyle(theme.onSurfaceVariant)
                Text(value).foregroundStyle(theme.onSurface).monospacedDigit().textSelection(.enabled)
            }
        }
    }

    private func qualityRow(_ tier: QualityTier) -> some View {
        let available = track.availableTiers.isEmpty || track.availableTiers.contains(tier.id)
        let playing = asset?.tier.id == tier.id
        let preferred = model.requestedTier(for: track).id == tier.id
        let loading = picked == tier.id && player.isLoading
        return PanelRow(selected: playing, enabled: available) {
            picked = tier.id
            model.switchTier(to: tier, for: track)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tier.name).font(.system(size: 13, weight: .semibold))
                    if preferred { badge("默认", color: theme.accent) }
                }
                if let detail = available ? tier.detail : "这首歌没有此音质" {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            Spacer(minLength: 8)
            if loading {
                ProgressView().controlSize(.small)
            } else if playing {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent)
            }
        }
        .help(available ? (playing ? "正在播放此音质" : "切换到\(tier.name)，并设为\(model.displayName(of: track.id.source))的默认音质") : "")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.14)))
    }

    private var providerText: String {
        switch asset?.provider {
        case .local: "本地文件"
        case .cache: "已缓存"
        case .trial: "试听"
        case .source: "在线"
        case nil: ""
        }
    }

    /// When the stream is not the tier asked for but a lower one (the account cannot have it,
    /// or the song has no such version), or a stereo file for a spatial mix.
    private var shortfallNote: String? {
        guard let asset, model.registry.source(for: track.id.source)?.offersQualityChoice != false else { return nil }
        let wanted = model.requestedTier(for: track)
        let short = wanted.isSpatial ? asset.tier.id != wanted.id : !asset.tier.isSpatial && asset.tier.level < wanted.level
        guard short, track.availableTiers.isEmpty || track.availableTiers.contains(wanted.id) else { return nil }
        return "设为「\(wanted.name)」，但只取到了「\(model.tierName(asset.tier, of: track))」，可能需要登录或会员。"
    }

    static func sampleRate(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000)
    }

    static func bitrate(_ bps: Int) -> String { "\((Double(bps) / 1000).rounded().formatted()) kbps" }

    static func channels(_ count: Int) -> String {
        switch count {
        case 1: "单声道"
        case 2: "立体声"
        default: "\(count) 声道"
        }
    }
}

struct LyricsSourcePanel: View {
    var track: Track
    var openSettings: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [LyricsCandidateSource] = []
    /// A source's answer once it has come (nil inside: it has none).
    @State private var results: [LyricsCandidateSource: ResolvedLyrics?] = [:]
    @State private var pin: LyricsPin?
    @State private var searching: Bool

    init(track: Track, startsWithSearch: Bool = false, openSettings: @escaping () -> Void) {
        self.track = track
        self.openSettings = openSettings
        _searching = State(initialValue: startsWithSearch)
    }

    private var isCurrent: Bool { model.player.current?.id == track.id }

    private var showing: LyricsCandidateSource? {
        guard isCurrent else { return nil }
        return model.player.lyricsOrigin.flatMap(LyricsCandidateSource.init(origin:))
    }

    var body: some View {
        Group {
            if searching {
                LyricsSearchPanel(track: track, pin: $pin) { searching = false }
            } else {
                sourceList
            }
        }
        .frame(width: 340)
        .background(theme.surface)
        .task(id: track.id) {
            pin = model.lyricPins.pin(for: track.id)
            sources = model.lyricCandidateSources(for: track)
            results = [:]
            for await candidate in model.lyricCandidates(for: track) {
                results[candidate.source] = .some(candidate.lyrics)
            }
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("歌词来源")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                Text("选中的歌词会一直用于这首歌")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
            PanelRow(selected: pin == nil, enabled: true) {
                pin = nil
                model.unpinLyrics(for: track)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动").font(.system(size: 13, weight: .semibold))
                    Text("按设置里的来源顺序挑选").font(.system(size: 11.5)).foregroundStyle(theme.onSurfaceVariant)
                }
                Spacer(minLength: 8)
                if pin == nil { checkmark }
            }
            if let pin, let picked = PickedLyrics(pin) {
                pickedRow(picked)
            }
            divider
            ForEach(sources) { source in
                candidateRow(source)
            }
            divider
            PanelRow(selected: false, enabled: true) {
                searching = true
            } content: {
                actionLabel("搜索歌词", detail: "在各平台按歌名、歌手找，也能选别的版本", systemImage: "magnifyingglass")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.onSurfaceVariant)
            }
            PanelRow(selected: false, enabled: true) {
                dismiss()
                model.openLyricsFile(for: track)
            } content: {
                actionLabel("打开歌词文件…", detail: "LRC、TTML、KRC 等，也可以拖到歌词上", systemImage: "doc.text")
                Spacer(minLength: 8)
            }
            divider
            Button(action: openSettings) {
                HStack(spacing: 3) {
                    Text("歌词来源设置")
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    private var divider: some View {
        Rectangle().fill(theme.onSurface.opacity(0.08)).frame(height: 1).padding(.vertical, 8)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent)
    }

    private func actionLabel(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
            }
        }
    }

    private func pickedRow(_ picked: PickedLyrics) -> some View {
        let current = isCurrent && model.player.lyricsOrigin == picked.origin
        let detail = current ? model.player.lyrics.map { Self.summary($0) } : nil
        return PanelRow(selected: true, enabled: true) {} content: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(picked.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if current { usingBadge }
                }
                Text(([picked.detail] + [detail].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            checkmark
        }
        .help(picked.help)
    }

    private var usingBadge: some View {
        Text("正在使用")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.accent.opacity(0.14)))
            .fixedSize()
    }

    private func candidateRow(_ source: LyricsCandidateSource) -> some View {
        let answer = results[source]
        let lyrics = answer.flatMap { $0 }
        let current = showing == source
        let pinned = pin == .source(source)
        return PanelRow(selected: pinned, enabled: lyrics != nil) {
            guard let lyrics else { return }
            pin = .source(source)
            model.pinLyrics(lyrics, to: .source(source), for: track)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(lyrics.map { source == .trackSource ? $0.origin.displayName : source.displayName } ?? source.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if current { usingBadge }
                }
                Text(answer == nil ? "正在查找…" : lyrics.map { Self.summary($0.document) } ?? "未找到")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if answer == nil {
                ProgressView().controlSize(.small)
            } else if pinned {
                checkmark
            }
        }
    }

    static func summary(_ document: LyricsDocument) -> String {
        var parts = [document.format.rawValue.uppercased(), document.hasSyllables ? "逐字" : "逐行"]
        if document.hasTranslation { parts.append("翻译") }
        if document.hasRomanization { parts.append("音译") }
        if document.hasDuet { parts.append("对唱") }
        parts.append("\(document.lines.count) 行")
        return parts.joined(separator: " · ")
    }
}

private struct PickedLyrics {
    var title: String
    var detail: String
    var help: String
    var origin: LyricsOrigin

    init?(_ pin: LyricsPin) {
        switch pin {
        case .source:
            return nil
        case .song(let result):
            title = result.title
            detail = "手动选择 · \(result.provider.displayName)"
            help = ([result.title, result.artists.joined(separator: " / "), result.album].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " — ")
            origin = .pickedSong(result.provider)
        case .file(let file):
            title = file.name
            detail = "歌词文件"
            help = "从「\(file.name)」载入，已保存在这首歌上"
            origin = .file(file.name)
        }
    }
}

/// A choice in these panels: a faint fill on hover, a firmer one when chosen; dimmed and inert
/// when it cannot be chosen.
struct PanelRow<Content: View>: View {
    var selected: Bool
    var enabled: Bool
    var action: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) { content }
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.onSurface.opacity(selected ? 0.08 : (hovering && enabled ? 0.05 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}
