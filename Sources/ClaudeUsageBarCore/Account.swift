import Foundation

/// Non-secret metadata for one vaulted Claude account. The credential blob is
/// stored separately in the Keychain under `keychainService`.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public var accountEmail: String?
    public var isSelf: Bool
    public let addedAt: Date
    /// True for accounts imported from a borrow handshake. Borrowed credentials
    /// are one-time and expire with the window, so these are ephemeral — removed
    /// on revert, unlike user-saved accounts from `captureCurrent`.
    public var isBorrowed: Bool

    public init(id: UUID, label: String, accountEmail: String?, isSelf: Bool, addedAt: Date, isBorrowed: Bool = false) {
        self.id = id
        self.label = label
        self.accountEmail = accountEmail
        self.isSelf = isSelf
        self.addedAt = addedAt
        self.isBorrowed = isBorrowed
    }

    // Custom decoder so an `accounts.json` written before `isBorrowed` existed
    // still loads (defaults to false) instead of failing and wiping the vault.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        accountEmail = try c.decodeIfPresent(String.self, forKey: .accountEmail)
        isSelf = try c.decode(Bool.self, forKey: .isSelf)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        isBorrowed = try c.decodeIfPresent(Bool.self, forKey: .isBorrowed) ?? false
    }

    public var keychainService: String {
        ClaudeometerConstants.vaultServicePrefix + id.uuidString
    }
}

/// The full on-disk state: the vaulted accounts plus the current borrow, if any.
public struct AccountsFile: Codable, Equatable, Sendable {
    public var accounts: [Account]
    public var activeBorrow: ActiveBorrow?

    public init(accounts: [Account] = [], activeBorrow: ActiveBorrow? = nil) {
        self.accounts = accounts
        self.activeBorrow = activeBorrow
    }

    public var selfAccount: Account? {
        accounts.first { $0.isSelf }
    }

    public func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    /// The Keychain service to read for the user's OWN usage. While a borrow is
    /// active the Claude Code item holds the lent credential, so read the self
    /// account's vault item instead — otherwise the personal meter and the team
    /// board would show the lent account's usage, not the user's own.
    public func ownUsageKeychainService(claudeCodeService: String) -> String {
        if activeBorrow != nil, let me = selfAccount {
            return me.keychainService
        }
        return claudeCodeService
    }
}

/// Persists `AccountsFile` as `accounts.json` in the given directory. Secrets are
/// NEVER written here — only metadata and borrow state.
public final class AccountStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("accounts.json")
    }

    public func load() -> AccountsFile {
        guard let data = try? Data(contentsOf: fileURL) else { return AccountsFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AccountsFile.self, from: data)) ?? AccountsFile()
    }

    public func save(_ file: AccountsFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
