import Testing
import Foundation
import CryptoKit
@testable import ClaudeUsageBarCore

/// Thread-safe box for recording the request/body intercepted by the
/// `@Sendable` handler registered via `MockURLProtocol.setHandler(for:_:)`, so
/// assertions can run after `await`ing the client call completes.
final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?
    private var _body: Data?

    var request: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _request
    }

    var body: Data? {
        lock.lock(); defer { lock.unlock() }
        return _body
    }

    func record(_ request: URLRequest, _ body: Data) {
        lock.lock(); defer { lock.unlock() }
        _request = request
        _body = body
    }
}

/// `.serialized` so tests within this suite don't race each other while
/// re-registering `MockURLProtocol`'s handler for `baseURL`. Other suites
/// (e.g. `RelayClientBorrowTests`) use a distinct `baseURL`, so `MockURLProtocol`
/// (keyed by base URL) can safely run concurrently with this one.
@Suite(.serialized)
struct RelayClientTests {
    let baseURL = URL(string: "http://localhost:9999")!

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbrelay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func makeIdentity() throws -> TeamIdentityStore {
        TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
    }

    /// Recomputes the canonical message from an intercepted request and
    /// verifies `X-Signature` against the identity's own signing public key —
    /// proves the client signs correctly with no network involved.
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

    @Test func enrollSignsRequestStoresUserIdAndOmitsUserIdHeader() async throws {
        let identity = try makeIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"userId":"user-123"}"#.utf8))
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        let userId = try await client.enroll(displayName: "Sanket")

        #expect(userId == "user-123")
        #expect(identity.loadOrNil()?.userId == "user-123")

        let request = try #require(captured.request)
        let body = try #require(captured.body)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/enroll")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == nil) // enroll is self-signed, no userId yet

        // Body carries the fields PROTOCOL.md requires for /enroll.
        let jsonAny = try JSONSerialization.jsonObject(with: body)
        let json = try #require(jsonAny as? [String: Any])
        #expect(json["displayName"] as? String == "Sanket")
        #expect(json["deviceId"] as? String == identity.loadOrNil()?.deviceId)
        #expect(json["signingPubKey"] as? String == (try identity.signingPublicKeyBase64()))
        #expect(json["encryptionPubKey"] as? String == (try identity.encryptionPublicKeyBase64()))

        try assertSignatureVerifies(request: request, body: body, method: "POST", path: "/enroll", identity: identity)
    }

    @Test func postUsageSendsAuthedSignedRequestAndSucceedsOn204() async throws {
        let identity = try makeIdentity()
        _ = try identity.create(displayName: "Sanket")
        try identity.setUserId("user-abc")
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        try await client.postUsage(
            fiveHourPct: 62.0, sevenDayPct: 20.0, resetAt: 1_893_456_000, availableToLend: true)

        let request = try #require(captured.request)
        let body = try #require(captured.body)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/usage")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-abc")
        #expect(request.value(forHTTPHeaderField: "X-Timestamp") != nil)
        #expect(request.value(forHTTPHeaderField: "X-Signature") != nil)

        let jsonAny = try JSONSerialization.jsonObject(with: body)
        let json = try #require(jsonAny as? [String: Any])
        #expect(json["fiveHourPct"] as? Double == 62.0)
        #expect(json["sevenDayPct"] as? Double == 20.0)
        #expect(json["resetAt"] as? Int == 1_893_456_000)
        #expect(json["availableToLend"] as? Bool == true)

        try assertSignatureVerifies(request: request, body: body, method: "POST", path: "/usage", identity: identity)
    }

    @Test func fetchBoardDecodesCannedArray() async throws {
        let identity = try makeIdentity()
        _ = try identity.create(displayName: "Sanket")
        try identity.setUserId("user-abc")
        let canned = """
        [
          {"userId":"user-abc","displayName":"Sanket","fiveHourPct":62.0,"sevenDayPct":20.0,
           "resetAt":1893456000,"availableToLend":true,"lastSeen":1893450000,"postedAt":1893450000},
          {"userId":"user-def","displayName":"Priya","fiveHourPct":null,"sevenDayPct":null,
           "resetAt":null,"availableToLend":null,"lastSeen":1893440000,"postedAt":null}
        ]
        """
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(canned.utf8))
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        let rows = try await client.fetchBoard()

        #expect(rows.count == 2)
        #expect(rows[0] == BoardRow(
            userId: "user-abc", displayName: "Sanket", fiveHourPct: 62.0, sevenDayPct: 20.0,
            resetAt: 1_893_456_000, availableToLend: true, lastSeen: 1_893_450_000, postedAt: 1_893_450_000))
        #expect(rows[1] == BoardRow(
            userId: "user-def", displayName: "Priya", fiveHourPct: nil, sevenDayPct: nil,
            resetAt: nil, availableToLend: nil, lastSeen: 1_893_440_000, postedAt: nil))

        let request = try #require(captured.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/board")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-abc")
        #expect((captured.body ?? Data()).isEmpty) // GET /board has an empty body

        try assertSignatureVerifies(
            request: request, body: captured.body ?? Data(), method: "GET", path: "/board", identity: identity)
    }

    @Test func nonTwoxxResponseThrowsHTTPError() async throws {
        let identity = try makeIdentity()
        _ = try identity.create(displayName: "Sanket")
        try identity.setUserId("user-abc")
        MockURLProtocol.setHandler(for: baseURL) { request, _ in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"bad signature"}"#.utf8))
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        do {
            _ = try await client.fetchBoard()
            Issue.record("expected RelayError.http to be thrown")
        } catch let error as RelayError {
            #expect(error == RelayError.http(status: 401, body: #"{"error":"bad signature"}"#))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func postUsageWithoutEnrollThrowsNotEnrolled() async throws {
        let identity = try makeIdentity()
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        do {
            try await client.postUsage(fiveHourPct: 1, sevenDayPct: 1, resetAt: nil, availableToLend: false)
            Issue.record("expected RelayError.notEnrolled to be thrown")
        } catch let error as RelayError {
            #expect(error == RelayError.notEnrolled)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func fetchBoardWithoutEnrollThrowsNotEnrolledWithoutNetworkCall() async throws {
        let identity = try makeIdentity()
        MockURLProtocol.setHandler(for: baseURL) { _, _ in
            Issue.record("network should not be called before enroll")
            throw URLError(.unknown)
        }
        let client = RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)

        do {
            _ = try await client.fetchBoard()
            Issue.record("expected RelayError.notEnrolled to be thrown")
        } catch let error as RelayError {
            #expect(error == RelayError.notEnrolled)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
