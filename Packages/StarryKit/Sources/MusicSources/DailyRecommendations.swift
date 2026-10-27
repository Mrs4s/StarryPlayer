import StarryCore

/// A named tag within a recommendation category.
public struct RecommendationStyle: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RecommendationStyleCategory: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var styles: [RecommendationStyle]
    public var selectedStyleIDs: [String]

    public init(id: String, name: String, styles: [RecommendationStyle], selectedStyleIDs: [String] = []) {
        self.id = id
        self.name = name
        self.styles = styles
        self.selectedStyleIDs = selectedStyleIDs
    }
}

/// Daily songs based on the account's selected tags.
public protocol StyleRecommendationSource: MusicSource {
    func recommendationStyles() async throws -> [RecommendationStyleCategory]
    func styleRecommendations() async throws -> [Track]
    /// Applies one category's tags. Read `recommendationStyles` again for the current selection.
    func setRecommendationStyles(categoryID: String, styleIDs: [String]) async throws
}

public protocol DailyRecommendationHistorySource: MusicSource {
    /// Available YYYY-MM-DD dates, newest first.
    func dailyRecommendationDates() async throws -> [String]
    func dailyRecommendationHistory(date: String) async throws -> [Track]
}
