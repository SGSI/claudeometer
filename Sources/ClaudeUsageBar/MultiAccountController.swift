import AppKit
import ClaudeUsageBarCore

/// Thin `@MainActor` bridge between `ClaudeUsageBarCore`'s `AccountManager` and the
/// menu-bar UI. Holds no business logic of its own — it caches the last-known
/// `AccountsFile` snapshot, schedules the auto-revert timer, and builds
/// `NSMenuItem`s from that cache.
@MainActor
final class MultiAccountController {
    private let manager: AccountManager
    private let detector = ClaudeProcessDetector()
    private var revertTimer: Timer?

    /// Cached copy of `manager.snapshot()`. Refreshed only on `reload()` (called
    /// from `start()` and after every mutation) so the 12fps status-image redraw
    /// never has to hit disk.
    private var state: AccountsFile = AccountsFile()

    /// Called whenever accounts or borrow state change, so the UI can re-render.
    var onChange: (() -> Void)?

    /// Outcome of attempting to switch to an account, so the caller can surface
    /// real failures instead of silently no-oping.
    enum SwitchOutcome {
        case switched(claudeRunning: Bool)
        case failed(String)
    }

    init() {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Claudeometer", isDirectory: true)
        self.manager = AccountManager(credentialStore: SecurityCLICredentialStore(),
                                      store: AccountStore(directory: base))
    }

    /// First-run self-capture and auto-revert scheduling.
    func start() {
        // TODO (M2): a crash between the Keychain overwrite and the accounts.json
        // save (see AccountManager.switchTo/revert) can leave a borrowed account
        // active with no badge and no auto-revert armed. start() should reconcile
        // on launch: compare the live Claude Code item's fingerprint against the
        // recorded self/borrow vault blobs and re-arm the revert if they disagree.
        if manager.snapshot().selfAccount == nil {
            // Capture whatever Claude Code is currently logged in as, as "Me".
            // Best-effort: the user may not have run `claude /login` yet, so this
            // is allowed to fail silently here — no alert on launch.
            _ = try? manager.captureCurrent(label: "Me", isSelf: true)
        }
        reload()
        scheduleRevert()
        onChange?()
    }

    /// Refreshes the cached snapshot from disk. Call after any mutation, before
    /// notifying `onChange`.
    private func reload() {
        state = manager.snapshot()
    }

    /// The menu-bar badge string, or nil when running on the self account. Reads
    /// the cached snapshot (no disk I/O) but still computes the live remaining
    /// time on every call so the countdown keeps ticking.
    var badge: (text: String, isBorrowing: Bool)? {
        guard let borrow = state.activeBorrow,
              let active = state.account(id: borrow.activeAccountId) else { return nil }
        let secs = Int(borrow.remaining(now: Date()))
        let text = "\u{2194} \(active.label) \(secs / 3600):" + String(format: "%02d", (secs % 3600) / 60)
        return (text, true)
    }

    /// True while a borrowed account is active locally. When this is false but
    /// the relay still lists one of our borrows as live, the borrow ended
    /// without the relay being told — `BorrowController.poll` uses this to
    /// revoke the stale borrow so the board's "borrowing from…" tag clears.
    var isBorrowing: Bool { state.activeBorrow != nil }

    /// Builds the account section for the `•••` menu, from the cached snapshot.
    func accountMenuItems(target: AnyObject) -> [NSMenuItem] {
        let file = state
        var items: [NSMenuItem] = []

        let header = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)

