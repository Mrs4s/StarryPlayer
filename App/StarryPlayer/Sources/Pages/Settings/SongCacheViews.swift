import AppKit
import Library
import StarryCore
import SwiftUI

struct SongCacheUsage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var summary: SongCache.Summary?
    @State private var browsing = false
    @State private var confirmingClear = false

    var body: some View {
        let used = summary?.size ?? 0
        let count = summary?.count ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CacheControl.format(used))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurface)
                    .contentTransition(.numericText(value: Double(used)))
                Text(summary?.limit.map { "/ 上限 \(CacheControl.format($0))" } ?? "/ 不限制")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.opacity)
                Spacer(minLength: 12)
                Text("\(count) 首")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.numericText(value: Double(count)))
            }
            if let limit = summary?.limit {
                CapacityBar(fraction: limit > 0 ? Double(used) / Double(limit) : 0)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                SettingsButton(title: "查看歌曲…", systemName: "music.note.list") { browsing = true }
                    .disabled(count == 0)
                SettingsButton(title: "全部清除", systemName: "trash", role: .destructive) { confirmingClear = true }
                    .disabled(count == 0)
            }
        }
        .animation(Motion.reveal, value: summary)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: SongCache.didChange)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $browsing) {
            SongCacheSheet().environment(model).environment(\.theme, theme)
        }
        .confirmationDialog("清除全部音乐缓存？", isPresented: $confirmingClear) {
            Button("全部清除", role: .destructive) { Task { await model.songCache?.removeAll() } }
        } message: {
            Text("已缓存的 \(count) 首歌（\(CacheControl.format(used))）会从这台 Mac 上删除，再听时重新下载。")
        }
    }

    private func reload() async {
        summary = await model.songCache?.summary() ?? SongCache.Summary(count: 0, size: 0, limit: AppModel.songCacheLimit(model.settings.settings.cache))
    }
}

private struct CapacityBar: View {
    var fraction: Double
    @Environment(\.theme) private var theme

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.onSurface.opacity(theme.isDark ? 0.1 : 0.08))
                Capsule()
                    .fill(clamped > 0.9 ? Color(hex: theme.isDark ? "#F5B94E" : "#D8962A") : theme.accent)
                    .frame(width: clamped > 0 ? max(6, geo.size.width * clamped) : 0)
            }
        }
        .frame(height: 6)
    }
}

struct SongCacheSheet: View {
    enum Order: Hashable { case recent, size, added, title }

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SongCache.Entry]?
    @State private var query = ""
    @State private var order: Order = .recent
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            hairline
            footer
        }
        .frame(width: 640, height: 580)
        .background(theme.surfaceAlt)
        .onExitCommand { dismiss() }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: SongCache.didChange)) { _ in
            Task { await reload() }
        }
        .confirmationDialog("清除全部音乐缓存？", isPresented: $confirmingClear) {
            Button("全部清除", role: .destructive) { Task { await model.songCache?.removeAll() } }
        } message: {
            Text("已缓存的 \(entries?.count ?? 0) 首歌会从这台 Mac 上删除，再听时重新下载。")
        }
    }

    private var hairline: some View {
        Rectangle().fill(theme.onSurface.opacity(theme.isDark ? 0.08 : 0.07)).frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已缓存的歌")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                Text(summaryText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.numericText(value: Double(entries?.count ?? 0)))
            }
            Spacer(minLength: 16)
            SearchField(text: $query, placeholder: "搜索歌曲、歌手或专辑", width: 200, focusedWidth: 240)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var summaryText: String {
        guard let entries else { return " " }
        let size = entries.reduce(Int64(0)) { $0 + $1.size }
        return "\(entries.count) 首 · \(CacheControl.format(size))"
    }

    @ViewBuilder
    private var content: some View {
        if let entries {
            let shown = sorted(filtered(entries))
            if entries.isEmpty {
                emptyState(symbol: "music.note", title: "还没有缓存的歌", detail: model.settings.settings.cache.enabled ? "听过 20 秒以上的歌会保存在这里，再听时直接从本机播放。" : "打开「缓存听过的歌」后，听过的歌会保存在这里。")
            } else if shown.isEmpty {
                emptyState(symbol: "magnifyingglass", title: "没有找到“\(query)”", detail: "换个歌名、歌手或专辑试试。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { entry in
                            SongCacheRow(entry: entry, query: query)
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .animation(Motion.reveal, value: shown.map(\.id))
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.55))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onSurface)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            SettingsButton(title: "全部清除", systemName: "trash", role: .destructive) { confirmingClear = true }
                .disabled(entries?.isEmpty ?? true)
            Spacer()
            Text("排序")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
            SettingsMenu(selection: $order, options: [(.recent, "最近播放"), (.added, "缓存时间"), (.size, "占用空间"), (.title, "歌名")])
            SettingsButton(title: "完成", role: .prominent) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func filtered(_ entries: [SongCache.Entry]) -> [SongCache.Entry] {
        let terms = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            let track = entry.track
            let text = ([track.title, track.alias ?? "", track.album?.name ?? ""] + track.artists.map(\.name)).joined(separator: " ")
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
    }

    private func sorted(_ entries: [SongCache.Entry]) -> [SongCache.Entry] {
        switch order {
        case .recent: entries.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
        case .added: entries.sorted { $0.addedAt > $1.addedAt }
        case .size: entries.sorted { $0.size > $1.size }
        case .title: entries.sorted { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        }
    }

    private func reload() async {
        let all = await model.songCache?.allEntries() ?? []
        withAnimation(Motion.reveal) { entries = all }
    }
}

private struct SongCacheRow: View {
    var entry: SongCache.Entry
    var query: String
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var track: Track { entry.track }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: track.artwork ?? track.album?.artwork, radius: 6, pixelSize: 100)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsHighlight.text(track.title, query: query, accent: theme.accent))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(SettingsHighlight.text(subtitle, query: query, accent: theme.accent, size: 12))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Tag(text: entry.playedTier.name, style: entry.playedTier.badge != nil ? .amber : .neutral, soft: true)
            Text(CacheControl.format(entry.size))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 64, alignment: .trailing)
            ZStack(alignment: .trailing) {
                Text(Self.relative(entry.lastPlayedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .opacity(hovering ? 0 : 1)
                IconButton(systemName: "trash", size: 26, iconSize: 12, variant: .tertiary, help: "从缓存中删除") { remove() }
                    .opacity(hovering ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.85)
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(theme.onSurface.opacity(hovering ? (theme.isDark ? 0.07 : 0.05) : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .onTapGesture(count: 2) { model.player.play(track) }
        .contextMenu {
            Button("播放") { model.player.play(track) }
            Button("下一首播放") { model.player.playNext(track) }
            Divider()
            Button("在访达中显示") { reveal() }
            Button("从缓存中删除", role: .destructive) { remove() }
        }
    }

    private var subtitle: String {
        let artists = track.artists.map(\.name).joined(separator: " / ")
        guard let album = track.album?.name, !album.isEmpty else { return artists }
        return artists.isEmpty ? album : "\(artists) · \(album)"
    }

    private func remove() {
        Task { await model.songCache?.remove(track.id) }
    }

    private func reveal() {
        guard let cache = model.songCache else { return }
        NSWorkspace.shared.activateFileViewerSelecting([cache.fileURL(entry)])
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "刚刚" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
