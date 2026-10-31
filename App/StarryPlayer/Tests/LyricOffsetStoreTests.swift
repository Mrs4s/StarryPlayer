import Foundation
import Library
import LyricsCore
import LyricsSync
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

    private func playing(_ document: LyricsDocument) async throws -> PlayerController {
        let player = PlayerController()
        player.play([Track(id: track, title: "Fixture", duration: 12)])
        for _ in 0..<200 where player.current == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(player.current?.id == track)
        player.useLyrics(.init(document: document, origin: .file("original.lrc")))
        return player
    }

    private var regenerated: LyricsAIAlignmentResult {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "あ", start: 1, end: 2), .init(text: "い", start: 2, end: 3)])])
        return .init(draft: draft, alignedLines: 1, alignedSyllables: 2)
    }

    @Test(arguments: [false, true])
    func regeneratedLyricsResetOffsetAndRestoreTheOriginalAfterRepeatedGeneration(unchangedTiming: Bool) async throws {
        let source = lyrics(1)
        let original = unchangedTiming ? regenerated.draft.document() : source
        let player = try await playing(original)
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        player.setLyricOffset(0.75)
        #expect(player.applyRegeneratedLyrics(regenerated, replacing: original, for: track))
        let generated = try #require(player.lyrics)
        #expect(generated == regenerated.draft.document())
        #expect(player.lyricOffset == 0)
        #expect(player.applyRegeneratedLyrics(regenerated, replacing: generated, for: track))
        player.restoreLyricsBeforeRegeneration()
        #expect(player.lyrics == original)
        #expect(player.lyricsOrigin == .file("original.lrc"))
        #expect(player.lyricOffset == 0.75)
        #expect(!player.canRestoreLyricsBeforeRegeneration)
    }

    @Test(arguments: [false, true])
    func staleGenerationCannotReplaceAnotherTrackOrChangedLyrics(trackChanged: Bool) async throws {
        let original = lyrics(1)
        let player = try await playing(original)
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        if trackChanged {
            let next = Track(id: .init(source: .example, id: "1002"), title: "Next", duration: 12)
            player.play([next])
            for _ in 0..<200 where player.current?.id != next.id { try await Task.sleep(for: .milliseconds(5)) }
            try #require(player.current?.id == next.id)
            player.useLyrics(.init(document: original, origin: .file("next.lrc")))
        } else {
            var changed = original
            changed.lines[0].translation = "changed"
            player.useLyrics(.init(document: changed, origin: .file("original.lrc")))
        }
        let current = player.lyrics
        #expect(!player.applyRegeneratedLyrics(regenerated, replacing: original, for: track))
        #expect(player.lyrics == current)
        #expect(!player.canRestoreLyricsBeforeRegeneration)
    }
}
