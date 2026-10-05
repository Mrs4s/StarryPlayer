import Foundation
import StarryCore
import Testing
@testable import StarryPlayer

struct ArtistPageFormattingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func album(_ id: String, _ y: Int?, _ m: Int = 1, _ d: Int = 1, type: String? = nil, edition: String? = nil) -> Album {
        let date = y.map { calendar.date(from: DateComponents(year: $0, month: m, day: d, hour: 12))! }
        return Album(id: id, source: .example, name: id, releaseDate: date, releaseType: type, edition: edition)
    }

    @Test func worksBecomeChips() {
        #expect(ArtistBio.blocks("我的快乐时代、K歌之王、十年、富士山下") == [.works(["我的快乐时代", "K歌之王", "十年", "富士山下"])])
        // Two names are a sentence, not a list of works.
        #expect(ArtistBio.blocks("十年、浮夸") == [.paragraph("十年、浮夸")])
    }

    @Test func shortLinesBecomeAList() {
        let text = "三届台湾金曲奖最佳国语男歌手奖\n十大劲歌金曲最受欢迎男歌星奖\n\n音乐风云榜最佳男歌手奖"
        #expect(ArtistBio.blocks(text) == [.list(["三届台湾金曲奖最佳国语男歌手奖", "十大劲歌金曲最受欢迎男歌星奖", "音乐风云榜最佳男歌手奖"])])
    }

    @Test func careerReadsAsPeriodsAndParagraphs() {
        let text = "华星时期\n1995年暑假期间，陈奕迅参加TVB举办的第14届新秀歌唱大赛，并获得冠军。\n英皇时期\n2000年，签约英皇娱乐。\n结语"
        #expect(ArtistBio.blocks(text) == [
            .heading("华星时期"),
            .paragraph("1995年暑假期间，陈奕迅参加TVB举办的第14届新秀歌唱大赛，并获得冠军。"),
            .heading("英皇时期"),
            .paragraph("2000年，签约英皇娱乐。"),
            // The last line has nothing under it, so it is not a heading.
            .paragraph("结语"),
        ])
    }

    @Test func discographyGroupsByYear() {
        let albums = [album("a", 2025, 10), album("b", 2025, 8), album("c", 2025, 3), album("d", 2024), album("e", nil)]
        let rows = DiscographyRows.rows(albums, columns: 2, calendar: calendar)
        #expect(rows.map(\.albums).map { $0.map(\.id) } == [["a", "b"], ["c"], ["d"], ["e"]])
        #expect(rows.map { $0.year?.title } == ["2025", nil, "2024", "其他"])
        #expect(rows.map { $0.year?.count } == [3, nil, 1, 1])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func albumSubtitles() {
        #expect(DiscographyRows.subtitle(album("a", 2025, 10, 23, type: "Single", edition: "录音室版"), calendar: calendar) == "10月23日 · 单曲")
        #expect(DiscographyRows.subtitle(album("b", 2025, 8, 25, type: "专辑", edition: "现场版"), calendar: calendar) == "8月25日 · 现场版")
        #expect(DiscographyRows.subtitle(album("c", 2015, 7, 3, type: "EP/Single"), calendar: calendar) == "7月3日 · EP")
        #expect(DiscographyRows.subtitle(album("d", nil)) == "")
    }

    @MainActor @Test func pagesListEachItemOnce() {
        let page = [album("a", 2025), album("b", 2025), album("a", 2024)]
        #expect(PagedFeed<Album>.unique(page, after: []).map(\.id) == ["a", "b"])
        #expect(PagedFeed<Album>.unique(page, after: [album("b", 2020)]).map(\.id) == ["a"])
    }
}
