import CryptoKit
import Foundation

public struct LyricsAIModelRelease: Codable, Sendable {
    public let id: String
    public let name: String
    public let archiveURL: URL
    public let archiveBytes: Int64
    public let sha256: String
    public let folderName: String
    public let minimumFreeBytes: Int64

    public init(id: String, name: String, archiveURL: URL, archiveBytes: Int64,
                sha256: String, folderName: String, minimumFreeBytes: Int64) {
        self.id = id
        self.name = name
        self.archiveURL = archiveURL
        self.archiveBytes = archiveBytes
        self.sha256 = sha256
        self.folderName = folderName
        self.minimumFreeBytes = minimumFreeBytes
    }
}

public struct LyricsAIModelDownloadProgress: Sendable {
    public enum Stage: Sendable { case downloading, verifying, unpacking, installing }
    public let stage: Stage
    public let receivedBytes: Int64
    public let totalBytes: Int64

    public init(_ stage: Stage, receivedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.stage = stage
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

public enum LyricsAIModelInstallError: Error, LocalizedError {
    case invalidRelease, busy, unavailable, http(Int), checksum, archive, incomplete, space

    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "模型下载配置无效，请更新 App 后重试。"
        case .busy: "模型正在下载，请等待当前任务完成。"
        case .unavailable: "推荐模型暂时无法下载，请稍后重试，或选择本地模型文件夹。"
        case .http(let status): "模型下载失败（HTTP \(status)），请稍后重试。"
        case .checksum: "模型文件校验失败，请重新下载。"
        case .archive: "模型包解压失败，请重新下载。"
        case .incomplete: "模型文件不完整，请重新下载。"
        case .space: "磁盘可用空间不足，请至少腾出 2 GB 后重试。"
        }
    }
}

