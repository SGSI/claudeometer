import Foundation
import CryptoKit

/// A decoded, non-secret view of a credential blob.
public struct DecodedCredential: Equatable, Sendable {
    public let accessTokenSuffix: String
    public let expiresAtMillis: Int64

    public init(accessTokenSuffix: String, expiresAtMillis: Int64) {
        self.accessTokenSuffix = accessTokenSuffix
        self.expiresAtMillis = expiresAtMillis
    }

    /// True when the credential's expiry has passed. Expiry of 0 means "no expiry known".
    public func isExpired(now: Date) -> Bool {
        guard expiresAtMillis > 0 else { return false }
        return Double(expiresAtMillis) < now.timeIntervalSince1970 * 1000
    }
}

/// An opaque Claude credential blob. The raw bytes are preserved verbatim so the
/// blob can be moved between Keychain items without corruption.
public struct CredentialBlob: Equatable, Sendable {
    public let raw: Data

    public init(raw: Data) {
        self.raw = raw
    }

    /// A stable content fingerprint (hex SHA-256) used to tell two blobs apart
    /// without exposing the secret.
    public var fingerprint: String {
        SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort decode of the non-secret fields we care about. Returns nil for
    /// malformed input.
    public func decoded() -> DecodedCredential? {
        struct Blob: Decodable { let claudeAiOauth: OAuth }
        struct OAuth: Decodable { let accessToken: String; let expiresAt: Int64? }
        guard let blob = try? JSONDecoder().decode(Blob.self, from: raw) else { return nil }
        return DecodedCredential(
            accessTokenSuffix: String(blob.claudeAiOauth.accessToken.suffix(8)),
            expiresAtMillis: blob.claudeAiOauth.expiresAt ?? 0
        )
    }
}
