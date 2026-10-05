import Foundation
import Testing
import StarryCore
@testable import MusicSources

@Suite struct QualityTierTests {
    final class Source: MusicSource, @unchecked Sendable {
        let id: SourceID = .example
        let displayName = "测试"
        let qualityTiers: [QualityTier]
        init(_ tiers: [QualityTier]) { qualityTiers = tiers }
        func resolvePlayableAsset(_ track: Track, tier: QualityTier) async throws -> PlayableAsset { throw PlaybackError.sourceUnreachable }
    }

    static let dolby = QualityTier(id: "dolby", name: "杜比全景声", level: .hiRes, isSpatial: true, badge: "杜比")
    static let platform = Source([
        QualityTier(id: "lq", name: "标准", level: .lq),
        QualityTier(id: "hq", name: "HQ 高品质", level: .hq),
        QualityTier(id: "lossless", name: "SQ 无损", level: .lossless),
        QualityTier(id: "hi-res", name: "Hi-Res", level: .hiRes),
        dolby,
    ])

    @Test func globalPreferenceMapsToTheBestStereoTierAtOrBelowIt() {
        #expect(Self.platform.tier(for: .hiRes).id == "hi-res")
        #expect(Self.platform.tier(for: .hq).id == "hq")
        #expect(Self.platform.tier(for: .sq).id == "lq")
        // A spatial mix is never what the global preference means.
        #expect(!AudioQuality.allCases.contains { Self.platform.tier(for: $0).isSpatial })
    }

    @Test func aTierPickedForTheSourceWins() {
        #expect(Self.platform.requestedTier(preferred: .hq, override: "dolby") == Self.dolby)
        #expect(Self.platform.requestedTier(preferred: .hq, override: nil).id == "hq")
        // A pick the source no longer has (Dolby on a Mac that cannot play it) is ignored.
        #expect(Self.platform.requestedTier(preferred: .lossless, override: "atmos").id == "lossless")
    }

    @Test func aSourceWithoutTiersUsesTheGenericLevels() {
        let plain = Source([])
        #expect(plain.tiers.map(\.id) == ["lq", "sq", "hq", "lossless", "hi-res"])
        #expect(plain.tier(for: .lossless) == QualityTier(.lossless))
    }

    @Test func badges() {
        #expect(QualityTier(.hiRes).badge == "Hi-Res")
        #expect(QualityTier(.hq).badge == nil)
        #expect(Self.dolby.badge == "杜比")
    }

    @Test func savedTracksKeepTheirTiers() throws {
        let track = Track(id: TrackRef(source: .example, id: "1"), title: "t", duration: 1, availableTiers: ["lq", "hi-res"])
        let json = try JSONEncoder().encode(track)
        #expect(String(decoding: json, as: UTF8.self).contains(#""availableQualities":["lq","hi-res"]"#))
        #expect(try JSONDecoder().decode(Track.self, from: json) == track)
    }
}
