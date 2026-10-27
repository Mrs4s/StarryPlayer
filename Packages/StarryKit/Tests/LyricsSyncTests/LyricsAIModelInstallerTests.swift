import CryptoKit
import Foundation
import Testing
@testable import LyricsSync

@Suite struct LyricsAIModelInstallerTests {
    private actor Downloads {
        var count = 0
        func copy(_ archive: URL) throws -> URL {
            count += 1
            let file = archive.deletingLastPathComponent().appendingPathComponent("download-\(UUID()).zip")
            try FileManager.default.copyItem(at: archive, to: file)
            return file
        }
    }
    private actor Gate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    @Test func verifiedModelIsInstalledOnceAndMissingFilesTriggerARepair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let downloads = Downloads()
        let installer = LyricsAIModelInstaller(directory: fixture.installations) { _, _ in try await downloads.copy(fixture.archive) }
        let first = try await installer.install(fixture.release)
        #expect(first.lastPathComponent == fixture.release.id)
        #expect(await installer.installedModel(for: fixture.release) == first)
        #expect(try await installer.install(fixture.release) == first)
        #expect(await downloads.count == 1)
        let weights = first.appendingPathComponent("fixture.mlpackage/weight.bin")
        try FileManager.default.removeItem(at: weights)
        #expect(await installer.installedModel(for: fixture.release) == nil)
        #expect(try await installer.install(fixture.release) == first)
        #expect(await downloads.count == 2)
        #expect(FileManager.default.fileExists(atPath: weights.path))
        #expect(try fixture.stagingFolders().isEmpty)
    }

    @Test func checksumFailureCannotReplaceAnExistingVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let downloads = Downloads()
        let installer = LyricsAIModelInstaller(directory: fixture.installations) { _, _ in try await downloads.copy(fixture.archive) }
        let existing = try await installer.install(fixture.release)
        let sentinel = existing.appendingPathComponent("keep.txt")
        try Data("preserve existing files".utf8).write(to: sentinel)
        let corrupted = fixture.releaseWith(sha256: String(repeating: "0", count: 64))
        await #expect(throws: LyricsAIModelInstallError.self) { try await installer.install(corrupted) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve existing files")
        #expect(try fixture.stagingFolders().isEmpty)
    }

    @Test func cancelledDownloadCannotPublishOrLeavePartialFilesEvenIfTheTransportFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate(), downloads = Downloads()
        let installer = LyricsAIModelInstaller(directory: fixture.installations) { _, _ in
            await gate.wait()
            return try await downloads.copy(fixture.archive)
        }
        let task = Task { try await installer.install(fixture.release) }
        for _ in 0..<200 {
            if await gate.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await gate.waiting)
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await installer.installedModel(for: fixture.release) == nil)
        #expect(try fixture.stagingFolders().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix("download-") })
    }

    @Test func incompleteArchiveAndUnsafeDestinationAreRejected() async throws {
        let fixture = try Fixture(includeRuntime: false)
        defer { fixture.remove() }
        let downloads = Downloads()
        let installer = LyricsAIModelInstaller(directory: fixture.installations) { _, _ in try await downloads.copy(fixture.archive) }
        await #expect(throws: LyricsAIError.self) { try await installer.install(fixture.release) }
        #expect(await installer.installedModel(for: fixture.release) == nil)
        let unsafe = fixture.releaseWith(id: "../outside")
        await #expect(throws: LyricsAIModelInstallError.self) { try await installer.install(unsafe) }
        #expect(await downloads.count == 1)
        #expect(try fixture.stagingFolders().isEmpty)
    }

    private struct Fixture: Sendable {
        let root: URL
        let archive: URL
        let installations: URL
        let release: LyricsAIModelRelease

        init(includeRuntime: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("starry-model-install-test-\(UUID())", isDirectory: true)
            archive = root.appendingPathComponent("fixture.zip")
            installations = root.appendingPathComponent("installed", isDirectory: true)
            let bundle = root.appendingPathComponent("Model", isDirectory: true)
            let metadata = bundle.appendingPathComponent("metadata", isDirectory: true)
            let model = bundle.appendingPathComponent("fixture.mlpackage", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: model.appendingPathComponent("weight.bin"))
            if includeRuntime {
                try Data(#"{"model":"fixture.mlpackage","inputs":{"mel":{"shape":[1,128,3000]},"valid_frames":{"shape":[1]}},"outputs":{"logits":{"shape":[1,1500,122],"blank_id":121},"sustain_logits":{"shape":[1,1500,8]}},"preprocessing":{"sample_rate":16000}}"#.utf8)
                    .write(to: metadata.appendingPathComponent("runtime.json"))
            }
            var vocabulary = Dictionary(uniqueKeysWithValues: (0..<121).map { ("token\($0)", $0) })
            vocabulary["[PAD]"] = 121
            try JSONEncoder().encode(vocabulary).write(to: metadata.appendingPathComponent("vocab.json"))
            for (name, count) in [("mel-filters.f32", 201 * 128), ("hann-400.f32", 400)] {
                try [Float](repeating: 1, count: count).withUnsafeBytes { Data($0) }.write(to: metadata.appendingPathComponent(name))
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", bundle.path, archive.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LyricsAIModelInstallError.archive }
            let data = try Data(contentsOf: archive)
            release = LyricsAIModelRelease(id: "fixture-v1", name: "Fixture", archiveURL: URL(string: "https://example.invalid/model.zip")!,
                archiveBytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                folderName: "Model", minimumFreeBytes: 0)
        }

        func releaseWith(id: String? = nil, sha256: String? = nil) -> LyricsAIModelRelease {
            .init(id: id ?? release.id, name: release.name, archiveURL: release.archiveURL, archiveBytes: release.archiveBytes,
                  sha256: sha256 ?? release.sha256, folderName: release.folderName, minimumFreeBytes: 0)
        }
        func stagingFolders() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: installations.path).filter { $0.hasPrefix(".install-") }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
