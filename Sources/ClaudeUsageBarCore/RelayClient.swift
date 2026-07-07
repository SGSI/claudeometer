import Foundation
import CryptoKit

/// Endpoint configuration for the Claudeometer relay.
///
/// The relay URL is intentionally NOT hardcoded in this (public) repo. It is
/// resolved from local, non-committed config so a fork/clone never points at
/// anyone's private relay. Set it via either:
///   • the `CLAUDEOMETER_RELAY_URL` environment variable, or
///   • a one-line file at `~/Library/Application Support/Claudeometer/relay-url`.
public struct RelayConfig: Sendable {
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Resolves the relay URL from local config (env first, then the file), or
    /// nil when the team relay hasn't been configured on this machine.
    public static func resolve() -> RelayConfig? {
        if let env = ProcessInfo.processInfo.environment["CLAUDEOMETER_RELAY_URL"],
           let url = validURL(env) {
            return RelayConfig(baseURL: url)
        }
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let file = base.appendingPathComponent("Claudeometer/relay-url")
            if let text = try? String(contentsOf: file, encoding: .utf8), let url = validURL(text) {
                return RelayConfig(baseURL: url)
            }
        }
        return nil
    }

    /// Whether a relay URL is configured locally (i.e. team features are usable).
    public static var isConfigured: Bool { resolve() != nil }

    /// The resolved relay, or a harmless localhost placeholder when unconfigured
    /// (so team calls simply fail locally rather than reaching a stranger's relay).
    public static var `default`: RelayConfig {
        resolve() ?? RelayConfig(baseURL: URL(string: "http://localhost:8080")!)
    }

    private static func validURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        return url
    }
}

/// One row of `GET /board`, matching `relay/PROTOCOL.md` exactly. Usage
/// fields are nil until the user has posted at least once.
public struct BoardRow: Codable, Equatable, Sendable {
    public let userId: String
    public let displayName: String
    public let fiveHourPct: Double?
    public let sevenDayPct: Double?
    public let resetAt: Int?
    public let availableToLend: Bool?
    public let lastSeen: Int
    public let postedAt: Int?
    /// Active-borrow visibility (relay v0.2.1+); nil/absent on older relays.
    public let borrowingFrom: String?   // whom this user is currently borrowing from
    public let borrowingUntil: Int?     // unix time that borrow window ends
    public let lendingTo: [String]?     // display names this user is currently lending to

    public init(
        userId: String,
        displayName: String,
        fiveHourPct: Double?,
        sevenDayPct: Double?,
        resetAt: Int?,
        availableToLend: Bool?,
        lastSeen: Int,
        postedAt: Int?,
        borrowingFrom: String? = nil,
        borrowingUntil: Int? = nil,
        lendingTo: [String]? = nil
    ) {
        self.userId = userId
        self.displayName = displayName
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.resetAt = resetAt
        self.availableToLend = availableToLend
        self.lastSeen = lastSeen
        self.postedAt = postedAt
        self.borrowingFrom = borrowingFrom
        self.borrowingUntil = borrowingUntil
        self.lendingTo = lendingTo
    }
}

/// One entry of `GET /borrow/inbox`'s `incoming` array: a pending request
/// where the caller is the lender, matching `relay/PROTOCOL.md` exactly.
/// Includes the requester's encryption public key so the lender can seal the
/// credential blob to it.
public struct IncomingRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let requesterId: String
    public let requesterName: String
    public let requesterEncryptionPubKey: String
    public let hours: Int
    public let createdAt: Int

    public init(
        requestId: String,
        requesterId: String,
        requesterName: String,
        requesterEncryptionPubKey: String,
        hours: Int,
        createdAt: Int
    ) {
        self.requestId = requestId
        self.requesterId = requesterId
        self.requesterName = requesterName
        self.requesterEncryptionPubKey = requesterEncryptionPubKey
        self.hours = hours
        self.createdAt = createdAt
    }
}

