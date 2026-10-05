import Foundation
import StarryCore

public struct KeptAccount: Codable, Hashable, Sendable, Identifiable {
    public var userID: String
    public var nickname: String
    public var avatar: Artwork?
    public var isVIP: Bool
    /// The server it is on (`AccountProfile.detail`).
    public var detail: String?
    public var credentials: Data
    public var keptAt: Date

    public var id: String { userID }

    public init(userID: String, nickname: String, avatar: Artwork? = nil, isVIP: Bool = false, detail: String? = nil, credentials: Data, keptAt: Date = Date()) {
        self.userID = userID
        self.nickname = nickname
        self.avatar = avatar
        self.isVIP = isVIP
        self.detail = detail
        self.credentials = credentials
        self.keptAt = keptAt
    }
}

/// The kept accounts of every source, saved as `accounts.json` in the data directory (0600, as
/// the sources' own sessions are). The signed-in account of a source is never in here: the
/// source keeps its session itself.
public struct AccountVault: Sendable {
    static let fileName = "accounts"

    private let directory: DataDirectory?
    private var accounts: [String: [KeptAccount]]

    /// Reads what was saved; nil `directory` keeps nothing on disk (tests, a run that keeps no data).
    public init(directory: DataDirectory?) {
        self.directory = directory
        accounts = directory?.readCodable([String: [KeptAccount]].self, name: Self.fileName) ?? [:]
    }

    public func accounts(for source: SourceID) -> [KeptAccount] {
        accounts[source.key] ?? []
    }

    public func account(_ userID: String, for source: SourceID) -> KeptAccount? {
        accounts(for: source).first { $0.userID == userID }
    }

    /// Keeps `account`, replacing an older copy of the same user. Throws when it cannot be
    /// saved, leaving the vault as it was: the caller must not sign the account out then.
    public mutating func keep(_ account: KeptAccount, for source: SourceID) throws {
        var updated = accounts
        var list = accounts(for: source).filter { $0.userID != account.userID }
        list.insert(account, at: 0)
        updated[source.key] = list
        try save(updated)
        accounts = updated
    }

    public mutating func remove(_ userID: String, for source: SourceID) {
        guard account(userID, for: source) != nil else { return }
        let list = accounts(for: source).filter { $0.userID != userID }
        accounts[source.key] = list.isEmpty ? nil : list
        try? save(accounts)
    }

    private func save(_ accounts: [String: [KeptAccount]]) throws {
        guard let directory else { return }
        if accounts.isEmpty {
            directory.delete(Self.fileName)
        } else {
            try directory.writeCodable(accounts, name: Self.fileName)
        }
    }
}
