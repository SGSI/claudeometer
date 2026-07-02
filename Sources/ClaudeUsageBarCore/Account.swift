import Foundation

/// Non-secret metadata for one vaulted Claude account. The credential blob is
/// stored separately in the Keychain under `keychainService`.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public var accountEmail: String?
    public var isSelf: Bool
    public let addedAt: Date

    public init(id: UUID, label: String, accountEmail: String?, isSelf: Bool, addedAt: Date) {
        self.id = id
        self.label = label
        self.accountEmail = accountEmail
        self.isSelf = isSelf
        self.addedAt = addedAt
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
