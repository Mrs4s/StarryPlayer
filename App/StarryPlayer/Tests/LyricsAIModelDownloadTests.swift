import Foundation
import LyricsSync
import Testing
@testable import StarryPlayer

@MainActor @Suite struct LyricsAIModelDownloadTests {
    private actor Gate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil; waiting = false }
    }

    private func wait(_ state: LyricsAIModelDownloadState) async throws {
        for _ in 0..<200 where state.isDownloading { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!state.isDownloading)
    }
    private func wait(_ gate: Gate) async throws {
        for _ in 0..<200 {
            if await gate.waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Download did not reach the gate")
    }

    @Test func modelChosenDuringDownloadIsNotOverwritten() async throws {
        let name = "starry-ai-download-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = Gate(), destination = URL(fileURLWithPath: "/synthetic-model/r32-v1")
        let state = LyricsAIModelDownloadState(defaults: defaults) { _, _ in await gate.wait(); return destination }
        state.start()
        try await wait(gate)
        defaults.set("/custom-model", forKey: LyricsAIModelDownloadState.directoryKey)
        await gate.open()
        try await wait(state)
        #expect(defaults.string(forKey: LyricsAIModelDownloadState.directoryKey) == "/custom-model")
        #expect(state.installedDirectory == destination)
        state.useInstalled()
        #expect(defaults.string(forKey: LyricsAIModelDownloadState.directoryKey) == destination.path)
    }

    @Test func cancelledDownloadDoesNotSelectItsResultAndCanBeRetried() async throws {
        let name = "starry-ai-download-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = Gate(), destination = URL(fileURLWithPath: "/synthetic-model/r32-v1")
        let state = LyricsAIModelDownloadState(defaults: defaults) { _, _ in await gate.wait(); return destination }
        state.start()
        try await wait(gate)
        state.cancel()
        #expect(state.isCancelling)
        await gate.open()
        try await wait(state)
        #expect(state.installedDirectory == nil)
        #expect(defaults.string(forKey: LyricsAIModelDownloadState.directoryKey) == nil)
        #expect(state.notice == "已停止下载")
        state.start()
        try await wait(gate)
        await gate.open()
        try await wait(state)
        #expect(state.installedDirectory == destination)
        #expect(defaults.string(forKey: LyricsAIModelDownloadState.directoryKey) == destination.path)
        #expect(state.error == nil)
    }

    @Test func failedDownloadKeepsTheSelectedModelAndOffersRetry() async throws {
        let name = "starry-ai-download-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/custom-model", forKey: LyricsAIModelDownloadState.directoryKey)
        let state = LyricsAIModelDownloadState(defaults: defaults) { _, _ in throw LyricsAIModelInstallError.checksum }
        state.start()
        try await wait(state)
        #expect(state.error != nil)
        #expect(!state.isCancelling)
        #expect(defaults.string(forKey: LyricsAIModelDownloadState.directoryKey) == "/custom-model")
    }

    @Test(arguments: [false, true])
    func removingDownloadedModelPreservesOtherSelections(usesCustomModel: Bool) async throws {
        let name = "starry-ai-download-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("starry-ai-model-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let state = LyricsAIModelDownloadState(defaults: defaults) { _, _ in folder }
        state.start()
        try await wait(state)
        if usesCustomModel { defaults.set("/custom-model", forKey: LyricsAIModelDownloadState.directoryKey) }

        state.removeInstalled()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(state.installedDirectory == nil)
        #expect(defaults.string(forKey: LyricsAIModelDownloadState.directoryKey) == (usesCustomModel ? "/custom-model" : nil))
        #expect(state.error == nil)
    }
}
