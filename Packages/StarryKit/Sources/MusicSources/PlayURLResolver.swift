import Foundation
import StarryCore

public protocol PlayURLResolverStep: Sendable {
    var provider: AssetProvider { get }
    func resolve(_ track: Track, tier: QualityTier) async throws -> PlayableAsset?
}

public struct ResolveOptions: Sendable {
    public var allowTrialPlay: Bool
    public var tier: QualityTier

    public init(allowTrialPlay: Bool = false, tier: QualityTier = QualityTier(.default)) {
        self.allowTrialPlay = allowTrialPlay
        self.tier = tier
    }
}

public struct PlayURLResolver: Sendable {
    public var steps: [any PlayURLResolverStep]

    public init(steps: [any PlayURLResolverStep]) {
        self.steps = steps
    }

    public func resolve(_ track: Track, options: ResolveOptions) async throws -> PlayableAsset {
        var lastError: Error?
        for step in steps {
            do {
                if let asset = try await step.resolve(track, tier: options.tier) {
                    if asset.isTrial, !options.allowTrialPlay { continue }
                    return asset
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        switch track.fee {
        case .vip, .purchase: throw PlaybackError.vipRequired
        default: throw PlaybackError.sourceUnreachable
        }
    }
}

public struct SourceStep: PlayURLResolverStep {
    public let provider: AssetProvider = .source
    private let lookup: @Sendable (SourceID) async -> (any MusicSource)?

    public init(lookup: @escaping @Sendable (SourceID) async -> (any MusicSource)?) {
        self.lookup = lookup
    }

    public func resolve(_ track: Track, tier: QualityTier) async throws -> PlayableAsset? {
        guard let source = await lookup(track.id.source) else { throw SourceError.notRegistered(track.id.source) }
        return try await source.resolvePlayableAsset(track, tier: tier)
    }
}

public struct CacheStep: PlayURLResolverStep {
    public let provider: AssetProvider = .cache
    private let lookup: @Sendable (Track, QualityTier) async -> PlayableAsset?

    public init(lookup: @escaping @Sendable (Track, QualityTier) async -> PlayableAsset?) {
        self.lookup = lookup
    }

    public func resolve(_ track: Track, tier: QualityTier) async throws -> PlayableAsset? {
        guard track.localPath == nil else { return nil }
        return await lookup(track, tier)
    }
}
