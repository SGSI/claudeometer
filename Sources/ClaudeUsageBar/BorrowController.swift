import ClaudeUsageBarCore
import CryptoKit
import Foundation
import os

/// Thin `@MainActor` bridge between `ClaudeUsageBarCore`'s M3 borrow-handshake
/// (`RelayClient.requestBorrow/fetchInbox/decide/pickup/revoke`) and the
/// menu-bar UI. Builds its own `RelayClient` over the same on-device identity
/// `TeamController` uses (a `TeamIdentityStore` pointed at the same
/// AppSupport/Claudeometer directory + Keychain-backed `RawKeyStore` — the
/// identity is derived from persisted state, so there's no need to share a
/// live instance) and its own `SecurityCLICredentialStore` to read the
/// lender's live Claude Code blob when approving. All credential switching
/// on approval funnels through `MultiAccountController.switchToBorrowed` —
/// this class holds no Keychain-writing logic of its own.
@MainActor
final class BorrowController {
    private let identity: TeamIdentityStore
    private let relay: RelayClient
    private let credentialStore = SecurityCLICredentialStore()
    private let multiAccount: MultiAccountController
    private let logger = Logger(subsystem: "Claudeometer", category: "BorrowController")

    private var pollTimer: Timer?

    /// Outgoing request ids we've already run through `acceptApproved`, so a
    /// flaky pickup/switch doesn't get retried forever against a mailbox entry
    /// the relay has already deleted (`pickup` is one-shot per `relay/PROTOCOL.md`).
    private var acceptedRequestIds: Set<String> = []

    /// Cached copy of the last successful `/borrow/inbox` fetch. Left in place
    /// when a later refresh fails, so a flaky relay doesn't blank the section.
    private(set) var incoming: [IncomingRequest] = []
    private(set) var outgoing: [OutgoingRequest] = []

    /// Called whenever `incoming`/`outgoing` change, so the UI can re-render.
    var onChange: (() -> Void)?

    init(multiAccount: MultiAccountController) {
        self.multiAccount = multiAccount
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Claudeometer", isDirectory: true)
        let identity = TeamIdentityStore(directory: base, keyStore: KeychainRawKeyStore())
        self.identity = identity
        self.relay = RelayClient(identity: identity) // config: .default → the live relay
    }

    /// True once the local identity has been assigned a relay `userId` —
    /// mirrors `TeamController.isEnrolled`; polling only makes sense once enrolled.
    private var isEnrolled: Bool {
        identity.loadOrNil()?.userId != nil
    }

    /// Starts an ~8s polling timer once enrolled. No-op if not enrolled yet —
    /// call again once enrollment completes (mirrors `TeamController.start()`).
    func start() {
        guard isEnrolled else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
    }

