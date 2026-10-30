import Foundation
import Testing
@testable import AudioProcessing

@Suite struct WaveformPeaksTests {
    @Test func unreadableFileGivesNothing() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        try? Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await WaveformPeaks.read(url) == nil)
    }
}
