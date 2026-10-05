import Foundation
import Testing
import StarryCore
@testable import MusicSources

@Suite struct ResolverTests {
    @Test func resolverSkipsTrialWhenDisabled() async throws {
        struct Trial: PlayURLResolverStep {
            let provider: AssetProvider = .trial
            func resolve(_ track: Track, tier: QualityTier) async throws -> PlayableAsset? {
                PlayableAsset(url: URL(string: "https://x/y.mp3")!, container: .mp3, tier: QualityTier(.lq), isTrial: true, provider: .trial)
            }
        }
        let resolver = PlayURLResolver(steps: [Trial()])
        let track = Track(id: TrackRef(source: .example, id: "1"), title: "t", duration: 10, fee: .vip)
        await #expect(throws: PlaybackError.vipRequired) {
            _ = try await resolver.resolve(track, options: ResolveOptions(allowTrialPlay: false))
        }
        let asset = try await resolver.resolve(track, options: ResolveOptions(allowTrialPlay: true))
        #expect(asset.isTrial)
    }

    @Test func lyricMatchScoring() {
        let candidate = LyricCandidate(title: "晴天", artists: ["周杰伦"], album: "叶惠美", duration: 269, payload: "1")
        #expect(LyricCandidateMatcher.score(candidate, for: LyricQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 270)) == 20)
        #expect(LyricCandidateMatcher.score(candidate, for: LyricQuery(title: "晴天", duration: 300)) == nil)
        #expect(LyricCandidateMatcher.score(candidate, for: LyricQuery(title: "晴")) == nil)
        #expect(LyricCandidateMatcher.score(candidate, for: LyricQuery(title: "晴", artist: "周杰伦")) == 9)
        // Same title by someone else is rejected when the query names artists.
        #expect(LyricCandidateMatcher.score(candidate, for: LyricQuery(title: "晴天", artist: "孙燕姿")) == nil)
        let duet = LyricCandidate(title: "Lemon (Live)", artists: ["米津玄師 / 菅田将暉"], duration: 255, payload: "2")
        #expect(LyricCandidateMatcher.score(duet, for: LyricQuery(title: "Lemon", artists: ["米津玄師"], duration: 256)) == 12)
    }

    @Test func lyricMatchPicksBestCandidate() {
        let query = LyricQuery(title: "明知故犯", artists: ["许美静"], album: "林夕字传", duration: 259)
        let candidates = [
            LyricCandidate(title: "明知故犯 (新加坡版)", artists: ["许美静"], album: "静听精彩十三首", duration: 260, payload: "sg"),
            LyricCandidate(title: "明知故犯", artists: ["许美静"], album: "林夕字传", duration: 259, payload: "main"),
            LyricCandidate(title: "明知道", artists: ["许美静"], duration: 261, payload: "other"),
        ]
        #expect(LyricCandidateMatcher.best(candidates, for: query)?.payload == "main")
        #expect(LyricCandidateMatcher.searchKeyword(for: query) == "明知故犯 许美静")
        #expect(LyricCandidateMatcher.fingerprint(for: query) == LyricCandidateMatcher.fingerprint(for: LyricQuery(title: "明知故犯 ", artists: ["许美静"], duration: 260)))
    }
}
