import LyricsProviders
import MusicSources
import StarryCore
import SwiftUI

struct LyricsSearchPanel: View {
    var track: Track
    @Binding var pin: LyricsPin?
    var back: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var keyword: String
    @State private var submitted: String
    @State private var attempt = 0
    @State private var providers: [LyricsProviderID] = []
    @State private var provider: LyricsProviderID?
    /// A platform's songs once it answers (nil inside: the search failed).
    @State private var answers: [LyricsProviderID: [LyricsSearchResult]?] = [:]
    @State private var loading: LyricsSearchResult.ID?
    @State private var outcomes: [LyricsSearchResult.ID: Outcome] = [:]

    private enum Outcome: Equatable {
        case lyrics(String)
        case noLyrics
        case failed
    }

    init(track: Track, pin: Binding<LyricsPin?>, back: @escaping () -> Void) {
        self.track = track
        _pin = pin
        self.back = back
        let words = LyricCandidateMatcher.searchKeyword(for: LyricQuery(track: track))
        _keyword = State(initialValue: words)
        _submitted = State(initialValue: words)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
                .padding(.top, 10)
            tabs
                .padding(.top, 10)
            Rectangle().fill(theme.onSurface.opacity(0.08)).frame(height: 1).padding(.top, 8)
            list
        }
        .padding([.horizontal, .top], 14)
        .padding(.bottom, 6)
        .frame(height: 520)
        .onAppear {
            providers = model.lyricSearchProviders
            if provider == nil { provider = providers.first }
        }
        .task(id: "\(attempt)|\(submitted)") {
            answers = [:]
            outcomes = [:]
            for await answer in model.searchLyrics(submitted) {
                answers[answer.provider] = .some(answer.results)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回歌词来源")
            Text("搜索歌词")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onSurface)
            Spacer()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
            TextField("歌名、歌手", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.onSurface)
                .onSubmit(submit)
            if !keyword.isEmpty {
                Button { keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.onSurface.opacity(0.07)))
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(providers) { id in
                let selected = id == provider
                Button { provider = id } label: {
                    HStack(spacing: 5) {
                        Text(id.displayName)
                        tabCount(id)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? theme.onSurface : theme.onSurfaceVariant)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(theme.onSurface.opacity(selected ? 0.1 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(Motion.hover, value: provider)
    }

    @ViewBuilder
    private func tabCount(_ id: LyricsProviderID) -> some View {
        switch answers[id] {
        case nil:
            ProgressView().controlSize(.mini)
        case .some(nil):
            Image(systemName: "exclamationmark.circle").font(.system(size: 10, weight: .bold))
        case .some(let results?):
            Text("\(results.count)").monospacedDigit().opacity(0.6)
        }
    }

    @ViewBuilder
    private var list: some View {
        if let provider {
            switch answers[provider] {
            case nil:
                note(submitted.isEmpty ? "输入歌名、歌手后按回车搜索" : "正在搜索…", busy: !submitted.isEmpty)
            case .some(nil):
                VStack(spacing: 8) {
                    Text("\(provider.displayName)搜索失败，可能是请求太频繁")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                    Button("重试") { attempt += 1 }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(let results?) where results.isEmpty:
                note("\(provider.displayName)没有找到相关的歌")
            case .some(let results?):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { result in
                            row(result)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.automatic)
            }
        } else {
            note("没有可搜索的歌词平台")
        }
    }

    private func note(_ text: String, busy: Bool = false) -> some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(theme.onSurfaceVariant)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ result: LyricsSearchResult) -> some View {
        let outcome = outcomes[result.id]
        let picked = if case .song(let song) = pin { song.id == result.id } else { false }
        return PanelRow(selected: picked, enabled: outcome != .noLyrics) {
            pick(result)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(([result.artists.joined(separator: " / ")] + [result.album].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                if let outcome {
                    Text(Self.text(outcome))
                        .font(.system(size: 11))
                        .foregroundStyle(outcome == .failed ? Color(hex: "#F5B94E") : theme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let duration = result.duration, duration > 0 {
                    Text(Self.clock(duration))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(closeInLength(duration) ? theme.accent : theme.onSurfaceVariant)
                        .help(closeInLength(duration) ? "时长与这首歌相近" : "")
                }
                if loading == result.id {
                    ProgressView().controlSize(.mini)
                } else if picked {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent)
                }
            }
        }
    }

    private func closeInLength(_ duration: TimeInterval) -> Bool {
        track.duration > 0 && abs(duration - track.duration) <= 3
    }

    private func submit() {
        let words = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if words == submitted { attempt += 1 } else { submitted = words }
    }

    private func pick(_ result: LyricsSearchResult) {
        loading = result.id
        Task {
            var outcome = Outcome.noLyrics
            var found: ResolvedLyrics?
            do {
                found = try await model.lyrics(of: result, for: track)
                if let found { outcome = .lyrics(LyricsSourcePanel.summary(found.document)) }
            } catch {
                outcome = .failed
            }
            outcomes[result.id] = outcome
            guard loading == result.id else { return }
            loading = nil
            if let found {
                pin = .song(result)
                model.pinLyrics(found, to: .song(result), for: track)
            }
        }
    }

    private static func text(_ outcome: Outcome) -> String {
        switch outcome {
        case .lyrics(let summary): summary
        case .noLyrics: "这首没有歌词"
        case .failed: "加载失败，点按重试"
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
