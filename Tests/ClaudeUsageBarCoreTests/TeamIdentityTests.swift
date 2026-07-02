import Testing
import Foundation
import CryptoKit
@testable import ClaudeUsageBarCore

@Suite struct TeamIdentityTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbteamid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadOrNilReturnsNilBeforeCreate() throws {
        let store = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        #expect(store.loadOrNil() == nil)
    }

    @Test func createPersistsProfileWithNilUserId() throws {
        let store = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        let profile = try store.create(displayName: "Sanket")

        #expect(profile.userId == nil)
        #expect(profile.displayName == "Sanket")
        #expect(profile.deviceId.isEmpty == false)
        #expect(store.loadOrNil() == profile)
    }

    @Test func loadOrNilRoundTripsAfterCreate() throws {
        let dir = try tempDir()
        let keyStore = InMemoryRawKeyStore()
        let store = TeamIdentityStore(directory: dir, keyStore: keyStore)
        let created = try store.create(displayName: "Sanket")

        // A fresh store instance pointed at the same directory/key store.
        let reloaded = TeamIdentityStore(directory: dir, keyStore: keyStore)
        #expect(reloaded.loadOrNil() == created)
    }

    @Test func signingAndEncryptionKeysReconstructAfterReload() throws {
        let dir = try tempDir()
        let keyStore = InMemoryRawKeyStore()
        let store = TeamIdentityStore(directory: dir, keyStore: keyStore)
        _ = try store.create(displayName: "Sanket")
        let originalSigningPub = try store.signingKey().publicKey.rawRepresentation
        let originalEncryptionPub = try store.encryptionKey().publicKey.rawRepresentation

        let reloaded = TeamIdentityStore(directory: dir, keyStore: keyStore)
        #expect(try reloaded.signingKey().publicKey.rawRepresentation == originalSigningPub)
        #expect(try reloaded.encryptionKey().publicKey.rawRepresentation == originalEncryptionPub)
    }

    @Test func signingKeyThrowsBeforeCreate() throws {
        let store = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        #expect(throws: TeamIdentityStore.IdentityError.noIdentity) {
            try store.signingKey()
        }
    }

    @Test func setUserIdPersists() throws {
        let dir = try tempDir()
        let store = TeamIdentityStore(directory: dir, keyStore: InMemoryRawKeyStore())
        _ = try store.create(displayName: "Sanket")

        try store.setUserId("user-abc-123")

        #expect(store.loadOrNil()?.userId == "user-abc-123")
    }

    @Test func setUserIdBeforeCreateThrows() throws {
        let store = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        #expect(throws: TeamIdentityStore.IdentityError.noIdentity) {
            try store.setUserId("user-abc-123")
        }
    }

    @Test func publicKeyBase64MatchesRawRepresentation() throws {
        let store = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        _ = try store.create(displayName: "Sanket")

        let signingB64 = try store.signingPublicKeyBase64()
        let encryptionB64 = try store.encryptionPublicKeyBase64()

        #expect(Data(base64Encoded: signingB64) == (try store.signingKey().publicKey.rawRepresentation))
        #expect(Data(base64Encoded: encryptionB64) == (try store.encryptionKey().publicKey.rawRepresentation))
        // Raw Ed25519/X25519 public keys are 32 bytes.
        #expect(try #require(Data(base64Encoded: signingB64)).count == 32)
        #expect(try #require(Data(base64Encoded: encryptionB64)).count == 32)
    }

    @Test func persistedJSONContainsDisplayNameButNoPrivateKeyMaterial() throws {
        let dir = try tempDir()
        let keyStore = InMemoryRawKeyStore()
        let store = TeamIdentityStore(directory: dir, keyStore: keyStore)
        _ = try store.create(displayName: "Sanket")
        let signingRaw = try store.signingKey().rawRepresentation
        let encryptionRaw = try store.encryptionKey().rawRepresentation

        let json = try String(contentsOf: dir.appendingPathComponent("teamidentity.json"), encoding: .utf8)

        #expect(json.contains("Sanket"))
        #expect(json.contains(signingRaw.base64EncodedString()) == false)
        #expect(json.contains(encryptionRaw.base64EncodedString()) == false)
    }
}
