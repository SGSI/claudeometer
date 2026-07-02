import Testing
import Foundation
import CryptoKit
@testable import ClaudeUsageBarCore

@Suite struct RelaySigningTests {
    /// SHA-256 of the empty string — the well-known constant from
    /// `relay/PROTOCOL.md` used as `BODY_SHA256_HEX` for empty-body requests.
    let emptyBodyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func emptyBodyHashMatchesKnownConstant() {
        #expect(RelaySigning.bodySHA256Hex(Data()) == emptyBodyHash)
    }

    @Test func bodyHashIsHexSHA256() {
        let hash = RelaySigning.bodySHA256Hex(Data("hello".utf8))
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        // Known SHA-256("hello")
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func canonicalMessageIsExactLiteralFormat() {
        let message = RelaySigning.canonicalMessage(
            method: "POST", path: "/usage", timestamp: "123", bodySHA256Hex: "abc")
        #expect(String(decoding: message, as: UTF8.self) == "POST\n/usage\n123\nabc")
    }

    @Test func canonicalMessageUsesUnixLineFeedSeparator() {
        let message = RelaySigning.canonicalMessage(
            method: "GET", path: "/board", timestamp: "1", bodySHA256Hex: "x")
        // \n must be exactly U+000A, not \r\n.
        #expect(message.contains(0x0A))
        #expect(message.contains(0x0D) == false)
    }

    @Test func signThenVerifyRoundTrips() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let message = RelaySigning.canonicalMessage(
            method: "GET",
            path: "/board",
            timestamp: "456",
            bodySHA256Hex: RelaySigning.bodySHA256Hex(Data()))

        let signatureB64 = try RelaySigning.signatureBase64(message: message, signingKey: signingKey)
        let signatureData = try #require(Data(base64Encoded: signatureB64))

        #expect(signatureData.count == 64) // Ed25519 signature length
        #expect(signingKey.publicKey.isValidSignature(signatureData, for: message))
    }

    @Test func signatureDoesNotVerifyAgainstWrongKey() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let message = RelaySigning.canonicalMessage(
            method: "POST", path: "/enroll", timestamp: "789", bodySHA256Hex: emptyBodyHash)

        let signatureB64 = try RelaySigning.signatureBase64(message: message, signingKey: signingKey)
        let signatureData = try #require(Data(base64Encoded: signatureB64))

        #expect(otherKey.publicKey.isValidSignature(signatureData, for: message) == false)
    }
}
