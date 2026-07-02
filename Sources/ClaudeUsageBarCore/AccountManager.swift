import Foundation

/// Orchestrates capturing, switching, and reverting accounts by moving credential
/// blobs between the Claude Code Keychain item and per-account vault items.
public struct AccountManager {
    private let credentialStore: CredentialStore
    private let store: AccountStore
    private let claudeCodeService: String
    private let now: () -> Date

    public enum ManagerError: Error, Equatable {
        case noSelfAccount
        case accountNotFound
        case noActiveClaudeCredential
    }

    public init(credentialStore: CredentialStore,
                store: AccountStore,
                claudeCodeService: String = ClaudeometerConstants.claudeCodeKeychainService,
                now: @escaping () -> Date = Date.init) {
        self.credentialStore = credentialStore
        self.store = store
        self.claudeCodeService = claudeCodeService
        self.now = now
    }

    /// The `acct` attribute needed to update the Claude Code item in place.
    private func claudeCodeAccount() -> String {
        // The "Claude Code" fallback only applies if the live attribute read fails;
        // the real value is confirmed by the human Keychain spike
        // (docs/superpowers/spikes/keychain-roundtrip.md).
        (try? credentialStore.accountAttribute(service: claudeCodeService)) ?? "Claude Code"
    }

    /// Snapshots whatever is currently in the Claude Code item into a new vault
    /// account. Marking `isSelf` clears any previous self flag.
    @discardableResult
    public func captureCurrent(label: String, isSelf: Bool) throws -> Account {
        guard let blob = try credentialStore.read(service: claudeCodeService) else {
            throw ManagerError.noActiveClaudeCredential
        }
        var file = store.load()
        // accountEmail stays nil in M1 (real email arrives with the profile call in
        // M2). Never persist any fragment of the token to disk.
        let account = Account(id: UUID(), label: label, accountEmail: nil, isSelf: isSelf, addedAt: now())
        try credentialStore.write(service: account.keychainService, account: account.id.uuidString, blob: blob)
        if isSelf {
            file.accounts = file.accounts.map { var a = $0; a.isSelf = false; return a }
        }
        file.accounts.append(account)
        try store.save(file)
        return account
    }

    /// Stores a `blob` received from a lender (e.g. via `BorrowCrypto.open`)
    /// into a new vault item as a switchable, non-self account. Unlike
    /// `captureCurrent`, this never touches the live Claude Code item — the
    /// blob comes from the caller. Returns the `Account` so the caller can
    /// then `switchTo(accountId:duration:)` it.
    @discardableResult
    public func importAccount(label: String, blob: CredentialBlob) throws -> Account {
        var file = store.load()
        // Borrowed accounts are ephemeral — sweep any stale ones (not the active
        // borrow) before importing, so repeated borrows don't pile up duplicates.
        let activeId = file.activeBorrow?.activeAccountId
        let stale = file.accounts.filter { Self.isEphemeralBorrow($0) && $0.id != activeId }.map(\.id)
        removeAccounts(stale, from: &file)

        let account = Account(id: UUID(), label: label, accountEmail: nil, isSelf: false, addedAt: now(), isBorrowed: true)
        try credentialStore.write(service: account.keychainService, account: account.id.uuidString, blob: blob)
        file.accounts.append(account)
        try store.save(file)
        return account
    }

    /// True for accounts that should not outlive their borrow: those explicitly
    /// flagged `isBorrowed`, plus legacy "… (borrowed)" imports written before the
    /// flag existed (never the self account).
    private static func isEphemeralBorrow(_ account: Account) -> Bool {
        !account.isSelf && (account.isBorrowed || account.label.hasSuffix("(borrowed)"))
    }

    /// Removes `ids` from the vault — both the metadata and the Keychain items.
    /// Missing Keychain items are not an error.
    private func removeAccounts(_ ids: [UUID], from file: inout AccountsFile) {
        for id in ids {
            if let account = file.account(id: id) {
                try? credentialStore.delete(service: account.keychainService)
            }
        }
        file.accounts.removeAll { ids.contains($0.id) }
    }

    /// Switches the Claude Code item to `accountId`'s blob for `duration` seconds.
    /// Switching to the self account is equivalent to `revert()`.
    public func switchTo(accountId: UUID, duration: TimeInterval) throws {
        var file = store.load()
        guard let target = file.account(id: accountId) else { throw ManagerError.accountNotFound }
        guard let selfAccount = file.selfAccount else { throw ManagerError.noSelfAccount }

        if target.isSelf {
            try revert()
            return
        }

        // Keep self's backup current only when we are not already borrowing.
        if file.activeBorrow == nil, let current = try credentialStore.read(service: claudeCodeService) {
            try credentialStore.write(service: selfAccount.keychainService,
                                      account: selfAccount.id.uuidString, blob: current)
        }

        guard let targetBlob = try credentialStore.read(service: target.keychainService) else {
            throw ManagerError.accountNotFound
        }
        try credentialStore.write(service: claudeCodeService, account: claudeCodeAccount(), blob: targetBlob)

        file.activeBorrow = ActiveBorrow(
            activeAccountId: target.id,
            selfAccountId: selfAccount.id,
            startedAt: now(),
            revertAt: now().addingTimeInterval(BorrowDuration.clamp(duration))
        )
        try store.save(file)
    }

    /// Restores the self account's blob into the Claude Code item and clears the
    /// borrow. No-op when not borrowing.
    public func revert() throws {
        var file = store.load()
        guard let borrow = file.activeBorrow else { return }
        guard let selfAccount = file.account(id: borrow.selfAccountId) else { throw ManagerError.noSelfAccount }
        guard let selfBlob = try credentialStore.read(service: selfAccount.keychainService) else {
            throw ManagerError.noActiveClaudeCredential
        }
        try credentialStore.write(service: claudeCodeService, account: claudeCodeAccount(), blob: selfBlob)
        file.activeBorrow = nil
        // Borrowed accounts don't outlive their borrow — drop them all (metadata
        // + Keychain items) so the vault doesn't accumulate stale "… (borrowed)"
        // entries. User-saved accounts (captureCurrent) are untouched.
        let borrowed = file.accounts.filter { Self.isEphemeralBorrow($0) }.map(\.id)
        removeAccounts(borrowed, from: &file)
        try store.save(file)
    }

    public func snapshot() -> AccountsFile {
        store.load()
    }
}
