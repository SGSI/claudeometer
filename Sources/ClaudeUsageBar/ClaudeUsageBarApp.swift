import AppKit
import ClaudeUsageBarCore
import Foundation
import UserNotifications

private let keychainService = ClaudeometerConstants.claudeCodeKeychainService
private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
private let settingsURL = URL(string: "https://claude.ai/settings/usage")!

/// Which page of the popover is currently showing. This is the single piece of
/// navigation state for the popover; it lives on `AppDelegate` (the owner of
/// `popover`/`renderPopover`) and `UsagePanelView` just renders whichever page
/// it's told to, rebuilding from scratch on every render like the rest of the panel.
enum PopoverPage {
    case main
    case team
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var popoverPage: PopoverPage = .main
    private let fetcher = ClaudeUsageFetcher()
    private var snapshot: UsageSnapshot?
    private var hotSessions: [LocalSessionSummary] = []
    private var statusMessage: String?
    private var timer: Timer?
    private var blinkTimer: Timer?
    private var iconTimer: Timer?
    private var markPhase: CGFloat = 0
    private var currentTitle = "..."
    private var currentColor = NSColor.secondaryLabelColor
    private var eventMonitor: Any?
    private var localKeyMonitor: Any?
    private var blinkOn = false
    private var notifiedWindowKey: String?
    private var firedThresholds: Set<Int> = []
    private var nextAutomaticRefreshAt = Date.distantPast
    private var rateLimitedUntil: Date?
    private let multiAccount = MultiAccountController()
    private let teamController = TeamController()
    private lazy var borrowController = BorrowController(multiAccount: multiAccount)
    private var notifiedIncomingBorrowIds: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let initialImage = makeStatusImage(text: "...", color: .systemBlue, phase: 0)
        statusItem = NSStatusBar.system.statusItem(withLength: initialImage.size.width + 8)
        statusItem.button?.image = initialImage
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        NSLog("ClaudeUsageBar status item created; button exists: \(statusItem.button != nil)")
        setTitle("...", color: .secondaryLabelColor)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 620)
        renderPopover(status: "Loading...")

        UsageHistoryStore.prune(now: Date())
        refresh()
        multiAccount.onChange = { [weak self] in
            Task { @MainActor in
                self?.renderPopover(status: self?.statusMessage)
                self?.renderStatusImage()
            }
        }
        multiAccount.start()
        teamController.onChange = { [weak self] in
            Task { @MainActor in
                self?.renderPopover(status: self?.statusMessage)
            }
        }
        teamController.start()
        borrowController.onChange = { [weak self] in
            Task { @MainActor in
                self?.notifyNewIncomingBorrowRequests()
                self?.renderPopover(status: self?.statusMessage)
            }
        }
        if teamController.isEnrolled {
            borrowController.start()
        } else {
            promptJoinTeam()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIfDue()
            }
        }
        // Gently animate (shimmer) the menu-bar Claude mark, ~12fps.
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.markPhase += 1.0 / 12.0
                self.renderStatusImage()
            }
        }
    }

    private func refreshIfDue() {
        let now = Date()
        if let rateLimitedUntil, now < rateLimitedUntil {
            return
        }
        guard now >= nextAutomaticRefreshAt else {
            return
        }
        refresh()
    }

    private func refresh() {
        Task {
            do {
                let snapshot = try await fetcher.fetch()
                self.snapshot = snapshot
                UsageHistoryStore.append(
                    fiveHour: snapshot.usage.fiveHour?.utilization ?? 0,
                    sevenDay: snapshot.usage.sevenDay?.utilization ?? 0,
                    now: Date()
                )
                self.statusMessage = nil
                self.rateLimitedUntil = nil
                self.nextAutomaticRefreshAt = Date().addingTimeInterval(self.pollInterval(for: snapshot))
                self.apply(snapshot)
                Task {
                    let localSessions = await LocalSessionAnalyzer.topSessions()
                    self.hotSessions = localSessions
                    self.renderPopover(status: self.statusMessage)
                }
                Task {
                    await self.postUsageToTeam(snapshot)
                }
            } catch {
                self.handleRefreshError(error)
            }
        }
    }

    private func handleRefreshError(_ error: Error) {
        if case UsageError.http(let status, _, let retryAfter) = error, status == 429 {
            let wait = max(TimeInterval(retryAfter ?? 0), 10 * 60)
            rateLimitedUntil = Date().addingTimeInterval(wait)
            nextAutomaticRefreshAt = rateLimitedUntil ?? Date().addingTimeInterval(wait)
            statusMessage = snapshot == nil ? "Claude is busy. Retrying \(resetText(nextAutomaticRefreshAt))." : nil
            renderPopover(status: statusMessage)
            return
        }

        statusMessage = error.localizedDescription
        if snapshot == nil {
            stopBlinking()
            setTitle("!", color: .systemRed)
        }
        renderPopover(status: statusMessage)
    }

    private func pollInterval(for snapshot: UsageSnapshot) -> TimeInterval {
        let utilization = snapshot.usage.fiveHour?.utilization ?? 0
        if utilization >= 90 { return 3 * 60 }
        if utilization >= 80 { return 4 * 60 }
        return 5 * 60
    }

    /// Maps a fetched `UsageSnapshot` to the relay's usage shape and posts it
    /// (best-effort — `TeamController.postUsage` logs and swallows failures),
    /// then refreshes the team board. No-ops entirely when not enrolled.
    private func postUsageToTeam(_ snapshot: UsageSnapshot) async {
        let fiveHourPct = snapshot.usage.fiveHour?.utilization ?? 0
        let sevenDayPct = snapshot.usage.sevenDay?.utilization ?? 0
        let resetAt = snapshot.usage.fiveHour?.resetsAt.map { Int($0.timeIntervalSince1970) }
        await teamController.postUsage(
            fiveHourPct: fiveHourPct,
            sevenDayPct: sevenDayPct,
            resetAt: resetAt,
            availableToLend: TeamController.availableToLend(fiveHourPct: fiveHourPct)
        )
        await teamController.refreshBoard()
    }

    private func apply(_ snapshot: UsageSnapshot) {
        let fiveHour = snapshot.usage.fiveHour?.utilization
        let weekly = snapshot.usage.sevenDay?.utilization
        let title = titleText(fiveHour: fiveHour, weekly: weekly)
        let color = color(for: fiveHour ?? weekly ?? 0)

        if (fiveHour ?? 0) >= 90 && (fiveHour ?? 0) < 100 {
            startBlinking(title: title)
        } else {
            stopBlinking()
            setTitle(title, color: color)
        }

        evaluateNotifications(snapshot)
        renderPopover(status: nil)
    }

    private func titleText(fiveHour: Double?, weekly: Double?) -> String {
        switch (fiveHour, weekly) {
        case let (.some(five), .some(_)):
            return formatPercent(five)
        case let (.some(five), .none):
            return formatPercent(five)
        case let (.none, .some(week)):
            return "7d \(formatPercent(week))"
        default:
            return "-"
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
            return
        }
        popoverPage = .main
        renderPopover(status: statusMessage)
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startPopoverEventMonitor()
        }
    }

    private func startPopoverEventMonitor() {
        if eventMonitor != nil { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if event.type == .keyDown && event.keyCode != 53 {
                    return
                }
                self.closePopover()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode != 53 {
                return event
            }
            Task { @MainActor in
                self?.closePopover()
            }
            return nil
        }
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func renderPopover(status: String?) {
        let fiveHourUtil = snapshot?.usage.fiveHour?.utilization ?? 0
        let accent = color(for: fiveHourUtil)
        let history = UsageHistoryStore.load()

        let panel = UsagePanelView(
            snapshot: snapshot,
            hotSessions: hotSessions,
            status: status,
            accent: accent,
            history: history,
            page: popoverPage,
            onRefresh: { [weak self] in self?.refresh() },
            onOpenSettings: { NSWorkspace.shared.open(settingsURL) },
            onLogin: { Self.openClaudeLogin() },
            onQuit: { NSApp.terminate(nil) },
            accountItems: multiAccount.accountMenuItems(target: self),
            teamBoard: teamController.board,
            selfUserId: teamController.userId,
            isTeamEnrolled: teamController.isEnrolled,
            onJoinTeam: { [weak self] in self?.promptJoinTeam() },
            onSetTeamRelayURL: { [weak self] in self?.promptSetTeamRelayURL() },
            onNavigateToTeam: { [weak self] in
                guard let self else { return }
                self.popoverPage = .team
                self.renderPopover(status: self.statusMessage)
            },
            onNavigateBack: { [weak self] in
                guard let self else { return }
                self.popoverPage = .main
                self.renderPopover(status: self.statusMessage)
            },
            incomingRequests: borrowController.incoming,
            outgoingRequests: borrowController.outgoing,
            onRequestBorrow: { [weak self] lenderId in
                Task { @MainActor in
                    if let error = await self?.borrowController.request(lenderId: lenderId, hours: 2) {
                        self?.showErrorAlert(title: "Couldn't send request", message: error)
                    }
                }
            },
            onApproveBorrow: { [weak self] request in
                Task { @MainActor in
                    if let error = await self?.borrowController.approve(request) {
                        self?.showErrorAlert(title: "Couldn't approve", message: error)
                    }
                }
            },
            onRejectBorrow: { [weak self] request in
                Task { @MainActor in
                    if let error = await self?.borrowController.reject(request) {
                        self?.showErrorAlert(title: "Couldn't reject", message: error)
                    }
                }
            },
            onCancelOutgoingBorrow: { [weak self] requestId in
                Task { @MainActor in
                    await self?.borrowController.revoke(requestId: requestId)
                }
            }
        )
        panel.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            panel.topAnchor.constraint(equalTo: effect.topAnchor),
            panel.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            effect.widthAnchor.constraint(equalToConstant: 340)
        ])
        effect.layoutSubtreeIfNeeded()

        let controller = NSViewController()
        controller.view = effect
        popover.contentViewController = controller

        let fittingHeight = min(max(effect.fittingSize.height, 1), 760)
        popover.contentSize = NSSize(width: 340, height: fittingHeight)
    }

    private func startBlinking(title: String) {
        if blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.setTitle(title, color: self.blinkOn ? .systemRed : .controlBackgroundColor)
                }
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = false
    }

    // Graduated 5-hour-window alerts. Each threshold fires at most once per window;
    // the fired set resets when the window rolls over (its resetsAt key changes).
    private static let notificationThresholds = [50, 75, 90, 100]

    private func evaluateNotifications(_ snapshot: UsageSnapshot) {
        guard let window = snapshot.usage.fiveHour else { return }
        let key = window.resetsAt?.description ?? "current"
        if notifiedWindowKey != key {
            notifiedWindowKey = key
            firedThresholds = []
        }

        let crossed = Self.notificationThresholds.filter { Double($0) <= window.utilization }
        let newlyCrossed = crossed.filter { !firedThresholds.contains($0) }
        guard let tier = newlyCrossed.max() else { return }
        firedThresholds.formUnion(crossed) // skip any lower tiers we jumped past
        sendThresholdNotification(tier: tier, window: window, windowKey: key)
    }

    private func sendThresholdNotification(tier: Int, window: UsageWindow, windowKey: String) {
        let resetPart = window.resetsAt.map { "Resets \(resetText($0))." } ?? ""
        let content = UNMutableNotificationContent()
        content.subtitle = "5-hour rolling window"

        switch tier {
        case 100:
            content.title = "Claudeometer · limit reached 😭"
            content.body = ["You've hit the 5-hour limit.", resetPart].filter { !$0.isEmpty }.joined(separator: " ")
            content.sound = .default
        case 90:
            content.title = "Claudeometer · 90% — panic 😰"
            content.body = ["Almost out — pause heavy sessions now.", resetPart].filter { !$0.isEmpty }.joined(separator: " ")
            content.sound = .default
        case 75:
            content.title = "Claudeometer · 75% used 😬"
            content.body = ["Getting close — start winding down heavy work.", resetPart].filter { !$0.isEmpty }.joined(separator: " ")
        default: // 50
            content.title = "Claudeometer · 50% used 🙂"
            content.body = ["Halfway through your 5-hour window.", resetPart].filter { !$0.isEmpty }.joined(separator: " ")
        }

        let identifier = "claudeometer-\(windowKey)-\(tier)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func setTitle(_ title: String, color: NSColor) {
        currentTitle = title
        currentColor = color
        renderStatusImage()
    }

    private func renderStatusImage() {
        // While borrowing, the badge wins the label — usage polling continues
        // underneath, it just doesn't drive the menu-bar title until we switch back.
        if let badge = multiAccount.badge {
            let image = makeStatusImage(text: badge.text, color: .systemOrange, phase: markPhase)
            statusItem.length = image.size.width + 8
            statusItem.button?.title = ""
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.toolTip = "Claudeometer — borrowing \(badge.text)"
            return
        }

        let image = makeStatusImage(text: currentTitle, color: currentColor, phase: markPhase)
        statusItem.length = image.size.width + 8
        statusItem.button?.title = ""
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Claudeometer \(currentTitle)"
    }

    private func color(for utilization: Double) -> NSColor {
        gradientColor(for: utilization)
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    // MARK: multi-account menu actions

    @objc func accountMenuTapped(_ sender: NSMenuItem) {
        // Tapping the self row (no submenu) switches back; other rows use their submenu,
        // so their own tap action never fires (AppKit routes the click to the submenu).
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        if multiAccount.isSelfAccount(id: id) { multiAccount.switchBack() }
    }

    @objc func saveCurrentAccountTapped() {
        let alert = NSAlert()
        alert.messageText = "Save current Claude login as…"
        alert.informativeText = "Give this account a name (e.g. a teammate's name)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let label = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, let message = multiAccount.saveCurrentAccount(label: label) {
                showErrorAlert(title: "Couldn't save account", message: message)
            }
        }
    }

    @objc func useAccountTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let seconds = TimeInterval(String(parts[1])) else { return }
        switch multiAccount.useAccount(id: id, seconds: seconds) {
        case .failed(let message):
            showErrorAlert(title: "Couldn't switch account", message: message)
        case .switched(claudeRunning: true):
            warnClaudeRunning()
        case .switched(claudeRunning: false):
            break
        }
    }

    @objc func switchBackTapped() {
        multiAccount.switchBack()
    }

    // MARK: team

    /// Prompts for a display name and enrolls with the relay on submit. Called
    /// once at launch when not yet enrolled, and again from the "Join team…"
    /// overflow-menu item. Leaving the name empty (or cancelling) just skips —
    /// the user can join later from that same menu item.
    private func promptJoinTeam() {
        // Team features require a locally-configured relay URL (see RelayConfig).
        // Without one — e.g. a fresh clone of the public repo — stay a personal
        // usage meter and never prompt or poll.
        guard RelayConfig.isConfigured else { return }
        let alert = NSAlert()
        alert.messageText = "Join your team?"
        alert.informativeText = "Enter your name to show up on the team usage board. You can do this later from the ••• menu."
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Not now")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Your name"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task { [weak self] in
            if let message = await self?.teamController.enroll(name: name) {
                self?.showErrorAlert(title: "Couldn't join team", message: message)
            } else {
                self?.borrowController.start()
            }
        }
    }

    /// Prompts for the team relay base URL and writes it to the local config
    /// file `RelayConfig.resolve()` reads at launch (see
    /// `ClaudeUsageBarCore/RelayClient.swift`). This is how a teammate points
    /// a fresh install at their team's self-hosted relay before "Join team…"
    /// becomes available. Reached from the "Set team relay URL…" overflow-menu
    /// item, which is always visible (unlike "Join team…").
    ///
    /// Intentionally does NOT touch `teamController`/`borrowController` — the
    /// relay URL is only resolved at process launch, so a saved change only
    /// takes effect after the user quits and reopens the app.
    @objc private func promptSetTeamRelayURL() {
        guard let relayFileURL = Self.relayConfigFileURL() else { return }
        let currentValue = (try? String(contentsOf: relayFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let alert = NSAlert()
        alert.messageText = "Team relay URL"
        alert.informativeText = "Points Claudeometer at your team's self-hosted relay, which powers the team usage board and borrowing."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "https://relay.yourteam.example.com"
        field.stringValue = currentValue
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try FileManager.default.createDirectory(
                at: relayFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (trimmed + "\n").write(to: relayFileURL, atomically: true, encoding: .utf8)
        } catch {
            showErrorAlert(title: "Couldn't save relay URL", message: error.localizedDescription)
            return
        }

        let saved = NSAlert()
        saved.messageText = "Saved — quit and reopen Claudeometer to enable team mode."
        saved.addButton(withTitle: "OK")
        saved.runModal()
    }

    /// `~/Library/Application Support/Claudeometer/relay-url` — the same path
    /// `RelayConfig.resolve()` reads, kept in sync with that file's location.
    private static func relayConfigFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claudeometer/relay-url")
    }

    /// Fires a local notification for each incoming borrow request not seen
    /// before, mirroring `evaluateNotifications`/`sendThresholdNotification`
    /// below. Dedup'd by `requestId` so a request doesn't re-notify on every
    /// ~8s poll while it's still pending.
    private func notifyNewIncomingBorrowRequests() {
        for request in borrowController.incoming where !notifiedIncomingBorrowIds.contains(request.requestId) {
            notifiedIncomingBorrowIds.insert(request.requestId)
            let content = UNMutableNotificationContent()
            content.title = "Claudeometer · borrow request"
            content.body = "\(request.requesterName) wants \(request.hours)h of your Claude."
            content.sound = .default
            let identifier = "claudeometer-borrow-\(request.requestId)"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    private func warnClaudeRunning() {
        let alert = NSAlert()
        alert.messageText = "Switched — restart `claude` to use it"
        alert.informativeText = "A claude session is running. The new account takes effect the next time you start claude; your current session is unaffected."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func openClaudeLogin() {
        let command = """
        #!/bin/zsh
        # Load the user's shell config so their normal PATH is available, then
        # locate the claude CLI across common install locations (no hardcoded node version).
        [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" 2>/dev/null
        export PATH="$HOME/.claude/local:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        CLAUDE="$(command -v claude 2>/dev/null)"
        if [ -z "$CLAUDE" ]; then
          for candidate in "$HOME/.claude/local/claude" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude $HOME/.nvm/versions/node/*/bin/claude; do
            [ -x "$candidate" ] && CLAUDE="$candidate" && break
          done
        fi
        if [ -z "$CLAUDE" ]; then
          echo "Could not find the 'claude' CLI. Install Claude Code, then try again."
        else
          "$CLAUDE" /login
        fi
        echo
        echo "Press any key to close this window..."
        read -k 1
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claudeometer-login.command")
        do {
            try command.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Terminal.app"))
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

final class UsagePanelView: NSView {
    private let onRefresh: () -> Void
    private let onOpenSettings: () -> Void
    private let onLogin: () -> Void
    private let onQuit: () -> Void
    private let accountItems: [NSMenuItem]
    private let isTeamEnrolled: Bool
    private let onJoinTeam: () -> Void
    private let onSetTeamRelayURL: () -> Void
    private let onNavigateToTeam: () -> Void
    private let onNavigateBack: () -> Void
    private let onRequestBorrow: (String) -> Void
    private let onApproveBorrow: (IncomingRequest) -> Void
    private let onRejectBorrow: (IncomingRequest) -> Void
    private let onCancelOutgoingBorrow: (String) -> Void

    init(
        snapshot: UsageSnapshot?,
        hotSessions: [LocalSessionSummary],
        status: String?,
        accent: NSColor,
        history: [UsageHistoryPoint],
        page: PopoverPage = .main,
        onRefresh: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onLogin: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        accountItems: [NSMenuItem] = [],
        teamBoard: [BoardRow] = [],
        selfUserId: String? = nil,
        isTeamEnrolled: Bool = false,
        onJoinTeam: @escaping () -> Void = {},
        onSetTeamRelayURL: @escaping () -> Void = {},
        onNavigateToTeam: @escaping () -> Void = {},
        onNavigateBack: @escaping () -> Void = {},
        incomingRequests: [IncomingRequest] = [],
        outgoingRequests: [OutgoingRequest] = [],
        onRequestBorrow: @escaping (String) -> Void = { _ in },
        onApproveBorrow: @escaping (IncomingRequest) -> Void = { _ in },
        onRejectBorrow: @escaping (IncomingRequest) -> Void = { _ in },
        onCancelOutgoingBorrow: @escaping (String) -> Void = { _ in }
    ) {
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
        self.onLogin = onLogin
        self.onQuit = onQuit
        self.accountItems = accountItems
        self.isTeamEnrolled = isTeamEnrolled
        self.onJoinTeam = onJoinTeam
        self.onSetTeamRelayURL = onSetTeamRelayURL
        self.onNavigateToTeam = onNavigateToTeam
        self.onNavigateBack = onNavigateBack
        self.onRequestBorrow = onRequestBorrow
        self.onApproveBorrow = onApproveBorrow
        self.onRejectBorrow = onRejectBorrow
        self.onCancelOutgoingBorrow = onCancelOutgoingBorrow
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 480))
        build(snapshot: snapshot, hotSessions: hotSessions, status: status, accent: accent, history: history,
              page: page, teamBoard: teamBoard, selfUserId: selfUserId,
              incomingRequests: incomingRequests, outgoingRequests: outgoingRequests)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(
        snapshot: UsageSnapshot?,
        hotSessions: [LocalSessionSummary],
        status: String?,
        accent: NSColor,
        history: [UsageHistoryPoint],
        page: PopoverPage,
        teamBoard: [BoardRow],
        selfUserId: String?,
        incomingRequests: [IncomingRequest],
        outgoingRequests: [OutgoingRequest]
    ) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])

        switch page {
        case .main:
            buildMainPage(
                root: root, snapshot: snapshot, hotSessions: hotSessions, status: status,
                accent: accent, history: history, teamBoard: teamBoard, selfUserId: selfUserId,
                incomingRequests: incomingRequests
            )
        case .team:
            buildTeamPage(
                root: root, teamBoard: teamBoard, selfUserId: selfUserId,
                incomingRequests: incomingRequests, outgoingRequests: outgoingRequests
            )
        }

        addFullWidth(footer(snapshot: snapshot), to: root)
    }

    /// Personal usage view: 5-hour hero, this-week windows, 24h pace, hot
    /// sessions — plus a compact "Team ›" nav row at the bottom when enrolled.
    /// The full team board / borrow UI lives on the team page (`buildTeamPage`).
    private func buildMainPage(
        root: NSStackView,
        snapshot: UsageSnapshot?,
        hotSessions: [LocalSessionSummary],
        status: String?,
        accent: NSColor,
        history: [UsageHistoryPoint],
        teamBoard: [BoardRow],
        selfUserId: String?,
        incomingRequests: [IncomingRequest]
    ) {
        addFullWidth(header(snapshot: snapshot, accent: accent), to: root)

        if let status, !status.isEmpty {
            addFullWidth(statusCard(status), to: root)
        }

        if let snapshot {
            addFullWidth(heroSection(snapshot: snapshot, accent: accent, history: history), to: root)
            addFullWidth(divider(), to: root)
            addFullWidth(weekSection(snapshot: snapshot), to: root)
            addFullWidth(sparklineCard(history: history, accent: accent), to: root)

            let trimmedHot = Array(hotSessions.prefix(3))
            if !trimmedHot.isEmpty {
                addFullWidth(hotSessionsView(trimmedHot), to: root)
            }

            if let extra = snapshot.usage.extraUsage, extra.isEnabled {
                addFullWidth(extraUsage(extra), to: root)
            }
        }

        if isTeamEnrolled {
            addFullWidth(divider(), to: root)
            addFullWidth(teamNavRow(board: teamBoard, selfUserId: selfUserId, incoming: incomingRequests), to: root)
        }
    }

    /// Team page: reached via the "Team ›" nav row. Holds every M2/M3 team +
    /// borrow affordance — the board, incoming requests (Approve/Reject), and
    /// this device's own pending/approved outgoing request (Cancel).
    private func buildTeamPage(
        root: NSStackView,
        teamBoard: [BoardRow],
        selfUserId: String?,
        incomingRequests: [IncomingRequest],
        outgoingRequests: [OutgoingRequest]
    ) {
        addFullWidth(teamPageHeader(), to: root)
        addFullWidth(divider(), to: root)

        let pendingOutgoing = outgoingRequests.filter { $0.status == "pending" || $0.status == "approved" }

        if !teamBoard.isEmpty {
            addFullWidth(teamSection(teamBoard, selfUserId: selfUserId), to: root)
        }

        if !incomingRequests.isEmpty || !pendingOutgoing.isEmpty {
            if !teamBoard.isEmpty {
                addFullWidth(divider(), to: root)
            }
            addFullWidth(borrowSection(incoming: incomingRequests, outgoing: pendingOutgoing), to: root)
        }

        if teamBoard.isEmpty && incomingRequests.isEmpty && pendingOutgoing.isEmpty {
            addFullWidth(
                label("No teammates posting usage yet.", size: 12, weight: .regular, color: .secondaryLabelColor),
                to: root
            )
        }
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func header(snapshot: UsageSnapshot?, accent: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = AnimatedBadgeView(accent: accent)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(icon)

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 1
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.addArrangedSubview(label("Claudeometer", size: 14, weight: .semibold, color: .labelColor))
        let email = label(snapshot?.accountEmail ?? "Claude Code account", size: 11, weight: .regular, color: .secondaryLabelColor)
        email.maximumNumberOfLines = 1
        email.lineBreakMode = .byTruncatingTail
        email.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copy.addArrangedSubview(email)
        row.addArrangedSubview(copy)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        return row
    }

    /// Header for the team page: a tappable "‹ Back" affordance (fires
    /// `onNavigateBack`) plus a "Team" title, mirroring the personal page's
    /// header row without duplicating the Claudeometer branding.
    private func teamPageHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let back = TappableRow(accessibilityLabel: "Back") { [weak self] in self?.onNavigateBack() }
        let backContent = NSStackView()
        backContent.orientation = .horizontal
        backContent.alignment = .centerY
        backContent.spacing = 2
        backContent.translatesAutoresizingMaskIntoConstraints = false
        backContent.addArrangedSubview(label("‹", size: 17, weight: .semibold, color: .controlAccentColor))
        backContent.addArrangedSubview(label("Back", size: 13, weight: .medium, color: .controlAccentColor))
        back.addSubview(backContent)
        NSLayoutConstraint.activate([
            backContent.leadingAnchor.constraint(equalTo: back.leadingAnchor),
            backContent.trailingAnchor.constraint(equalTo: back.trailingAnchor),
            backContent.topAnchor.constraint(equalTo: back.topAnchor, constant: 3),
            backContent.bottomAnchor.constraint(equalTo: back.bottomAnchor, constant: -3)
        ])
        row.addArrangedSubview(back)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        row.addArrangedSubview(label("Team", size: 14, weight: .semibold, color: .labelColor))

        return row
    }

    private func statusCard(_ text: String) -> NSView {
        let card = paddedContainer(background: NSColor.systemRed.withAlphaComponent(0.16))
        let textLabel = label(text, size: 12, weight: .medium, color: .systemRed)
        textLabel.preferredMaxLayoutWidth = 280
        card.addSubview(textLabel)
        pinOnlySubview(in: card)
        return card
    }

    private func heroSection(snapshot: UsageSnapshot, accent: NSColor, history: [UsageHistoryPoint]) -> NSView {
        let five = snapshot.usage.fiveHour?.utilization ?? 0

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(sectionHeaderLabel("5-HOUR WINDOW", tracking: 0.3))
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(headerSpacer)
        headerRow.addArrangedSubview(label(moodEmoji(for: formatPercent(five)), size: 15, weight: .regular, color: .labelColor))
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let heroNumber = label(formatPercent(five), size: 38, weight: .bold, color: .labelColor)
        heroNumber.font = Self.heroFont(size: 38, weight: .bold)
        stack.addArrangedSubview(heroNumber)

        let (burn, eta) = burnRateAndETA(history: history, currentFiveHour: five)
        let subtitle = label(heroSubtitle(burn: burn, eta: eta), size: 13, weight: .medium, color: .secondaryLabelColor)
        subtitle.maximumNumberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(subtitle)

        let bar = ProgressBarView(value: five / 100, color: accent)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if let resetsAt = snapshot.usage.fiveHour?.resetsAt {
            let caption = label("resets \(resetText(resetsAt))", size: 11, weight: .regular, color: .tertiaryLabelColor)
            caption.maximumNumberOfLines = 1
            caption.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(caption)
        }

        return stack
    }

    private func heroSubtitle(burn: Double?, eta: String?) -> String {
        guard let burn else { return "collecting pace…" }
        let steady = (eta == "holding steady") || burn <= 0
        let arrow = steady ? "→" : "↑"
        let sign = burn > 0 ? "+" : ""
        let base = "\(sign)\(Int(burn))%/hr \(arrow)"
        if let eta {
            return "\(base) · \(eta)"
        }
        return base
    }

    private func weekSection(snapshot: UsageSnapshot) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionHeaderLabel("THIS WEEK"))

        addWeekRow("7-day all", snapshot.usage.sevenDay, to: stack)
        addWeekRow("Sonnet", snapshot.usage.sevenDaySonnet, to: stack)
        addWeekRow("Opus", snapshot.usage.sevenDayOpus, to: stack)
        addWeekRow("OAuth apps", snapshot.usage.sevenDayOAuthApps, to: stack)

        return stack
    }

    private func addWeekRow(_ title: String, _ window: UsageWindow?, to stack: NSStackView) {
        guard let window else { return }
        let row = weekRow(title, window)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func weekRow(_ title: String, _ window: UsageWindow) -> NSView {
        let accent = gradientColor(for: window.utilization)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let name = label(title, size: 13, weight: .regular, color: .labelColor)
        name.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: 104).isActive = true
        row.addArrangedSubview(name)

        let bar = ProgressBarView(value: window.utilization / 100, color: accent)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(bar)

        let pct = monoLabel(formatPercent(window.utilization), size: 13, weight: .semibold, color: legibleTextColor(for: accent))
        pct.alignment = .right
        pct.widthAnchor.constraint(equalToConstant: 42).isActive = true
        row.addArrangedSubview(pct)

        return row
    }

    private func sparklineCard(history: [UsageHistoryPoint], accent: NSColor) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionHeaderLabel("LAST 24H · pace"))

        let spark = SparklineView(points: history, accent: accent)
        stack.addArrangedSubview(spark)
        spark.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private func hotSessionsView(_ sessions: [LocalSessionSummary]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sectionHeaderLabel("Claude Code · Hot sessions"))
        for session in sessions.prefix(3) {
            let row = hotSessionRow(session)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func hotSessionRow(_ session: LocalSessionSummary) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let title = label(session.displayName, size: 12, weight: .medium, color: .labelColor)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.toolTip = "\(session.displayName)\n\(session.path)"
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let tokens = monoLabel(formatCompactTokens(session.tokens), size: 12, weight: .bold, color: .secondaryLabelColor)
        tokens.alignment = .right
        tokens.maximumNumberOfLines = 1
        tokens.widthAnchor.constraint(equalToConstant: 64).isActive = true
        row.addArrangedSubview(tokens)

        return row
    }

    private func extraUsage(_ extra: ExtraUsage) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(sectionHeaderLabel("Extra usage"))

        let used = (extra.usedCredits ?? 0) / 100
        let valueText: String
        if let limit = extra.monthlyLimit {
            let cap = Double(limit) / 100
            let pct = cap > 0 ? (used / cap * 100) : 0
            valueText = String(format: "$%.2f / $%.2f (%.0f%%)", used, cap, pct)
        } else {
            valueText = String(format: "$%.2f used", used)
        }
        container.addArrangedSubview(monoLabel(valueText, size: 13, weight: .semibold, color: .labelColor))
        return container
    }

    /// Team board: one row per teammate, busiest (highest 5-hour usage) first.
    /// Rows with no usage posted yet (`fiveHourPct == nil`) sort last.
    private func teamSection(_ board: [BoardRow], selfUserId: String?) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionHeaderLabel("TEAM"))

        let sorted = board.sorted { ($0.fiveHourPct ?? -1) > ($1.fiveHourPct ?? -1) }
        for row in sorted {
            let view = teamRow(row, isSelf: selfUserId != nil && row.userId == selfUserId)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    private func teamRow(_ row: BoardRow, isSelf: Bool) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(lendDot(visible: row.availableToLend == true))

        let nameStack = NSStackView()
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 1
        nameStack.translatesAutoresizingMaskIntoConstraints = false

        let nameText = isSelf ? "\(row.displayName) (you)" : row.displayName
        let nameLabel = label(nameText, size: 12, weight: isSelf ? .semibold : .regular, color: .labelColor)
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameStack.addArrangedSubview(nameLabel)

        if let resetAt = row.resetAt {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(resetAt))
            let caption = label("resets \(resetText(resetDate))", size: 10, weight: .regular, color: .tertiaryLabelColor)
            caption.maximumNumberOfLines = 1
            caption.lineBreakMode = .byTruncatingTail
            nameStack.addArrangedSubview(caption)
        }

        // Active-borrow visibility (relay v0.2.1+): surfaces that this member's
        // usage is currently propped up by someone else's quota (borrowing) or
        // that they're propping up teammates (lending), so a high `fiveHourPct`
        // doesn't get mistaken for "heavy user of their own quota."
        if let borrowingFrom = row.borrowingFrom {
            let countdown = borrowCountdownText(until: row.borrowingUntil)
            let tag = label("↔ borrowing from \(borrowingFrom) · \(countdown)",
                             size: 10, weight: .regular, color: .secondaryLabelColor)
            tag.maximumNumberOfLines = 1
            tag.lineBreakMode = .byTruncatingTail
            nameStack.addArrangedSubview(tag)
        }

        if let lendingTo = row.lendingTo, !lendingTo.isEmpty {
            let tag = label("↑ lending to \(lendingTo.joined(separator: ", "))",
                             size: 10, weight: .regular, color: .secondaryLabelColor)
            tag.maximumNumberOfLines = 1
            tag.lineBreakMode = .byTruncatingTail
            nameStack.addArrangedSubview(tag)
        }
        container.addArrangedSubview(nameStack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(spacer)

        if !isSelf, row.availableToLend == true {
            let request = ActionButton(title: "Request 2h") { [weak self] in self?.onRequestBorrow(row.userId) }
            request.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            container.addArrangedSubview(request)
        }

        let pctText = row.fiveHourPct.map(formatPercent) ?? "—"
        let pctColor = row.fiveHourPct.map(gradientColor(for:)) ?? NSColor.tertiaryLabelColor
        let pct = monoLabel(pctText, size: 13, weight: .semibold, color: legibleTextColor(for: pctColor))
        pct.alignment = .right
        pct.widthAnchor.constraint(equalToConstant: 42).isActive = true
        container.addArrangedSubview(pct)

        return container
    }

    /// The "BORROW" section: incoming requests (actionable — Approve/Reject)
    /// followed by the caller's own pending/approved outgoing requests
    /// (Cancel, which revokes). Approved-and-lent-out requests already drop
    /// off `incoming` per `relay/PROTOCOL.md` (it only returns *pending*
    /// requests) — the borrowed badge + "Switch back to <you>" item in the
    /// ••• menu (from `MultiAccountController.switchToBorrowed`) cover the
    /// lent-out/active side without duplicating that affordance here.
    private func borrowSection(incoming: [IncomingRequest], outgoing: [OutgoingRequest]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionHeaderLabel("BORROW"))

        for request in incoming {
            let row = incomingRequestRow(request)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for request in outgoing {
            let row = outgoingRequestRow(request)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    private func incomingRequestRow(_ request: IncomingRequest) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        let text = label("\(request.requesterName) wants \(request.hours)h of your Claude",
                         size: 12, weight: .regular, color: .labelColor)
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        container.addArrangedSubview(text)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let approve = ActionButton(title: "Approve") { [weak self] in self?.onApproveBorrow(request) }
        buttons.addArrangedSubview(approve)

        let reject = ActionButton(title: "Reject") { [weak self] in self?.onRejectBorrow(request) }
        buttons.addArrangedSubview(reject)

        container.addArrangedSubview(buttons)
        return container
    }

    private func outgoingRequestRow(_ request: OutgoingRequest) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let statusText = request.status == "approved" ? "approved — picking up…" : "waiting for \(request.lenderName)…"
        let text = label("Requested \(request.hours)h from \(request.lenderName) (\(statusText))",
                         size: 12, weight: .regular, color: .secondaryLabelColor)
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(text)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(spacer)

        let requestId = request.requestId
        let cancel = ActionButton(title: "Cancel") { [weak self] in self?.onCancelOutgoingBorrow(requestId) }
        container.addArrangedSubview(cancel)

        return container
    }

    /// Small filled dot marking a teammate as `availableToLend`; an empty (clear)
    /// placeholder otherwise, so rows stay aligned whether or not it's shown.
    private func lendDot(visible: Bool) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 3
        view.layer?.backgroundColor = (visible ? NSColor.systemGreen : NSColor.clear).cgColor
        view.widthAnchor.constraint(equalToConstant: 6).isActive = true
        view.heightAnchor.constraint(equalToConstant: 6).isActive = true
        view.toolTip = visible ? "Available to lend" : nil
        return view
    }

    /// Compact nav row on the main page that opens the team page. Shows a
    /// light-touch hint (pending incoming requests, lendable teammates, or a
    /// plain member count, in that priority order) so there's a reason to tap
    /// in even when nothing needs attention.
    private func teamNavRow(board: [BoardRow], selfUserId: String?, incoming: [IncomingRequest]) -> NSView {
        let row = TappableRow(accessibilityLabel: "Team") { [weak self] in self?.onNavigateToTeam() }
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9)
        ])

        content.addArrangedSubview(label("Team", size: 13, weight: .medium, color: .labelColor))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(spacer)

        if let hint = teamNavHint(board: board, selfUserId: selfUserId, incoming: incoming) {
            content.addArrangedSubview(hint)
        }

        content.addArrangedSubview(label("›", size: 15, weight: .semibold, color: .tertiaryLabelColor))

        return row
    }

    /// Picks the single most useful hint for the "Team ›" row: a pending
    /// incoming-request badge outranks a lendable-teammate count, which
    /// outranks a plain member count. Returns nil (no hint) once the board
    /// has nothing to say — e.g. right after enrolling, before anyone has
    /// posted usage yet.
    private func teamNavHint(board: [BoardRow], selfUserId: String?, incoming: [IncomingRequest]) -> NSView? {
        if !incoming.isEmpty {
            return badge(text: "\(incoming.count) request\(incoming.count == 1 ? "" : "s")", color: .systemOrange)
        }
        let lendable = board.filter { $0.availableToLend == true && $0.userId != selfUserId }.count
        if lendable > 0 {
            return label("\(lendable) lendable", size: 11, weight: .regular, color: .secondaryLabelColor)
        }
        if !board.isEmpty {
            return label("\(board.count) teammate\(board.count == 1 ? "" : "s")", size: 11, weight: .regular, color: .tertiaryLabelColor)
        }
        return nil
    }

    /// Small rounded pill used for the incoming-request count on the nav row —
    /// same visual language as `lendDot`/`ProgressBarView`'s rounded, tinted style.
    private func badge(text: String, color: NSColor) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor

        let textLabel = monoLabel(text, size: 10, weight: .semibold, color: color)
        container.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            textLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            textLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            textLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3)
        ])
        return container
    }

    private func footer(snapshot: UsageSnapshot?) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let updatedText = snapshot != nil ? "Updated \(relative(snapshot!.fetchedAt))" : "Waiting for data"
        row.addArrangedSubview(label(updatedText, size: 11, weight: .regular, color: .tertiaryLabelColor))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        row.addArrangedSubview(iconButton(symbol: "arrow.clockwise", action: #selector(refreshTapped)))
        row.addArrangedSubview(iconButton(symbol: "ellipsis.circle", action: #selector(overflowTapped(_:))))

        return row
    }

    private func iconButton(symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.target = self
        button.action = action
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?.withSymbolConfiguration(configuration)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private static func heroFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // Start from the monospaced-digit system font (so the hero number never jitters
        // as digits change), then apply the rounded design for the SF Rounded look.
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    @objc private func refreshTapped() { onRefresh() }
    @objc private func openTapped() { onOpenSettings() }
    @objc private func loginTapped() { onLogin() }
    @objc private func quitTapped() { onQuit() }
    @objc private func joinTeamMenuItemTapped() { onJoinTeam() }
    @objc private func setTeamRelayURLMenuItemTapped() { onSetTeamRelayURL() }

    @objc private func overflowTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open usage", action: #selector(openTapped), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let loginItem = NSMenuItem(title: "Login", action: #selector(loginTapped), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        if !isTeamEnrolled {
            let joinTeamItem = NSMenuItem(title: "Join team…", action: #selector(joinTeamMenuItemTapped), keyEquivalent: "")
            joinTeamItem.target = self
            menu.addItem(joinTeamItem)
        }
        // Always visible (unlike "Join team…" above): this is how a teammate
        // points a fresh install at the relay before team mode is enabled.
        let setRelayItem = NSMenuItem(title: "Set team relay URL…", action: #selector(setTeamRelayURLMenuItemTapped), keyEquivalent: "")
        setRelayItem.target = self
        menu.addItem(setRelayItem)
        menu.addItem(.separator())
        if !accountItems.isEmpty {
            for item in accountItems { menu.addItem(item) }
            menu.addItem(.separator())
        }
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}

/// A small `NSButton` that fires a closure instead of a target/action selector,
/// so per-row borrow actions (Request/Approve/Reject/Cancel) can capture the
/// row's own value (lender id, request) directly instead of round-tripping
/// through `representedObject` (which `NSButton`, unlike `NSMenuItem`, doesn't have).
final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    init(title: String, handler: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.controlSize = .small
        self.handler = handler
        self.target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler?()
    }
}

/// A plain `NSView` "row" that fires `handler` on click anywhere within its
/// bounds — used for the "Team ›" nav row and "‹ Back" header, where the
/// whole row (not just a small button) needs to be tappable. Plain AppKit
/// hit-testing would otherwise return a child label first and swallow the
/// click before it ever reaches this view, so `hitTest` is overridden to
/// always claim points inside its own bounds.
final class TappableRow: NSView {
    private let handler: () -> Void

    init(accessibilityLabel: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        handler()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityPerformPress() -> Bool {
        handler()
        return true
    }
}

final class ProgressBarView: NSView {
    private let value: Double
    private let color: NSColor

    init(value: Double, color: NSColor) {
        self.value = min(max(value, 0), 1)
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = bounds.height / 2
        let bg = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        bg.fill()

        let fillWidth = bounds.width * value
        guard fillWidth > 0 else { return }
        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: fillWidth, height: bounds.height)
        let fillRadius = min(radius, fillWidth / 2)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)
        color.setFill()
        fill.fill()
    }
}

/// Shows the burn *rate* (pace) over the last 24h, bucketed per hour.
/// Each bucket = total 5-hour-window utilization gained during that hour (%/hr),
/// so idle hours sit on the baseline and active bursts spike up. Window resets
/// (negative deltas) are ignored.
final class SparklineView: NSView {
    private let pace: [Double]
    private let hasEnoughData: Bool
    private let accent: NSColor

    init(points: [UsageHistoryPoint], accent: NSColor) {
        self.accent = accent
        let now = Date()
        let hours = 24
        let recent = points
            .filter { $0.ts >= now.addingTimeInterval(-Double(hours) * 3600) }
            .sorted { $0.ts < $1.ts }

        var buckets = [Double](repeating: 0, count: hours)
        if recent.count >= 2 {
            for i in 1..<recent.count {
                let delta = recent[i].fiveHour - recent[i - 1].fiveHour
                guard delta > 0 else { continue } // ignore resets / idle
                let ageHours = now.timeIntervalSince(recent[i].ts) / 3600
                let index = hours - 1 - Int(ageHours) // newest hour at the right
                if index >= 0 && index < hours { buckets[index] += delta }
            }
        }
        self.pace = buckets

        // A 24h pace curve only means anything once there's at least an hour of
        // samples — until then show a friendly collecting state instead of a flat line.
        let span = recent.first.map { now.timeIntervalSince($0.ts) } ?? 0
        self.hasEnoughData = recent.count >= 3 && span >= 3600

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard hasEnoughData else {
            drawCaption("Collecting usage — fills in as you use Claude")
            return
        }

        let pad: CGFloat = 4
        let baseline = bounds.minY + pad
        let usableHeight = bounds.height - 2 * pad
        let scaleTop = max(pace.max() ?? 0, 8) // floor so small bumps stay small
        let count = pace.count

        func point(at index: Int) -> NSPoint {
            let x = count <= 1 ? bounds.midX : bounds.width * CGFloat(index) / CGFloat(count - 1)
            let y = baseline + usableHeight * CGFloat(min(pace[index] / scaleTop, 1))
            return NSPoint(x: x, y: y)
        }
        let points = (0..<count).map(point)

        // baseline hairline
        let base = NSBezierPath()
        base.lineWidth = 1
        base.move(to: NSPoint(x: bounds.minX, y: baseline))
        base.line(to: NSPoint(x: bounds.maxX, y: baseline))
        NSColor.separatorColor.setStroke()
        base.stroke()

        // area fill with a downward fade
        let area = NSBezierPath()
        area.move(to: NSPoint(x: points.first!.x, y: baseline))
        for p in points { area.line(to: p) }
        area.line(to: NSPoint(x: points.last!.x, y: baseline))
        area.close()
        if let gradient = NSGradient(colors: [accent.withAlphaComponent(0.30), accent.withAlphaComponent(0.0)]) {
            gradient.draw(in: area, angle: -90)
        }

        // pace line
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.move(to: points.first!)
        for p in points.dropFirst() { line.line(to: p) }
        accent.setStroke()
        line.stroke()
    }

    private func drawCaption(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = NSString(string: text).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        NSString(string: text).draw(at: origin, withAttributes: attributes)
    }
}

@main
@MainActor
enum ClaudeUsageBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}

struct ClaudeUsageFetcher {
    func fetch() async throws -> UsageSnapshot {
        let credentials = try readCredentials()

        if credentials.expiresAt > 0 && credentials.expiresAt < Int64(Date().timeIntervalSince1970 * 1000) {
            throw UsageError.expiredToken
        }

        async let usage: UsageResponse = getJSON(usageURL, token: credentials.accessToken)
        async let profile: ProfileResponse = getJSON(profileURL, token: credentials.accessToken)

        return try await UsageSnapshot(
            accountEmail: profile.account.email,
            orgUUID: profile.organization.uuid,
            fetchedAt: Date(),
            usage: usage
        )
    }

    /// Which Keychain item to read for the user's OWN usage: the self account's
    /// vault item while a borrow is active (so the meter + board show your own
    /// numbers, not the lent account's), else the live Claude Code item.
    private func usageKeychainService() -> String {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claudeometer", isDirectory: true) else { return keychainService }
        return AccountStore(directory: base).load().ownUsageKeychainService(claudeCodeService: keychainService)
    }

    private func readCredentials() throws -> OAuthCredentials {
        let service = usageKeychainService()
        let process = Process()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw UsageError.keychain(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let blob = try JSONDecoder().decode(KeychainBlob.self, from: data)
        return blob.claudeAiOauth
    }

    private func getJSON<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            throw UsageError.http(http.statusCode, String(body.prefix(240)), retryAfter)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseISO8601(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(raw)")
        }
        return try decoder.decode(T.self, from: data)
    }
}

struct KeychainBlob: Decodable {
    let claudeAiOauth: OAuthCredentials
}

struct OAuthCredentials: Decodable {
    let accessToken: String
    let expiresAt: Int64
    let subscriptionType: String?
    let rateLimitTier: String?
}

struct UsageSnapshot {
    let accountEmail: String?
    let orgUUID: String
    let fetchedAt: Date
    let usage: UsageResponse
}

struct UsageHistoryPoint: Codable {
    let ts: Date
    let fiveHour: Double
    let sevenDay: Double
}

enum UsageHistoryStore {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("Claudeometer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    static func load() -> [UsageHistoryPoint] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let points = try? decoder.decode([UsageHistoryPoint].self, from: data) else { return [] }
        return points.sorted { $0.ts < $1.ts }
    }

    // History older than this is deleted. Pruned on every append (≈every refresh)
    // and once at launch, so the file never grows past a 30-day window.
    private static let maxAgeDays: Double = 30

    static func append(fiveHour: Double, sevenDay: Double, now: Date) {
        var points = load()
        points.append(UsageHistoryPoint(ts: now, fiveHour: fiveHour, sevenDay: sevenDay))
        write(prune(points, now: now))
    }

    /// Drop any points older than `maxAgeDays` and persist. Safe to call anytime.
    static func prune(now: Date) {
        write(prune(load(), now: now))
    }

    private static func prune(_ points: [UsageHistoryPoint], now: Date) -> [UsageHistoryPoint] {
        let cutoff = now.addingTimeInterval(-maxAgeDays * 24 * 60 * 60)
        return points.filter { $0.ts >= cutoff }
    }

    private static func write(_ points: [UsageHistoryPoint]) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(points).write(to: url)
    }
}

struct LocalSessionSummary: Sendable {
    let sessionID: String
    let path: String
    let displayName: String
    let tokens: Int
    let lastSeen: Date
}

enum LocalSessionAnalyzer {
    static func topSessions() async -> [LocalSessionSummary] {
        await Task.detached(priority: .utility) {
            scanTopSessions()
        }.value
    }

    private static func scanTopSessions() -> [LocalSessionSummary] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
        let cutoff = Date().addingTimeInterval(-5 * 60 * 60)
        var sessions: [String: LocalSessionAccumulator] = [:]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in data.split(separator: "\n") {
                guard let raw = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let timestampText = event["timestamp"] as? String,
                      let timestamp = parseISO8601(timestampText),
                      timestamp >= cutoff else {
                    continue
                }

                let sessionID = (event["sessionId"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let cwd = (event["cwd"] as? String) ?? projectName(from: url)
                var accumulator = sessions[sessionID] ?? LocalSessionAccumulator(
                    sessionID: sessionID,
                    path: cwd,
                    headline: nil,
                    tokens: 0,
                    lastSeen: timestamp
                )

                if accumulator.headline == nil,
                   event["toolUseResult"] == nil,
                   (event["isMeta"] as? Bool) != true,
                   let message = event["message"] as? [String: Any],
                   (message["role"] as? String) == "user",
                   let headline = headlineFromMessage(message) {
                    accumulator.headline = headline
                }

                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    accumulator.tokens += tokensFromUsage(usage)
                }
                if timestamp > accumulator.lastSeen {
                    accumulator.lastSeen = timestamp
                }
                sessions[sessionID] = accumulator
            }
        }

        return sessions.values
            .sorted { $0.tokens > $1.tokens }
            .prefix(6)
            .map {
                LocalSessionSummary(
                    sessionID: $0.sessionID,
                    path: $0.path,
                    displayName: $0.headline ?? displayName(for: $0.path),
                    tokens: $0.tokens,
                    lastSeen: $0.lastSeen
                )
            }
    }

    private static func headlineFromMessage(_ message: [String: Any]) -> String? {
        let raw: String?
        if let text = message["content"] as? String {
            raw = text
        } else if let parts = message["content"] as? [[String: Any]] {
            // Only genuine human-typed text parts — skip tool_result / tool_use / image parts,
            // whose embedded text is machine output, not a prompt.
            let texts = parts.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }
            raw = texts.isEmpty ? nil : texts.joined(separator: " ")
        } else {
            raw = nil
        }

        guard let collapsed = raw?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !collapsed.isEmpty else {
            return nil
        }

        let cleaned = collapsed
            .replacingOccurrences(of: #"\[Image #[0-9]+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, isHumanPrompt(cleaned) else { return nil }
        return String(cleaned.prefix(54))
    }

    /// Reject content that is machine output (JSON/tool/command/system) rather than a
    /// real prompt, so session names never show raw blobs like `{ "status": "error" … }`.
    private static func isHumanPrompt(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        // JSON object/array blobs or XML-ish tags (<system-reminder>, <command-name>, …)
        if first == "{" || first == "[" || first == "<" { return false }
        let lowered = text.lowercased()
        let bannedPrefixes = [
            "caveat:", "command-", "the user opened", "this session is being continued",
            "api error", "[request interrupted", "<system-reminder", "[image"
        ]
        if bannedPrefixes.contains(where: { lowered.hasPrefix($0) }) { return false }
        let bannedSubstrings = [
            "\"tool_use_id\"", "\"tool_result\"", "<system-reminder>", "</system-reminder>",
            "\"is_error\"", "\"status\":", "\"data\":"
        ]
        if bannedSubstrings.contains(where: { lowered.contains($0) }) { return false }
        // Embedded JSON object: a quoted key/value pair next to braces.
        if text.contains("\": ") && (text.contains("{") || text.contains("}")) { return false }
        return true
    }

    private static func tokensFromUsage(_ usage: [String: Any]) -> Int {
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreate = usage["cache_creation_input_tokens"] as? Int
        let nested = usage["cache_creation"] as? [String: Any]
        let nestedCreate = (nested?["ephemeral_5m_input_tokens"] as? Int ?? 0) + (nested?["ephemeral_1h_input_tokens"] as? Int ?? 0)
        return input + output + cacheRead + (cacheCreate ?? nestedCreate)
    }

    private static func projectName(from url: URL) -> String {
        // Claude Code encodes a project's cwd as a dash-joined path, e.g.
        // "-Users-jane-Desktop-app". Turn the current user's home prefix into "~/".
        let encodedHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/", with: "-")
        return url.deletingLastPathComponent().lastPathComponent
            .replacingOccurrences(of: encodedHome + "-", with: "~/")
            .replacingOccurrences(of: "-", with: "/")
    }

    private static func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        if !last.isEmpty && last != "/" {
            return last
        }
        return path
    }
}

private struct LocalSessionAccumulator {
    let sessionID: String
    let path: String
    var headline: String?
    var tokens: Int
    var lastSeen: Date
}

struct ProfileResponse: Decodable {
    let account: ProfileAccount
    let organization: ProfileOrganization
}

struct ProfileAccount: Decodable {
    let email: String?
}

struct ProfileOrganization: Decodable {
    let uuid: String
}

struct UsageResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDayOAuthApps: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case extraUsage = "extra_usage"
    }
}

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool
    let monthlyLimit: Int?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

enum UsageError: LocalizedError {
    case keychain(String)
    case expiredToken
    case badResponse
    case http(Int, String, Int?)

    var errorDescription: String? {
        switch self {
        case .keychain(let message):
            return "Could not read Claude Code Keychain token. Run `claude` once. \(message)"
        case .expiredToken:
            return "Claude Code token is expired. Run `claude` once to refresh it."
        case .badResponse:
            return "Unexpected response from Anthropic."
        case .http(let status, let body, _):
            return "Anthropic returned HTTP \(status). \(body)"
        }
    }
}

private func parseISO8601(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) {
        return date
    }
    return ISO8601DateFormatter().date(from: raw)
}

private func formatPercent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

private func formatCompactTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
    if tokens >= 1_000 {
        return String(format: "%.0fK", Double(tokens) / 1_000)
    }
    return "\(tokens)"
}

private func gradientColor(for utilization: Double) -> NSColor {
    let clamped = min(max(utilization, 0), 100)
    let anchors: [(percent: Double, color: NSColor)] = [
        (0, .systemGreen),
        (60, .systemYellow),
        (80, .systemOrange),
        (90, .systemRed),
        (100, .systemRed)
    ]
    let resolved = anchors.map { (percent: $0.percent, color: $0.color.usingColorSpace(.deviceRGB) ?? $0.color) }
    for index in 1..<resolved.count {
        let lower = resolved[index - 1]
        let upper = resolved[index]
        if clamped <= upper.percent {
            let span = upper.percent - lower.percent
            let t = span <= 0 ? 0 : (clamped - lower.percent) / span
            return lerpColor(lower.color, upper.color, CGFloat(t))
        }
    }
    return resolved.last?.color ?? .systemRed
}

private func lerpColor(_ start: NSColor, _ end: NSColor, _ t: CGFloat) -> NSColor {
    let clampedT = min(max(t, 0), 1)
    let red = start.redComponent + (end.redComponent - start.redComponent) * clampedT
    let green = start.greenComponent + (end.greenComponent - start.greenComponent) * clampedT
    let blue = start.blueComponent + (end.blueComponent - start.blueComponent) * clampedT
    let alpha = start.alphaComponent + (end.alphaComponent - start.alphaComponent) * clampedT
    return NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
}

private func burnRateAndETA(history: [UsageHistoryPoint], currentFiveHour: Double) -> (burnPerHour: Double?, etaText: String?) {
    let now = Date()
    let window = history
        .filter { $0.ts >= now.addingTimeInterval(-60 * 60) }
        .sorted { $0.ts < $1.ts }
    guard window.count >= 2 else { return (nil, nil) }

    var points = window
    if let earliest = points.first, let latest = points.last, earliest.fiveHour > latest.fiveHour {
        var dropIndex: Int?
        var largestDrop = 15.0
        for index in 1..<points.count {
            let drop = points[index - 1].fiveHour - points[index].fiveHour
            if drop > largestDrop {
                largestDrop = drop
                dropIndex = index
            }
        }
        if let dropIndex {
            points = Array(points[dropIndex...])
        }
        guard points.count >= 2 else { return (nil, nil) }
    }

    guard let earliest = points.first, let latest = points.last else { return (nil, nil) }
    let hoursElapsed = max(latest.ts.timeIntervalSince(earliest.ts) / 3600, 1.0 / 60.0)
    let burn = (latest.fiveHour - earliest.fiveHour) / hoursElapsed
    let roundedBurn = burn.rounded()

    let etaText: String?
    if burn > 0.5 {
        let remaining = max(0, 100 - currentFiveHour)
        let etaHours = remaining / burn
        etaText = "full in ~\(formatDuration(hours: etaHours))"
    } else {
        etaText = "holding steady"
    }
    return (roundedBurn, etaText)
}

private func formatDuration(hours: Double) -> String {
    let totalMinutes = max(0, Int((hours * 60).rounded()))
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if h > 0 {
        return "\(h)h \(m)m"
    }
    return "\(m)m"
}

private func usageAdvice(utilization: Double, reset: Date?, hotSessions: [LocalSessionSummary]) -> (title: String, body: String) {
    let topSessions = hotSessions.prefix(2).map(\.displayName).joined(separator: ", ")
    let resetPart: String
    if let reset {
        resetPart = "Reset \(resetText(reset))."
    } else {
        resetPart = "Reset time unavailable."
    }

    let hour = Calendar.current.component(.hour, from: Date())
    let breakSuggestion: String
    switch hour {
    case 13...14:
        breakSuggestion = "Have lunch while the window resets."
    case 17...18:
        breakSuggestion = "Take a short walk while the limit resets."
    default:
        breakSuggestion = ""
    }

    if utilization >= 100 {
        let session = topSessions.isEmpty ? "Close heavy sessions for now." : "Close: \(topSessions)."
        let body = ["Claude is crying now.", breakSuggestion, resetPart, session].filter { !$0.isEmpty }.joined(separator: " ")
        return ("Limit hit :'( ", body)
    }

    if utilization >= 90 {
        let session = topSessions.isEmpty ? "Pause heavy sessions." : "Pause: \(topSessions)."
        let body = ["Panic mode, but recoverable.", breakSuggestion, resetPart, session].filter { !$0.isEmpty }.joined(separator: " ")
        return ("Panic window !!", body)
    }

    if utilization >= 60 {
        let session = topSessions.isEmpty ? "Slow down long-running sessions." : "Slow down: \(topSessions)."
        let body = ["\(formatPercent(utilization)) used.", session, breakSuggestion].filter { !$0.isEmpty }.joined(separator: " ")
        return ("Careful now", body)
    }

    if utilization >= 50 {
        let body = ["You crossed \(formatPercent(utilization)). Save big context work for after reset.", breakSuggestion].filter { !$0.isEmpty }.joined(separator: " ")
        return ("Watch pace", body)
    }

    return ("All good :)", "Plenty of room. Build calmly.")
}

private func resetText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE HH:mm"
    let delta = Int(date.timeIntervalSinceNow)
    if delta <= 0 {
        return "\(formatter.string(from: date))"
    }
    let days = delta / 86_400
    let hours = (delta % 86_400) / 3_600
    let minutes = (delta % 3_600) / 60
    if days > 0 {
        return "\(formatter.string(from: date)) (in \(days)d \(hours)h)"
    }
    if hours > 0 {
        return "\(formatter.string(from: date)) (in \(hours)h \(minutes)m)"
    }
    return "\(formatter.string(from: date)) (in \(minutes)m)"
}

/// Formats the time remaining until `until` (unix time) as `H:MM`, for the
/// "borrowing from … · <countdown>" tag on the team page. Returns `0:00` when
/// `until` is nil or already in the past — a borrow window shown as expired
/// rather than a negative/garbage duration.
private func borrowCountdownText(until: Int?) -> String {
    guard let until else { return "0:00" }
    let remaining = max(0, until - Int(Date().timeIntervalSince1970))
    let hours = remaining / 3_600
    let minutes = (remaining % 3_600) / 60
    return String(format: "%d:%02d", hours, minutes)
}

private func relative(_ date: Date) -> String {
    let seconds = max(0, Int(-date.timeIntervalSinceNow))
    if seconds < 60 { return "\(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    return "\(minutes / 60)h ago"
}

private func legibleTextColor(for accent: NSColor) -> NSColor {
    // System yellow is too light to read as text on the light panel. Keep it as a
    // bar fill, but swap to a darker amber when it is used for text.
    guard let rgb = accent.usingColorSpace(.deviceRGB) else { return accent }
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return luminance > 0.7 ? .systemOrange : accent
}

@MainActor
private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 0
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

@MainActor
private func monoLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let field = label(text, size: size, weight: weight, color: color)
    field.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    return field
}

@MainActor
private func sectionHeaderLabel(_ text: String, tracking: CGFloat = 0) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    field.font = font
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.translatesAutoresizingMaskIntoConstraints = false
    if tracking != 0 {
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: tracking
            ]
        )
    }
    return field
}

@MainActor
private func divider() -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.separatorColor.cgColor
    view.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return view
}

@MainActor
private func paddedContainer(background: NSColor) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = 12
    view.layer?.backgroundColor = background.cgColor
    view.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    return view
}

@MainActor
private func pinOnlySubview(in container: NSView) {
    guard let child = container.subviews.first else { return }
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
        child.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        child.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
        child.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
    ])
}

private func makeStatusImage(text: String, color: NSColor, phase: CGFloat) -> NSImage {
    let mood = moodEmoji(for: text)
    let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
    ]
    let moodAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Apple Color Emoji", size: 12.5) ?? NSFont.systemFont(ofSize: 12.5)
    ]
    let textSize = NSString(string: text).size(withAttributes: textAttributes)
    let moodSize = NSString(string: mood).size(withAttributes: moodAttributes)
    let markX: CGFloat = 7
    let markWidth: CGFloat = 16
    let textX = markX + markWidth + 7
    let moodGap: CGFloat = 5
    let moodX = textX + ceil(textSize.width) + moodGap
    let rightPadding: CGFloat = 8
    let size = NSSize(width: ceil(moodX + moodSize.width + rightPadding), height: 22)
    let image = NSImage(size: size)
    image.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high
    let background = color.usingColorSpace(.deviceRGB) ?? color
    let usesLightForeground = shouldUseLightForeground(for: background)
    let foreground = usesLightForeground ? NSColor.white : NSColor(calibratedWhite: 0.08, alpha: 1)
    let resolvedTextAttributes = textAttributes.merging([.foregroundColor: foreground]) { _, new in new }
    background.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 0, y: 1, width: size.width, height: 20),
        xRadius: 10,
        yRadius: 10
    ).fill()

    // Always draw the vector mark (not a static PNG) so it can shimmer.
    drawClaudeMark(in: NSRect(x: markX, y: 5.5, width: markWidth, height: 13), color: foreground, phase: phase, animated: true)

    let textY = floor((size.height - textSize.height) / 2) + 0.8
    let moodY = floor((size.height - moodSize.height) / 2) + 1.0
    NSString(string: text).draw(at: NSPoint(x: textX, y: textY), withAttributes: resolvedTextAttributes)
    NSString(string: mood).draw(at: NSPoint(x: moodX, y: moodY), withAttributes: moodAttributes)

    image.unlockFocus()
    image.isTemplate = false
    return image
}

private func moodEmoji(for text: String) -> String {
    let digits = text.filter(\.isNumber)
    guard let value = Int(digits) else { return "🙂" }
    switch value {
    case 100...:
        return "😭"
    case 90..<100:
        return "😰"
    case 80..<90:
        return "😬"
    case 60..<80:
        return "🙂"
    default:
        return "😊"
    }
}

/// Draws the Claude sunburst. When `animated`, brightness sweeps around the spokes
/// (a shimmer) and the burst gently pulses; `phase` is elapsed seconds.
private func drawClaudeMark(in rect: NSRect, color: NSColor = .white, phase: CGFloat = 0, animated: Bool = false) {
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let angles: [CGFloat] = [-170, -128, -93, -58, -21, 12, 49, 83, 116, 151]
    let reach: CGFloat = animated ? 0.48 * (1 + 0.06 * sin(phase * 2 * .pi * 0.5)) : 0.48
    for (index, angle) in angles.enumerated() {
        let radians = angle * .pi / 180
        let inner: CGFloat = 2.0
        let outerX = center.x + cos(radians) * rect.width * reach
        let outerY = center.y + sin(radians) * rect.height * reach
        let innerX = center.x + cos(radians) * inner
        let innerY = center.y + sin(radians) * inner
        let alpha: CGFloat
        if animated {
            let wave = sin(phase * 2 * .pi * 0.6 - CGFloat(index) * (2 * .pi / CGFloat(angles.count)))
            alpha = 0.45 + 0.55 * (0.5 + 0.5 * wave)
        } else {
            alpha = 1
        }
        color.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: innerX, y: innerY))
        path.line(to: NSPoint(x: outerX, y: outerY))
        path.stroke()
    }
}

private func shouldUseLightForeground(for color: NSColor) -> Bool {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return luminance <= 0.62
}

/// Animated "Claude Code" header badge: a rounded terminal-style square with the
/// shimmering Claude sunburst and a blinking cursor. Animates only while on screen.
final class AnimatedBadgeView: NSView {
    private let accent: NSColor
    private var phase: CGFloat = 0
    private var timer: Timer?

    init(accent: NSColor) {
        self.accent = accent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 22) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] firedTimer in
            guard let self else { firedTimer.invalidate(); return }
            Task { @MainActor in
                self.phase += 1.0 / 12.0
                self.needsDisplay = true
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let badge = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
        accent.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()

        let foreground: NSColor = shouldUseLightForeground(for: accent) ? .white : NSColor(calibratedWhite: 0.08, alpha: 1)
        let markSize: CGFloat = 13
        let markRect = NSRect(x: badge.midX - markSize / 2, y: badge.midY - markSize / 2 + 2, width: markSize, height: markSize)
        drawClaudeMark(in: markRect, color: foreground, phase: phase, animated: true)

        // Blinking terminal cursor (~1Hz) at the bottom center.
        if sin(phase * 2 * .pi) > 0 {
            foreground.setFill()
            let cursor = NSRect(x: badge.midX - 3, y: badge.minY + 2.5, width: 6, height: 2)
            NSBezierPath(rect: cursor).fill()
        }
    }
}
