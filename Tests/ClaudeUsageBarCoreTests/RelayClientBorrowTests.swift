import Testing
import Foundation
import CryptoKit
@testable import ClaudeUsageBarCore

/// `.serialized` so tests within this suite don't race each other while
/// re-registering `MockURLProtocol`'s handler for `baseURL`. Uses a distinct
/// port from `RelayClientTests` so `MockURLProtocol` (keyed by base URL) can
/// safely run concurrently with that suite.
@Suite(.serialized)
struct RelayClientBorrowTests {
    let baseURL = URL(string: "http://localhost:9998")!

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbrelayborrow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func makeEnrolledIdentity(userId: String = "user-abc") throws -> TeamIdentityStore {
        let identity = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        _ = try identity.create(displayName: "Sanket")
        try identity.setUserId(userId)
        return identity
    }

    /// Recomputes the canonical message from an intercepted request and
    /// verifies `X-Signature` against the identity's own signing public key,
    /// including the path (with any path-segment ids) — proves the client
    /// signs exactly what `relay/PROTOCOL.md` requires with no network involved.
    func assertSignatureVerifies(
        request: URLRequest,
        body: Data,
        method: String,
        path: String,
        identity: TeamIdentityStore
    ) throws {
        let timestamp = try #require(request.value(forHTTPHeaderField: "X-Timestamp"))
        let signatureB64 = try #require(request.value(forHTTPHeaderField: "X-Signature"))
        let signatureData = try #require(Data(base64Encoded: signatureB64))
        let message = RelaySigning.canonicalMessage(
            method: method, path: path, timestamp: timestamp,
            bodySHA256Hex: RelaySigning.bodySHA256Hex(body))
        let publicKeyB64 = try identity.signingPublicKeyBase64()
        let publicKeyData = try #require(Data(base64Encoded: publicKeyB64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        #expect(publicKey.isValidSignature(signatureData, for: message))
    }

    @Test func requestBorrowSendsSignedRequestAndReturnsRequestId() async throws {
        let identity = try makeEnrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"requestId":"req-123"}"#.utf8))
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        let requestId = try await client.requestBorrow(lenderId: "user-lender", hours: 2)

        #expect(requestId == "req-123")
        let request = try #require(captured.request)
        let body = try #require(captured.body)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/borrow/request")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-abc")

        let jsonAny = try JSONSerialization.jsonObject(with: body)
        let json = try #require(jsonAny as? [String: Any])
        #expect(json["lenderId"] as? String == "user-lender")
        #expect(json["hours"] as? Int == 2)

