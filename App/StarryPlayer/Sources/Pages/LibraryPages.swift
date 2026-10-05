import MusicSources
import StarryCore
import SwiftUI

struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "最近播放", stat: "\(model.library.history.count) 首歌曲", statIcon: "clock.arrow.circlepath")
                HStack {
                    PillButton(title: "播放全部", systemName: "play.fill") {
                        model.player.play(model.library.history, context: PlaybackContext(source: nil, originType: .history, originName: "最近播放"))
                    }
                    .disabled(model.library.history.isEmpty)
                    PillButton(title: "清空记录", systemName: "trash", variant: .tertiary) { model.library.clearHistory() }
                    Spacer()
                }
                if model.library.history.isEmpty {
                    StateView(systemName: "clock.arrow.circlepath", title: "还没有播放记录")
                } else {
                    SongList(tracks: model.library.history, context: PlaybackContext(source: nil, originType: .history, originName: "最近播放"))
                }
            }
        }
    }
}

struct DailyPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var state: Loadable<[Track]> = .idle

    private var source: SourceID { model.browsingSourceID }
    private var context: PlaybackContext { PlaybackContext(source: source, originType: .dailyRecommendation, originName: "每日推荐") }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    VStack(spacing: 2) {
                        Text(Date().formatted(.dateTime.month(.abbreviated))).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onSurfaceVariant)
                        Text(Date().formatted(.dateTime.day())).font(.system(size: 36, weight: .bold)).foregroundStyle(theme.primary)
                    }
                    .frame(width: 112, height: 112)
                    .background(theme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每日推荐").font(.system(size: 30, weight: .bold)).foregroundStyle(theme.onSurface)
                        Text("根据你的音乐口味生成").font(.system(size: 14)).foregroundStyle(theme.onSurfaceVariant)
                        PillButton(title: "播放全部", systemName: "play.fill") {
                            if let tracks = state.value, !tracks.isEmpty { model.player.play(tracks, context: context) }
                        }
                        .disabled(state.value == nil)
                        .padding(.top, 4)
                    }
                    Spacer()
                }
                if !model.hasDailyRecommendations {
                    SourceLacks(feature: "每日推荐", systemName: "calendar")
                } else if !model.isLoggedIn {
                    LoginPrompt()
                } else {
                    AsyncContent(state: state, retry: { Task { await load() } }) { tracks in
                        SongList(tracks: tracks, context: context)
                    }
                }
            }
        }
        .task(id: model.hasDailyRecommendations ? model.homeKey : nil) { if model.signedInUser != nil { await load() } }
    }

    private func load() async {
        state = .loading
        state = await Loadable.run { try await model.require(source, as: (any DailyRecommendationSource).self, "每日推荐").dailyRecommendations() }
    }
}

/// All media: every song the browsing source's account keeps (its uploads, a server's whole
/// library), 500 at a time as the list scrolls (`TrackListLoader(pages:)`), every one of them
/// for a playback.
struct AllMediaPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var list: TrackListLoader?
    @State private var locator = TrackListLocator()

    private var source: SourceID { model.browsingSourceID }
    private var context: PlaybackContext { PlaybackContext(source: source, originType: .allMedia, originName: "所有媒体") }
    private var loadKey: String? { model.hasAllMedia && model.signedInUser != nil ? "\(source.key)|\(model.homeKey)" : nil }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "所有媒体", stat: list.flatMap { $0.tracks.isEmpty && !$0.isComplete ? nil : "\($0.totalCount) 首歌曲" }, statIcon: "square.stack")
                HStack {
                    PillButton(title: "播放全部", systemName: "play.fill") { list?.play(on: model.player, context: context) }
                        .disabled(list?.tracks.isEmpty != false)
                    Spacer()
                    LocatePlayingButton(list: list, locator: locator, context: context, query: "", gap: 0) {}
                }
                if !model.hasAllMedia {
                    SourceLacks(feature: "所有媒体", systemName: "square.stack")
                } else if !model.isLoggedIn {
                    LoginPrompt()
                } else if let list {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if list.tracks.isEmpty, list.isComplete {
                            StateView(systemName: "square.stack", title: "还没有媒体")
                        } else {
                            TrackListRows(list: list, context: context, locator: locator)
                        }
                        TrackListEnd(list: list) {}
                    }
                }
            }
        }
        .task(id: loadKey) {
            guard loadKey != nil, let media = try? model.require(source, as: (any AllMediaSource).self, "所有媒体") else {
                list = nil
                return
            }
            list = TrackListLoader { try await media.allMedia(page: $0) }
        }
    }
}

struct LoginPrompt: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            StateView(systemName: "person.crop.circle.badge.questionmark", title: "需要登录", detail: "登录\(model.currentSourceName)后查看")
                .frame(minHeight: 0)
            PillButton(title: "登录", systemName: "person", variant: .secondary) { model.requestLogin() }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Shown on a page of the browsing source's content that the source does not have (daily
/// recommendations on a server without them), after switching to it with the page open.
struct SourceLacks: View {
    var feature: String
    var systemName: String
    @Environment(AppModel.self) private var model

    var body: some View {
        StateView(systemName: systemName, title: "\(model.currentSourceName)没有\(feature)", detail: "在侧栏切换到其他来源查看")
            .frame(maxWidth: .infinity, minHeight: 280)
    }
}
