import Foundation
import Testing
@testable import PlaybackEngine

@MainActor
@Suite struct PCMPlayerTests {
    @Test func undecodableFileThrows() async {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        try? Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: (any Error).self) {
            _ = try await PCMPlayer.decode(source, to: PCMPlayer.directory.appendingPathComponent("never.caf"))
        }
    }
}