/// One entry of `GET /borrow/inbox`'s `outgoing` array: one of the caller's
/// own requests and its current status.
public struct OutgoingRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let lenderId: String
    public let lenderName: String
    public let hours: Int
    public let status: String
    public let decidedAt: Int?

    public init(
        requestId: String,
        lenderId: String,
        lenderName: String,
        hours: Int,
        status: String,
        decidedAt: Int?
    ) {
        self.requestId = requestId
        self.lenderId = lenderId
        self.lenderName = lenderName
        self.hours = hours
        self.status = status
        self.decidedAt = decidedAt
    }
}

/// One of the caller's own team memberships, from `GET /my-teams` — used to
/// populate the client's team switcher (includes teams joined server-side).
public struct TeamMembership: Codable, Equatable, Sendable {
    public let name: String
    public let role: String

    public init(name: String, role: String) {
        self.name = name
        self.role = role
    }

    /// Whether the caller owns this team (can approve joins, manage members).
    public var isOwner: Bool { role == "owner" }
}

/// One entry of `GET /teams`'s public-team discovery list.
public struct TeamSummary: Codable, Equatable, Sendable {
    public let name: String
    public let memberCount: Int

    public init(name: String, memberCount: Int) {
        self.name = name
        self.memberCount = memberCount
    }
}

/// One pending ask-to-join, as returned by `GET /teams/{name}/requests`.
public struct JoinRequestSummary: Codable, Equatable, Sendable {
    public let id: String
    public let userName: String
    public let createdAt: Int

    public init(id: String, userName: String, createdAt: Int) {
        self.id = id
        self.userName = userName
        self.createdAt = createdAt
    }
}

/// The result of a `POST /teams/{name}/join`: either joined immediately (correct
/// password) or a pending ask-to-join awaiting owner approval.
public enum JoinOutcome: Equatable, Sendable {
    case joined
    case pending
}

/// `GET /borrow/inbox` response body.
public struct BorrowInbox: Codable, Equatable, Sendable {
    public let incoming: [IncomingRequest]
    public let outgoing: [OutgoingRequest]

