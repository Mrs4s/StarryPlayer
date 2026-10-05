import Foundation
import Testing

private enum TestCorpus {
    // Swift initializes this once, including when tests first request files concurrently.
    static let folder: Result<URL, Error> = Result {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../scripts/local-files/make-corpus.py").standardizedFileURL
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "starry-test-corpus-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, folder.path, "1"]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0,
                         "Corpus generation failed; install Python 3 and ffmpeg and make them available on PATH.")
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

func corpusFile(_ name: String) throws -> URL {
    let file = try TestCorpus.folder.get().appending(path: name)
    try #require(FileManager.default.fileExists(atPath: file.path), "Missing generated fixture: \(name)")
    return file
}
