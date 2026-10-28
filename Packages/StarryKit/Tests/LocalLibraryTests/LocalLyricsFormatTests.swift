import Foundation
import LyricsCore
import Testing
@testable import LocalLibrary

@Suite struct LocalLyricsFormatTests {
    @Test func localSidecarsRecognizeKRAAndSRTAndSkipUnusableCandidates() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "starry-sidecars-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = directory.appending(path: "Song.flac")
        try "broken".write(to: directory.appending(path: "Song.ttml"), atomically: true, encoding: .utf8)
        try "[00:01.00]<00:01.00>你<00:02.00>好<00:03.00>".write(to: directory.appending(path: "Song.kra"), atomically: true, encoding: .utf8)
        #expect(LocalLyrics.sidecar(for: song, providerName: "Local")?.format == .lrc)
        try FileManager.default.removeItem(at: directory.appending(path: "Song.kra"))
        try "1\n00:00:01,000 --> 00:00:03,000\n你好\n".write(to: directory.appending(path: "Song.srt"), atomically: true, encoding: .utf8)
        #expect(LocalLyrics.sidecar(for: song, providerName: "Local")?.format == .srt)
        try FileManager.default.removeItem(at: directory.appending(path: "Song.srt"))
        try "# Format: [mm:ss.xx]Lyrics\n[00:01.00]你好".write(to: directory.appending(path: "Song.txt"), atomically: true, encoding: .utf8)
        #expect(LocalLyrics.sidecar(for: song, providerName: "Local")?.body.contains("你好") == true)
        #expect(LocalLyrics.timedFormat("just words") == nil)
        #expect(LocalLyrics.timedFormat("1\n00:00:01,000 --> 00:00:03,000\nWords") == .srt)
        try "【@Alice】{未|[00:01:00]み>[00:01:00]mi}[00:02:00]".write(to: directory.appending(path: "Song.krl"), atomically: true, encoding: .utf8)
        #expect(LocalLyrics.sidecar(for: song, providerName: "Local")?.format == .krl)
        try FileManager.default.removeItem(at: directory.appending(path: "Song.krl"))
        let ass = "[Script Info]\n[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00,0:00:02.00,{\\k100}Words"
        try ass.write(to: directory.appending(path: "Song.ass"), atomically: true, encoding: .utf8)
        #expect(LocalLyrics.sidecar(for: song, providerName: "Local")?.format == .ass)
    }
}
