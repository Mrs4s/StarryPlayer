import Foundation
import MusicSources
import Observation
import StarryCore

/// The daily page's lists, kept for one source and account.
/// Request counters discard replies from older loads or a page that has closed.
@MainActor @Observable
final class DailyRecommendationsModel {
    enum Kind: Hashable {
        case today, styles, history

        var title: LocalizedStringResource {
            switch self {
            case .today: LocalizedStringResource("daily.title", defaultValue: "每日推荐")
            case .styles: LocalizedStringResource("daily.styles.title", defaultValue: "风格推荐")
            case .history: LocalizedStringResource("daily.history.title", defaultValue: "历史日推")
            }
        }

        var systemName: String {
            switch self {
            case .today: "calendar"
            case .styles: "slider.horizontal.3"
            case .history: "calendar.badge.clock"
            }
        }

        func isAvailable(in source: any MusicSource) -> Bool {
            switch self {
            case .today: source.supports((any DailyRecommendationSource).self)
            case .styles: source.supports((any StyleRecommendationSource).self)
            case .history: source.supports((any DailyRecommendationHistorySource).self)
            }
        }
    }

    let source: any MusicSource
    let kind: Kind
    private(set) var today: Loadable<[Track]> = .idle
    private(set) var styles: Loadable<[RecommendationStyleCategory]> = .idle
    private(set) var styleSongs: Loadable<[Track]> = .idle
    private(set) var dates: Loadable<[String]> = .idle
    private(set) var historySongs: Loadable<[Track]> = .idle
    private(set) var selectedDate: String?
    private(set) var savingStyles = false

    @ObservationIgnored private var todayRequest = 0
    @ObservationIgnored private var stylesRequest = 0
    @ObservationIgnored private var datesRequest = 0
    @ObservationIgnored private var historyRequest = 0

    init(source: any MusicSource, kind: Kind = .today, initialDate: String? = nil) {
        self.source = source
        self.kind = kind
        selectedDate = kind == .history ? initialDate : nil
    }

    var songs: Loadable<[Track]> {
        switch kind {
        case .today: today
        case .styles: styleSongs
        case .history: historySongs
        }
    }

    var context: PlaybackContext {
        switch kind {
        case .today:
            PlaybackContext(source: source.id, originType: .dailyRecommendation, originName: "每日推荐")
        case .styles:
            PlaybackContext(source: source.id, originType: .dailyRecommendation, originID: "style", originName: "风格推荐")
        case .history:
            PlaybackContext(source: source.id, originType: .dailyRecommendation,
                            originID: selectedDate.map { "history:\($0)" },
                            originName: selectedDate.map { "历史日推 · \($0)" } ?? "历史日推")
        }
    }

    func load(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        switch kind {
        case .today: await loadToday(force: force)
        case .styles: await loadStyles(force: force)
        case .history: await loadDates(force: force)
        }
    }

    func cancel() {
        if savingStyles {
            styles = .idle
            styleSongs = .idle
        }
        todayRequest += 1
        stylesRequest += 1
        datesRequest += 1
        historyRequest += 1
        savingStyles = false
    }

    private func loadToday(force: Bool) async {
        guard force || today.value == nil else { return }
        guard let daily = source.capability((any DailyRecommendationSource).self) else { return }
        todayRequest += 1
        let request = todayRequest
        today = .loading
        let result = await Loadable.run { try await daily.dailyRecommendations() }
        guard request == todayRequest, !Task.isCancelled else { return }
        today = result
    }

    private func loadStyles(force: Bool) async {
        guard !savingStyles, force || styles.value == nil || styleSongs.value == nil else { return }
        guard let daily = source.capability((any StyleRecommendationSource).self) else { return }
        stylesRequest += 1
        let request = stylesRequest
        styles = .loading
        styleSongs = .loading
        let result = await Loadable.run { try await daily.recommendationStyles() }
        guard request == stylesRequest, !Task.isCancelled else { return }
        styles = result
        let songs = await Loadable.run { try await daily.styleRecommendations() }
        guard request == stylesRequest, !Task.isCancelled else { return }
        styleSongs = songs
    }

    /// Retries the song list independently of the style configuration.
    func reloadStyleSongs() async {
        guard !Task.isCancelled, !savingStyles, !styles.isLoading, let daily = source.capability((any StyleRecommendationSource).self) else { return }
        stylesRequest += 1
        let request = stylesRequest
        styleSongs = .loading
        let songs = await Loadable.run { try await daily.styleRecommendations() }
        guard request == stylesRequest, !Task.isCancelled else { return }
        styleSongs = songs
    }

    func saveStyles(in category: RecommendationStyleCategory, styleIDs: Set<String>) async throws -> Bool {
        guard !Task.isCancelled, !savingStyles, let daily = source.capability((any StyleRecommendationSource).self) else { return false }
        let ids = category.styles.map(\.id).filter(styleIDs.contains)
        guard !ids.isEmpty else { return false }
        if Set(ids) == Set(category.selectedStyleIDs) { return true }
        stylesRequest += 1
        let request = stylesRequest
        savingStyles = true
        defer { if request == stylesRequest { savingStyles = false } }
        try await daily.setRecommendationStyles(categoryID: category.id, styleIDs: ids)
        guard request == stylesRequest, !Task.isCancelled else { return false }
        // The preference is saved even if the following reload fails.
        if var categories = styles.value, let index = categories.firstIndex(where: { $0.id == category.id }) {
            categories[index].selectedStyleIDs = ids
            styles = .loaded(categories)
        }
        styleSongs = .loading
        let result = await Loadable.run { try await daily.recommendationStyles() }
        guard request == stylesRequest, !Task.isCancelled else { return false }
        styles = result
        let songs = await Loadable.run { try await daily.styleRecommendations() }
        guard request == stylesRequest, !Task.isCancelled else { return false }
        styleSongs = songs
        return true
    }

    private func loadDates(force: Bool) async {
        if !force, dates.value != nil {
            if let selectedDate, historySongs.value == nil { await loadHistory(date: selectedDate) }
            return
        }
        guard let daily = source.capability((any DailyRecommendationHistorySource).self) else { return }
        datesRequest += 1
        let request = datesRequest
        dates = .loading
        historyRequest += 1
        historySongs = .idle
        let result = await Loadable.run { try await daily.dailyRecommendationDates() }
        guard request == datesRequest, !Task.isCancelled else { return }
        dates = result
        if let dates = result.value {
            let date = selectedDate.flatMap { dates.contains($0) ? $0 : nil } ?? dates.first
            selectDate(date)
            if let date { await loadHistory(date: date) }
        } else {
            selectedDate = nil
        }
    }

    func selectDate(_ date: String?) {
        if let date, dates.value?.contains(date) != true { return }
        selectedDate = date
        historyRequest += 1
        historySongs = .idle
    }

    func loadHistory(date: String) async {
        guard !Task.isCancelled, selectedDate == date, let daily = source.capability((any DailyRecommendationHistorySource).self) else { return }
        historyRequest += 1
        let request = historyRequest
        historySongs = .loading
        let result = await Loadable.run { try await daily.dailyRecommendationHistory(date: date) }
        guard request == historyRequest, selectedDate == date, !Task.isCancelled else { return }
        historySongs = result
    }
}
