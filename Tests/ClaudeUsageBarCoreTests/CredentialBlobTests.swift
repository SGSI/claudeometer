import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct CredentialBlobTests {
    let sample = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-abcd1234","expiresAt":1893456000000}}"#.utf8)

    @Test func decodesTokenSuffixAndExpiry() {
        let decoded = CredentialBlob(raw: sample).decoded()
        #expect(decoded?.accessTokenSuffix == "abcd1234")
        #expect(decoded?.expiresAtMillis == 1893456000000)
    }

    @Test func fingerprintIsStableAndContentSensitive() {
        let a = CredentialBlob(raw: sample).fingerprint
        let b = CredentialBlob(raw: sample).fingerprint
        let c = CredentialBlob(raw: Data("{}".utf8)).fingerprint
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 64) // hex SHA-256
    }

    @Test func expiryComparison() {
        let d = DecodedCredential(accessTokenSuffix: "x", expiresAtMillis: 1000) // 1000 ms
        #expect(d.isExpired(now: Date(timeIntervalSince1970: 2)) == true)    // 2000 ms > 1000
        #expect(d.isExpired(now: Date(timeIntervalSince1970: 0.5)) == false) // 500 ms < 1000
    }

    @Test func zeroExpiryNeverExpires() {
        let d = DecodedCredential(accessTokenSuffix: "x", expiresAtMillis: 0)
        #expect(d.isExpired(now: Date(timeIntervalSince1970: 9_999_999_999)) == false)
    }

    @Test func malformedBlobDecodesToNil() {
        #expect(CredentialBlob(raw: Data("not json".utf8)).decoded() == nil)
    }
}
