import Foundation
import Testing
import StarryCore
@testable import MusicSources

@Suite struct SearchOverviewTests {
    private func song(_ id: String, _ title: String) -> Track { Track(id: TrackRef(source: .example, id: id), title: title, duration: 200) }

    @Test func artistNamedLikeTheQueryWins() {
        let overview = SearchOverview(
            songs: [song("1", "晴天")],
            artists: [Artist(id: "2", source: .example, name: "周杰伦", alias: "Jay Chou / 周董")]
        )
        guard case .artist(let artist) = SearchOverview.guessTopResult(for: "jay chou", in: overview) else { Issue.record("expected the artist"); return }
        #expect(artist.id == "2")
        guard case .song(let track) = SearchOverview.guessTopResult(for: "晴天", in: overview) else { Issue.record("expected the song"); return }
        #expect(track.id.id == "1")
    }

    @Test func fallsBackToTheFirstResult() {
        let album = Album(id: "a", source: .example, name: "叶惠美")
        #expect(SearchOverview.guessTopResult(for: "叶惠美", in: SearchOverview(songs: [song("1", "晴天")], albums: [album])) == .album(album))
        #expect(SearchOverview.guessTopResult(for: "x", in: SearchOverview(songs: [song("1", "晴天")], albums: [album])) == .song(song("1", "晴天")))
        #expect(SearchOverview.guessTopResult(for: "x", in: SearchOverview()) == nil)
    }
}