        try assertSignatureVerifies(
            request: request, body: body, method: "POST", path: "/borrow/request", identity: identity)
    }

    @Test func fetchInboxDecodesIncomingAndOutgoing() async throws {
        let identity = try makeEnrolledIdentity()
        let canned = """
        { "incoming": [ { "requestId":"req-1","requesterId":"user-req","requesterName":"Alice",
                           "requesterEncryptionPubKey":"cGFkZGluZ3BhZGRpbmdwYWRkaW5ncGFkZGluZw==",
                           "hours":2,"createdAt":123 } ],
          "outgoing": [ { "requestId":"req-2","lenderId":"user-lender","lenderName":"Bob","hours":3,
                           "status":"approved","decidedAt":456 } ] }
        """
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(canned.utf8))
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        let inbox = try await client.fetchInbox()

        #expect(inbox.incoming == [
            IncomingRequest(
                requestId: "req-1", requesterId: "user-req", requesterName: "Alice",
                requesterEncryptionPubKey: "cGFkZGluZ3BhZGRpbmdwYWRkaW5ncGFkZGluZw==",
                hours: 2, createdAt: 123)
        ])
        #expect(inbox.outgoing == [
            OutgoingRequest(
                requestId: "req-2", lenderId: "user-lender", lenderName: "Bob",
                hours: 3, status: "approved", decidedAt: 456)
        ])

        let request = try #require(captured.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/borrow/inbox")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-abc")
        #expect((captured.body ?? Data()).isEmpty)

        try assertSignatureVerifies(
            request: request, body: captured.body ?? Data(), method: "GET", path: "/borrow/inbox", identity: identity)
    }

    @Test func decideApproveSendsCiphertextAndSucceedsOn204() async throws {
        let identity = try makeEnrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        try await client.decide(requestId: "req-123", approve: true, ciphertext: "c2VhbGVkLWJveA==")

        let request = try #require(captured.request)
        let body = try #require(captured.body)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/borrow/decision")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-abc")

        let jsonAny = try JSONSerialization.jsonObject(with: body)
        let json = try #require(jsonAny as? [String: Any])
        #expect(json["requestId"] as? String == "req-123")
        #expect(json["approve"] as? Bool == true)
        #expect(json["ciphertext"] as? String == "c2VhbGVkLWJveA==")

        try assertSignatureVerifies(
            request: request, body: body, method: "POST", path: "/borrow/decision", identity: identity)
    }

    @Test func decideRejectOmitsCiphertext() async throws {
        let identity = try makeEnrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        try await client.decide(requestId: "req-123", approve: false, ciphertext: nil)

        let body = try #require(captured.body)
        let jsonAny = try JSONSerialization.jsonObject(with: body)
        let json = try #require(jsonAny as? [String: Any])
        #expect(json["approve"] as? Bool == false)
        #expect((json["ciphertext"] as? String) == nil)
    }

    @Test func pickupSignsFullPathIncludingRequestIdAndReturnsCiphertext() async throws {
        let identity = try makeEnrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"ciphertext":"c2VhbGVkLWJveA=="}"#.utf8))
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        let ciphertext = try await client.pickup(requestId: "req-123")

        #expect(ciphertext == "c2VhbGVkLWJveA==")
        let request = try #require(captured.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/borrow/pickup/req-123")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-abc")
        #expect((captured.body ?? Data()).isEmpty)

        // The signature MUST cover the full path, including the request id —
        // verify against the correct path succeeds...
        try assertSignatureVerifies(
            request: request, body: captured.body ?? Data(),
            method: "GET", path: "/borrow/pickup/req-123", identity: identity)

        // ...and verifying against a *different* id (or the bare route) must fail,
        // proving the id is actually part of the signed message.
        let timestamp = try #require(request.value(forHTTPHeaderField: "X-Timestamp"))
        let signatureB64 = try #require(request.value(forHTTPHeaderField: "X-Signature"))
        let signatureData = try #require(Data(base64Encoded: signatureB64))
        let wrongMessage = RelaySigning.canonicalMessage(
            method: "GET", path: "/borrow/pickup/some-other-id", timestamp: timestamp,
            bodySHA256Hex: RelaySigning.bodySHA256Hex(Data()))
        let publicKeyB64 = try identity.signingPublicKeyBase64()
        let publicKeyData = try #require(Data(base64Encoded: publicKeyB64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        #expect(!publicKey.isValidSignature(signatureData, for: wrongMessage))
    }

    @Test func revokeSendsSignedRequestAndSucceedsOn204() async throws {
        let identity = try makeEnrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        try await client.revoke(requestId: "req-123")

        let request = try #require(captured.request)
        let body = try #require(captured.body)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/borrow/revoke")

        let jsonAny = try JSONSerialization.jsonObject(with: body)
        let json = try #require(jsonAny as? [String: Any])
        #expect(json["requestId"] as? String == "req-123")

        try assertSignatureVerifies(
            request: request, body: body, method: "POST", path: "/borrow/revoke", identity: identity)
    }

    @Test func nonTwoxxResponseThrowsHTTPErrorForEachBorrowMethod() async throws {
        let identity = try makeEnrolledIdentity()
        MockURLProtocol.setHandler(for: baseURL) { request, _ in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"forbidden"}"#.utf8))
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        await #expect(throws: RelayError.http(status: 403, body: #"{"error":"forbidden"}"#)) {
            _ = try await client.requestBorrow(lenderId: "user-lender", hours: 2)
        }
        await #expect(throws: RelayError.http(status: 403, body: #"{"error":"forbidden"}"#)) {
            _ = try await client.fetchInbox()
        }
        await #expect(throws: RelayError.http(status: 403, body: #"{"error":"forbidden"}"#)) {
            try await client.decide(requestId: "req-123", approve: true, ciphertext: "abc")
        }
        await #expect(throws: RelayError.http(status: 403, body: #"{"error":"forbidden"}"#)) {
            _ = try await client.pickup(requestId: "req-123")
        }
        await #expect(throws: RelayError.http(status: 403, body: #"{"error":"forbidden"}"#)) {
            try await client.revoke(requestId: "req-123")
        }
    }

    @Test func borrowMethodsWithoutEnrollThrowNotEnrolledWithoutNetworkCall() async throws {
        let identity = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        MockURLProtocol.setHandler(for: baseURL) { _, _ in
            Issue.record("network should not be called before enroll")
            throw URLError(.unknown)
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        await #expect(throws: RelayError.notEnrolled) {
            _ = try await client.requestBorrow(lenderId: "user-lender", hours: 2)
        }
        await #expect(throws: RelayError.notEnrolled) {
            _ = try await client.fetchInbox()
        }
        await #expect(throws: RelayError.notEnrolled) {
            try await client.decide(requestId: "req-123", approve: true, ciphertext: "abc")
        }
        await #expect(throws: RelayError.notEnrolled) {
            _ = try await client.pickup(requestId: "req-123")
        }
        await #expect(throws: RelayError.notEnrolled) {
            try await client.revoke(requestId: "req-123")
        }
    }
}
