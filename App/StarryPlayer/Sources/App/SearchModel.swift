import AppKit
import MusicSources
import Observation
import StarryCore
import SwiftUI

@MainActor @Observable
final class SearchModel {
    enum Item: Hashable, Identifiable {
        case query(String)
        case recent(String)
        case suggestion(String)
        case trend(rank: Int, SearchTrend)

        var id: String {
            switch self {
            case .query: "query"
            case .recent(let text): "recent:\(text)"
            case .suggestion(let text): "suggestion:\(text)"
            case .trend(let rank, _): "trend:\(rank)"
            }
        }

        var text: String {
            switch self {
            case .query(let text), .recent(let text), .suggestion(let text): text
            case .trend(_, let trend): trend.query
            }
        }
    }

    var text = ""
    private(set) var isActive = false
    private(set) var focusRequest = 0
    /// The highlighted entry (`Item.id`); Return picks it instead of searching the text.
    var highlighted: String?

    private(set) var history: [String]
    private(set) var trends: [SearchTrend] = []
    private(set) var trendsState: TrendsState = .idle
    private(set) var suggestions: [String] = []
    /// Suggestions for the text are on their way (none cached, the request not answered yet).
    private(set) var suggestionsPending = false

    private(set) var hints: [SearchHint] = []
    private(set) var hintIndex = 0

    enum TrendsState { case idle, loading, loaded, failed }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var suggestionCache: [String: [String]] = [:]
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var trendsLoadedAt: Date?
    @ObservationIgnored private var hintRotation: Task<Void, Never>?
    /// Where the pointer was when the list last changed under it: entering an entry without
    /// moving from there (the rows moved, not the pointer) does not take the highlight, or
    /// Return would pick whatever slid under a resting pointer instead of the typed text.
    @ObservationIgnored private var pointerAnchor: CGPoint?

