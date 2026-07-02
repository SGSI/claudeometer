import Testing
import Foundation
@testable import ClaudeUsageBarCore

/// In-memory CredentialStore for deterministic tests.
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    var items: [String: CredentialBlob] = [:]
    var acctAttribute: String? = "Claude Code"

    func read(service: String) throws -> CredentialBlob? { items[service] }
    func write(service: String, account: String, blob: CredentialBlob) throws { items[service] = blob }
    func delete(service: String) throws { items[service] = nil }
    func accountAttribute(service: String) throws -> String? { acctAttribute }
}

@Suite struct AccountManagerTests {
    let ccService = ClaudeometerConstants.claudeCodeKeychainService

    func makeManager(_ fake: FakeCredentialStore, dir: URL, now: @escaping () -> Date = { Date(timeIntervalSince1970: 1000) }) -> AccountManager {
        AccountManager(credentialStore: fake, store: AccountStore(directory: dir), now: now)
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbmgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func blob(_ s: String) -> CredentialBlob { CredentialBlob(raw: Data(s.utf8)) }

    @Test func captureSelfStoresBlobAndMarksSelf() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())

        let account = try mgr.captureCurrent(label: "Me", isSelf: true)

        #expect(account.isSelf == true)
        #expect(fake.items[account.keychainService] == blob("MY-CREDS"))
        #expect(mgr.snapshot().selfAccount?.id == account.id)
    }

    @Test func captureWithNoActiveCredentialThrows() throws {
        let mgr = makeManager(FakeCredentialStore(), dir: try tempDir())
        #expect(throws: AccountManager.ManagerError.noActiveClaudeCredential) {
            try mgr.captureCurrent(label: "Me", isSelf: true)
        }
    }

    @Test func onlyOneSelfAccount() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("A")
        let mgr = makeManager(fake, dir: try tempDir())
        _ = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("B")
        _ = try mgr.captureCurrent(label: "NewMe", isSelf: true)
        #expect(mgr.snapshot().accounts.filter { $0.isSelf }.count == 1)
    }

    @Test func switchWritesTargetBlobAndRecordsBorrow() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        let me = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("PRIYA-CREDS")
        let priya = try mgr.captureCurrent(label: "Priya", isSelf: false)
        // restore my creds as the active item before switching
        fake.items[ccService] = blob("MY-CREDS")

        try mgr.switchTo(accountId: priya.id, duration: 7200)

        #expect(fake.items[ccService] == blob("PRIYA-CREDS"))         // active is Priya
        #expect(fake.items[me.keychainService] == blob("MY-CREDS"))   // self backed up
        let borrow = mgr.snapshot().activeBorrow
        #expect(borrow?.activeAccountId == priya.id)
        #expect(borrow?.selfAccountId == me.id)
        #expect(borrow?.revertAt == Date(timeIntervalSince1970: 1000 + 7200))
    }

    @Test func revertRestoresSelf() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        _ = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("PRIYA-CREDS")
        let priya = try mgr.captureCurrent(label: "Priya", isSelf: false)
        fake.items[ccService] = blob("MY-CREDS")
        try mgr.switchTo(accountId: priya.id, duration: 7200)

        try mgr.revert()

        #expect(fake.items[ccService] == blob("MY-CREDS"))
        #expect(mgr.snapshot().activeBorrow == nil)
    }

    @Test func switchingWhileBorrowingKeepsSelfBackupIntact() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        let me = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("A-CREDS"); let a = try mgr.captureCurrent(label: "A", isSelf: false)
        fake.items[ccService] = blob("B-CREDS"); let b = try mgr.captureCurrent(label: "B", isSelf: false)
        fake.items[ccService] = blob("MY-CREDS")

        try mgr.switchTo(accountId: a.id, duration: 3600)   // now borrowing A (self backed up)
        try mgr.switchTo(accountId: b.id, duration: 3600)   // switch to B while borrowing

        #expect(fake.items[ccService] == blob("B-CREDS"))
        #expect(fake.items[me.keychainService] == blob("MY-CREDS")) // self NOT clobbered by A's blob
        #expect(mgr.snapshot().activeBorrow?.activeAccountId == b.id)
    }

    @Test func switchingToSelfReverts() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        let me = try mgr.captureCurrent(label: "Me", isSelf: true)
        fake.items[ccService] = blob("PRIYA-CREDS"); let priya = try mgr.captureCurrent(label: "Priya", isSelf: false)
        fake.items[ccService] = blob("MY-CREDS")
        try mgr.switchTo(accountId: priya.id, duration: 3600)

        try mgr.switchTo(accountId: me.id, duration: 3600)

        #expect(fake.items[ccService] == blob("MY-CREDS"))
        #expect(mgr.snapshot().activeBorrow == nil)
    }

    @Test func switchToUnknownAccountThrows() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        _ = try mgr.captureCurrent(label: "Me", isSelf: true)
        #expect(throws: AccountManager.ManagerError.accountNotFound) {
            try mgr.switchTo(accountId: UUID(), duration: 3600)
        }
    }

    @Test func importAccountStoresBlobAsNonSelfAccount() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        _ = try mgr.captureCurrent(label: "Me", isSelf: true)

        let imported = try mgr.importAccount(label: "Bob", blob: blob("BOB-CREDS"))

        #expect(imported.isSelf == false)
        #expect(imported.accountEmail == nil)
        #expect(fake.items[imported.keychainService] == blob("BOB-CREDS"))
        #expect(mgr.snapshot().accounts.contains(imported))
        // importAccount never touches the live Claude Code item.
        #expect(fake.items[ccService] == blob("MY-CREDS"))
    }

    @Test func importAccountThenSwitchToWritesBlobIntoClaudeCodeItem() throws {
        let fake = FakeCredentialStore()
        fake.items[ccService] = blob("MY-CREDS")
        let mgr = makeManager(fake, dir: try tempDir())
        let me = try mgr.captureCurrent(label: "Me", isSelf: true)

        let imported = try mgr.importAccount(label: "Bob", blob: blob("BOB-CREDS"))
        try mgr.switchTo(accountId: imported.id, duration: 3600)

        #expect(fake.items[ccService] == blob("BOB-CREDS"))          // active is Bob
        #expect(fake.items[me.keychainService] == blob("MY-CREDS"))  // self backed up
        let borrow = mgr.snapshot().activeBorrow
        #expect(borrow?.activeAccountId == imported.id)
        #expect(borrow?.selfAccountId == me.id)
    }
}
