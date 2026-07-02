import Foundation
import CryptoKit

/// Pure helpers implementing the relay's canonical request-signing scheme.
/// See `relay/PROTOCOL.md` — the Go relay verifies exactly what these produce,
/// so nothing here may deviate from the documented format.
public enum RelaySigning {
    /// Lowercase hex SHA-256 of `body`. For an empty body this is the
    /// well-known empty-string hash
    /// `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
    public static func bodySHA256Hex(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// The exact UTF-8 bytes of `<METHOD>\n<PATH>\n<TIMESTAMP>\n<BODY_SHA256_HEX>`
    /// (`\n` = U+000A), matching the Go relay's verification byte-for-byte.
    public static func canonicalMessage(
        method: String,
        path: String,
        timestamp: String,
        bodySHA256Hex: String
    ) -> Data {
        Data("\(method)\n\(path)\n\(timestamp)\n\(bodySHA256Hex)".utf8)
    }

    /// Standard (padded) base64 of the 64-byte Ed25519 signature over `message`.
    public static func signatureBase64(
        message: Data,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        try signingKey.signature(for: message).base64EncodedString()
    }
}
