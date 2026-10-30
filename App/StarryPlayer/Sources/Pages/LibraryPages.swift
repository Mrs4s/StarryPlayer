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
            StateView(systemName: "person.crop.circle.badge.questionmark",
                      localizedTitle: LocalizedStringResource("common.loginRequired", defaultValue: "需要登录"),
                      detail: .localized(LocalizedStringResource("common.loginRequired.detail", defaultValue: "登录\(model.currentSourceName)后查看")))
                .frame(minHeight: 0)
            PillButton(localizedTitle: LocalizedStringResource("common.login", defaultValue: "登录"), systemName: "person", variant: .secondary) { model.requestLogin() }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

struct SourceLacks: View {
    var feature: DisplayText
    var systemName: String
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale

    init(feature: String, systemName: String) {
        self.feature = .verbatim(feature)
        self.systemName = systemName
    }

    init(localizedFeature: LocalizedStringResource, systemName: String) {
        feature = .localized(localizedFeature)
        self.systemName = systemName
    }

    var body: some View {
        StateView(systemName: systemName,
                  localizedTitle: LocalizedStringResource("common.sourceLacks", defaultValue: "\(model.currentSourceName)没有\(feature.resolved(locale: locale))"),
                  detail: .localized(LocalizedStringResource("common.sourceLacks.detail", defaultValue: "在侧栏切换到其他来源查看")))
            .frame(maxWidth: .infinity, minHeight: 280)
    }
}
