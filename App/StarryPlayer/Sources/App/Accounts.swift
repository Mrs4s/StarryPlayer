import Foundation
import Library
import MusicSources
import Observation
import StarryCore

/// Manages one active account per source and saved accounts in `AccountVault`.
/// Always read the adapter's current state; delayed events must not restore stale state.
@MainActor
@Observable
final class AccountCenter {
    /// By source. A source missing here has no account, or has not reported yet.
    private(set) var states: [SourceID: AccountState] = [:]
    private(set) var users: [SourceID: String] = [:]
    /// The vault's accounts, mirrored so views follow it.
    private(set) var kept: [SourceID: [KeptAccount]] = [:]
    /// Sources adding or switching an account right now; their buttons wait, and another
    /// switch is not started.
    private(set) var switching: Set<SourceID> = []

    /// A source's state changed: (source, the user signed in before — kept through
    /// `.loggingIn` —, the new state), on the main actor.
    @ObservationIgnored var onChange: ((SourceID, String?, AccountState) -> Void)?

    @ObservationIgnored private var vault: AccountVault
    @ObservationIgnored private var watches: [SourceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var setAside: [SourceID: String] = [:]

    init(directory: DataDirectory?) {
        vault = AccountVault(directory: directory)
    }

    func state(of id: SourceID) -> AccountState { states[id] ?? .anonymous }

    func profile(of id: SourceID) -> AccountProfile? {
        if case .loggedIn(let profile) = state(of: id) { return profile }
        return nil
    }

    func isLoggedIn(_ id: SourceID) -> Bool { profile(of: id) != nil }

    func currentUser(of id: SourceID) -> String? { users[id] }

    func keptAccounts(of id: SourceID) -> [KeptAccount] { kept[id] ?? [] }

    func watch(_ source: any AccountSource) async throws {
        let id = source.id
        let adapter = source.account
        kept[id] = vault.accounts(for: id)
        await sync(source)
        watches[id]?.cancel()
        watches[id] = Task { [weak self] in
            for await _ in adapter.stateUpdates {
                let state = await adapter.state
                guard let self else { return }
                self.apply(state, for: id)
            }
        }
        try await adapter.refresh()
    }

    func unwatch(_ id: SourceID) {
        watches.removeValue(forKey: id)?.cancel()
        states[id] = nil
        users[id] = nil
        setAside[id] = nil
    }

    private func sync(_ source: any AccountSource) async {
        apply(await source.account.state, for: source.id)
    }

    private func apply(_ state: AccountState, for id: SourceID) {
        guard states[id] == nil || state != self.state(of: id) else { return }
        states[id] = state
        let previous = users[id]
        switch state {
        case .loggedIn(let profile):
            users[id] = profile.userID
            if profile.userID != previous, vault.account(profile.userID, for: id) != nil {
                vault.remove(profile.userID, for: id)
                kept[id] = vault.accounts(for: id)
            }
        case .anonymous, .expired:
            users[id] = nil
        case .loggingIn:
            break
        }
        onChange?(id, previous, state)
    }

    /// Keeps the signed-in account and signs it out here, so another account can sign in
    /// (adding an account). `endAdding` brings it back when no one signed in. False when the login dialog
    /// should not open (the source keeps one account, or is busy).
    func beginAdding(_ source: any AccountSource) async throws -> Bool {
        let id = source.id
        guard source.account.supportsMultipleAccounts, !switching.contains(id) else { return false }
        switching.insert(id)
        defer { switching.remove(id) }
        guard let kept = try await keep(source) else { return true }
        setAside[id] = kept.userID
        await source.account.signOutLocally()
        await sync(source)
        return true
    }

    /// The login dialog of `beginAdding` closed: the account set aside signs in again unless
    /// another one did. Asks the adapter, not `states`: the dialog closes as soon as the login
    /// succeeds, maybe before its state has come through.
    func endAdding(_ source: any AccountSource) async throws {
        guard let userID = setAside.removeValue(forKey: source.id) else { return }
        await sync(source)
        if case .loggedIn = await source.account.state { return }
        try await switchAccount(source, to: userID)
    }

    /// Signs `userID` in from the vault, keeping the account signed in until now; the new state
    /// is applied when this returns. When that fails (credentials no longer valid, no network),
    /// the account before comes back and the one asked for stays in the list, for the user to
    /// retry or remove.
    func switchAccount(_ source: any AccountSource, to userID: String) async throws {
        let id = source.id
        guard !switching.contains(id), let target = vault.account(userID, for: id) else { return }
        switching.insert(id)
        defer { switching.remove(id) }
        let previous = try await keep(source)
        do {
            try await source.account.restoreCredentials(target.credentials)
            await sync(source)
        } catch {
            if let previous { try? await source.account.restoreCredentials(previous.credentials) }
            await sync(source)
            throw AccountSwitchError.failed(target.nickname, ErrorText.describe(error))
        }
    }

    func forget(_ userID: String, of id: SourceID) {
        vault.remove(userID, for: id)
        kept[id] = vault.accounts(for: id)
    }

    /// Puts the signed-in account in the vault with fresh credentials; nil when no one is signed
    /// in. Throws — before anything signs the account out — when it cannot be kept: the source
    /// is still signing in, hands out no credentials, or the vault cannot be written.
    private func keep(_ source: any AccountSource) async throws -> KeptAccount? {
        await sync(source)
        switch await source.account.state {
        case .loggedIn(let profile):
            guard let credentials = await source.account.exportCredentials() else { throw AccountSwitchError.cannotKeep(profile.nickname) }
            let account = KeptAccount(userID: profile.userID, nickname: profile.nickname, avatar: profile.avatar, isVIP: profile.isVIP, detail: profile.detail, credentials: credentials)
            do {
                try vault.keep(account, for: source.id)
            } catch {
                throw AccountSwitchError.cannotKeep(profile.nickname)
            }
            kept[source.id] = vault.accounts(for: source.id)
            return account
        case .loggingIn:
            throw AccountSwitchError.busy
        case .anonymous, .expired:
            return nil
        }
    }
}

enum AccountSwitchError: LocalizedError {
    /// The kept account could not sign in: its name and why.
    case failed(String, String)
    /// The signed-in account could not be kept aside, so it was left signed in.
    case cannotKeep(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .failed(let name, let reason): "无法切换到「\(name)」：\(reason)"
        case .cannotKeep(let name): "无法保存「\(name)」的登录信息，没有切换账号"
        case .busy: "正在登录，请稍后再试"
        }
    }
}

struct LoginRequest: Identifiable, Hashable {
    var source: SourceID
    var adding = false

    var id: String { "\(source.key)|\(adding)" }
}
