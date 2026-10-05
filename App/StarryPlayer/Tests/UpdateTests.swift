import Foundation
import Testing
@testable import StarryPlayer

private actor RequestLog {
    private(set) var hosts: [String] = []
    func add(_ url: URL?) { hosts.append(url?.host() ?? "") }
}

private let githubRelease = Data(#"""
{
  "tag_name": "v1.1.0",
  "name": "Starry Player 1.1.0",
  "body": "安装包为 ad-hoc 签名。\r\n\r\n## What's Changed\r\n* feat: 检查更新 by @mrs4s in https://github.com/Mrs4s/StarryPlayer/pull/3\r\n\r\n**Full Changelog**: https://github.com/Mrs4s/StarryPlayer/compare/v1.0.0...v1.1.0",
  "html_url": "https://github.com/Mrs4s/StarryPlayer/releases/tag/v1.1.0",
  "assets": [
    {"name": "StarryPlayer-1.1.0-arm64.dmg", "browser_download_url": "https://github.com/Mrs4s/StarryPlayer/releases/download/v1.1.0/StarryPlayer-1.1.0-arm64.dmg"},
    {"name": "StarryPlayer-1.1.0-x86_64.dmg", "browser_download_url": "https://github.com/Mrs4s/StarryPlayer/releases/download/v1.1.0/StarryPlayer-1.1.0-x86_64.dmg"},
    {"name": "checksums.txt", "browser_download_url": "https://github.com/Mrs4s/StarryPlayer/releases/download/v1.1.0/checksums.txt"}
  ]
}
"""#.utf8)

private let projectFile = Data("""
targets:
  StarryPlayer:
    settings:
      base:
        MARKETING_VERSION: "1.2.0"
        CURRENT_PROJECT_VERSION: "5"
""".utf8)

private func version(_ text: String) -> AppVersion { AppVersion(text)! }

struct AppVersionTests {
    @Test func parsesTagsAndBundleVersions() {
        #expect(AppVersion("v1.2.3")?.parts == [1, 2, 3])
        #expect(AppVersion(" 1.2.3 ")?.parts == [1, 2, 3])
        #expect(AppVersion("1.2.3-beta.1")?.parts == [1, 2, 3])
        #expect(AppVersion("2")?.parts == [2])
        for bad in ["", "v", "beta", "1..2", "1.2."] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func comparesNumerically() {
        #expect(version("1.10.0") > version("1.9.9"))
        #expect(version("v1.0.1") > version("1.0.0"))
        #expect(version("2.0") > version("1.99.99"))
        #expect(version("1.2") == version("1.2.0"))
        #expect(!(version("1.2.0") < version("1.2")))
        #expect(version("1.2.0").description == "1.2.0")
    }
}

struct ReleaseFeedTests {
    @Test func readsGitHubsLatestRelease() throws {
        let release = try ReleaseFeed.release(fromGitHub: githubRelease)
        #expect(release.version == version("1.1.0"))
        #expect(release.page.absoluteString == "https://github.com/Mrs4s/StarryPlayer/releases/tag/v1.1.0")
        #expect(release.images.keys.sorted() == ["arm64", "x86_64"])
        #expect(release.images["x86_64"]?.lastPathComponent == "StarryPlayer-1.1.0-x86_64.dmg")
        #expect(release.notes?.contains("What's Changed") == true)
    }

    @Test func readsVersionsFromMirrors() {
        #expect(ReleaseFeed.version(from: Data(#"{"type":"gh","version":"1.3.0"}"#.utf8), format: .resolvedVersion) == version("1.3.0"))
        #expect(ReleaseFeed.version(from: Data(#"{"type":"gh","version":null}"#.utf8), format: .resolvedVersion) == nil)
        #expect(ReleaseFeed.version(from: projectFile, format: .projectFile) == version("1.2.0"))
        #expect(ReleaseFeed.version(from: Data("name: StarryPlayer".utf8), format: .projectFile) == nil)
    }

    @Test func prefersGitHub() async throws {
        let log = RequestLog()
        let feed = ReleaseFeed { request in
            await log.add(request.url)
            return githubRelease
        }
        let release = try await feed.latest()
        #expect(release.version == version("1.1.0"))
        #expect(release.notes != nil)
        #expect(await log.hosts == ["api.github.com"])
    }

    /// GitHub blocked or rate limited: the version comes from whichever mirror answers, and the
    /// downloads point where the release workflow publishes them.
    @Test func fallsBackToMirrorsWhenGitHubFails() async throws {
        let feed = ReleaseFeed { request in
            guard request.url?.host() == "fastly.jsdelivr.net" else { throw URLError(.timedOut) }
            return projectFile
        }
        let release = try await feed.latest()
        #expect(release.version == version("1.2.0"))
        #expect(release.notes == nil)
        #expect(release.page.absoluteString == "https://github.com/Mrs4s/StarryPlayer/releases/tag/v1.2.0")
        #expect(release.images["arm64"]?.absoluteString == "https://github.com/Mrs4s/StarryPlayer/releases/download/v1.2.0/StarryPlayer-1.2.0-arm64.dmg")
        #expect(release.images["x86_64"]?.lastPathComponent == "StarryPlayer-1.2.0-x86_64.dmg")
    }

    @Test func asksEveryMirror() async throws {
        let log = RequestLog()
        let feed = ReleaseFeed { request in
            await log.add(request.url)
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: URLError.self) { try await feed.latest() }
        let hosts = await log.hosts
        #expect(hosts.first == "api.github.com")
        #expect(Set(hosts.dropFirst()) == Set(ReleaseFeed.mirrors.compactMap { $0.url.host() }))
        #expect(hosts.contains("data.jsdelivr.com"))
    }
}

@MainActor
struct UpdateCenterTests {
    private let defaults = UserDefaults(suiteName: "UpdateCenterTests.\(UUID().uuidString)")!

    private func center(current: String, answer: Result<Data, URLError>) -> UpdateCenter {
        UpdateCenter(current: AppVersion(current), feed: ReleaseFeed { _ in try answer.get() }, defaults: defaults)
    }

    @Test func findsANewerRelease() async throws {
        let updates = center(current: "1.0.0", answer: .success(githubRelease))
        #expect(updates.isDue())
        guard case .available(let release) = await updates.check() else { Issue.record("no update found"); return }
        #expect(release.version == version("1.1.0"))
        #expect(updates.lastChecked != nil)
        #expect(!updates.isDue())
        // Remembered across launches.
        #expect(center(current: "1.0.0", answer: .success(githubRelease)).lastChecked == updates.lastChecked)
    }

    @Test func sameOrOlderIsUpToDate() async {
        #expect(await center(current: "1.1.0", answer: .success(githubRelease)).check() == .upToDate)
        #expect(await center(current: "1.2.0", answer: .success(githubRelease)).check() == .upToDate)
    }

    @Test func failureLeavesTheCheckDue() async {
        let updates = center(current: "1.0.0", answer: .failure(URLError(.notConnectedToInternet)))
        #expect(await updates.check() == .failed)
        #expect(updates.lastChecked == nil)
        #expect(updates.isDue())
    }

    @Test func dueOnceADay() async throws {
        let updates = center(current: "1.0.0", answer: .success(githubRelease))
        await updates.check()
        let checked = try #require(updates.lastChecked)
        #expect(!updates.isDue(at: checked.addingTimeInterval(23 * 3600)))
        #expect(updates.isDue(at: checked.addingTimeInterval(UpdateCenter.checkInterval)))
        #expect(updates.isDue(at: checked.addingTimeInterval(-60)))
    }

    @Test func skipsOneVersion() throws {
        let updates = center(current: "1.0.0", answer: .success(githubRelease))
        let release = try ReleaseFeed.release(fromGitHub: githubRelease)
        #expect(!updates.isSkipped(release))
        updates.skip(release)
        #expect(updates.isSkipped(release))
        #expect(!updates.isSkipped(AppRelease(version: version("1.1.1"))))
    }
}

struct ReleaseNotesTests {
    @Test func splitsGitHubNotesIntoBlocks() {
        let notes = "<!-- Release notes generated using configuration in .github/release.yml -->\r\n安装说明\r\n\r\n## What's Changed\r\n* one by @a\r\n- two\r\n---\r\n**Full Changelog**: https://example.com"
        #expect(ReleaseNotes.blocks(notes) == [
            .paragraph("安装说明"),
            .heading("What's Changed"),
            .bullet("one by @a"),
            .bullet("two"),
            .paragraph("**Full Changelog**: https://example.com"),
        ])
    }

    @Test func linksBareURLs() {
        let text = ReleaseNotes.inline("**Full Changelog**: https://github.com/Mrs4s/StarryPlayer/compare/v1.0.0...v1.1.0")
        #expect(String(text.characters) == "Full Changelog: https://github.com/Mrs4s/StarryPlayer/compare/v1.0.0...v1.1.0")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://github.com/Mrs4s/StarryPlayer/compare/v1.0.0...v1.1.0")!])
    }
}
