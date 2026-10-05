import Foundation
import MusicSources
import StarryCore
import Testing
@testable import StarryPlayer

@Suite
@MainActor
struct SearchModelTests {
    private func model(history: [String] = []) -> SearchModel {
        let defaults = UserDefaults(suiteName: "starry-search-tests-\(UUID().uuidString)")!
        let search = SearchModel(defaults: defaults)
        history.forEach(search.remember)
        return search
    }

    private func typing(_ search: SearchModel, _ text: String, suggestions: [String] = []) {
        search.activate()
        search.setText(text)
        search.textChanged()
        search.receive(suggestions, for: text)
    }

    @Test func historyIsNewestFirstOnceEachAndCapped() {
        let search = model(history: ["a", "b", "a"])
        #expect(search.history == ["a", "b"])
        (0..<30).forEach { search.remember("q\($0)") }
        #expect(search.history.count == SearchModel.historyLimit)
        #expect(search.history.first == "q29")
        search.forget("q29")
        #expect(search.history.first == "q28")
    }

    @Test func typedPanelListsTheQueryThenRecentMatchesThenSuggestions() {
        let search = model(history: ["周杰伦晴天", "林俊杰", "周杰伦", "周杰"])
        typing(search, "周杰", suggestions: ["周杰伦", "周杰伦歌单", "周杰伦晴天", "周杰伦稻香", "周杰伦青花瓷", "周杰伦搁浅", "周杰伦七里香", "周杰伦兰亭序", "周杰伦红尘客栈", "周杰伦告白气球"])
        let items = search.panel.items
        #expect(items.first == .query("周杰"))
        // The recent searches containing the text (not the text itself), newest first…
        #expect(items[1] == .recent("周杰伦"))
        #expect(items[2] == .recent("周杰伦晴天"))
        // …then the suggestions not already listed, up to the panel's length.
        #expect(items.dropFirst(3).allSatisfy { if case .suggestion = $0 { true } else { false } })
        #expect(!items.contains(.suggestion("周杰伦")))
        #expect(items.count == 1 + SearchModel.suggestionsShown)
    }

    @Test func emptyPanelListsRecentSearchesThenTheTrendingList() {
        let search = model(history: ["a", "b"])
        search.activate()
        #expect(search.panel.query.isEmpty)
        #expect(search.panel.items == [.recent("b"), .recent("a")])
    }

    @Test func arrowsWalkThePanelAndUpLeavesIt() {
        let search = model()
        typing(search, "夜", suggestions: ["夜航星", "夜晚"])
        #expect(search.moveHighlight(1))
        #expect(search.highlighted == SearchModel.Item.query("夜").id)
        search.moveHighlight(1)
        search.moveHighlight(1)
        search.moveHighlight(1)
        #expect(search.highlighted == SearchModel.Item.suggestion("夜晚").id)
        search.moveHighlight(-1)
        search.moveHighlight(-1)
        search.moveHighlight(-1)
        #expect(search.highlighted == nil)
        search.moveHighlight(1)
        search.setText("夜航")
        search.textChanged()
        #expect(search.highlighted == nil)
    }

    @Test func suggestionsForAnOlderTextAreCachedButNotShown() {
        let search = model()
        search.activate()
        search.setText("夜航")
        search.textChanged()
        search.receive(["夜晚"], for: "夜")
        #expect(search.panel.items == [.query("夜航")])
        #expect(search.panel.pending)
        search.setText("夜")
        search.textChanged()
        #expect(search.panel.items == [.query("夜"), .suggestion("夜晚")])
        #expect(!search.panel.pending)
    }

    @Test func closingKeepsThePanelAsItWas() {
        let search = model()
        typing(search, "夜", suggestions: ["夜航星"])
        let before = search.panel
        search.deactivate()
        search.remember("夜航星")
        search.setText("夜航星")
        #expect(!search.isActive)
        #expect(search.panel == before)
        search.activate()
        #expect(search.panel.query == "夜航星")
    }

    @Test func theRouteSetsTheClosedBoxText() {
        let search = model()
        search.routeChanged(.search("晴天"))
        #expect(search.text == "晴天")
        search.routeChanged(.home)
        #expect(search.text.isEmpty)
        typing(search, "七里")
        search.routeChanged(.search("晴天"))
        #expect(search.text == "七里")
        search.deactivate()
        #expect(search.text == "晴天")
        typing(search, "七里香")
        search.submit(search.text)
        #expect(search.text == "七里香")
        #expect(search.history.first == "七里香")
    }
}

struct SearchFormatTests {
    @Test func cardSubtitles() {
        let album = Album(id: "1", source: .example, name: "叶惠美", artists: [ArtistRef(id: "6452", name: "周杰伦")], releaseDate: Date(timeIntervalSince1970: 1_059_667_200))
        #expect(SearchFormat.albumSubtitle(album) == "周杰伦 · 2003")
        #expect(SearchFormat.albumSubtitle(Album(id: "2", source: .example, name: "x")) == "")
        let playlist = Playlist(id: "3", source: .example, name: "精选", creatorName: "someone", trackCount: 42)
        #expect(SearchFormat.playlistSubtitle(playlist) == "42 首 · someone")
        let artist = Artist(id: "6452", source: .example, name: "周杰伦", albumCount: 41, songCount: 568, alias: "Jay Chou", followerCount: 19_021_444)
        #expect(SearchFormat.artistDetail(artist) == "568 首歌曲 · 41 张专辑 · \(TimeFormatting.compactCount(19_021_444)) 粉丝")
        #expect(SearchFormat.artistSubtitle(artist) == "Jay Chou")
        #expect(SearchFormat.artistDetail(Artist(id: "1", source: .example, name: "x", alias: "y")) == "y")
    }
}