    public init(incoming: [IncomingRequest], outgoing: [OutgoingRequest]) {
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

/// Errors surfaced by `RelayClient`.
public enum RelayError: Error, Equatable {
    /// No enrolled `userId` yet — call `enroll` first.
    case notEnrolled
    /// The relay responded with an unexpected HTTP status.
    case http(status: Int, body: String)
    /// The response body didn't decode into the expected type.
    case decode
}

/// Talks to the Go relay over HTTP, signing every request per
/// `relay/PROTOCOL.md`. The encryption keypair is registered but unused here
/// (reserved for M3).
public struct RelayClient: Sendable {
    private let session: URLSession
    private let config: RelayConfig
    private let now: @Sendable () -> Date
    private let identity: TeamIdentityStore

    public init(
        session: URLSession = .shared,
        config: RelayConfig = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        identity: TeamIdentityStore
    ) {
        self.session = session
        self.config = config
        self.now = now
        self.identity = identity
    }

    /// Ensures a local identity exists (creating one if needed), then
    /// registers it with the relay. Idempotent on the relay side for the same
    /// device + signing key. Persists and returns the assigned `userId`.
    @discardableResult
    public func enroll(displayName: String) async throws -> String {
        let profile = try identity.loadOrNil() ?? identity.create(displayName: displayName)
        let body = EnrollRequestBody(
            displayName: profile.displayName,
            signingPubKey: try identity.signingPublicKeyBase64(),
            encryptionPubKey: try identity.encryptionPublicKeyBase64(),
            deviceId: profile.deviceId
        )
        let bodyData = try JSONEncoder().encode(body)
        let request = try signedRequest(method: "POST", path: "/enroll", body: bodyData, userId: nil)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        let decoded = try Self.decode(EnrollResponseBody.self, from: data)
        try identity.setUserId(decoded.userId)
        return decoded.userId
    }

    /// Upserts the caller's usage snapshot. Requires a prior `enroll`.
    public func postUsage(
        fiveHourPct: Double,
        sevenDayPct: Double,
        resetAt: Int?,
        availableToLend: Bool
    ) async throws {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let body = UsageRequestBody(
            fiveHourPct: fiveHourPct,
            sevenDayPct: sevenDayPct,
            resetAt: resetAt,
            availableToLend: availableToLend
        )
        let bodyData = try JSONEncoder().encode(body)
        let request = try signedRequest(method: "POST", path: "/usage", body: bodyData, userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 204)
    }

    /// Fetches the board. With `team` nil, returns the union of the caller's
    /// teams; with a team name, that team's board (caller must be a member).
    /// Requires a prior `enroll`.
    public func fetchBoard(team: String? = nil) async throws -> [BoardRow] {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let query = team.map { [URLQueryItem(name: "team", value: $0)] } ?? []
        let request = try signedRequest(method: "GET", path: "/board", body: Data(), userId: userId, query: query)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        return try Self.decode([BoardRow].self, from: data)
    }

    /// Creates a team owned by the caller. Requires a prior `enroll`.
    public func createTeam(name: String, password: String, visibility: String) async throws {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let body = try JSONEncoder().encode(CreateTeamBody(name: name, password: password, visibility: visibility))
        let request = try signedRequest(method: "POST", path: "/teams", body: body, userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
    }

    /// Lists the caller's own team memberships (name + role). Requires a prior `enroll`.
    public func myTeams() async throws -> [TeamMembership] {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let request = try signedRequest(method: "GET", path: "/my-teams", body: Data(), userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        return try Self.decode([TeamMembership].self, from: data)
    }

    /// Lists public teams for discovery. Requires a prior `enroll`.
    public func listPublicTeams() async throws -> [TeamSummary] {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let request = try signedRequest(method: "GET", path: "/teams", body: Data(), userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        return try Self.decode([TeamSummary].self, from: data)
    }

    /// Joins a team: a correct password joins immediately (`.joined`); a public
    /// team without/with a wrong password records an ask-to-join (`.pending`).
    /// Requires a prior `enroll`.
    public func joinTeam(name: String, password: String?) async throws -> JoinOutcome {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let body = try JSONEncoder().encode(JoinTeamBody(password: password ?? ""))
        let request = try signedRequest(method: "POST", path: "/teams/\(name)/join", body: body, userId: userId)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.decode }
        switch http.statusCode {
        case 200: return .joined
        case 202: return .pending
        default: throw RelayError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }

    /// Leaves a team (an emptied team is deleted server-side). Requires a prior `enroll`.
    public func leaveTeam(name: String) async throws {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let request = try signedRequest(method: "POST", path: "/teams/\(name)/leave", body: Data(), userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 204)
    }

    /// Lists a team's pending ask-to-join requests. Caller must be the owner.
    /// Requires a prior `enroll`.
    public func listJoinRequests(team: String) async throws -> [JoinRequestSummary] {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let request = try signedRequest(method: "GET", path: "/teams/\(team)/requests", body: Data(), userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        return try Self.decode([JoinRequestSummary].self, from: data)
    }

    /// Approves or rejects a pending join request. Caller must be the owner.
    /// Requires a prior `enroll`.
    public func decideJoinRequest(team: String, id: String, approve: Bool) async throws {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let body = try JSONEncoder().encode(DecideJoinBody(approve: approve))
        let request = try signedRequest(method: "POST", path: "/teams/\(team)/requests/\(id)", body: body, userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 204)
    }

    /// Requests to borrow `hours` from `lenderId`. Requires a prior `enroll`.
    /// `1...4` per `relay/PROTOCOL.md`; validation is server-side.
    @discardableResult
    public func requestBorrow(lenderId: String, hours: Int) async throws -> String {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let body = BorrowRequestBody(lenderId: lenderId, hours: hours)
        let bodyData = try JSONEncoder().encode(body)
        let request = try signedRequest(method: "POST", path: "/borrow/request", body: bodyData, userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        let decoded = try Self.decode(BorrowRequestResponseBody.self, from: data)
        return decoded.requestId
    }

    /// Fetches the requests addressed to the caller — pending requests where
    /// the caller is the lender (`incoming`) and the caller's own requests
    /// (`outgoing`). Requires a prior `enroll`.
    public func fetchInbox() async throws -> BorrowInbox {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let request = try signedRequest(method: "GET", path: "/borrow/inbox", body: Data(), userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        return try Self.decode(BorrowInbox.self, from: data)
    }

    /// Approves or rejects an incoming request. The caller must be the
    /// request's lender. `ciphertext` is the sealed credential blob (see
    /// `BorrowCrypto.seal`) and is required on approve; pass `nil` on reject.
    /// Requires a prior `enroll`.
    public func decide(requestId: String, approve: Bool, ciphertext: String?) async throws {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let body = BorrowDecisionRequestBody(requestId: requestId, approve: approve, ciphertext: ciphertext)
        let bodyData = try JSONEncoder().encode(body)
        let request = try signedRequest(method: "POST", path: "/borrow/decision", body: bodyData, userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 204)
    }

    /// Retrieves the sealed credential blob for an approved request. The
    /// caller must be the requester; this is a one-shot read — the relay
    /// deletes the mailbox entry after returning it. The request id is a path
    /// segment, so it is covered by the request signature. Requires a prior
    /// `enroll`.
    public func pickup(requestId: String) async throws -> String {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let path = "/borrow/pickup/\(requestId)"
        let request = try signedRequest(method: "GET", path: path, body: Data(), userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 200)
        let decoded = try Self.decode(BorrowPickupResponseBody.self, from: data)
        return decoded.ciphertext
    }

    /// Revokes a request. The caller must be the request's lender or
    /// requester. Requires a prior `enroll`.
    public func revoke(requestId: String) async throws {
        guard let userId = identity.loadOrNil()?.userId else { throw RelayError.notEnrolled }
        let body = BorrowRevokeRequestBody(requestId: requestId)
        let bodyData = try JSONEncoder().encode(body)
        let request = try signedRequest(method: "POST", path: "/borrow/revoke", body: bodyData, userId: userId)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, expect: 204)
    }

    /// Builds a `URLRequest` carrying the canonical signature headers from
    /// `relay/PROTOCOL.md`: `X-Timestamp`, `X-Signature`, and (when `userId`
    /// is non-nil) `X-User-Id`.
    private func signedRequest(method: String, path: String, body: Data, userId: String?, query: [URLQueryItem] = []) throws -> URLRequest {
        var url = config.baseURL.appendingPathComponent(path)
        // The signature covers the path only (per PROTOCOL.md); the query is
        // attached to the URL but not signed. Server-side authorization
        // (membership checks) guards what the query can select.
        if !query.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            if let withQuery = comps.url { url = withQuery }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let timestamp = String(Int(now().timeIntervalSince1970))
        let bodyHash = RelaySigning.bodySHA256Hex(body)
        let message = RelaySigning.canonicalMessage(
            method: method, path: path, timestamp: timestamp, bodySHA256Hex: bodyHash)
        let signature = try RelaySigning.signatureBase64(message: message, signingKey: identity.signingKey())
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        if let userId {
            request.setValue(userId, forHTTPHeaderField: "X-User-Id")
        }
        return request
    }

    private static func checkStatus(_ response: URLResponse, data: Data, expect: Int) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == expect else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RelayError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RelayError.decode
        }
    }
}

private struct EnrollRequestBody: Encodable {
    let displayName: String
    let signingPubKey: String
    let encryptionPubKey: String
    let deviceId: String
}

private struct EnrollResponseBody: Decodable {
    let userId: String
}

private struct UsageRequestBody: Encodable {
    let fiveHourPct: Double
    let sevenDayPct: Double
    let resetAt: Int?
    let availableToLend: Bool
}

private struct BorrowRequestBody: Encodable {
    let lenderId: String
    let hours: Int
}

private struct BorrowRequestResponseBody: Decodable {
    let requestId: String
}

private struct BorrowDecisionRequestBody: Encodable {
    let requestId: String
    let approve: Bool
    let ciphertext: String?
}

private struct BorrowPickupResponseBody: Decodable {
    let ciphertext: String
}

private struct BorrowRevokeRequestBody: Encodable {
    let requestId: String
}

private struct CreateTeamBody: Encodable {
    let name: String
    let password: String
    let visibility: String
}

private struct JoinTeamBody: Encodable {
    let password: String
}

private struct DecideJoinBody: Encodable {
    let approve: Bool
}