        for account in file.accounts {
            let active = file.activeBorrow?.activeAccountId == account.id
                || (file.activeBorrow == nil && account.isSelf)
            let item = NSMenuItem(title: account.label, action: #selector(AppDelegate.accountMenuTapped(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.state = active ? .on : .off
            item.representedObject = account.id.uuidString
            if !account.isSelf { item.submenu = durationSubmenu(for: account.id, target: target) }
            items.append(item)
        }

        let add = NSMenuItem(title: "Save current login as account…",
                             action: #selector(AppDelegate.saveCurrentAccountTapped), keyEquivalent: "")
        add.target = target
        items.append(add)

        if file.activeBorrow != nil, let me = file.selfAccount {
            let back = NSMenuItem(title: "Switch back to \(me.label)",
                                  action: #selector(AppDelegate.switchBackTapped), keyEquivalent: "")
            back.target = target
            items.append(back)
        }
        return items
    }

    private func durationSubmenu(for accountId: UUID, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        for seconds in BorrowDuration.presets {
            let mins = Int(seconds / 60)
            let title = mins % 60 == 0 ? "Use for \(mins / 60)h" : "Use for \(mins)m"
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.useAccountTapped(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = "\(accountId.uuidString)|\(Int(seconds))"
            menu.addItem(item)
        }
        return menu
    }

    // MARK: actions invoked by AppDelegate

    /// True when `id` is the self ("Me") account, per the cached snapshot. Lets
    /// the UI detect the self row explicitly instead of using badge-presence as
    /// a proxy.
    func isSelfAccount(id: UUID) -> Bool {
        state.selfAccount?.id == id
    }

    /// Attempts to snapshot the current Claude Code login as a new named account.
    /// Returns nil on success, or a user-facing error message on failure.
    func saveCurrentAccount(label: String) -> String? {
        do {
            _ = try manager.captureCurrent(label: label, isSelf: false)
            reload()
            onChange?()
            return nil
        } catch {
            return "No active Claude Code login found. Use the Login item to sign in first."
        }
    }

    /// Attempts to switch to `id` for `seconds`. Reports the real outcome instead
    /// of swallowing failures.
    func useAccount(id: UUID, seconds: TimeInterval) -> SwitchOutcome {
        if state.selfAccount == nil {
            // No self account captured yet (e.g. first switch attempt before any
            // successful `claude /login`). Try once more, lazily, so a self
            // account can still be established later in the session.
            _ = try? manager.captureCurrent(label: "Me", isSelf: true)
            reload()
        }
        do {
            try manager.switchTo(accountId: id, duration: seconds)
            reload()
            scheduleRevert()
            onChange?()
            return .switched(claudeRunning: detector.isClaudeRunning())
        } catch {
            return .failed(Self.friendlyMessage(for: error))
        }
    }

    /// Switches to a credential blob received via the M3 borrow handshake:
    /// imports it as a new vault account, then switches to it for `seconds`,
    /// arming the same auto-revert timer and menu-bar badge `useAccount`
    /// uses. This is the single path all borrowed-credential switching goes
    /// through — `BorrowController` holds no credential-switching logic of its
    /// own. Returns nil on success, or a user-facing error message on failure.
    func switchToBorrowed(label: String, blob: CredentialBlob, seconds: TimeInterval) -> String? {
        if state.selfAccount == nil {
            // Mirrors `useAccount`: no self account captured yet (e.g. before any
            // successful `claude /login`). Try once more, lazily.
            _ = try? manager.captureCurrent(label: "Me", isSelf: true)
            reload()
        }
        do {
            let account = try manager.importAccount(label: label, blob: blob)
            try manager.switchTo(accountId: account.id, duration: seconds)
            reload()
            scheduleRevert()
            onChange?()
            return nil
        } catch {
            return Self.friendlyMessage(for: error)
        }
    }

    func switchBack() {
        try? manager.revert()
        revertTimer?.invalidate()
        revertTimer = nil
        reload()
        onChange?()
    }

    func isClaudeRunning() -> Bool { detector.isClaudeRunning() }

    private func scheduleRevert() {
        revertTimer?.invalidate()
        guard let borrow = state.activeBorrow else { return }
        let delay = max(1, borrow.remaining(now: Date()))
        revertTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.switchBack()
            }
        }
    }

    /// Maps `AccountManager.ManagerError` to a friendlier, user-facing message;
    /// falls back to `localizedDescription` for anything else.
    private static func friendlyMessage(for error: Error) -> String {
        switch error {
        case AccountManager.ManagerError.noSelfAccount:
            return "No account captured yet. Use the Login item to sign in first, then try again."
        case AccountManager.ManagerError.accountNotFound:
            return "That account no longer exists. It may have been removed."
        case AccountManager.ManagerError.noActiveClaudeCredential:
            return "No active Claude Code login found. Use the Login item to sign in first."
        default:
            return error.localizedDescription
        }
    }
}
