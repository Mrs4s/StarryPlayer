import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalActivityAnalyzerTests {
    @Test func rejectsUnreadableFiles() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "starry-not-audio-\(UUID().uuidString).mp3")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: VocalActivityError.unreadable) { try VocalActivityAnalyzer(file: url, model: nil) }
    }
}
