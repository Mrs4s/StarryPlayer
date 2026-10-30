import Foundation

public struct LyricsAIReviewIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case estimatedReading, uncertainReading, uncertainTiming
    }

    public var syllableIDs: [UUID]
    public var kind: Kind
    public var message: String

    public init(syllableIDs: [UUID], kind: Kind, message: String) {
        self.syllableIDs = syllableIDs
        self.kind = kind
        self.message = message
    }
}
