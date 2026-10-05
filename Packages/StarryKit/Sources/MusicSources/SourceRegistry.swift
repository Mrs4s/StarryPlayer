import Foundation
import Observation
import StarryCore

public enum SourceError: Error, Sendable, Equatable {
    case notRegistered(SourceID)
    case capabilityMissing(String)
    case notImplemented(String)
    case invalidResponse(String)
    case network(String)
}

@MainActor
@Observable
public final class SourceRegistry {
    public private(set) var sources: [any MusicSource] = []
    public var currentSourceID: SourceID

    public init() {
        currentSourceID = .local
    }

    public func register(_ source: any MusicSource) {
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        if self.source(for: currentSourceID) == nil { currentSourceID = source.id }
    }

    public func unregister(_ id: SourceID) {
        sources.removeAll { $0.id == id }
        if id == currentSourceID, let first = sources.first { currentSourceID = first.id }
    }

    public func source(for id: SourceID) -> (any MusicSource)? {
        sources.first { $0.id == id }
    }

    public var current: (any MusicSource)? { source(for: currentSourceID) }

    public func source<T>(for id: SourceID, as type: T.Type) -> T? {
        source(for: id)?.capability(type)
    }
}
