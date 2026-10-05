import Foundation
import StarryCore
import Testing
@testable import Library

struct AccountVaultTests {
    private func directory() -> DataDirectory {
        DataDirectory(url: FileManager.default.temporaryDirectory.appending(path: "AccountVaultTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func account(_ id: String, _ credentials: String = "c") -> KeptAccount {
        KeptAccount(userID: id, nickname: "u\(id)", credentials: Data(credentials.utf8))
    }

    @Test func keepsPerSourceAcrossLaunches() throws {
        let dir = directory()
        var vault = AccountVault(directory: dir)
        try vault.keep(account("1"), for: .example)
        try vault.keep(account("2"), for: .example)
        try vault.keep(account("9"), for: .another)
        try vault.keep(account("1", "fresh"), for: .example)

        let reopened = AccountVault(directory: dir)
        #expect(reopened.accounts(for: .example).map(\.userID) == ["1", "2"])
        #expect(reopened.account("1", for: .example)?.credentials == Data("fresh".utf8))
        #expect(reopened.accounts(for: .another).map(\.userID) == ["9"])
        #expect(reopened.accounts(for: .subsonic(serverID: "home")).isEmpty)
    }

    /// Removing the last account deletes the file, so no credentials linger on disk.
    @Test func removingTheLastAccountDeletesTheFile() throws {
        let dir = directory()
        var vault = AccountVault(directory: dir)
        try vault.keep(account("1"), for: .example)
        #expect(FileManager.default.fileExists(atPath: dir.fileURL(AccountVault.fileName).path))
        vault.remove("1", for: .example)
        #expect(vault.accounts(for: .example).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.fileURL(AccountVault.fileName).path))
    }

    /// A vault that cannot be written throws and keeps what it had, so no account is signed
    /// out on the strength of a copy that was never saved.
    @Test func failedWriteKeepsTheVaultAsItWas() throws {
        let dir = directory()
        var vault = AccountVault(directory: dir)
        try vault.keep(account("1"), for: .example)
        try FileManager.default.removeItem(at: dir.fileURL(AccountVault.fileName))
        try FileManager.default.createDirectory(at: dir.fileURL(AccountVault.fileName), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try vault.keep(account("2"), for: .example) }
        #expect(vault.accounts(for: .example).map(\.userID) == ["1"])
    }
}

private extension SourceID {
    static let another = SourceID.plugin(id: "another")
}
