import ClaudeUsageBarCore
import Foundation
import os

/// Thin `@MainActor` bridge between `ClaudeUsageBarCore`'s `RelayClient`/
/// `TeamIdentityStore` and the menu-bar UI. Holds no networking/crypto logic of
/// its own (that lives in the Core relay client) — just the enrollment state,
/// the cached team board, and an `onChange` hook so the UI can re-render.
@MainActor
final class TeamController {
    private let identity: TeamIdentityStore
    private let relay: RelayClient
    private let logger = Logger(subsystem: "Claudeometer", category: "TeamController")

    /// Cached copy of the last successful `/board` fetch. Left in place when a
    /// later refresh fails, so a flaky relay doesn't blank the team section.
    private(set) var board: [BoardRow] = []

    /// Called whenever `board` changes or enrollment completes, so the UI can re-render.
    var onChange: (() -> Void)?

    init() {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Claudeometer", isDirectory: true)
        let identity = TeamIdentityStore(directory: base, keyStore: KeychainRawKeyStore())
        self.identity = identity
        self.relay = RelayClient(identity: identity) // config: .default → the live relay
    }

    /// True once the local identity has been assigned a relay `userId`.
    var isEnrolled: Bool {
        identity.loadOrNil()?.userId != nil
    }

    /// This device's `userId`, once enrolled — used to mark the current user's own
    /// row in the team board.
    var userId: String? {
        identity.loadOrNil()?.userId
    }

    /// The locally-chosen display name, if a local identity exists yet (whether or
    /// not enrollment against the relay has completed).
    var displayName: String? {
        identity.loadOrNil()?.displayName
    }

    /// Loads whatever identity already exists and, if already enrolled, kicks off
    /// an initial board refresh. Never prompts for a name itself — the caller
    /// (`AppDelegate`) owns that UI and calls `enroll(name:)` explicitly.
    func start() {
        guard isEnrolled else { return }
        Task { [weak self] in
            await self?.refreshBoard()
        }
    }

    /// Enrolls this device with the relay under `name`. This is user-initiated
    /// (submitting the "join team" prompt), so failures are never swallowed:
    /// returns nil on success (board refreshed, `onChange` fired), or a
    /// user-facing error message on failure.
    func enroll(name: String) async -> String? {
        do {
            _ = try await relay.enroll(displayName: name)
            await refreshBoard()
            onChange?()
            return nil
        } catch {
            logger.error("enroll failed: \(String(describing: error), privacy: .public)")
            return Self.friendlyMessage(for: error)
        }
    }

    /// Best-effort usage post, run after every background usage refresh. Not
    /// user-initiated, so failures are logged and swallowed rather than surfaced —
    /// a missed post shouldn't interrupt the app.
    func postUsage(fiveHourPct: Double, sevenDayPct: Double, resetAt: Int?, availableToLend: Bool) async {
        guard isEnrolled else { return }
        do {
            try await relay.postUsage(
                fiveHourPct: fiveHourPct,
                sevenDayPct: sevenDayPct,
                resetAt: resetAt,
                availableToLend: availableToLend
            )
        } catch {
            logger.error("postUsage failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Best-effort board refresh. Failures are logged; the previous `board` is
    /// left in place so a flaky relay doesn't blank the team section.
    func refreshBoard() async {
        guard isEnrolled else { return }
        do {
            board = try await relay.fetchBoard()
            onChange?()
        } catch {
            logger.error("refreshBoard failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Heuristic for `postUsage`'s `availableToLend`: comfortably under half of
    /// the 5-hour window used means there's headroom to lend to a teammate.
    static func availableToLend(fiveHourPct: Double) -> Bool {
        fiveHourPct < 50
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
