import Foundation
import CryptoKit

/// Non-secret, persisted identity for the local device's participation in a
/// team. `userId` is nil until `enroll` succeeds against the relay.
public struct TeamProfile: Codable, Equatable, Sendable {
    public var userId: String?
    public var displayName: String
    public var deviceId: String

    public init(userId: String?, displayName: String, deviceId: String) {
        self.userId = userId
        self.displayName = displayName
        self.deviceId = deviceId
    }
}

/// Abstraction over raw private-key-bytes storage so business logic can be
/// tested without touching the real Keychain. A Keychain-backed implementation
/// belongs in the app layer, added later.
public protocol RawKeyStore: Sendable {
    /// Returns the bytes for `key`, or nil if no such item exists.
    func read(_ key: String) -> Data?
    /// Creates or overwrites the item for `key`.
    func write(_ key: String, _ data: Data)
    /// Deletes the item for `key`. A missing item is not an error.
    func delete(_ key: String)
}

/// Thread-safe in-memory `RawKeyStore`. Never persists to disk — intended for
/// tests (and previews); a real app would use a Keychain-backed store.
public final class InMemoryRawKeyStore: RawKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func read(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func write(_ key: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }

    public func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

/// Owns the local team identity: the signing/encryption keypairs (private
/// bytes in `RawKeyStore`, never on disk) plus the persisted `TeamProfile`
/// (`teamidentity.json` in the given directory — no secrets in that file).
public final class TeamIdentityStore: Sendable {
    public enum IdentityError: Error, Equatable {
        /// No keys/profile exist yet — call `create` first.
        case noIdentity
    }

    private enum KeyStoreKey {
        static let signing = "team.signingKey.v1"
        static let encryption = "team.encryptionKey.v1"
    }

    private let fileURL: URL
    private let keyStore: RawKeyStore

    public init(directory: URL, keyStore: RawKeyStore) {
        self.fileURL = directory.appendingPathComponent("teamidentity.json")
        self.keyStore = keyStore
    }

    /// Reads the persisted profile, or nil if none exists yet.
    public func loadOrNil() -> TeamProfile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TeamProfile.self, from: data)
    }

    /// Generates a fresh signing keypair, encryption keypair, and deviceId;
    /// stores the private key bytes in the key store; persists the profile
    /// (`userId` nil until enrolled).
    @discardableResult
    public func create(displayName: String) throws -> TeamProfile {
        let signingKey = Curve25519.Signing.PrivateKey()
        let encryptionKey = Curve25519.KeyAgreement.PrivateKey()
        keyStore.write(KeyStoreKey.signing, signingKey.rawRepresentation)
        keyStore.write(KeyStoreKey.encryption, encryptionKey.rawRepresentation)
        let profile = TeamProfile(userId: nil, displayName: displayName, deviceId: UUID().uuidString)
        try persist(profile)
        return profile
    }

    /// Reconstructs the Ed25519 signing key from stored raw bytes.
    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        guard let data = keyStore.read(KeyStoreKey.signing) else { throw IdentityError.noIdentity }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// Reconstructs the X25519 encryption key from stored raw bytes. Unused in
    /// M2 — the encryption keypair is only registered, in preparation for M3.
    public func encryptionKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let data = keyStore.read(KeyStoreKey.encryption) else { throw IdentityError.noIdentity }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// Persists the relay-assigned userId onto the existing profile.
    public func setUserId(_ id: String) throws {
        guard var profile = loadOrNil() else { throw IdentityError.noIdentity }
        profile.userId = id
        try persist(profile)
    }

    /// Standard (padded) base64 of the signing public key's 32 raw bytes.
    public func signingPublicKeyBase64() throws -> String {
        try signingKey().publicKey.rawRepresentation.base64EncodedString()
    }

    /// Standard (padded) base64 of the encryption public key's 32 raw bytes.
    public func encryptionPublicKeyBase64() throws -> String {
        try encryptionKey().publicKey.rawRepresentation.base64EncodedString()
    }

    private func persist(_ profile: TeamProfile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: fileURL, options: .atomic)
    }
}
