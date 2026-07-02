import Testing
import Foundation
import CryptoKit
@testable import ClaudeUsageBarCore

@Suite struct BorrowCryptoTests {
    /// A realistic Claude Code credential blob shape (see `CredentialBlob.decoded()`).
    let realisticCredentialJSON = """
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-\
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",\
    "refreshToken":"sk-ant-ort01-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",\
    "expiresAt":1893456000000,"scopes":["user:inference"],"subscriptionType":"pro"}}
    """

    @Test func sealOpenRoundTripsRealisticJSONCredentialBlob() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let pubB64 = recipient.publicKey.rawRepresentation.base64EncodedString()
        let plaintext = Data(realisticCredentialJSON.utf8)

        let sealed = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)
        let opened = try BorrowCrypto.open(sealed, with: recipient)

        #expect(opened == plaintext)
    }

    @Test func sealOpenRoundTripsBinaryBlob() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let pubB64 = recipient.publicKey.rawRepresentation.base64EncodedString()
        var bytes = [UInt8](repeating: 0, count: 300)
        for i in 0..<bytes.count { bytes[i] = UInt8((i * 37 + 11) % 256) }
        let plaintext = Data(bytes)

        let sealed = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)
        let opened = try BorrowCrypto.open(sealed, with: recipient)

        #expect(opened == plaintext)
    }

    @Test func sealOpenRoundTripsEmptyPlaintext() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let pubB64 = recipient.publicKey.rawRepresentation.base64EncodedString()
        let plaintext = Data()

        let sealed = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)
        let opened = try BorrowCrypto.open(sealed, with: recipient)

        #expect(opened == plaintext)
    }

    @Test func openWithWrongPrivateKeyThrowsAuthenticationFailed() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let wrongRecipient = Curve25519.KeyAgreement.PrivateKey()
        let pubB64 = recipient.publicKey.rawRepresentation.base64EncodedString()
        let plaintext = Data("top secret credential bytes".utf8)
        let sealed = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)

        #expect(throws: BorrowCryptoError.authenticationFailed) {
            _ = try BorrowCrypto.open(sealed, with: wrongRecipient)
        }
    }

    @Test func openWithTamperedCiphertextThrowsAuthenticationFailed() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let pubB64 = recipient.publicKey.rawRepresentation.base64EncodedString()
        let plaintext = Data("another secret payload".utf8)
        let sealed = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)
        var raw = try #require(Data(base64Encoded: sealed))
        // Flip a byte inside the ciphertext/tag region (after ephPub(32) + nonce(12)).
        let tamperIndex = raw.startIndex + 32 + 12
        raw[tamperIndex] ^= 0xFF
        let tampered = raw.base64EncodedString()

        #expect(throws: BorrowCryptoError.authenticationFailed) {
            _ = try BorrowCrypto.open(tampered, with: recipient)
        }
    }

    @Test func openWithTamperedEphemeralPublicKeyThrowsAuthenticationFailed() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let pubB64 = recipient.publicKey.rawRepresentation.base64EncodedString()
        let plaintext = Data("yet another secret".utf8)
        let sealed = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)
        var raw = try #require(Data(base64Encoded: sealed))
        raw[raw.startIndex] ^= 0xFF // corrupt a byte of the ephemeral public key itself

        #expect(throws: BorrowCryptoError.authenticationFailed) {
            _ = try BorrowCrypto.open(raw.base64EncodedString(), with: recipient)
        }
    }

    @Test func openWithMalformedBase64ThrowsMalformedCiphertext() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()

        #expect(throws: BorrowCryptoError.malformedCiphertext) {
            _ = try BorrowCrypto.open("not valid base64!!", with: recipient)
        }
    }

    @Test func openWithTooShortDataThrowsMalformedCiphertext() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let tooShort = Data(repeating: 1, count: 10).base64EncodedString()

        #expect(throws: BorrowCryptoError.malformedCiphertext) {
            _ = try BorrowCrypto.open(tooShort, with: recipient)
        }
    }

    @Test func sealWithInvalidPublicKeyThrowsInvalidPublicKey() throws {
        #expect(throws: BorrowCryptoError.invalidPublicKey) {
            _ = try BorrowCrypto.seal(Data("x".utf8), toRecipientPublicKeyBase64: "not-valid-base64-key")
        }
    }

    @Test func sealWithWrongLengthPublicKeyThrowsInvalidPublicKey() throws {
        let shortKey = Data(repeating: 9, count: 16).base64EncodedString()
        #expect(throws: BorrowCryptoError.invalidPublicKey) {
            _ = try BorrowCrypto.seal(Data("x".utf8), toRecipientPublicKeyBase64: shortKey)
        }
    }

    @Test func sealProducesDifferentCiphertextEachTimeNonDeterministic() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let pubB64 = recipient.publicKey.rawRepresentation.base64EncodedString()
        let plaintext = Data("same plaintext".utf8)

        let sealedA = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)
        let sealedB = try BorrowCrypto.seal(plaintext, toRecipientPublicKeyBase64: pubB64)

        #expect(sealedA != sealedB) // fresh ephemeral key + nonce each call
        #expect(try BorrowCrypto.open(sealedA, with: recipient) == plaintext)
        #expect(try BorrowCrypto.open(sealedB, with: recipient) == plaintext)
    }
}
