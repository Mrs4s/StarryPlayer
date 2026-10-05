import Foundation
import Observation
import os

/// A release version as tagged: "1.2.3" or "v1.2.3". Missing parts count as zero (1.2 is 1.2.0);
/// anything after the numbers ("-beta", "+5") is not compared.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let numbers = text.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    /// This build's version.
    static let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")

    var description: String { parts.map(String.init).joined(separator: ".") }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        (0..<max(a.parts.count, b.parts.count)).allSatisfy { a.part($0) == b.part($0) }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) where a.part(index) != b.part(index) {
            return a.part(index) < b.part(index)
        }
        return false
    }
}

/// A published release. From GitHub's API it has everything; from a mirror (GitHub out of reach)
/// only the version, and its page and disk images are where the release workflow puts them.
struct AppRelease: Equatable, Sendable {
    var version: AppVersion
    /// The release notes in Markdown; nil when a mirror gave only the version.
    var notes: String?
    var page: URL
    /// Disk images by architecture ("arm64", "x86_64").
    var images: [String: URL]

    /// Only the version known: the page and images named as `scripts/package.sh` and
    /// `.github/workflows/release.yml` publish them.
    init(version: AppVersion) {
        let tag = "v\(version)"
        let releases = "https://github.com/\(ReleaseFeed.repository)/releases"
        self.version = version
        notes = nil
        page = URL(string: "\(releases)/tag/\(tag)")!
        images = Dictionary(uniqueKeysWithValues: Self.architectures.map { ($0, URL(string: "\(releases)/download/\(tag)/StarryPlayer-\(version)-\($0).dmg")!) })
    }

    init(version: AppVersion, notes: String?, page: URL, images: [String: URL]) {
        self.version = version
        self.notes = notes
        self.page = page
        self.images = images
    }

    static let architectures = ["arm64", "x86_64"]

    /// The architecture of this Mac rather than of this build: an Intel build running under
    /// Rosetta is offered the Apple silicon image.
    static let machineArchitecture: String = {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1 ? "arm64" : "x86_64"
    }()

    /// The disk image for this Mac, or the release page when there is none.
    var download: URL { images[Self.machineArchitecture] ?? page }
}

/// Where releases are looked up: GitHub's API, and when that cannot be reached (blocked in
/// mainland China, rate limited) the latest tag through jsDelivr's mirrors.
struct ReleaseFeed: Sendable {
    /// A URL's body; throws for a failed request or a status other than 2xx.
    typealias Load = @Sendable (URLRequest) async throws -> Data

    static let repository = "Mrs4s/StarryPlayer"

    var load: Load

    static let live = ReleaseFeed { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    struct Mirror: Sendable {
        enum Format: Sendable {
            /// jsDelivr's data API: `{"version": "1.2.3"}`.
            case resolvedVersion
            /// `project.yml` at the latest tag, read for `MARKETING_VERSION` (as the release
            /// workflow checks the tag against it).
            case projectFile
        }

        var url: URL
        var format: Format
    }

    /// Asked all at once when GitHub fails; the first to answer is taken. jsDelivr's main CDN
    /// (`cdn.jsdelivr.net`) is often blocked in China, its other hosts less so.
    static let mirrors = [
        Mirror(url: URL(string: "https://data.jsdelivr.com/v1/packages/gh/\(repository)/resolved?specifier=latest")!, format: .resolvedVersion),
    ] + ["fastly", "gcore", "testingcf"].map {
        Mirror(url: URL(string: "https://\($0).jsdelivr.net/gh/\(repository)@latest/project.yml")!, format: .projectFile)
    }

    private static let log = Logger(subsystem: "moe.mrs4s.starry-player", category: "updates")

    func latest() async throws -> AppRelease {
        do {
            return try await fromGitHub()
        } catch {
            try Task.checkCancellation()
            Self.log.notice("GitHub releases unreachable (\(error.localizedDescription, privacy: .public)); trying mirrors")
            if let version = await fromMirrors() { return AppRelease(version: version) }
            throw error
        }
    }

    private func fromGitHub() async throws -> AppRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try Self.release(fromGitHub: await load(request))
    }