public actor LyricsAIModelInstaller {
    public typealias Progress = @Sendable (LyricsAIModelDownloadProgress) -> Void
    typealias Download = @Sendable (LyricsAIModelRelease, @escaping Progress) async throws -> URL

    private let root: URL
    private let download: Download
    private var busy = false
    private static let receiptName = "starry-installation.json"

    public init(directory: URL) {
        root = directory.standardizedFileURL.resolvingSymlinksInPath()
        download = Self.fetch
    }

    init(directory: URL, download: @escaping Download) {
        root = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.download = download
    }

    public func installedModel(for release: LyricsAIModelRelease) -> URL? {
        guard (try? Self.validate(release)) != nil else { return nil }
        let directory = root.appendingPathComponent(release.id, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.receiptName)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.id == release.id, receipt.sha256 == release.sha256,
              let current = try? Self.inventory(directory), current == receipt.files,
              (try? LyricsAIModelBundle.load(from: directory)) != nil else { return nil }
        return directory
    }

    public func install(_ release: LyricsAIModelRelease, progress: @escaping Progress = { _ in }) async throws -> URL {
        guard !busy else { throw LyricsAIModelInstallError.busy }
        busy = true
        defer { busy = false }
        try Self.validate(release)
        try Task.checkCancellation()
        if let installed = installedModel(for: release) { return installed }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let space = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           space < release.minimumFreeBytes { throw LyricsAIModelInstallError.space }
        let staging = root.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }

        progress(.init(.downloading, totalBytes: release.archiveBytes))
        let downloaded = try await download(release, progress)
        defer { try? manager.removeItem(at: downloaded) }
        try Task.checkCancellation()
        let archive = staging.appendingPathComponent("model.zip")
        try manager.moveItem(at: downloaded, to: archive)
        progress(.init(.verifying))
        guard let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == release.archiveBytes,
              try Self.digest(archive) == release.sha256 else { throw LyricsAIModelInstallError.checksum }

        progress(.init(.unpacking))
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
        try manager.createDirectory(at: expanded, withIntermediateDirectories: false)
        let extraction = Extraction(archive: archive, destination: expanded)
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try extraction.run() }.value
        } onCancel: { extraction.cancel() }
        try Task.checkCancellation()
        let candidate = expanded.appendingPathComponent(release.folderName, isDirectory: true)
        _ = try LyricsAIModelBundle.load(from: candidate)
        let files = try Self.inventory(candidate)
        let receipt = Receipt(id: release.id, sha256: release.sha256, files: files)
        try JSONEncoder().encode(receipt).write(to: candidate.appendingPathComponent(Self.receiptName), options: .atomic)
        try Task.checkCancellation()
        progress(.init(.installing))

        let destination = root.appendingPathComponent(release.id, isDirectory: true)
        let backup = staging.appendingPathComponent("previous", isDirectory: true)
        let replacing = manager.fileExists(atPath: destination.path)
        if replacing { try manager.moveItem(at: destination, to: backup) }
        do { try manager.moveItem(at: candidate, to: destination) }
        catch {
            if replacing { try manager.moveItem(at: backup, to: destination) }
            throw error
        }
        return destination
    }

    private struct Receipt: Codable {
        var id: String
        var sha256: String
        var files: [String: Int64]
    }

    private static func validate(_ release: LyricsAIModelRelease) throws {
        func component(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix(".") && !value.contains("/") && !value.contains("\\")
        }
        guard component(release.id), component(release.folderName), release.archiveBytes > 0,
              release.minimumFreeBytes >= 0, release.sha256.count == 64,
              release.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              ["https", "http"].contains(release.archiveURL.scheme?.lowercased() ?? "") else {
            throw LyricsAIModelInstallError.invalidRelease
        }
    }

    private static func inventory(_ directory: URL) throws -> [String: Int64] {
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw LyricsAIModelInstallError.incomplete
        }
        // Enumerate relative paths: URL enumeration can change /var to /private/var.
        guard let entries = FileManager.default.enumerator(atPath: directory.path) else {
            throw LyricsAIModelInstallError.incomplete
        }
        var files: [String: Int64] = [:]
        for case let relative as String in entries {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw LyricsAIModelInstallError.incomplete }
            if relative == receiptName { continue }
            if values.isRegularFile == true {
                files[relative] = Int64(values.fileSize ?? -1)
            }
        }
        guard !files.isEmpty else { throw LyricsAIModelInstallError.incomplete }
        return files
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fetch(_ release: LyricsAIModelRelease, progress: @escaping Progress) async throws -> URL {
        let transfer = Transfer(release: release, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: { transfer.cancel() }
    }

    private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let release: LyricsAIModelRelease
        let progress: Progress
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, any Error>?
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        private var lastUpdate: TimeInterval = 0

        init(release: LyricsAIModelRelease, progress: @escaping Progress) { self.release = release; self.progress = progress }

        func start(_ continuation: CheckedContinuation<URL, any Error>) {
            lock.withLock {
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: release.archiveURL)
                request.setValue("StarryPlayer-LyricsAI", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        }

        func cancel() {
            lock.withLock { cancelled = true; task?.cancel() }
        }

        private func finish(_ result: Result<URL, any Error>) {
            let pending = lock.withLock { () -> (CheckedContinuation<URL, any Error>?, URLSession?, Bool) in
                let value = (continuation, session, cancelled)
                continuation = nil; session = nil; task = nil
                return value
            }
            pending.1?.invalidateAndCancel()
            guard let continuation = pending.0 else {
                if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
                return
            }
            if pending.2 {
                if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
                continuation.resume(throwing: CancellationError())
            } else { continuation.resume(with: result) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                finish(.failure(status == 404 ? LyricsAIModelInstallError.unavailable : LyricsAIModelInstallError.http(status)))
                return
            }
            // URLSession deletes its file after this delegate method returns.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("starry-ai-download-\(UUID()).zip")
            do {
                try FileManager.default.moveItem(at: location, to: file)
                finish(.success(file))
            } catch { finish(.failure(error)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error { finish(.failure(error)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesWritten <= release.archiveBytes else { finish(.failure(LyricsAIModelInstallError.checksum)); return }
            let now = ProcessInfo.processInfo.systemUptime
            let emit = lock.withLock {
                guard continuation != nil, !cancelled, now - lastUpdate >= 0.1 || totalBytesWritten == release.archiveBytes else { return false }
                lastUpdate = now
                return true
            }
            if emit { progress(.init(.downloading, receivedBytes: totalBytesWritten, totalBytes: release.archiveBytes)) }
        }
    }

    private final class Extraction: @unchecked Sendable {
        private let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        init(archive: URL, destination: URL) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        func run() throws {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try process.run()
            }
            process.waitUntilExit()
            if lock.withLock({ cancelled }) { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw LyricsAIModelInstallError.archive }
        }
        func cancel() {
            lock.withLock {
                cancelled = true
                if process.isRunning { process.terminate() }
            }
        }
    }
}
