import Foundation
import Library
import MusicSources
import StarryCore
import Testing
@testable import StarryPlayer

private actor FakeAccountAdapter: AccountAdapter {
    nonisolated let supportedMethods: [LoginMethod] = [.cookie]
    nonisolated let supportsMultipleAccounts = true
    private var current: AccountState = .anonymous
    private var continuations: [UUID: AsyncStream<AccountState>.Continuation] = [:]
    var revoked: Set<String> = []

    var state: AccountState { current }

    nonisolated var stateUpdates: AsyncStream<AccountState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id, continuation) }
        }
    }

    private func register(_ id: UUID, _ continuation: AsyncStream<AccountState>.Continuation) {
        continuations[id] = continuation
        continuation.yield(current)
    }

    private func set(_ state: AccountState) {
        current = state
        for continuation in continuations.values { continuation.yield(state) }
    }

    func revoke(_ user: String) { revoked.insert(user) }

    func refresh() async throws {}

    func loginWithCookie(_ cookie: String) async throws {
        set(.loggedIn(AccountProfile(userID: cookie, nickname: "user-\(cookie)")))
    }

    func logout() async throws { set(.anonymous) }

    func exportCredentials() async -> Data? {
        guard case .loggedIn(let profile) = current else { return nil }
        return Data(profile.userID.utf8)
    }

    func restoreCredentials(_ credentials: Data) async throws {
        let user = String(decoding: credentials, as: UTF8.self)
        set(.anonymous)
        guard !revoked.contains(user) else { throw SourceError.invalidResponse("expired") }
        set(.loggedIn(AccountProfile(userID: user, nickname: "user-\(user)")))
    }

    func signOutLocally() async { set(.anonymous) }
}

private final class FakeAccountSource: AccountSource, @unchecked Sendable {
    let id: SourceID = .example
    let displayName = "fake"
    let adapter = FakeAccountAdapter()
    var account: AccountAdapter { adapter }

    func resolvePlayableAsset(_ track: Track, tier: QualityTier) async throws -> PlayableAsset {
        throw PlaybackError.sourceUnreachable
    }
}

@MainActor
struct AccountCenterTests {
    private let source = FakeAccountSource()
    private let center = AccountCenter(directory: nil)

    private func signedIn() -> String? { center.profile(of: source.id)?.userID }

    private func waitFor(_ user: String?) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while signedIn() != user {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func login(_ user: String) async throws {
        try await source.adapter.loginWithCookie(user)
        try await waitFor(user)
    }

    @Test func addAndSwitch() async throws {
        try await center.watch(source)
        try await login("a")
        #expect(try await center.beginAdding(source))
        try await waitFor(nil)
        try await login("b")
        try await center.endAdding(source)
        #expect(signedIn() == "b")
        #expect(center.keptAccounts(of: source.id).map(\.userID) == ["a"])

        try await center.switchAccount(source, to: "a")
        try await waitFor("a")
        #expect(center.keptAccounts(of: source.id).map(\.userID) == ["b"])
    }

    @Test func closingRightAfterTheLoginKeepsTheNewAccount() async throws {
        try await center.watch(source)
        try await login("a")
        #expect(try await center.beginAdding(source))
        try await source.adapter.loginWithCookie("b")
        try await center.endAdding(source)
        try await waitFor("b")
        #expect(center.keptAccounts(of: source.id).map(\.userID) == ["a"])
    }

    @Test func abandonedAddingRestores() async throws {
        try await center.watch(source)
        try await login("a")
        #expect(try await center.beginAdding(source))
        try await waitFor(nil)
        try await center.endAdding(source)
        try await waitFor("a")
        #expect(center.keptAccounts(of: source.id).isEmpty)
    }

    @Test func failedSwitchKeepsTheCurrentAccount() async throws {
        try await center.watch(source)
        try await login("a")
        #expect(try await center.beginAdding(source))
        try await login("b")
        try await center.endAdding(source)
        await source.adapter.revoke("a")

        await #expect(throws: AccountSwitchError.self) { try await center.switchAccount(source, to: "a") }
        try await waitFor("b")
        #expect(center.keptAccounts(of: source.id).map(\.userID) == ["a"])
    }
}