    private func fromMirrors() async -> AppVersion? {
        await withTaskGroup(of: AppVersion?.self) { group in
            for mirror in Self.mirrors {
                group.addTask {
                    let request = URLRequest(url: mirror.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                    return (try? await load(request)).flatMap { Self.version(from: $0, format: mirror.format) }
                }
            }
            for await version in group {
                if let version {
                    group.cancelAll()
                    return version
                }
            }
            return nil
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadUrl: URL
        }

        var tagName: String
        var body: String?
        var htmlUrl: URL
        var assets: [Asset]
    }

    static func release(fromGitHub data: Data) throws -> AppRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard let version = AppVersion(release.tagName) else { throw URLError(.cannotParseResponse) }
        var images: [String: URL] = [:]
        for asset in release.assets {
            if let architecture = AppRelease.architectures.first(where: { asset.name.hasSuffix("-\($0).dmg") }) {
                images[architecture] = asset.browserDownloadUrl
            }
        }
        return AppRelease(version: version, notes: release.body, page: release.htmlUrl, images: images)
    }

    static func version(from data: Data, format: Mirror.Format) -> AppVersion? {
        switch format {
        case .resolvedVersion:
            struct Resolved: Decodable { var version: String? }
            return (try? JSONDecoder().decode(Resolved.self, from: data))?.version.flatMap(AppVersion.init)
        case .projectFile:
            let text = String(decoding: data, as: UTF8.self)
            return text.firstMatch(of: #/MARKETING_VERSION:\s*"?([0-9][0-9.]*)/#).flatMap { AppVersion(String($0.1)) }
        }
    }
}

/// Looks for a newer release: when asked (the app menu, Settings), and on its own once a day
/// while the setting is on.
@MainActor
@Observable
final class UpdateCenter {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case failed
    }

    private(set) var status: Status = .idle
    private(set) var lastChecked: Date?
    let current: AppVersion?

    @ObservationIgnored private let feed: ReleaseFeed
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?

    static let checkInterval: TimeInterval = 24 * 3600
    private static let lastCheckedKey = "starry.updates.lastChecked"
    private static let skippedKey = "starry.updates.skipped"

    init(current: AppVersion? = .current, feed: ReleaseFeed = .live, defaults: UserDefaults = .standard) {
        self.current = current
        self.feed = feed
        self.defaults = defaults
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    /// Looks now, or waits for the look already under way.
    @discardableResult
    func check() async -> Status {
        if let running {
            await running.value
            return status
        }
        let task = Task { await look() }
        running = task
        await task.value
        running = nil
        return status
    }

    private func look() async {
        status = .checking
        do {
            let release = try await feed.latest()
            let now = Date()
            lastChecked = now
            defaults.set(now, forKey: Self.lastCheckedKey)
            if let current, release.version > current {
                status = .available(release)
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed
        }
    }

    /// An automatic check is due: none has succeeded in the last day (or the clock went back).
    func isDue(at now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        return elapsed >= Self.checkInterval || elapsed < 0
    }

    /// Not offered again by automatic checks; a check asked for still shows it.
    func skip(_ release: AppRelease) {
        defaults.set(release.version.description, forKey: Self.skippedKey)
    }

    func isSkipped(_ release: AppRelease) -> Bool {
        defaults.string(forKey: Self.skippedKey).flatMap(AppVersion.init) == release.version
    }

    /// Checks shortly after launch and then every hour whenever one is due and `isEnabled` (read
    /// each time, so the setting applies at once) says so; a newer release, unless skipped, goes
    /// to `found`.
    func startAutomaticChecks(isEnabled: @escaping @MainActor () -> Bool, found: @escaping @MainActor (AppRelease) -> Void) {
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled, let self {
                if isEnabled(), self.isDue(), case .available(let release) = await self.check(), !self.isSkipped(release) {
                    found(release)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

extension AppModel {
    /// A check asked for from the app menu: the release when there is one, else a toast.
    func checkForUpdates() {
        Task {
            switch await updates.check() {
            case .available(let release): presentUpdate(release)
            case .upToDate: showToast("已是最新版本（\(updates.current?.description ?? "")）")
            case .failed: showToast("检查更新失败，请检查网络后重试")
            case .idle, .checking: break
            }
        }
    }

    func presentUpdate(_ release: AppRelease) {
        updateWindow.show(title: "软件更新", model: self) {
            UpdateView(release: release)
        }
    }

    func closeUpdate() {
        updateWindow.close()
    }
}
