import Foundation
import StarryCore
import Testing
@testable import StarryPlayer

struct HomePageFormattingTests {
    private func track(_ id: String, _ artists: String...) -> Track {
        Track(id: TrackRef(source: .example, id: id), title: id, artists: artists.enumerated().map { ArtistRef(id: "\($0.offset)", name: $0.element) }, duration: 200)
    }

    @Test func dateLineIsChineseWhateverTheLocale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 12))!
        #expect(HomePage.dateLine(date) == "9月29日 星期二")
    }

    @Test func artistLineTakesThreeDistinctLeadArtists() {
        #expect(HomePage.artistLine([]) == "")
        #expect(HomePage.artistLine([track("a", "林晚风"), track("b", "林晚风", "苏禾")]) == "林晚风")
        #expect(HomePage.artistLine([track("a", "林晚风"), track("b", "Kaito Mori"), track("c", "白鹭乐队")]) == "林晚风、Kaito Mori、白鹭乐队")
        #expect(HomePage.artistLine([track("a", "林晚风"), track("b", "Kaito Mori"), track("c", "白鹭乐队"), track("d", "苏禾")]) == "林晚风、Kaito Mori、白鹭乐队 等")
    }
}
