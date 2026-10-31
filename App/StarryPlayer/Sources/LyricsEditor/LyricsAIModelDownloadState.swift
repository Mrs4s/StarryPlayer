import Foundation
import LyricsSync
import Observation
import StarryCore

@MainActor @Observable
final class LyricsAIModelDownloadState {
    typealias Install = @Sendable (LyricsAIModelRelease, @escaping LyricsAIModelInstaller.Progress) async throws -> URL
    static let directoryKey = "starry.lyricsEditor.aiTiming.modelDirectory"
    static let recommended: LyricsAIModelRelease = {
        guard let url = Bundle.main.url(forResource: "LyricsAIModel", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let release = try? JSONDecoder().decode(LyricsAIModelRelease.self, from: data) else {
            preconditionFailure("Missing bundled LyricsAIModel.json release descriptor")
        }
        return release
    }()
    static let shared = LyricsAIModelDownloadState()

    let release: LyricsAIModelRelease
    private(set) var installedDirectory: URL?
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var isCancelling = false
    private(set) var progress = LyricsAIModelDownloadProgress(.downloading)
    private(set) var error: String?
    private(set) var notice: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request = UUID()
    private let installer: LyricsAIModelInstaller
    private let install: Install
    private let defaults: UserDefaults

    init(release: LyricsAIModelRelease = recommended, installer: LyricsAIModelInstaller? = nil,
         defaults: UserDefaults = .standard, install: Install? = nil) {
        self.release = release
        let installer = installer ?? LyricsAIModelInstaller(directory: DataDirectory.defaultURL.appendingPathComponent("Models/LyricsAI", isDirectory: true))
        self.installer = installer
        self.install = install ?? { release, progress in try await installer.install(release, progress: progress) }
        self.defaults = defaults
    }

    var progressText: String {
        if isCancelling { return "正在停止下载…" }
        switch progress.stage {
        case .downloading:
            if progress.receivedBytes == 0 { return "正在连接模型下载服务器…" }
            return "正在下载 \(bytes(progress.receivedBytes)) / \(bytes(release.archiveBytes))"
        case .verifying: return "正在校验模型文件…"
        case .unpacking: return "正在解压模型…"
        case .installing: return "正在安装模型…"
        }
    }

    var fraction: Double { min(1, max(0, Double(progress.receivedBytes) / Double(release.archiveBytes))) }
    var downloadSize: String { bytes(release.archiveBytes) }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal) }

    func discover() async {
        guard !isChecking, !isDownloading else { return }
        let id = request
        isChecking = true
        let found = await installer.installedModel(for: release)
        isChecking = false
        guard !isDownloading, request == id else { return }
        installedDirectory = found
        if let found, (defaults.string(forKey: Self.directoryKey) ?? "").isEmpty {
            defaults.set(found.path, forKey: Self.directoryKey)
        }
    }

    func useInstalled() {
        guard let installedDirectory else { return }
        defaults.set(installedDirectory.path, forKey: Self.directoryKey)
        error = nil; notice = nil
    }

    func removeInstalled() {
        guard let installedDirectory, !isDownloading else { return }
        request = UUID()
        do { try FileManager.default.removeItem(at: installedDirectory) }
        catch { self.error = error.localizedDescription; return }
        self.installedDirectory = nil
        if defaults.string(forKey: Self.directoryKey) == installedDirectory.path {
            defaults.removeObject(forKey: Self.directoryKey)
        }
        error = nil; notice = "已删除下载的模型"
    }

    func start() {
        guard !isDownloading else { return }
        let previousPath = defaults.string(forKey: Self.directoryKey) ?? ""
        request = UUID()
        let id = request
        let install = install, release = release
        isDownloading = true; isCancelling = false
        error = nil; notice = nil
        progress = .init(.downloading, totalBytes: release.archiveBytes)
        task = Task { [weak self] in
            do {
                let directory = try await install(release) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.request == id, self.isDownloading, !self.isCancelling else { return }
                        self.progress = progress
                    }
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.installedDirectory = directory
                // A model chosen in another window while downloading takes precedence.
                if (self.defaults.string(forKey: Self.directoryKey) ?? "") == previousPath {
                    self.defaults.set(directory.path, forKey: Self.directoryKey)
                }
                self.notice = "推荐模型已安装"
                self.finish()
            } catch {
                guard let self else { return }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.notice = "已停止下载"
                } else { self.error = error.localizedDescription }
                self.finish()
            }
        }
    }

    func cancel() {
        guard isDownloading else { return }
        isCancelling = true
        task?.cancel()
    }

    private func finish() {
        isDownloading = false; isCancelling = false; task = nil
    }
}
