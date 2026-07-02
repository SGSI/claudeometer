import Foundation
import CryptoKit

/// Errors thrown by `BorrowCrypto` when sealing or opening a borrow sealed box.
public enum BorrowCryptoError: Error, Equatable {
    /// The provided public key string wasn't valid standard base64 of 32 raw bytes.
    case invalidPublicKey
    /// The ciphertext wasn't valid standard base64, or was too short to contain
    /// an ephemeral public key + nonce + tag.
    case malformedCiphertext
    /// `AES.GCM.open` rejected the box — wrong key (e.g. wrong recipient
    /// private key) or tampered ciphertext/tag.
    case authenticationFailed
}

/// Implements the sealed-box format from `relay/PROTOCOL.md` ("M3 — Borrow
/// Handshake" → "Sealed-box format"): ECIES over CryptoKit's
/// `Curve25519.KeyAgreement`, with AES-GCM under an HKDF-derived key. This is
/// Swift-to-Swift only — the relay stores/relays the resulting base64 blob
/// opaquely and never decrypts it.
public enum BorrowCrypto {
    private static let hkdfInfo = Data("claudeometer-borrow-v1".utf8)
    private static let ephPubLength = 32
    private static let nonceLength = 12
    private static let tagLength = 16

    /// Seals `plaintext` to `recipientPublicKeyBase64` (standard base64 of the
    /// recipient's raw 32-byte X25519 public key). Returns standard base64 of
    /// `ephPub(32) || nonce(12) || ciphertext || tag(16)`.
    public static func seal(_ plaintext: Data, toRecipientPublicKeyBase64 pub: String) throws -> String {
        let recipientPublicKey = try publicKey(fromBase64: pub)
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralPrivateKey.publicKey
        let shared = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let key = derivedKey(
            from: shared,
            ephemeralPublicKey: ephemeralPublicKey,
            recipientPublicKey: recipientPublicKey
        )
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            // Only happens if the nonce isn't the standard 12 bytes; `AES.GCM.seal`
            // without an explicit nonce always generates a 12-byte one.
            throw BorrowCryptoError.malformedCiphertext
        }
        return (ephemeralPublicKey.rawRepresentation + combined).base64EncodedString()
    }

    /// Opens a sealed box produced by `seal(_:toRecipientPublicKeyBase64:)`
    /// using the matching recipient private key. Throws
    /// `BorrowCryptoError.malformedCiphertext` for structurally invalid input
    /// and `.authenticationFailed` for a wrong key or tampered ciphertext.
    public static func open(_ ciphertextBase64: String, with recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let data = Data(base64Encoded: ciphertextBase64) else {
            throw BorrowCryptoError.malformedCiphertext
        }
        let minimumLength = ephPubLength + nonceLength + tagLength
        guard data.count >= minimumLength else {
            throw BorrowCryptoError.malformedCiphertext
        }
        let ephemeralPublicKeyData = data.prefix(ephPubLength)
        let combined = data.suffix(from: data.startIndex + ephPubLength)
        let ephemeralPublicKey = try publicKey(fromRaw: Data(ephemeralPublicKeyData))
        let recipientPublicKey = recipientPrivateKey.publicKey
        let shared = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let key = derivedKey(
            from: shared,
            ephemeralPublicKey: ephemeralPublicKey,
            recipientPublicKey: recipientPublicKey
        )
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as BorrowCryptoError {
            throw error
        } catch {
            throw BorrowCryptoError.authenticationFailed
        }
    }

    /// `HKDF<SHA256>(shared, salt: ephPub||recipientPub, info: "claudeometer-borrow-v1", outputByteCount: 32)`.
    private static func derivedKey(
        from shared: SharedSecret,
        ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey,
        recipientPublicKey: Curve25519.KeyAgreement.PublicKey
    ) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublicKey.rawRepresentation + recipientPublicKey.rawRepresentation,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
    }

    private static func publicKey(fromBase64 base64: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let data = Data(base64Encoded: base64) else {
            throw BorrowCryptoError.invalidPublicKey
        }
        return try publicKey(fromRaw: data)
    }

    private static func publicKey(fromRaw data: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        guard data.count == ephPubLength else {
            throw BorrowCryptoError.invalidPublicKey
        }
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        } catch {
            throw BorrowCryptoError.invalidPublicKey
        }
    }
}
