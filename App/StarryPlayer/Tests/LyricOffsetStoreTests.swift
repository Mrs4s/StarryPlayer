import Foundation
import Library
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricOffsetStoreTests {
    private let track = TrackRef(source: .example, id: "1001")
    private func lyrics(_ first: TimeInterval) -> LyricsDocument {
        LyricsDocument(format: .lrc, lines: [
            .plain(id: 0, start: first, end: first + 3, text: "这一路上走走停停"),
            .plain(id: 1, start: first + 3, end: first + 6, text: "顺着少年漂流的痕迹"),
        ])
    }

    @Test func keyFollowsTheLyricTiming() {
        let key = LyricOffsetStore.key(track: track, lyrics: lyrics(25.237))
        #expect(key == LyricOffsetStore.key(track: track, lyrics: lyrics(25.237)))
        #expect(key.hasPrefix("plugin:example:1001#"))
        #expect(key != LyricOffsetStore.key(track: track, lyrics: lyrics(25.5)))
        #expect(key != LyricOffsetStore.key(track: TrackRef(source: .example, id: "1"), lyrics: lyrics(25.237)))
    }

    @Test func offsetsPersistAndHandSetZeroForgets() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "starry-offsets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = LyricOffsetStore.key(track: track, lyrics: lyrics(25.237))
        let store = LyricOffsetStore(directory: DataDirectory(url: folder))
        store.set(0.77, calibrated: true, for: key)
        let reopened = LyricOffsetStore(directory: DataDirectory(url: folder))
        #expect(reopened.entry(for: key)?.offset == 0.77)
        #expect(reopened.entry(for: key)?.calibrated == true)
        reopened.set(0, calibrated: true, for: key)
        #expect(LyricOffsetStore(directory: DataDirectory(url: folder)).entry(for: key)?.offset == 0)
        reopened.set(0, calibrated: false, for: key)
        #expect(LyricOffsetStore(directory: DataDirectory(url: folder)).entry(for: key) == nil)
    }
}
