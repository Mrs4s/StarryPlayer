import Foundation
import Testing
@testable import StarryPlayer

struct AlbumPageFormattingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func commentTimes() {
        let now = date(2026, 9, 29, 12, 0)
        #expect(CommentTime.text(now.addingTimeInterval(-30), now: now, calendar: calendar) == "刚刚")
        #expect(CommentTime.text(now.addingTimeInterval(-5 * 60), now: now, calendar: calendar) == "5 分钟前")
        #expect(CommentTime.text(date(2026, 9, 29, 8, 5), now: now, calendar: calendar) == "08:05")
        #expect(CommentTime.text(date(2026, 9, 28, 23, 40), now: now, calendar: calendar) == "昨天 23:40")
        #expect(CommentTime.text(date(2026, 3, 7), now: now, calendar: calendar) == "3月7日")
        #expect(CommentTime.text(date(2014, 11, 29), now: now, calendar: calendar) == "2014年11月29日")
    }

    @Test func albumDuration() {
        #expect(DetailFormat.durationText(48 * 60 + 20) == "48 分钟")
        #expect(DetailFormat.durationText(72 * 60) == "1 小时 12 分钟")
    }

    @Test func playlistUpdateDays() {
        let now = date(2026, 9, 30, 10, 0)
        #expect(DetailFormat.dayText(date(2026, 9, 30, 0, 5), now: now, calendar: calendar) == "今天")
        #expect(DetailFormat.dayText(date(2026, 9, 29, 23, 50), now: now, calendar: calendar) == "昨天")
        #expect(DetailFormat.dayText(date(2026, 9, 25), now: now, calendar: calendar) == "9月25日")
        #expect(DetailFormat.dayText(date(2024, 3, 12), now: now, calendar: calendar) == "2024年3月12日")
    }
}
