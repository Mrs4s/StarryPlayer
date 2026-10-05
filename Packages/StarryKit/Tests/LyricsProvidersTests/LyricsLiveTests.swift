import Foundation
import Testing
@testable import LyricsProviders

/// Hits the AMLL TTML DB. Run with `LYRICS_LIVE=1 swift test --filter LyricsLive`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYRICS_LIVE"] != nil), .serialized)
struct LyricsLiveTests {
    @Test func amllHitAndFastMiss() async throws {
        // The server is slow at times; the app waits 8 s, the test is lenient.
        let database = AMLLDatabase(cache: LyricsCache(directory: nil), timeout: 25)
        var started = Date()
        let hit = await database.ttml(template: AMLLDatabase.defaultTemplate, folder: "ncm-lyrics", ids: ["536622304"])
        print("amll hit took", Date().timeIntervalSince(started), "s")
        #expect(hit?.contains("<tt") == true)
        // A missing id answers 302 to a slow web page; the redirect must not be followed.
        started = Date()
        let miss = await database.ttml(template: AMLLDatabase.defaultTemplate, folder: "ncm-lyrics", ids: ["1"])
        print("amll miss took", Date().timeIntervalSince(started), "s")
        #expect(miss == nil)
    }
}
