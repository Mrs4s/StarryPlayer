import StarryCore
import Testing
@testable import StarryPlayer

struct NavigationHistoryTests {
    private let album = Route.album(Album(id: "1", source: .example, name: "Album", trackCount: 12, company: "Label"))
    private let artist = Route.artist(Artist(id: "2", source: .example, name: "Artist"))
    private let playlist = Route.collection(Playlist(id: "3", source: .example, name: "Playlist"))

    private func history(_ routes: Route...) -> NavigationHistory {
        var history = NavigationHistory()
        routes.forEach { history.open($0) }
        return history
    }

    private func search(_ n: Int) -> Route { .search("\(n)") }

    @Test func reopeningAPageMovesItsEntryToTheTop() throws {
        var history = history(album, artist, playlist)
        let entry = try #require(history.entries.first { $0.route == album })
        history.open(album)
        #expect(history.entries.map(\.route) == [.home, artist, playlist, album])
        #expect(history.current.id == entry.id)
        history.goBack()
        #expect(history.current.route == playlist)
    }

    @Test func sameIDIsSamePageWhateverTheMetadata() {
        var history = history(album, artist)
        let id = history.entries[1].id
        history.open(.album(Album(id: "1", source: .example, name: "Album")))
        #expect(history.entries.count == 3)
        #expect(history.current.id == id)
        #expect(history.current.route == album)
        #expect(!Route.album(Album(id: "1", source: .local, name: "Album")).isSamePage(as: album))
        #expect(!Route.search("a").isSamePage(as: .search("b")))
    }

    @Test func currentPageIsANoOp() {
        var history = history(album)
        let before = history.entries.map(\.id)
        history.open(.album(Album(id: "1", source: .example, name: "Album")))
        #expect(history.entries.map(\.id) == before)
    }

    @Test func goingBackDropsThePageLeft() {
        var history = history(album, artist)
        let behind = history.entries[1].id
        history.goBack()
        #expect(history.entries.map(\.route) == [.home, album])
        #expect(history.live.map(\.route) == [.home, album])
        #expect(history.current.id == behind)
        history.open(artist)
        #expect(history.entries.count == 3)
        history.goBack()
        history.goBack()
        #expect(!history.canGoBack)
        history.goBack()
        #expect(history.entries.map(\.route) == [.home])
    }

    @Test func movedPageStaysLive() {
        var history = history(album, artist, playlist)
        let live = Set(history.live.map(\.id))
        history.open(album)
        #expect(Set(history.live.map(\.id)) == live)
    }

    @Test func keepsTheCurrentPageAndEightBehind() {
        var history = NavigationHistory()
        (1...12).forEach { history.open(search($0)) }
        #expect(history.live.map(\.route) == (4...12).map(search))
        // Going back does not mount the page coming into the window behind.
        history.goBack()
        #expect(history.live.map(\.route) == (4...11).map(search))
        (1...8).forEach { _ in history.goBack() }
        #expect(history.current.route == search(3))
        #expect(history.live.map(\.route) == [search(3)])
        // So does opening one.
        history.open(search(1))
        #expect(history.entries.map(\.route) == [.home, search(2), search(3), search(1)])
        #expect(history.live.map(\.route) == [search(3), search(1)])
    }
}
