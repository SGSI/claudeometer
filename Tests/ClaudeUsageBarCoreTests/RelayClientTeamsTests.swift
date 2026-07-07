import Testing
import Foundation
import CryptoKit
@testable import ClaudeUsageBarCore

/// Team-endpoint client tests. Distinct `baseURL` from `RelayClientTests` so
/// `MockURLProtocol` (keyed by base URL) can run this suite concurrently.
@Suite(.serialized)
struct RelayClientTeamsTests {
    let baseURL = URL(string: "http://localhost:9997")!

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbteams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func enrolledIdentity() throws -> TeamIdentityStore {
        let identity = TeamIdentityStore(directory: try tempDir(), keyStore: InMemoryRawKeyStore())
        _ = try identity.create(displayName: "Sanket")
        try identity.setUserId("user-abc")
        return identity
    }

    func assertSignatureVerifies(request: URLRequest, body: Data, method: String, path: String, identity: TeamIdentityStore) throws {
        let timestamp = try #require(request.value(forHTTPHeaderField: "X-Timestamp"))
        let signatureB64 = try #require(request.value(forHTTPHeaderField: "X-Signature"))
        let signatureData = try #require(Data(base64Encoded: signatureB64))
        let message = RelaySigning.canonicalMessage(
            method: method, path: path, timestamp: timestamp,
            bodySHA256Hex: RelaySigning.bodySHA256Hex(body))
        let publicKeyData = try #require(Data(base64Encoded: try identity.signingPublicKeyBase64()))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        #expect(publicKey.isValidSignature(signatureData, for: message))
    }

    func client(_ identity: TeamIdentityStore) -> RelayClient {
        RelayClient(session: makeSession(), config: RelayConfig(baseURL: baseURL), identity: identity)
    }

    @Test func createTeamPostsBodyAndSignsPath() async throws {
        let identity = try enrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"name":"Growth"}"#.utf8))
        }
        try await client(identity).createTeam(name: "Growth", password: "pw", visibility: "public")

        let request = try #require(captured.request)
        let body = try #require(captured.body)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/teams")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-abc")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["name"] as? String == "Growth")
        #expect(json["password"] as? String == "pw")
        #expect(json["visibility"] as? String == "public")
        try assertSignatureVerifies(request: request, body: body, method: "POST", path: "/teams", identity: identity)
    }

    @Test func myTeamsDecodesWithRoles() async throws {
        let identity = try enrolledIdentity()
        MockURLProtocol.setHandler(for: baseURL) { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"[{"name":"KC-Tech","role":"owner"},{"name":"Growth","role":"member"}]"#.utf8))
        }
        let teams = try await client(identity).myTeams()
        #expect(teams == [TeamMembership(name: "KC-Tech", role: "owner"), TeamMembership(name: "Growth", role: "member")])
        #expect(teams[0].isOwner)
        #expect(!teams[1].isOwner)
    }

    @Test func listPublicTeamsDecodes() async throws {
        let identity = try enrolledIdentity()
        MockURLProtocol.setHandler(for: baseURL) { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"[{"name":"Growth","memberCount":3},{"name":"Ops","memberCount":1}]"#.utf8))
        }
        let teams = try await client(identity).listPublicTeams()
        #expect(teams == [TeamSummary(name: "Growth", memberCount: 3), TeamSummary(name: "Ops", memberCount: 1)])
    }

    @Test func joinTeamWithPasswordReturnsJoinedAndSignsDecodedPath() async throws {
        let identity = try enrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"status":"member"}"#.utf8))
        }
        let outcome = try await client(identity).joinTeam(name: "Growth", password: "pw")
        #expect(outcome == .joined)

        let request = try #require(captured.request)
        #expect(request.url?.path == "/teams/Growth/join")
        try assertSignatureVerifies(request: request, body: try #require(captured.body),
                                    method: "POST", path: "/teams/Growth/join", identity: identity)
    }

    @Test func joinTeamWithoutPasswordReturnsPending() async throws {
        let identity = try enrolledIdentity()
        MockURLProtocol.setHandler(for: baseURL) { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
             Data(#"{"status":"pending"}"#.utf8))
        }
        let outcome = try await client(identity).joinTeam(name: "Growth", password: nil)
        #expect(outcome == .pending)
    }

    @Test func leaveTeamSucceedsOn204() async throws {
        let identity = try enrolledIdentity()
        MockURLProtocol.setHandler(for: baseURL) { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await client(identity).leaveTeam(name: "Growth")
    }

    @Test func listJoinRequestsDecodes() async throws {
        let identity = try enrolledIdentity()
        MockURLProtocol.setHandler(for: baseURL) { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"[{"id":"jr1","userName":"Priya","createdAt":1893450000}]"#.utf8))
        }
        let reqs = try await client(identity).listJoinRequests(team: "Growth")
        #expect(reqs == [JoinRequestSummary(id: "jr1", userName: "Priya", createdAt: 1_893_450_000)])
    }

    @Test func decideJoinRequestPostsApproveAndSucceedsOn204() async throws {
        let identity = try enrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await client(identity).decideJoinRequest(team: "Growth", id: "jr1", approve: true)

        let request = try #require(captured.request)
        #expect(request.url?.path == "/teams/Growth/requests/jr1")
        let body = try #require(captured.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["approve"] as? Bool == true)
    }

    @Test func fetchBoardWithTeamAddsQuerySignsPathAndDecodesRedaction() async throws {
        let identity = try enrolledIdentity()
        let captured = CapturedRequest()
        MockURLProtocol.setHandler(for: baseURL) { request, body in
            captured.record(request, body)
            let canned = """
            [ {"userId":"user-abc","displayName":"Me","fiveHourPct":40.0,"sevenDayPct":10.0,
               "resetAt":null,"availableToLend":false,"lastSeen":1893450000,"postedAt":1893450000,
               "borrowingFrom":"another team","borrowingUntil":null,"lendingTo":[]} ]
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(canned.utf8))
        }
        let board = try await client(identity).fetchBoard(team: "tech")
        #expect(board.count == 1)
        #expect(board[0].borrowingFrom == "another team")
        #expect(board[0].borrowingUntil == nil)

        let request = try #require(captured.request)
        #expect(request.url?.path == "/board")
        let comps = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
        #expect(comps?.queryItems?.first(where: { $0.name == "team" })?.value == "tech")
        // Signature is over the path only, no query.
        try assertSignatureVerifies(request: request, body: try #require(captured.body),
                                    method: "GET", path: "/board", identity: identity)
    }
}
