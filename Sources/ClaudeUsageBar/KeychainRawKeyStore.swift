import ClaudeUsageBarCore
import Foundation
import Security

/// Real `RawKeyStore` backed by the macOS Keychain (`SecItem` API). Used to store
/// the team-identity signing/encryption private key bytes — they never touch disk;
/// only `teamidentity.json` (no secrets) is persisted by `TeamIdentityStore`.
///
/// Each `key` (e.g. `"team.signingKey.v1"`) maps to its own generic-password item
/// under service `"Claudeometer-team-" + key`, mirroring the naming convention
/// `SecurityCLICredentialStore`/`AccountManager` use for their own Keychain items.
public struct KeychainRawKeyStore: RawKeyStore {
    public init() {}

    private static func service(for key: String) -> String {
        "Claudeometer-team-" + key
    }

    public func read(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service(for: key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Upserts: tries `SecItemUpdate` first (item already exists), falling back to
    /// `SecItemAdd` when it doesn't. Silently no-ops on unexpected Keychain errors —
    /// callers that need to observe write failures should read back afterward.
    public func write(_ key: String, _ data: Data) {
        let service = Self.service(for: key)
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return }

        var addQuery = matchQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Deletes the item for `key`. `errSecItemNotFound` is not an error — a missing
    /// item already satisfies "deleted".
    public func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service(for: key)
        ]
        SecItemDelete(query as CFDictionary)
    }
}
