import MusicSources
import StarryCore
import SwiftUI

struct DailyPage: View {
    var kind: DailyRecommendationsModel.Kind = .today
    var initialDate: String?
    @Environment(AppModel.self) private var model

    private var available: Bool { model.currentSource.map { kind.isAvailable(in: $0) } ?? false }

    var body: some View {
        if available, model.isLoggedIn, let source = model.currentSource {
            DailyRecommendationsContent(source: source, kind: kind, initialDate: initialDate)
                .id(model.homeKey)
        } else {
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    PageTitle(localizedTitle: kind.title)
                    if !available {
                        SourceLacks(localizedFeature: kind.title, systemName: kind.systemName)
                    } else {
                        LoginPrompt()
                    }
                }
            }
        }
    }
}

private struct DailyRecommendationsContent: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationStore.self) private var localization
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var pageActive
    @State private var daily: DailyRecommendationsModel
    @State private var stylePicker: RecommendationStylePicker.Request?
    @State private var stylePickerHeight: CGFloat = 400

    init(source: any MusicSource, kind: DailyRecommendationsModel.Kind, initialDate: String?) {
        _daily = State(initialValue: DailyRecommendationsModel(source: source, kind: kind, initialDate: initialDate))
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch daily.kind {
                case .today:
                    songList(daily.today, empty: LocalizedStringResource("daily.empty", defaultValue: "今天还没有推荐歌曲")) {
                        await daily.load(force: true)
                    }
                case .styles:
                    styleContent
                case .history:
                    historyContent
                }
            }
        }
        .disabled(stylePicker != nil)
        .accessibilityHidden(stylePicker != nil)
        .overlayPreferenceValue(StylePickerAnchorKey.self) { anchor in
            stylePickerOverlay(anchor)
        }
        .task { await daily.load() }
        .onChange(of: pageActive) { _, active in if !active { stylePicker = nil } }
        .onDisappear {
            stylePicker = nil
            daily.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            VStack(spacing: 2) {
                if daily.kind == .today {
                    Text(Date().formatted(.dateTime.month(.abbreviated).locale(localization.formattingLocale)))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onSurfaceVariant)
                    Text(Date().formatted(.dateTime.day().locale(localization.formattingLocale)))
                        .font(.system(size: 36, weight: .bold)).foregroundStyle(theme.primary)
                } else {
                    Image(systemName: daily.kind.systemName)
                        .font(.system(size: 36, weight: .medium)).foregroundStyle(theme.primary)
                }
            }
            .frame(width: 112, height: 112)
            .background(theme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                DisplayTextView(text: .localized(daily.kind.title)).font(.system(size: 30, weight: .bold)).foregroundStyle(theme.onSurface)
                DisplayTextView(text: subtitle).font(.system(size: 14)).foregroundStyle(theme.onSurfaceVariant)
                HStack(spacing: 12) {
                    PillButton(localizedTitle: LocalizedStringResource("common.playAll", defaultValue: "播放全部"), systemName: "play.fill") {
                        if let tracks = daily.songs.value, !tracks.isEmpty {
                            model.player.play(tracks, context: daily.context)
                        }
                    }
                    .disabled(daily.songs.value?.isEmpty != false || daily.savingStyles)
                    if let tracks = daily.songs.value, !tracks.isEmpty {
                        DisplayTextView(text: .localized(LocalizedStringResource("common.songCount", defaultValue: "\(tracks.count) 首歌曲")))
                            .font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant).fixedSize()
                    }
                    Spacer(minLength: 12)
                    if daily.kind == .today { recommendationLinks }
                    if daily.kind == .styles { styleSelectionButton }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var recommendationLinks: some View {
        let styles = DailyRecommendationsModel.Kind.styles.isAvailable(in: daily.source)
        let history = DailyRecommendationsModel.Kind.history.isAvailable(in: daily.source)
        if styles || history {
            HStack(spacing: 0) {
                if styles { recommendationLink(DailyRecommendationsModel.Kind.styles.title, route: .dailyStyles) }
                if styles && history {
                    Rectangle().fill(theme.outlineVariant).frame(width: 1, height: 14)
                }
                if history { recommendationLink(DailyRecommendationsModel.Kind.history.title, route: .dailyHistory()) }
            }
            .background(theme.onSurface.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.outlineVariant, lineWidth: 1))
            .fixedSize()
        }
    }

    private func recommendationLink(_ title: LocalizedStringResource, route: Route) -> some View {
        Button { model.navigate(route) } label: {
            DisplayTextView(text: .localized(title))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .contentShape(Capsule())
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isPill: true))
    }

    private var subtitle: DisplayText {
        switch daily.kind {
        case .today: .localized(LocalizedStringResource("daily.subtitle", defaultValue: "根据你的音乐口味生成"))
        case .styles: .localized(LocalizedStringResource("daily.styles.subtitle", defaultValue: "选择喜欢的风格，发现更多合口味的歌曲"))
        case .history:
            if let date = daily.selectedDate {
                .localized(LocalizedStringResource("daily.history.dateSubtitle", defaultValue: "重温 \(date) 的每日推荐"))
            } else {
                .localized(LocalizedStringResource("daily.history.subtitle", defaultValue: "找回往日推荐的好音乐"))
            }
        }
    }

    private var styleContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .failed(let message) = daily.styles {
                HStack(spacing: 12) {
                    DisplayTextView(text: message).font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant)
                    PillButton(localizedTitle: LocalizedStringResource("common.retry", defaultValue: "重试"), systemName: "arrow.clockwise", variant: .tertiary, height: 28) {
                        Task { await daily.load(force: true) }
                    }
                }
            }
            songList(daily.styleSongs, empty: LocalizedStringResource("daily.styles.empty", defaultValue: "暂时没有风格推荐歌曲")) {
                await daily.reloadStyleSongs()
            }
        }
    }

    private var styleSelectionButton: some View {
        Button {
            if let categories = daily.styles.value {
                stylePickerHeight = 400
                stylePicker = .init(categories: categories)
            }
        } label: {
            HStack(spacing: 8) {
                DisplayTextView(text: styleSelectionTitle).font(.system(size: 13)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isPill: true))
        .background(theme.onSurface.opacity(0.05), in: Capsule())
        .disabled(daily.styles.value?.isEmpty != false || daily.savingStyles)
        .help(localization.string(LocalizedStringResource("daily.styles.choose", defaultValue: "选择推荐风格")))
        .accessibilityLabel(localization.string(LocalizedStringResource("daily.styles.choose", defaultValue: "选择推荐风格")))
        .accessibilityValue(localization.string(styleSelectionTitle))
        .anchorPreference(key: StylePickerAnchorKey.self, value: .bounds) { $0 }
    }

    private var styleSelectionTitle: DisplayText {
        let choose = DisplayText.localized(LocalizedStringResource("daily.styles.choose", defaultValue: "选择推荐风格"))
        guard let categories = daily.styles.value else {
            return daily.styles.isLoading ? .localized(LocalizedStringResource("daily.styles.loading", defaultValue: "加载风格…")) : choose
        }
        if categories.isEmpty { return .localized(LocalizedStringResource("daily.styles.unavailable", defaultValue: "暂无可选风格")) }
        let names = categories.flatMap { category in
            category.styles.filter { category.selectedStyleIDs.contains($0.id) }.map(\.name)
        }
        guard !names.isEmpty else { return choose }
        let title = names.prefix(2).formatted(.list(type: .and).locale(localization.formattingLocale))
        return names.count > 2
            ? .localized(LocalizedStringResource("daily.styles.selectionSummary", defaultValue: "\(title) 等 \(names.count) 项"))
            : .verbatim(title)
    }

    @ViewBuilder
    private func stylePickerOverlay(_ anchor: Anchor<CGRect>?) -> some View {
        if let request = stylePicker, let anchor {
            let width = RecommendationStylePicker.width
            GeometryReader { geometry in
                let button = geometry[anchor]
                let bottomInset = model.player.current == nil ? 0 : Metrics.playerBarInset
                let leading = button.minX + width <= geometry.size.width - 12 ? button.minX : button.maxX - width
                let x = min(max(12, leading), max(12, geometry.size.width - width - 12))
                let y = min(max(12, button.maxY + 8), max(12, geometry.size.height - bottomInset - stylePickerHeight - 12))
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { if !daily.savingStyles { stylePicker = nil } }
                        .accessibilityHidden(true)
                    RecommendationStylePicker(request: request, daily: daily) { stylePicker = nil }
                        .id(request.id)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(theme.surfacePanel, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(theme.outlineVariant, lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stylePickerHeight = $0 }
                        .offset(x: x, y: y)
                }
            }
        }
    }

    private var historyContent: some View {
        AsyncContent(state: daily.dates, retry: { Task { await daily.load(force: true) } }) { dates in
            if dates.isEmpty {
                StateView(systemName: "calendar.badge.clock",
                          localizedTitle: LocalizedStringResource("daily.history.empty", defaultValue: "暂无历史日推"),
                          detail: .localized(LocalizedStringResource("daily.history.empty.detail", defaultValue: "当前账号还没有可查看的历史推荐")))
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    historyDateTabs(dates)
                    songList(daily.historySongs, empty: LocalizedStringResource("daily.history.emptyDate", defaultValue: "这一天没有推荐歌曲")) {
                        if let date = daily.selectedDate { await daily.loadHistory(date: date) }
                    }
                }
            }
        }
    }

    private func historyDateTabs(_ dates: [String]) -> some View {
        let includesYear = Set(dates.map { $0.prefix(4) }).count > 1
        let items = dates.map { date in
            let title = (includesYear ? date : String(date.suffix(5))).replacingOccurrences(of: "-", with: ".")
            return PageTabs<String>.Item(value: date, title: title)
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            PageTabs(items: items, selection: Binding {
                daily.selectedDate ?? dates[0]
            } set: { date in
                daily.selectDate(date)
                Task { await daily.loadHistory(date: date) }
            })
            .frame(height: 44)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.outlineVariant).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.string(LocalizedStringResource("daily.history.dates", defaultValue: "推荐日期")))
        .accessibilityValue(daily.selectedDate ?? "")
    }

    private func songList(_ state: Loadable<[Track]>, empty: LocalizedStringResource, retry: @escaping @MainActor () async -> Void) -> some View {
        AsyncContent(state: state, retry: { Task { await retry() } }) { tracks in
            if tracks.isEmpty {
                StateView(systemName: "music.note.list", localizedTitle: empty)
            } else {
                SongList(tracks: tracks, context: daily.context)
            }
        }
    }
}

private struct StylePickerAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}