    private static let historyKey = "starry.search.history"
    static let historyLimit = 20
    static let recentShown = 8
    static let trendsShown = 10
    static let recentMatchesShown = 3
    static let suggestionsShown = 8
    static let suggestDelay: Duration = .milliseconds(140)
    static let hintInterval: Duration = .seconds(12)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.stringArray(forKey: Self.historyKey) ?? []
    }

    func attach(_ app: AppModel) {
        self.app = app
    }

    var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hint: SearchHint? { hints.isEmpty ? nil : hints[hintIndex % hints.count] }

    struct Panel: Equatable {
        var query: String
        var items: [Item]
        var pending = false
    }

    /// The panel as it is — or, while the box closes, as it was when it began to: the text a
    /// pick writes into the field and the history it adds to must not rearrange the rows that
    /// are fading out.
    var panel: Panel {
        if !isActive, let frozenPanel { return frozenPanel }
        return livePanel
    }

    private var livePanel: Panel {
        Panel(query: query, items: items, pending: suggestionsPending && suggestions.isEmpty)
    }

    /// Observed: thawing it must lay the hidden panel out again for the next opening.
    private var frozenPanel: Panel?
    @ObservationIgnored private var thawTask: Task<Void, Never>?
    @ObservationIgnored private var routeQuery = ""

    var items: [Item] {
        let query = query
        guard !query.isEmpty else {
            return history.prefix(Self.recentShown).map(Item.recent)
                + trends.prefix(Self.trendsShown).enumerated().map { Item.trend(rank: $0.offset + 1, $0.element) }
        }
        let key = Self.fold(query)
        let recent = history.filter { $0 != query && Self.fold($0).contains(key) }.prefix(Self.recentMatchesShown)
        var seen = Set([query] + recent)
        let suggested = suggestions.filter { seen.insert($0).inserted }.prefix(Self.suggestionsShown - recent.count)
        return [.query(query)] + recent.map(Item.recent) + suggested.map(Item.suggestion)
    }

    func activate() {
        guard !isActive else { return }
        thawTask?.cancel()
        frozenPanel = nil
        isActive = true
        highlighted = nil
        pointerAnchor = NSEvent.mouseLocation
        if !query.isEmpty { textChanged() }
        loadTrendsIfStale()
    }

    func focus() {
        activate()
        focusRequest += 1
    }

    func deactivate(keepingText: Bool = false) {
        guard isActive else { return }
        frozenPanel = livePanel
        isActive = false
        if !keepingText { text = routeQuery }
        // Once the card has closed, the hidden panel lays out what the next opening shows, so
        // the card opens straight to its height.
        thawTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            guard !Task.isCancelled, let self, !isActive else { return }
            frozenPanel = nil
            highlighted = nil
        }
    }

    func routeChanged(_ route: Route) {
        if case .search(let query) = route { routeQuery = query } else { routeQuery = "" }
        guard !isActive else { return }
        text = routeQuery
        suggestions = []
        suggestionsPending = false
    }

    func textChanged() {
        highlighted = nil
        pointerAnchor = NSEvent.mouseLocation
        suggestTask?.cancel()
        let query = query
        guard !query.isEmpty else {
            suggestions = []
            suggestionsPending = false
            return
        }
        if let cached = suggestionCache[query] {
            suggestions = cached
            suggestionsPending = false
            return
        }
        let key = Self.fold(query)
        suggestions = suggestions.filter { Self.fold($0).contains(key) }
        suggestionsPending = true
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: Self.suggestDelay)
            guard !Task.isCancelled, let self else { return }
            do {
                guard let source = app?.searchSource else { throw CancellationError() }
                let words = try await source.searchSuggestions(query)
                guard !Task.isCancelled else { return }
                receive(words, for: query)
            } catch {
                // Not cached: the same text asks again next time.
                guard !Task.isCancelled else { return }
                if self.query == query { suggestionsPending = false }
            }
        }
    }

    func receive(_ words: [String], for query: String) {
        if suggestionCache.count > 200 { suggestionCache.removeAll() }
        suggestionCache[query] = words
        guard self.query == query else { return }
        suggestions = words
        suggestionsPending = false
    }

    func setText(_ value: String) {
        if text != value { text = value }
    }

    @discardableResult
    func moveHighlight(_ step: Int) -> Bool {
        let ids = panel.items.map(\.id)
        guard !ids.isEmpty else { return false }
        guard let current = highlighted, let index = ids.firstIndex(of: current) else {
            highlighted = step > 0 ? ids.first : ids.last
            return true
        }
        let next = index + step
        highlighted = ids.indices.contains(next) ? ids[next] : (next < 0 ? nil : ids.last)
        return true
    }

    func hover(_ id: String) {
        if let anchor = pointerAnchor {
            guard NSEvent.mouseLocation != anchor else { return }
            pointerAnchor = nil
        }
        highlighted = id
    }

    func commit() {
        if let id = highlighted, let item = panel.items.first(where: { $0.id == id }) {
            choose(item)
        } else {
            submit(text)
        }
    }

    func choose(_ item: Item) {
        submit(item.text)
    }

    func submit(_ raw: String) {
        var query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, let hint { query = hint.query }
        guard !query.isEmpty else { return }
        deactivate(keepingText: true)
        remember(query)
        setText(query)
        app?.navigate(.search(query))
    }

    func remember(_ query: String) {
        var list = history.filter { $0 != query }
        list.insert(query, at: 0)
        history = Array(list.prefix(Self.historyLimit))
        defaults.set(history, forKey: Self.historyKey)
    }

    func forget(_ query: String) {
        history.removeAll { $0 == query }
        defaults.set(history, forKey: Self.historyKey)
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Self.historyKey)
    }

    /// Loads the hints and the trending list shortly after launch, so the box has a hint and
    /// the panel its list when first opened, and starts turning the hints.
    func prepare() async {
        try? await Task.sleep(for: .seconds(1.5))
        await loadHints()
    }

    func sourceChanged() async {
        suggestionCache.removeAll()
        suggestions = []
        trends = []
        trendsState = .idle
        trendsLoadedAt = nil
        hints = []
        hintIndex = 0
        hintRotation?.cancel()
        await loadHints()
    }

    private func loadHints() async {
        let source = app?.searchSource
        async let hints = try? source?.searchHints()
        loadTrendsIfStale()
        if let loaded = await hints ?? nil, !loaded.isEmpty, source?.id == app?.browsingSourceID {
            self.hints = loaded
            startHintRotation()
        }
    }

    /// A source without search, or without a trending list, has none to show (not a failure).
    func loadTrendsIfStale() {
        guard trendsState != .loading else { return }
        if let loadedAt = trendsLoadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        guard let source = app?.searchSource else {
            trends = []
            trendsState = .loaded
            return
        }
        if trends.isEmpty { trendsState = .loading }
        Task {
            do {
                let loaded = try await source.trendingSearches()
                guard source.id == app?.browsingSourceID else { return }
                trends = loaded
                trendsLoadedAt = Date()
                trendsState = .loaded
            } catch {
                trendsState = trends.isEmpty ? .failed : .loaded
            }
        }
    }

    private func startHintRotation() {
        hintRotation?.cancel()
        guard hints.count > 1 else { return }
        hintRotation = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: Self.hintInterval) } catch { return }
                guard let self else { return }
                if !isActive, text.isEmpty, NSApp.isActive, !hints.isEmpty {
                    hintIndex = (hintIndex + 1) % hints.count
                }
            }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
