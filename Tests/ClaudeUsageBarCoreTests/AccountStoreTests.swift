import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct AccountStoreTests {
    /// Fresh temp dir per test.
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadMissingReturnsEmpty() throws {
        let store = AccountStore(directory: try tempDir())
        #expect(store.load() == AccountsFile())
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = try tempDir()
        let store = AccountStore(directory: dir)
        let account = Account(id: UUID(), label: "Priya", accountEmail: nil, isSelf: false,
                              addedAt: Date(timeIntervalSince1970: 42))
        try store.save(AccountsFile(accounts: [account], activeBorrow: nil))
        #expect(store.load().accounts == [account])
    }

    @Test func keychainServiceUsesPrefix() {
        let id = UUID()
        let account = Account(id: id, label: "x", accountEmail: nil, isSelf: false, addedAt: Date())
        #expect(account.keychainService == "Claudeometer-account-\(id.uuidString)")
    }

    @Test func selfAccountAndLookup() {
        let me = Account(id: UUID(), label: "Me", accountEmail: nil, isSelf: true, addedAt: Date())
        let other = Account(id: UUID(), label: "Priya", accountEmail: nil, isSelf: false, addedAt: Date())
        let file = AccountsFile(accounts: [me, other], activeBorrow: nil)
        #expect(file.selfAccount == me)
        #expect(file.account(id: other.id) == other)
        #expect(file.account(id: UUID()) == nil)
    }

    @Test func persistedFileHasNoRawSecret() throws {
        // Guardrail: metadata store must never contain a token; only labels/ids.
        let dir = try tempDir()
        let store = AccountStore(directory: dir)
        let account = Account(id: UUID(), label: "Priya", accountEmail: "p@example.com", isSelf: false, addedAt: Date())
        try store.save(AccountsFile(accounts: [account], activeBorrow: nil))
        let json = try String(contentsOf: dir.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(json.contains("Priya"))
        #expect(json.contains("accessToken") == false)
        #expect(json.contains("claudeAiOauth") == false)
    }
}