    /// Best-effort inbox refresh: fetches `/borrow/inbox`, updates
    /// `incoming`/`outgoing`, auto-accepts any newly-approved outgoing
    /// request, then notifies `onChange`. Not user-initiated, so failures are
    /// logged and swallowed rather than surfaced.
    func poll() async {
        guard isEnrolled else { return }
        do {
            let inbox = try await relay.fetchInbox()
            incoming = inbox.incoming
            outgoing = inbox.outgoing
            for request in inbox.outgoing
            where request.status == "approved" && !acceptedRequestIds.contains(request.requestId) {
                await acceptApproved(request)
            }
            // Reconcile early reverts: the app reverts a borrow locally (auto-revert
            // timer or manual "switch back") without notifying the relay, so a
            // reverted borrow lingers as `picked_up` within its window and the board
            // keeps showing "borrowing from …". If we're no longer on a borrowed
            // account, revoke any still-live borrow so the relay (and board) clear.
            // Also covers a pickup that succeeded but whose local switch failed.
            if !multiAccount.isBorrowing {
                for request in inbox.outgoing where request.status == "picked_up" {
                    try? await relay.revoke(requestId: request.requestId)
                }
            }
            onChange?()
        } catch {
            logger.error("poll failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Requests to borrow `hours` from `lenderId`. User-initiated, so failures
    /// are surfaced instead of swallowed. Returns nil on success (inbox
    /// refreshed, `onChange` fired), or a user-facing error message on failure.
    func request(lenderId: String, hours: Int) async -> String? {
        do {
            _ = try await relay.requestBorrow(lenderId: lenderId, hours: hours)
            await poll()
            return nil
        } catch {
            logger.error("request failed: \(String(describing: error), privacy: .public)")
            return Self.friendlyMessage(for: error)
        }
    }

    /// Approves an incoming borrow request: reads the lender's OWN credential
    /// blob, seals it to the requester's encryption public key, and relays the
    /// approval. User-initiated, so failures are surfaced.
    ///
    /// The blob must come from the self vault item, not the live Claude Code
    /// item: while *we* are borrowing, the live item holds a third party's
    /// credential, and lending that on would hand their Claude login to the
    /// requester without their consent. `ownUsageService` resolves to the self
    /// item exactly when a borrow is active.
    func approve(_ req: IncomingRequest) async -> String? {
        do {
            let ownService = multiAccount.ownUsageService(
                claudeCodeService: ClaudeometerConstants.claudeCodeKeychainService
            )
            guard let blob = try credentialStore.read(service: ownService) else {
                return "No active Claude login to lend."
            }
            let sealed = try BorrowCrypto.seal(blob.raw, toRecipientPublicKeyBase64: req.requesterEncryptionPubKey)
            try await relay.decide(requestId: req.requestId, approve: true, ciphertext: sealed)
            await poll()
            return nil
        } catch {
            logger.error("approve failed: \(String(describing: error), privacy: .public)")
            return Self.friendlyMessage(for: error)
        }
    }

    /// Rejects an incoming borrow request. User-initiated, so failures are surfaced.
    func reject(_ req: IncomingRequest) async -> String? {
        do {
            try await relay.decide(requestId: req.requestId, approve: false, ciphertext: nil)
            await poll()
            return nil
        } catch {
            logger.error("reject failed: \(String(describing: error), privacy: .public)")
            return Self.friendlyMessage(for: error)
        }
    }

    /// Revokes a request (caller may be either its lender or requester), then
    /// refreshes the inbox. Best-effort: failures are logged, not surfaced —
    /// mirrors the "keep it simple" cancel affordance in the UI.
    func revoke(requestId: String) async {
        do {
            try await relay.revoke(requestId: requestId)
        } catch {
            logger.error("revoke failed: \(String(describing: error), privacy: .public)")
        }
        await poll()
    }

    /// Picks up the sealed credential blob for a newly-approved outgoing
    /// request, decrypts it, and switches to it via
    /// `MultiAccountController.switchToBorrowed` — which owns the borrowed
    /// badge + auto-revert. Best-effort: this runs from the background poll
    /// loop (not a user tap), so failures are logged, not surfaced.
    private func acceptApproved(_ req: OutgoingRequest) async {
        do {
            // pickup is one-shot on the relay, so mark accepted only AFTER it
            // succeeds — a transient (pre-consumption) network failure is then
            // retried on the next poll instead of silently dropping the borrow.
            let ciphertext = try await relay.pickup(requestId: req.requestId)
            acceptedRequestIds.insert(req.requestId)
            let key = try identity.encryptionKey()
            let plaintext = try BorrowCrypto.open(ciphertext, with: key)
            let blob = CredentialBlob(raw: plaintext)
            if let error = multiAccount.switchToBorrowed(
                label: "\(req.lenderName) (borrowed)",
                blob: blob,
                seconds: TimeInterval(req.hours) * 3600
            ) {
                logger.error("switchToBorrowed failed: \(error, privacy: .public)")
            }
        } catch {
            // 404/409 → the mailbox is already gone (consumed or expired):
            // nothing to retry, so stop re-attempting. Anything else is
            // transient — leave it unaccepted so the next poll retries.
            if case RelayError.http(let status, _) = error, status == 404 || status == 409 {
                acceptedRequestIds.insert(req.requestId)
                logger.error("acceptApproved: mailbox gone (HTTP \(status)) for \(req.requestId, privacy: .public)")
            } else {
                logger.error("acceptApproved transient failure (will retry): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        switch error {
        case RelayError.http(let status, let body):
            return "The relay returned an error (HTTP \(status)). \(body)"
        case RelayError.decode:
            return "Couldn't understand the relay's response. Please try again."
        case RelayError.notEnrolled:
            return "Not enrolled yet — please try again."
        default:
            return error.localizedDescription
        }
    }
}
