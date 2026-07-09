import AppKit
import ClaudeUsageBarCore
import Foundation
import UserNotifications

private let keychainService = ClaudeometerConstants.claudeCodeKeychainService
private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
private let settingsURL = URL(string: "https://claude.ai/settings/usage")!

/// Fixed warm cream/terracotta palette matching the marketing-site mockup
/// (`docs/index.html`'s `:root` custom properties, the `#screens` popover
/// cards). Deliberately NOT tied to system semantic colors — the popover is a
/// fixed-light brand surface, same as the mockup, regardless of the system's
/// light/dark appearance (see `popover.appearance` / `effect.appearance` in
/// `renderPopover`, which force `.aqua` so this palette always reads correctly).
enum Theme {
    static let card = NSColor(hex: 0xFBF6EC)
    static let ink = NSColor(hex: 0x2A2420)
    static let inkSoft = NSColor(hex: 0x6B6052)
    static let inkFaint = NSColor(hex: 0x7D7263)
    static let terra = NSColor(hex: 0xDD6B43)
    static let terraDeep = NSColor(hex: 0xC2552F)
    static let terraText = NSColor(hex: 0xA8481F) // accessible terracotta for small text on cream
    static let green = NSColor(hex: 0x5D9A4F)
    static let yellow = NSColor(hex: 0xC99A2E)
    static let line = NSColor(hex: 0x2A2420, alpha: 0.12)
    static let lineSoft = NSColor(hex: 0x2A2420, alpha: 0.07)
    static let track = NSColor(hex: 0x2A2420, alpha: 0.09)
    static let terraSoft = NSColor(hex: 0xDD6B43, alpha: 0.12)
    static let terraSoftBorder = NSColor(hex: 0xDD6B43, alpha: 0.25)
    static let greenSoft = NSColor(hex: 0x5D9A4F, alpha: 0.14)
    static let greenSoftBorder = NSColor(hex: 0x5D9A4F, alpha: 0.28)
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Which page of the popover is currently showing. This is the single piece of
/// navigation state for the popover; it lives on `AppDelegate` (the owner of
/// `popover`/`renderPopover`) and `UsagePanelView` just renders whichever page
/// it's told to, rebuilding from scratch on every render like the rest of the panel.
/// One screen in the popover navigation stack. `.board(team:)` with a nil team
/// is the "All teams" union board.
enum PopoverScreen: Equatable {
    case main
    case teamsList
    case board(team: String?)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Popover navigation stack (bottom = .main). Back pops; the header shows a
    /// "‹ Back" only when `count > 1`, so it can never be lost to a data refresh.
    private var navStack: [PopoverScreen] = [.main]
    private var currentScreen: PopoverScreen { navStack.last ?? .main }
    /// Coalesces render requests to one per runloop tick, so a tap and the async
    /// board/requests refreshes it triggers collapse into a single rebuild.
    private var renderScheduled = false
    /// Cached pending join-requests for the selected team (owner view only).
    private var teamJoinRequests: [JoinRequestSummary] = []

    /// Persistent popover container: the panel content is swapped inside this
    /// single effect view on each render, instead of replacing the whole
    /// `contentViewController` (which flickers when renders land in quick
    /// succession — e.g. switching teams).
    private let popoverEffect: NSVisualEffectView = {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .aqua)
        effect.translatesAutoresizingMaskIntoConstraints = false
        return effect
    }()
    /// Last applied popover height, so we only resize when it actually changes.
    private var lastPopoverHeight: CGFloat = 0
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
    private var teamController = TeamController()
    private lazy var borrowController = BorrowController(multiAccount: multiAccount)
    private var notifiedIncomingBorrowIds: Set<String> = []
    private var notifiedApprovedIds: Set<String> = []
    private var notifiedDeclinedIds: Set<String> = []
    private var lastLendingTo: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            // macOS denies notifications to ad-hoc / unsigned apps with
            // UNErrorDomain code 1 ("Notifications are not allowed for this
            // application"). Delivery only works once the app is code-signed with
            // a real Developer ID (see scripts/release.sh) — no code workaround.
            if let error {
                NSLog("[Claudeometer] notifications unavailable: %@ — the app must be Developer ID-signed (ad-hoc builds are denied by macOS).", error.localizedDescription)
            }
        }
        // Actionable Approve/Reject buttons on the lender's incoming-request
        // notification (see `notifyNewIncomingBorrowRequests`, which tags its
        // content with this category, and `userNotificationCenter(_:didReceive:)`
        // below, which handles the button taps).
        let approveAction = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.authenticationRequired])
        let rejectAction = UNNotificationAction(identifier: "REJECT", title: "Reject", options: [.destructive])
        let borrowRequestCategory = UNNotificationCategory(
            identifier: "BORROW_REQUEST", actions: [approveAction, rejectAction], intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([borrowRequestCategory])

        let initialImage = makeStatusImage(text: "...", color: .systemBlue, phase: 0)
        statusItem = NSStatusBar.system.statusItem(withLength: initialImage.size.width + 8)
        statusItem.button?.image = initialImage
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        NSLog("ClaudeUsageBar status item created; button exists: \(statusItem.button != nil)")
        setTitle("...", color: .secondaryLabelColor)
        popover.behavior = .transient
        // The popover is a fixed warm-cream "brand" surface (matching the marketing
        // mockup), not a system panel — force light appearance so the vibrancy
        // backing and popover chrome don't fight the palette under Dark Mode.
        popover.appearance = NSAppearance(named: .aqua)
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
        multiAccount.onBorrowEndingSoon = { [weak self] label in
            self?.sendBorrowEndingSoonNotification(accountLabel: label)
        }
        multiAccount.onBorrowEnded = { [weak self] _ in
            self?.sendBorrowEndedNotification()
        }
        multiAccount.start()
        startTeam()
        if RelayConfig.isConfigured {
            if !teamController.isEnrolled { promptJoinTeam() }
        } else {
            promptSetupTeam()
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
                    await self.postOwnUsageToTeam(active: snapshot)
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

    /// Posts the user's OWN account usage to the team board. The gauge snapshot
    /// (`active`) is the live account — the lent one while borrowing — so to keep
    /// the board reporting your real account, fetch the self vault item separately
    /// while borrowing. When not borrowing, `active` already is your own account.
    private func postOwnUsageToTeam(active: UsageSnapshot) async {
        let cc = ClaudeometerConstants.claudeCodeKeychainService
        let ownService = multiAccount.ownUsageService(claudeCodeService: cc)
        if ownService == cc {
            await postUsageToTeam(active)            // not borrowing → active is your own
        } else if let own = try? await fetcher.fetch(service: ownService) {
            await postUsageToTeam(own)               // borrowing → report your self account
        }
        // else: self usage unavailable (e.g. token expired mid-borrow) — skip the
        // post rather than report the borrowed account's usage under your name.
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
            availableToLend: BorrowPolicy.availableToLend(fiveHourPct: fiveHourPct, sevenDayPct: sevenDayPct)
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
        navStack = [.main]
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

    /// Schedules a single render on the next runloop tick, coalescing the many
    /// render requests a team switch fires (the tap plus async board/requests
    /// refreshes) into one rebuild — eliminating the flicker/Back-button races.
    private func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.renderPopover(status: self.statusMessage)
        }
    }

    private func navPush(_ screen: PopoverScreen) {
        navStack.append(screen)
        setNeedsRender()
    }

    private func navPop() {
        if navStack.count > 1 { navStack.removeLast() }
        setNeedsRender()
    }

    private func navReplaceTop(_ screen: PopoverScreen) {
        if navStack.isEmpty { navStack = [screen] } else { navStack[navStack.count - 1] = screen }
        setNeedsRender()
    }

    /// Opens a team's board (nil = All teams): selects it, fetches its board +
    /// owner join-requests, and navigates. From the board (a ▾ switch) it swaps
    /// the current screen; from the list it pushes.
    private func openBoard(team: String?) {
        teamController.selectTeam(team)
        refreshTeamJoinRequests()
        if case .board = currentScreen {
            navReplaceTop(.board(team: team))
        } else {
            navPush(.board(team: team))
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
            activeBorrowStatus: multiAccount.activeBorrowStatus,
            screen: currentScreen,
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
                self.navPush(.teamsList)
                Task { await self.teamController.refreshMyTeams() }
            },
            onNavigateBack: { [weak self] in self?.navPop() },
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
            },
            myTeams: teamController.myTeams,
            selectedTeam: teamController.selectedTeam,
            pendingJoinRequests: teamJoinRequests,
            onOpenBoard: { [weak self] name in self?.openBoard(team: name) },
            onCreateTeam: { [weak self] in self?.promptCreateTeam() },
            onJoinNamedTeam: { [weak self] in self?.promptJoinNamedTeam() },
            onLeaveTeam: { [weak self] team in self?.confirmLeaveTeam(team) },
            onApproveJoin: { [weak self] id in self?.decideJoin(id: id, approve: true) },
            onRejectJoin: { [weak self] id in self?.decideJoin(id: id, approve: false) }
        )
        panel.translatesAutoresizingMaskIntoConstraints = false

        // Swap only the inner panel inside the persistent effect view. The panel's
        // own edge constraints go away with it (they're anchored to the child), so
        // they don't accumulate; the effect's width constraint is added once.
        popoverEffect.subviews.forEach { $0.removeFromSuperview() }
        popoverEffect.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: popoverEffect.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: popoverEffect.trailingAnchor),
            panel.topAnchor.constraint(equalTo: popoverEffect.topAnchor),
            panel.bottomAnchor.constraint(equalTo: popoverEffect.bottomAnchor)
        ])

        if popover.contentViewController == nil {
            popoverEffect.widthAnchor.constraint(equalToConstant: 340).isActive = true
            let controller = NSViewController()
            controller.view = popoverEffect
            popover.contentViewController = controller
        }
        popoverEffect.layoutSubtreeIfNeeded()

        // Only resize the popover when the height genuinely changes — an unchanged
        // contentSize assignment still nudges the window and adds to the flicker.
        let fittingHeight = min(max(popoverEffect.fittingSize.height, 1), 760)
        if abs(fittingHeight - lastPopoverHeight) > 0.5 {
            popover.contentSize = NSSize(width: 340, height: fittingHeight)
            lastPopoverHeight = fittingHeight
        }
    }

    private func startBlinking(title: String) {
        // Keep the badge's number fresh on every poll — the blink timer reads
        // `currentTitle` live, so re-entering at 90–100% updates the shown %
        // instead of freezing at the value captured when blinking first started.
        currentTitle = title
        if blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.setTitle(self.currentTitle, color: self.blinkOn ? .systemRed : .controlBackgroundColor)
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
    /// Wires the team controllers' callbacks and starts them. Polling only runs
    /// when the relay is configured and the user is enrolled. Called at launch
    /// and again after the relay URL changes.
    private func startTeam() {
        teamController.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.notifyReturnedBorrows(board: self.teamController.board, selfUserId: self.teamController.userId)
                self.setNeedsRender()
            }
        }
        borrowController.onChange = { [weak self] in
            Task { @MainActor in
                self?.notifyNewIncomingBorrowRequests()
                self?.notifyOutgoingBorrowUpdates()
                self?.setNeedsRender()
            }
        }
        teamController.start()
        if teamController.isEnrolled { borrowController.start() }
    }

    /// Re-creates the team controllers so a newly-saved relay URL takes effect
    /// immediately (the URL is resolved at controller init — no relaunch), then
    /// offers enrollment if not yet on the team.
    private func reconfigureTeam() {
        teamController = TeamController()
        borrowController = BorrowController(multiAccount: multiAccount)
        startTeam()
        renderPopover(status: statusMessage)
        if RelayConfig.isConfigured, !teamController.isEnrolled { promptJoinTeam() }
    }

    /// First-launch prompt to point the app at the team relay. Skippable — with
    /// no relay set, Claudeometer stays a personal usage meter.
    private func promptSetupTeam() {
        let alert = NSAlert()
        alert.messageText = "Connect to your team?"
        alert.informativeText = "Enter your team's relay URL to see the team usage board and borrow Claude quota. You can skip and set it later from the ••• menu."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Skip")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "https://relay.yourteam.example.com"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if saveRelayURL(trimmed) { reconfigureTeam() }
    }

    /// Writes the relay URL to the local config file `RelayConfig.resolve()` reads.
    @discardableResult
    private func saveRelayURL(_ url: String) -> Bool {
        guard let relayFileURL = Self.relayConfigFileURL() else { return false }
        do {
            try FileManager.default.createDirectory(
                at: relayFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (url + "\n").write(to: relayFileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            showErrorAlert(title: "Couldn't save relay URL", message: error.localizedDescription)
            return false
        }
    }

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

    /// Refreshes the pending join-requests for the selected team, but only when
    /// the caller owns it (members can't see them). Clears the cache otherwise.
    private func refreshTeamJoinRequests() {
        guard let team = teamController.selectedTeam, teamController.isOwner(of: team) else {
            teamJoinRequests = []
            setNeedsRender()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            self.teamJoinRequests = await self.teamController.listJoinRequests(team: team)
            self.setNeedsRender()
        }
    }

    /// Approves/rejects a pending join request on the selected team.
    private func decideJoin(id: String, approve: Bool) {
        guard let team = teamController.selectedTeam else { return }
        Task { [weak self] in
            guard let self else { return }
            if let err = await self.teamController.decideJoinRequest(team: team, id: id, approve: approve) {
                self.showErrorAlert(title: "Couldn't update request", message: err)
            }
            self.refreshTeamJoinRequests()
        }
    }

    private func confirmLeaveTeam(_ team: String) {
        let alert = NSAlert()
        alert.messageText = "Leave \(team)?"
        alert.informativeText = "You'll stop sharing usage with this team and can't borrow from its members until you rejoin."
        alert.addButton(withTitle: "Leave")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            guard let self else { return }
            if let err = await self.teamController.leaveTeam(name: team) {
                self.showErrorAlert(title: "Couldn't leave team", message: err)
            }
            self.refreshTeamJoinRequests()
        }
    }

    /// Prompts for a team name + password (+ visibility) and creates the team.
    private func promptCreateTeam() {
        guard RelayConfig.isConfigured, teamController.isEnrolled else { return }
        let alert = NSAlert()
        alert.messageText = "Create a team"
        alert.informativeText = "Pick a unique team name and a password teammates will use to join."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 82))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 56, width: 260, height: 24))
        nameField.placeholderString = "Team name"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        passField.placeholderString = "Team password"
        let publicCheck = NSButton(checkboxWithTitle: "Public (discoverable by anyone)", target: nil, action: nil)
        publicCheck.frame = NSRect(x: 0, y: 2, width: 260, height: 20)
        accessory.addSubview(nameField)
        accessory.addSubview(passField)
        accessory.addSubview(publicCheck)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passField.stringValue
        guard !name.isEmpty, !password.isEmpty else { return }
        let visibility = publicCheck.state == .on ? "public" : "private"
        Task { [weak self] in
            guard let self else { return }
            if let err = await self.teamController.createTeam(name: name, password: password, visibility: visibility) {
                self.showErrorAlert(title: "Couldn't create team", message: err)
            }
            self.refreshTeamJoinRequests()
        }
    }

    /// Prompts for a team name + password and joins (or requests to join).
    private func promptJoinNamedTeam() {
        guard RelayConfig.isConfigured, teamController.isEnrolled else { return }
        let alert = NSAlert()
        alert.messageText = "Join a team"
        alert.informativeText = "Enter the team name and password. For a public team, leave the password blank to request to join."
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        nameField.placeholderString = "Team name"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passField.placeholderString = "Team password (optional for public)"
        accessory.addSubview(nameField)
        accessory.addSubview(passField)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let password = passField.stringValue.isEmpty ? nil : passField.stringValue
        Task { [weak self] in
            guard let self else { return }
            let (err, pending) = await self.teamController.joinTeam(name: name, password: password)
            if let err {
                self.showErrorAlert(title: "Couldn't join team", message: err)
            } else if pending {
                self.showInfoAlert(title: "Request sent", message: "Your request to join \(name) is pending the owner's approval.")
            }
            self.refreshTeamJoinRequests()
        }
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Prompts for the team relay base URL and writes it to the local config
    /// file `RelayConfig.resolve()` reads at launch (see
    /// `ClaudeUsageBarCore/RelayClient.swift`). This is how a teammate points
    /// a fresh install at their team's self-hosted relay before "Join team…"
    /// becomes available. Reached from the "Set team relay URL…" overflow-menu
    /// item, which is always visible (unlike "Join team…").
    ///
    /// On save it applies immediately via `reconfigureTeam()` (re-initializing the
    /// team controllers with the new URL) — no relaunch needed.
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

        if saveRelayURL(trimmed) { reconfigureTeam() }
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
            // Lets the notification surface Approve/Reject actions (registered in
            // `applicationDidFinishLaunching`) and lets `userNotificationCenter(_:didReceive:)`
            // find the matching request when a button is tapped.
            content.categoryIdentifier = "BORROW_REQUEST"
            content.userInfo = ["requestId": request.requestId]
            let identifier = "claudeometer-borrow-\(request.requestId)"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// Fires a local notification when one of our own outgoing borrow requests
    /// is approved (or already picked up) or declined, mirroring
    /// `notifyNewIncomingBorrowRequests` above. Dedup'd by `requestId` in two
    /// separate sets so each request notifies at most once per outcome,
    /// rather than re-firing on every ~8s `borrowController` poll.
    private func notifyOutgoingBorrowUpdates() {
        for request in borrowController.outgoing {
            if request.status == "approved" || request.status == "picked_up" {
                guard !notifiedApprovedIds.contains(request.requestId) else { continue }
                notifiedApprovedIds.insert(request.requestId)
                let content = UNMutableNotificationContent()
                content.title = "Claudeometer · borrow approved"
                content.body = "\(request.lenderName) approved your request — you're on their quota for \(request.hours)h."
                content.sound = .default
                let identifier = "claudeometer-borrow-approved-\(request.requestId)"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            } else if request.status == "rejected" {
                guard !notifiedDeclinedIds.contains(request.requestId) else { continue }
                notifiedDeclinedIds.insert(request.requestId)
                let content = UNMutableNotificationContent()
                content.title = "Claudeometer · borrow declined"
                content.body = "\(request.lenderName) declined your borrow request."
                content.sound = .default
                let identifier = "claudeometer-borrow-declined-\(request.requestId)"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            }
        }
    }

    /// Posted from `MultiAccountController.onBorrowEndingSoon`, ~10 minutes
    /// before an active borrow's auto-revert timer fires. `accountLabel` is the
    /// borrowed account's label ("krish (borrowed)"); the trailing " (borrowed)"
    /// is stripped for display, mirroring `UsagePanelView.borrowingBanner`.
    private func sendBorrowEndingSoonNotification(accountLabel: String) {
        let suffix = " (borrowed)"
        let name = accountLabel.hasSuffix(suffix) ? String(accountLabel.dropLast(suffix.count)) : accountLabel
        let content = UNMutableNotificationContent()
        content.title = "Claudeometer · borrow ending soon"
        content.body = "\(name)'s quota ends in ~10 min."
        content.sound = .default
        let identifier = "claudeometer-borrow-ending-soon-\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Posted from `MultiAccountController.onBorrowEnded`, only on the
    /// AUTO-revert path — a manual "Switch back to Me" is user-initiated and
    /// never triggers this (see `MultiAccountController.switchBack(notify:)`).
    private func sendBorrowEndedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Claudeometer · borrow ended"
        content.body = "Borrow ended — you're back on your own account."
        content.sound = .default
        let identifier = "claudeometer-borrow-ended-\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Lender-side notification: fires when a teammate stops appearing in the
    /// current user's own `lendingTo` list on the team board — i.e. they
    /// finished borrowing this account. Compares against `lastLendingTo`
    /// (dedup: only notifies on the transition out, never re-fires while a
    /// borrow is still active, and never fires before enrollment/self-row
    /// lookup succeeds).
    private func notifyReturnedBorrows(board: [BoardRow], selfUserId: String?) {
        guard let selfUserId, let myRow = board.first(where: { $0.userId == selfUserId }) else { return }
        let currentLendingTo = Set(myRow.lendingTo ?? [])
        let returned = lastLendingTo.subtracting(currentLendingTo)
        for name in returned {
            let content = UNMutableNotificationContent()
            content.title = "Claudeometer · borrow returned"
            content.body = "\(name) finished borrowing your account."
            content.sound = .default
            let identifier = "claudeometer-borrow-returned-\(name)-\(Int(Date().timeIntervalSince1970))"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
        lastLendingTo = currentLendingTo
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

    /// Handles the Approve/Reject actions on the "borrow request" notification
    /// (registered as the `BORROW_REQUEST` category in
    /// `applicationDidFinishLaunching`). The async form of this delegate method
    /// (mirroring `willPresent` above) completes automatically on return — no
    /// manual completion handler to invoke.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard action == "APPROVE" || action == "REJECT" else { return }
        guard let requestId = response.notification.request.content.userInfo["requestId"] as? String else { return }
        await handleBorrowRequestAction(action, requestId: requestId)
    }

    /// Looks up `requestId` in the still-live `borrowController.incoming` and
    /// approves/rejects it. If the request is no longer present (already
    /// decided, revoked, or expired), this is a silent no-op.
    @MainActor
    private func handleBorrowRequestAction(_ action: String, requestId: String) async {
        guard let request = borrowController.incoming.first(where: { $0.requestId == requestId }) else { return }
        if action == "APPROVE" {
            _ = await borrowController.approve(request)
        } else {
            _ = await borrowController.reject(request)
        }
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
    private let onOpenBoard: (String?) -> Void
    private let onCreateTeam: () -> Void
    private let onJoinNamedTeam: () -> Void
    private let onLeaveTeam: (String) -> Void
    private let onApproveJoin: (String) -> Void
    private let onRejectJoin: (String) -> Void

    init(
        snapshot: UsageSnapshot?,
        hotSessions: [LocalSessionSummary],
        status: String?,
        accent: NSColor,
        history: [UsageHistoryPoint],
        activeBorrowStatus: (label: String, remaining: TimeInterval)? = nil,
        screen: PopoverScreen = .main,
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
        onCancelOutgoingBorrow: @escaping (String) -> Void = { _ in },
        myTeams: [TeamMembership] = [],
        selectedTeam: String? = nil,
        pendingJoinRequests: [JoinRequestSummary] = [],
        onOpenBoard: @escaping (String?) -> Void = { _ in },
        onCreateTeam: @escaping () -> Void = {},
        onJoinNamedTeam: @escaping () -> Void = {},
        onLeaveTeam: @escaping (String) -> Void = { _ in },
        onApproveJoin: @escaping (String) -> Void = { _ in },
        onRejectJoin: @escaping (String) -> Void = { _ in }
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
        self.onOpenBoard = onOpenBoard
        self.onCreateTeam = onCreateTeam
        self.onJoinNamedTeam = onJoinNamedTeam
        self.onLeaveTeam = onLeaveTeam
        self.onApproveJoin = onApproveJoin
        self.onRejectJoin = onRejectJoin
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 480))
        build(snapshot: snapshot, hotSessions: hotSessions, status: status, accent: accent, history: history,
              activeBorrowStatus: activeBorrowStatus, screen: screen, teamBoard: teamBoard, selfUserId: selfUserId,
              incomingRequests: incomingRequests, outgoingRequests: outgoingRequests,
              myTeams: myTeams, selectedTeam: selectedTeam, pendingJoinRequests: pendingJoinRequests)
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
        activeBorrowStatus: (label: String, remaining: TimeInterval)?,
        screen: PopoverScreen,
        teamBoard: [BoardRow],
        selfUserId: String?,
        incomingRequests: [IncomingRequest],
        outgoingRequests: [OutgoingRequest],
        myTeams: [TeamMembership] = [],
        selectedTeam: String? = nil,
        pendingJoinRequests: [JoinRequestSummary] = []
    ) {
        // Opaque cream card background (mockup `--card: #fbf6ec`), painted over the
        // popover's system vibrancy so the fixed brand palette always reads correctly.
        wantsLayer = true
        layer?.backgroundColor = Theme.card.cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])

        switch screen {
        case .main:
            buildMainPage(
                root: root, snapshot: snapshot, hotSessions: hotSessions, status: status,
                accent: accent, history: history, activeBorrowStatus: activeBorrowStatus,
                teamBoard: teamBoard, selfUserId: selfUserId,
                incomingRequests: incomingRequests
            )
        case .teamsList:
            buildTeamsListPage(root: root, myTeams: myTeams)
        case .board(let team):
            buildBoardPage(
                root: root, team: team, teamBoard: teamBoard, selfUserId: selfUserId,
                incomingRequests: incomingRequests, outgoingRequests: outgoingRequests,
                myTeams: myTeams, pendingJoinRequests: pendingJoinRequests
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
        activeBorrowStatus: (label: String, remaining: TimeInterval)?,
        teamBoard: [BoardRow],
        selfUserId: String?,
        incomingRequests: [IncomingRequest]
    ) {
        addFullWidth(header(snapshot: snapshot, accent: accent), to: root)

        // While borrowing, the gauge below shows the BORROWED account's usage —
        // this banner makes that unmistakable ("On krish's quota · 0:26 left").
        if let activeBorrowStatus {
            addFullWidth(
                borrowingBanner(accountLabel: activeBorrowStatus.label, remaining: activeBorrowStatus.remaining),
                to: root
            )
        }

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

    /// L1 — the Teams list: "All teams" (union board) plus each of the caller's
    /// teams as full-width rows that drill into that team's board. Create/Join
    /// live in the ⋯ menu (and as buttons in the 0-teams empty state).
    private func buildTeamsListPage(root: NSStackView, myTeams: [TeamMembership]) {
        addFullWidth(navHeader(title: "Teams"), to: root)
        addFullWidth(divider(), to: root)

        if myTeams.isEmpty {
            addFullWidth(emptyTeamsView(), to: root)
            return
        }

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(sectionHeaderLabel("YOUR TEAMS"))

        func add(_ view: NSView) {
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        add(teamListRow(name: "All teams", detail: "everyone across your teams", owned: false) { [weak self] in self?.onOpenBoard(nil) })
        for team in myTeams {
            let name = team.name
            add(teamListRow(name: name, detail: team.isOwner ? "you own this" : "member", owned: team.isOwner) { [weak self] in self?.onOpenBoard(name) })
        }
        addFullWidth(list, to: root)
    }

    /// One tappable row in the Teams list.
    private func teamListRow(name: String, detail: String, owned: Bool, _ action: @escaping () -> Void) -> NSView {
        let row = TappableRow(accessibilityLabel: name, handler: action)
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = Theme.line.cgColor
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8)
        ])
        content.addArrangedSubview(InitialsAvatarView(name: name, diameter: 28, fontSize: 12))

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        let nameLabel = label(owned ? "\(name)  ★" : name, size: 13.5, weight: .semibold, color: Theme.ink)
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(label(detail, size: 10.5, weight: .regular, color: Theme.inkFaint))
        content.addArrangedSubview(textStack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(spacer)
        content.addArrangedSubview(label("›", size: 15, weight: .semibold, color: Theme.inkFaint))
        return row
    }

    /// 0-teams empty state — the one place Create/Join appear inline (an empty
    /// list has no rows to anchor discovery), teaching that they're also in ⋯.
    private func emptyTeamsView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label("You're not on a team yet.", size: 13, weight: .semibold, color: Theme.ink))
        let sub = label("Create one to share usage, or join a\nteam with its name and password.", size: 11.5, weight: .regular, color: Theme.inkSoft)
        sub.alignment = .center
        sub.maximumNumberOfLines = 3
        stack.addArrangedSubview(sub)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.addArrangedSubview(ActionButton(title: "Create", style: .filled) { [weak self] in self?.onCreateTeam() })
        buttons.addArrangedSubview(ActionButton(title: "Join", style: .ghost) { [weak self] in self?.onJoinNamedTeam() })
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(label("You can also find these in the ⋯ menu.", size: 10.5, weight: .regular, color: Theme.inkFaint))
        return stack
    }

    /// L2 — a single team's board (nil = the "All teams" union): owner join
    /// requests, the member board, borrow section, and a Leave row.
    private func buildBoardPage(
        root: NSStackView,
        team: String?,
        teamBoard: [BoardRow],
        selfUserId: String?,
        incomingRequests: [IncomingRequest],
        outgoingRequests: [OutgoingRequest],
        myTeams: [TeamMembership],
        pendingJoinRequests: [JoinRequestSummary]
    ) {
        addFullWidth(navHeader(backLabel: "Teams", title: team ?? "All teams"), to: root)
        addFullWidth(divider(), to: root)

        // Owner-only: pending ask-to-join requests, at the top of the board.
        if !pendingJoinRequests.isEmpty {
            addFullWidth(joinRequestsSection(pendingJoinRequests), to: root)
            addFullWidth(divider(), to: root)
        }

        let pendingOutgoing = outgoingRequests.filter { $0.status == "pending" || $0.status == "approved" }
        // Lenders this device has a pending request to → show "Requested" instead
        // of another "Request 2h".
        let pendingLenderIds = Set(outgoingRequests.filter { $0.status == "pending" }.map(\.lenderId))

        if !teamBoard.isEmpty {
            addFullWidth(teamSection(teamBoard, selfUserId: selfUserId, pendingLenderIds: pendingLenderIds), to: root)
        } else {
            addFullWidth(label("No teammates posting usage yet.", size: 12, weight: .regular, color: Theme.inkSoft), to: root)
        }

        if !incomingRequests.isEmpty || !pendingOutgoing.isEmpty {
            addFullWidth(divider(), to: root)
            addFullWidth(borrowSection(incoming: incomingRequests, outgoing: pendingOutgoing), to: root)
        }

        // Leave — only for a specific team the user is in (not the "All" view).
        if let team, myTeams.contains(where: { $0.name == team }) {
            addFullWidth(divider(), to: root)
            addFullWidth(leaveTeamRow(team: team), to: root)
        }
    }

    /// Owner's pending ask-to-join requests, each with Approve / Reject.
    private func joinRequestsSection(_ requests: [JoinRequestSummary]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sectionHeaderLabel("JOIN REQUESTS"))
        for req in requests {
            let container = NSStackView()
            container.orientation = .horizontal
            container.alignment = .centerY
            container.spacing = 9
            container.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(InitialsAvatarView(name: req.userName, diameter: 26, fontSize: 11))
            let text = label("\(req.userName) wants to join", size: 12.5, weight: .regular, color: Theme.ink)
            text.maximumNumberOfLines = 1
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            container.addArrangedSubview(text)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            container.addArrangedSubview(spacer)
            let id = req.id
            container.addArrangedSubview(ActionButton(title: "Approve", style: .filled) { [weak self] in self?.onApproveJoin(id) })
            container.addArrangedSubview(ActionButton(title: "Reject", style: .ghost) { [weak self] in self?.onRejectJoin(id) })
            stack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A muted "Leave <team>" tappable row.
    private func leaveTeamRow(team: String) -> NSView {
        let row = TappableRow(accessibilityLabel: "Leave \(team)") { [weak self] in self?.onLeaveTeam(team) }
        let lbl = label("Leave \(team)", size: 12, weight: .regular, color: Theme.terraText)
        row.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            lbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            lbl.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4)
        ])
        return row
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func header(snapshot: UsageSnapshot?, accent: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false

        // The badge is always brand-terra (mockup `.pop-badge`), not tinted by
        // `accent` — usage level is already conveyed by the hero number, gauge,
        // and week/team row colors below, so the badge stays pure branding.
        let icon = AnimatedBadgeView()
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true
        row.addArrangedSubview(icon)

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 1
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.addArrangedSubview(label("Claudeometer", size: 15, weight: .bold, color: Theme.ink))
        let email = label(snapshot?.accountEmail ?? "Claude Code account", size: 12, weight: .regular, color: Theme.inkSoft)
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
    /// Robust nav header used by the team-list and board screens: a "‹ <back>"
    /// control with a guaranteed hit-area and required compression resistance (so
    /// no data refresh or long title can ever squeeze the Back control away),
    /// plus a bold title on the right.
    private func navHeader(backLabel: String = "Back", title: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true

        let back = TappableRow(accessibilityLabel: "Back") { [weak self] in self?.onNavigateBack() }
        back.setContentCompressionResistancePriority(.required, for: .horizontal)
        back.setContentHuggingPriority(.required, for: .horizontal)
        let backContent = NSStackView()
        backContent.orientation = .horizontal
        backContent.alignment = .centerY
        backContent.spacing = 2
        backContent.translatesAutoresizingMaskIntoConstraints = false
        backContent.addArrangedSubview(label("‹", size: 17, weight: .semibold, color: Theme.terraText))
        let backText = label(backLabel, size: 13, weight: .medium, color: Theme.terraText)
        backText.setContentCompressionResistancePriority(.required, for: .horizontal)
        backContent.addArrangedSubview(backText)
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

        let titleLabel = label(title, size: 15, weight: .bold, color: Theme.ink)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(titleLabel)

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

    /// Prominent full-width soft-terra banner shown on the personal page while
    /// borrowing a teammate's quota, making clear the gauge % below is the
    /// BORROWED account's usage, not the user's own. Same soft-terra palette as
    /// the borrow pills, just full-width and roomier. `accountLabel` is the
    /// borrowed account's label ("krish (borrowed)"); a trailing " (borrowed)"
    /// is stripped for display, and `remaining` renders as an `H:MM` countdown.
    private func borrowingBanner(accountLabel: String, remaining: TimeInterval) -> NSView {
        let suffix = " (borrowed)"
        let name = accountLabel.hasSuffix(suffix) ? String(accountLabel.dropLast(suffix.count)) : accountLabel
        let text = "⤢  On \(name)'s quota · \(formatHMM(remaining)) left"

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.terraSoft.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.terraSoftBorder.cgColor

        let textLabel = label(text, size: 12.5, weight: .semibold, color: Theme.terraText)
        textLabel.maximumNumberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            textLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            textLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9)
        ])
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
        headerRow.addArrangedSubview(label(moodEmoji(for: formatPercent(five)), size: 15, weight: .regular, color: Theme.ink))
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Big serif display percentage (mockup `.hero-pct`, Fraunces 900) via
        // AppKit's built-in New York serif design — see `heroFont` below.
        let heroNumber = label(formatPercent(five), size: 46, weight: .black, color: Theme.ink)
        heroNumber.font = Self.heroFont(size: 46, weight: .black)
        stack.addArrangedSubview(heroNumber)

        let (burn, eta) = burnRateAndETA(history: history, currentFiveHour: five)
        let subtitle = NSTextField(labelWithAttributedString: heroSubtitleAttributed(burn: burn, eta: eta))
        subtitle.maximumNumberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(subtitle)

        // Horizontal green→yellow→terra gauge gradient (mockup `.bar > i`), not
        // tinted by `accent` — the gradient itself communicates the level.
        let bar = ProgressBarView(value: five / 100, gradientColors: [Theme.green, Theme.yellow, Theme.terra])
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if let resetsAt = snapshot.usage.fiveHour?.resetsAt {
            let caption = label("resets \(resetText(resetsAt))", size: 11, weight: .regular, color: Theme.inkFaint)
            caption.maximumNumberOfLines = 1
            caption.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(caption)
        }

        return stack
    }

    /// Builds the mockup's `<b>+14%/hr ↑</b> · full in ~3h` treatment: a bold
    /// terra-tinted burn-rate lead followed by a muted ink-soft ETA.
    private func heroSubtitleAttributed(burn: Double?, eta: String?) -> NSAttributedString {
        guard let burn else {
            return NSAttributedString(string: "collecting pace…", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: Theme.inkSoft
            ])
        }
        let steady = (eta == "holding steady") || burn <= 0
        let arrow = steady ? "→" : "↑"
        let sign = burn > 0 ? "+" : ""
        let lead = "\(sign)\(Int(burn))%/hr \(arrow)"

        let result = NSMutableAttributedString(string: lead, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: Theme.terraText
        ])
        if let eta {
            result.append(NSAttributedString(string: " · \(eta)", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: Theme.inkSoft
            ]))
        }
        return result
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

        // The weekly windows all roll over together, so the first one carrying a
        // `resets_at` speaks for the section — mirroring the 5-hour hero caption.
        if let resetsAt = weeklyResetsAt(snapshot.usage) {
            let caption = label("resets \(resetText(resetsAt))", size: 11, weight: .regular, color: Theme.inkFaint)
            caption.maximumNumberOfLines = 1
            caption.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(caption)
        }

        return stack
    }

    private func addWeekRow(_ title: String, _ window: UsageWindow?, to stack: NSStackView) {
        guard let window else { return }
        let row = weekRow(title, window)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func weekRow(_ title: String, _ window: UsageWindow) -> NSView {
        let tint = themeLevelColor(for: window.utilization)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let name = label(title, size: 13, weight: .regular, color: Theme.ink)
        name.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: 104).isActive = true
        row.addArrangedSubview(name)

        let bar = ProgressBarView(value: window.utilization / 100, color: tint)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(bar)

        // Mockup keeps the numeric value plain ink text (`.qrow .val`) — only the
        // bar fill is tinted by level.
        let pct = monoLabel(formatPercent(window.utilization), size: 13, weight: .bold, color: Theme.ink)
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

        // Mockup's pace sparkline is always brand-terra, not `accent`-tinted
        // (its gradient stop is a fixed `#dd6b43`).
        let spark = SparklineView(points: history, accent: Theme.terra)
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

        let title = label(session.displayName, size: 12, weight: .semibold, color: Theme.ink)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.toolTip = "\(session.displayName)\n\(session.path)"
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let tokens = monoLabel(formatCompactTokens(session.tokens), size: 12, weight: .regular, color: Theme.inkFaint)
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
        container.addArrangedSubview(monoLabel(valueText, size: 13, weight: .semibold, color: Theme.ink))
        return container
    }

    /// Team board: one row per teammate, busiest (highest 5-hour usage) first.
    /// Rows with no usage posted yet (`fiveHourPct == nil`) sort last.
    private func teamSection(_ board: [BoardRow], selfUserId: String?, pendingLenderIds: Set<String> = []) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionHeaderLabel("TEAM"))

        // The current user's own row carries who they're borrowing FROM (a display
        // name) and until when — used below to swap a lender's "Request 2h" button
        // for a "Borrowing · H:MM" status pill on the row you're already borrowing from.
        let myRow = selfUserId.flatMap { id in board.first { $0.userId == id } }

        // Online teammates first, then least-depleted first within each group —
        // so the best borrow candidates (online + most headroom) sit at the top.
        let sorted = TeamBoardSort.forDisplay(board, now: Date())
        for row in sorted {
            let view = teamRow(
                row,
                isSelf: selfUserId != nil && row.userId == selfUserId,
                myBorrowingFrom: myRow?.borrowingFrom,
                myBorrowingUntil: myRow?.borrowingUntil,
                myFiveHourPct: myRow?.fiveHourPct,
                mySevenDayPct: myRow?.sevenDayPct,
                hasPendingRequest: pendingLenderIds.contains(row.userId)
            )
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    /// One row of the team board (mockup `.team-row`): avatar + name/reset (and
    /// a trailing "Request 2h" button on lendable rows, or a "Borrowing · H:MM"
    /// pill on the row you're already borrowing from) on top; then any
    /// borrow/lend pill on its own full-width line; then a slim level-tinted
    /// mini-bar + % — all indented past the avatar so they align under the name.
    ///
    /// `myBorrowingFrom`/`myBorrowingUntil` are the current user's own active
    /// borrow (lender display name + unix end time), used only to decide the
    /// trailing affordance; nil when the user isn't borrowing.
    private func teamRow(
        _ row: BoardRow,
        isSelf: Bool,
        myBorrowingFrom: String? = nil,
        myBorrowingUntil: Int? = nil,
        myFiveHourPct: Double? = nil,
        mySevenDayPct: Double? = nil,
        hasPendingRequest: Bool = false
    ) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 7
        container.translatesAutoresizingMaskIntoConstraints = false

        // Presence/freshness from the teammate's last usage post — drives the
        // avatar status dot, the "· Xm ago" caption color, and stale dimming.
        let activity = TeamActivity.classify(postedAt: row.postedAt, now: Date())

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 9
        top.translatesAutoresizingMaskIntoConstraints = false

        let avatar = InitialsAvatarView(name: row.displayName, diameter: 26, fontSize: 11, activity: activity)
        top.addArrangedSubview(avatar)

        let nameStack = NSStackView()
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 1
        nameStack.translatesAutoresizingMaskIntoConstraints = false

        let nameText = isSelf ? "\(row.displayName) (you)" : row.displayName
        let nameLabel = label(nameText, size: 13.5, weight: .semibold, color: Theme.ink)
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameStack.addArrangedSubview(nameLabel)

        // Caption combines the reset phrase with a "· Xm ago" freshness suffix,
        // so a teammate who closed their laptop at 25% shows how old that number
        // is instead of looking current. Amber once genuinely stale.
        let resetText = row.resetAt.map { "resets \(relativeResetText(Date(timeIntervalSince1970: TimeInterval($0))))" }
        let (captionText, isStale) = TeamActivity.caption(resetText: resetText, postedAt: row.postedAt, now: Date())
        if let captionText {
            let caption = label(captionText, size: 10.5, weight: .regular, color: isStale ? Theme.yellow : Theme.inkFaint)
            caption.maximumNumberOfLines = 1
            caption.lineBreakMode = .byTruncatingTail
            nameStack.addArrangedSubview(caption)
        }
        top.addArrangedSubview(nameStack)

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(topSpacer)

        // Trailing affordance on the name line (right side). If the user is
        // already borrowing FROM this teammate, show a non-interactive
        // "Borrowing · H:MM" status pill instead of another request button —
        // even if this teammate is no longer flagged `availableToLend` (they're
        // lending to you). Otherwise a lendable teammate keeps "Request 2h". The
        // borrow/lend pills below move to their own full-width line(s), so this
        // trailing item never competes with them for width and truncates.
        if !isSelf {
            if let myBorrowingFrom, row.displayName == myBorrowingFrom {
                top.addArrangedSubview(pillTag("Borrowing · \(borrowCountdownText(until: myBorrowingUntil))", style: .borrow))
            } else if hasPendingRequest {
                // Already asked this teammate — one outstanding request per lender
                // until they approve or reject, so show a non-interactive status
                // instead of another "Request 2h".
                top.addArrangedSubview(pillTag("Requested", style: .neutral))
            } else if BorrowPolicy.canBorrow(
                mineFive: myFiveHourPct,
                mineSeven: mySevenDayPct,
                lenderFive: row.fiveHourPct,
                lenderSeven: row.sevenDayPct
            ) {
                top.addArrangedSubview(ActionButton(title: "Request 2h", style: .ghost) { [weak self] in
                    self?.onRequestBorrow(row.userId)
                })
            }
        }

        container.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        // Active-borrow visibility (relay v0.2.1+): surfaces that this member's
        // usage is currently propped up by someone else's quota (borrowing) or
        // that they're propping up teammates (lending), so a high `fiveHourPct`
        // doesn't get mistaken for "heavy user of their own quota." Independent
        // conditions (unchanged from before) — a row can show more than one, each
        // on its OWN full-width line so the full pill text always shows.
        if let borrowingFrom = row.borrowingFrom {
            let countdown = borrowCountdownText(until: row.borrowingUntil)
            let line = pillLine(pillTag("↔ borrowing from \(borrowingFrom) · \(countdown)", style: .borrow))
            container.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        if let lendingTo = row.lendingTo, !lendingTo.isEmpty {
            let line = pillLine(pillTag("↑ lending to \(lendingTo.joined(separator: ", "))", style: .lend))
            container.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 10
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let tint = row.fiveHourPct.map(themeLevelColor(for:)) ?? Theme.track
        let bar = ProgressBarView(value: (row.fiveHourPct ?? 0) / 100, color: tint)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(bar)

        // Mockup keeps `.team-val` plain ink text — only the bar fill is level-tinted.
        let pctText = row.fiveHourPct.map(formatPercent) ?? "—"
        let pct = monoLabel(pctText, size: 12, weight: .bold, color: Theme.ink)
        pct.alignment = .right
        pct.widthAnchor.constraint(equalToConstant: 34).isActive = true
        bottom.addArrangedSubview(pct)

        // Indent the mini-bar row so it lines up under the name, past the avatar
        // (mockup `.team-bottom { padding-left: 35px }`).
        let indented = NSStackView()
        indented.orientation = .horizontal
        indented.alignment = .centerY
        indented.translatesAutoresizingMaskIntoConstraints = false
        let leadingSpacer = NSView()
        leadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        leadingSpacer.widthAnchor.constraint(equalToConstant: 35).isActive = true
        indented.addArrangedSubview(leadingSpacer)
        indented.addArrangedSubview(bottom)
        // Fade the bar + % when the number is stale so it visibly recedes and
        // isn't mistaken for a current reading.
        indented.alphaValue = isStale ? 0.4 : 1.0
        container.addArrangedSubview(indented)
        indented.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        return container
    }

    private enum PillStyle {
        case borrow
        case lend
        case neutral
    }

    /// Small rounded pill matching the mockup's `.team-tag.borrow` / `.team-tag.lend`
    /// — soft terra for "borrowing from …", soft green for "lending to …".
    private func pillTag(_ text: String, style: PillStyle) -> NSView {
        let (background, border, textColor): (NSColor, NSColor, NSColor)
        switch style {
        case .borrow: (background, border, textColor) = (Theme.terraSoft, Theme.terraSoftBorder, Theme.terraText)
        case .lend: (background, border, textColor) = (Theme.greenSoft, Theme.greenSoftBorder, Theme.green)
        case .neutral: (background, border, textColor) = (Theme.track, Theme.line, Theme.inkSoft)
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.backgroundColor = background.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = border.cgColor
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textLabel = label(text, size: 10, weight: .semibold, color: textColor)
        textLabel.maximumNumberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            textLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            textLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3)
        ])
        return container
    }

    /// Places a borrow/lend pill on its own full-width line, indented 35pt to
    /// align under the name (past the avatar, like the mini-bar row). The pill
    /// sizes to its content, left-aligned; a low-priority trailing spacer absorbs
    /// the remaining width so the pill neither stretches nor gets squeezed by the
    /// "Request 2h" button (which now lives on the name line above).
    private func pillLine(_ pill: NSView) -> NSView {
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 0
        line.translatesAutoresizingMaskIntoConstraints = false

        let leadingSpacer = NSView()
        leadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        leadingSpacer.widthAnchor.constraint(equalToConstant: 35).isActive = true
        line.addArrangedSubview(leadingSpacer)

        line.addArrangedSubview(pill)

        let trailingSpacer = NSView()
        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        trailingSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        line.addArrangedSubview(trailingSpacer)

        return line
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
        stack.spacing = 14
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

    /// Styled like the mockup's "Borrow request" card body: avatar, a
    /// "**Name** wants **Nh** of your Claude." line, then full-width
    /// Approve (filled terra) / Reject (ghost) actions.
    private func incomingRequestRow(_ request: IncomingRequest) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 12
        card.translatesAutoresizingMaskIntoConstraints = false

        let ask = NSStackView()
        ask.orientation = .horizontal
        ask.alignment = .top
        ask.spacing = 12
        ask.translatesAutoresizingMaskIntoConstraints = false

        let avatar = InitialsAvatarView(name: request.requesterName, diameter: 34, fontSize: 13)
        ask.addArrangedSubview(avatar)

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 3
        copy.translatesAutoresizingMaskIntoConstraints = false

        let textLabel = NSTextField(labelWithAttributedString: borrowAskAttributed(name: request.requesterName, hours: request.hours))
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        copy.addArrangedSubview(textLabel)

        // The relay doesn't expose the request's server-side expiry to the
        // client, so — unlike the mockup's illustrative "expires in 4:58" —
        // this shows real data: how long ago the request actually came in.
        let askedAt = Date(timeIntervalSince1970: TimeInterval(request.createdAt))
        copy.addArrangedSubview(label("asked \(relative(askedAt))", size: 10.5, weight: .regular, color: Theme.inkFaint))

        ask.addArrangedSubview(copy)
        card.addArrangedSubview(ask)
        ask.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.addArrangedSubview(ActionButton(title: "Approve", style: .filled) { [weak self] in self?.onApproveBorrow(request) })
        buttons.addArrangedSubview(ActionButton(title: "Reject", style: .ghost) { [weak self] in self?.onRejectBorrow(request) })
        card.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true

        return card
    }

    /// "**Arjun** wants **2h** of your Claude." (mockup `.borrow-text b`).
    private func borrowAskAttributed(name: String, hours: Int) -> NSAttributedString {
        let regular: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: Theme.ink
        ]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: Theme.ink
        ]
        let result = NSMutableAttributedString(string: name, attributes: bold)
        result.append(NSAttributedString(string: " wants ", attributes: regular))
        result.append(NSAttributedString(string: "\(hours)h", attributes: bold))
        result.append(NSAttributedString(string: " of your Claude.", attributes: regular))
        return result
    }

    private func outgoingRequestRow(_ request: OutgoingRequest) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let statusText = request.status == "approved" ? "approved — picking up…" : "waiting for \(request.lenderName)…"
        let text = label("Requested \(request.hours)h from \(request.lenderName) (\(statusText))",
                         size: 12, weight: .regular, color: Theme.inkSoft)
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(text)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(spacer)

        let requestId = request.requestId
        let cancel = ActionButton(title: "Cancel", style: .ghost) { [weak self] in self?.onCancelOutgoingBorrow(requestId) }
        container.addArrangedSubview(cancel)

        return container
    }

    /// Compact nav row on the main page that opens the team page. Shows a
    /// light-touch hint (pending incoming requests, lendable teammates, or a
    /// plain member count, in that priority order) so there's a reason to tap
    /// in even when nothing needs attention.
    private func teamNavRow(board: [BoardRow], selfUserId: String?, incoming: [IncomingRequest]) -> NSView {
        let row = TappableRow(accessibilityLabel: "Team") { [weak self] in self?.onNavigateToTeam() }
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = Theme.line.cgColor
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

        content.addArrangedSubview(label("Teams", size: 13, weight: .medium, color: Theme.ink))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(spacer)

        if let hint = teamNavHint(board: board, selfUserId: selfUserId, incoming: incoming) {
            content.addArrangedSubview(hint)
        }

        content.addArrangedSubview(label("›", size: 15, weight: .semibold, color: Theme.inkFaint))

        return row
    }

    /// Picks the single most useful hint for the "Team ›" row: a pending
    /// incoming-request badge outranks a lendable-teammate count, which
    /// outranks a plain member count. Returns nil (no hint) once the board
    /// has nothing to say — e.g. right after enrolling, before anyone has
    /// posted usage yet.
    private func teamNavHint(board: [BoardRow], selfUserId: String?, incoming: [IncomingRequest]) -> NSView? {
        if !incoming.isEmpty {
            return badge(text: "\(incoming.count) request\(incoming.count == 1 ? "" : "s")", color: Theme.terraDeep)
        }
        let myRow = selfUserId.flatMap { id in board.first { $0.userId == id } }
        let lendable = board.filter {
            $0.userId != selfUserId && BorrowPolicy.canBorrow(
                mineFive: myRow?.fiveHourPct,
                mineSeven: myRow?.sevenDayPct,
                lenderFive: $0.fiveHourPct,
                lenderSeven: $0.sevenDayPct
            )
        }.count
        if lendable > 0 {
            return label("\(lendable) lendable", size: 11, weight: .regular, color: Theme.inkSoft)
        }
        if !board.isEmpty {
            return label("\(board.count) teammate\(board.count == 1 ? "" : "s")", size: 11, weight: .regular, color: Theme.inkFaint)
        }
        return nil
    }

    /// Small rounded pill used for the incoming-request count on the nav row —
    /// same tinted-pill language as `pillTag`/`ProgressBarView`'s rounded style.
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
        row.addArrangedSubview(label(updatedText, size: 11, weight: .regular, color: Theme.inkFaint))

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
        button.contentTintColor = Theme.inkSoft
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private static func heroFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // Start from the monospaced-digit system font (so the hero number never jitters
        // as digits change), then swap in the serif design — AppKit's built-in "New
        // York" — to match the mockup's big Fraunces display percentage (`.hero-pct`).
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    @objc private func refreshTapped() { onRefresh() }
    @objc private func openTapped() { onOpenSettings() }
    @objc private func loginTapped() { onLogin() }
    @objc private func quitTapped() { onQuit() }
    @objc private func joinTeamMenuItemTapped() { onJoinTeam() }
    @objc private func createTeamMenuItemTapped() { onCreateTeam() }
    @objc private func joinNamedTeamMenuItemTapped() { onJoinNamedTeam() }
    @objc private func setTeamRelayURLMenuItemTapped() { onSetTeamRelayURL() }

    @objc private func overflowTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open usage", action: #selector(openTapped), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let loginItem = NSMenuItem(title: "Login", action: #selector(loginTapped), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        if isTeamEnrolled {
            // Multi-team actions, moved out of the on-screen UI into the menu.
            let createItem = NSMenuItem(title: "Create team…", action: #selector(createTeamMenuItemTapped), keyEquivalent: "")
            createItem.target = self
            menu.addItem(createItem)
            let joinNamedItem = NSMenuItem(title: "Join team…", action: #selector(joinNamedTeamMenuItemTapped), keyEquivalent: "")
            joinNamedItem.target = self
            menu.addItem(joinNamedItem)
        } else {
            // Not yet enrolled → the one-time "join the relay under a name" flow.
            let joinTeamItem = NSMenuItem(title: "Join team…", action: #selector(joinTeamMenuItemTapped), keyEquivalent: "")
            joinTeamItem.target = self
            menu.addItem(joinTeamItem)
        }
        // Always visible: this is how a teammate
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

/// A small pill-shaped button matching the mockup's `.btn-primary` (filled
/// terra) / `.btn-ghost` (outlined) treatments, with hover/pressed feedback —
/// AppKit's stock bezel styles can't produce this shape, so it's fully
/// custom-drawn. Fires a closure instead of a target/action selector, so
/// per-row borrow actions (Request/Approve/Reject/Cancel) can capture the
/// row's own value (lender id, request) directly instead of round-tripping
/// through `representedObject` (which `NSButton`, unlike `NSMenuItem`, doesn't have).
final class ActionButton: NSButton {
    enum Style {
        case filled
        case ghost
    }

    private var handler: (() -> Void)?
    private let style: Style
    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(title: String, style: Style = .ghost, handler: @escaping () -> Void) {
        self.style = style
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        self.target = self
        self.action = #selector(fire)
        wantsLayer = true
        font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        guard base.width.isFinite else { return NSSize(width: 60, height: 26) }
        return NSSize(width: base.width + 22, height: 26)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        super.mouseDown(with: event) // blocks until mouseUp; preserves NSButton's click/target flow
        isPressed = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        let fill: NSColor
        let border: NSColor?
        let textColor: NSColor
        switch style {
        case .filled:
            let base = Theme.terraDeep
            if isPressed {
                fill = base.blended(withFraction: 0.18, of: .black) ?? base
            } else if isHovering {
                fill = base.blended(withFraction: 0.12, of: .white) ?? base
            } else {
                fill = base
            }
            border = nil
            textColor = .white
        case .ghost:
            fill = isPressed ? Theme.line : (isHovering ? Theme.lineSoft : .clear)
            border = Theme.line
            textColor = Theme.ink
        }

        fill.setFill()
        path.fill()
        if let border {
            path.lineWidth = 1
            border.setStroke()
            path.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: textColor
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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

/// Circular initials avatar (mockup `.team-avatar` / `.borrow-avatar`): a
/// solid terra-deep disc with the person's first initial in white, bold.
final class InitialsAvatarView: NSView {
    private let initial: String
    private let fontSize: CGFloat
    /// Presence state for the corner status dot. `nil` (the default) draws no
    /// dot, so avatars outside the team board (e.g. borrow cards) are unchanged.
    private let activity: TeamActivity?

    init(name: String, diameter: CGFloat, fontSize: CGFloat, activity: TeamActivity? = nil) {
        self.initial = InitialsAvatarView.firstLetter(of: name)
        self.fontSize = fontSize
        self.activity = activity
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func firstLetter(of name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.terraDeep.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let text = initial as NSString
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5)
        text.draw(at: origin, withAttributes: attributes)

        if let activity {
            drawStatusDot(online: activity.isOnline)
        }
    }

    /// A small presence dot flush in the bottom-right, overlapping the disc edge,
    /// with a card-colored ring so it reads as a separate badge: solid green when
    /// online, hollow-looking faint ink when offline/idle/stale.
    private func drawStatusDot(online: Bool) {
        let ring: CGFloat = 1.5
        let dotDiameter = (bounds.width * 0.32).rounded()
        let outer = dotDiameter + ring * 2
        let outerRect = NSRect(x: bounds.maxX - outer, y: bounds.minY, width: outer, height: outer)
        Theme.card.setFill()
        NSBezierPath(ovalIn: outerRect).fill()

        let dotColor = online ? Theme.green : Theme.inkFaint.withAlphaComponent(0.45)
        dotColor.setFill()
        NSBezierPath(ovalIn: outerRect.insetBy(dx: ring, dy: ring)).fill()
    }
}

/// Rounded-cap progress track (mockup `.bar`/`.mini-bar`/`.qrow .mini`), fixed
/// to the warm `Theme.track` background in every instance. Supports either a
/// single-hue fill (week/team rows, tinted green/yellow/terra by level) or a
/// multi-stop horizontal gradient fill (the 5-hour hero gauge).
final class ProgressBarView: NSView {
    private enum FillMode {
        case solid(NSColor)
        case gradient([NSColor])
    }

    private let value: Double
    private let fillMode: FillMode

    init(value: Double, color: NSColor) {
        self.value = min(max(value, 0), 1)
        self.fillMode = .solid(color)
        super.init(frame: .zero)
        wantsLayer = true
    }

    /// Horizontal gradient fill matching the mockup's
    /// `.bar > i { background: linear-gradient(90deg, green, yellow 62%, terra) }` —
    /// the gradient spans whatever width is currently filled, not the full track,
    /// so it always shows the same green→yellow→terra sweep regardless of value.
    init(value: Double, gradientColors: [NSColor]) {
        self.value = min(max(value, 0), 1)
        self.fillMode = .gradient(gradientColors)
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        Theme.track.setFill()
        track.fill()

        let fillWidth = bounds.width * value
        guard fillWidth > 0 else { return }
        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: fillWidth, height: bounds.height)
        let fillRadius = min(radius, fillWidth / 2)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)

        switch fillMode {
        case .solid(let color):
            color.setFill()
            fillPath.fill()
        case .gradient(let colors) where colors.count >= 2:
            NSGraphicsContext.saveGraphicsState()
            fillPath.addClip()
            let locations: [CGFloat] = colors.count == 3
                ? [0, 0.62, 1]
                : (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
            NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)?
                .draw(in: fillRect, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        case .gradient(let colors):
            (colors.first ?? Theme.terra).setFill()
            fillPath.fill()
        }
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
        Theme.lineSoft.setStroke()
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
            .foregroundColor: Theme.inkFaint
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
    /// Fetches usage for the credential stored under `service`. The caller
    /// chooses which account to read: the live Claude Code item (the active
    /// account — borrowed while borrowing) for the gauge, or a self vault item
    /// for the team-board post. Defaults to the live Claude Code item.
    func fetch(service: String = ClaudeometerConstants.claudeCodeKeychainService) async throws -> UsageSnapshot {
        let credentials = try readCredentials(service: service)

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

    private func readCredentials(service: String) throws -> OAuthCredentials {
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

/// The weekly rollover reported by the API. `seven_day` is the headline window,
/// but a plan that only exposes the per-model ones still has a reset to show, so
/// fall through to those rather than dropping the caption.
private func weeklyResetsAt(_ usage: UsageResponse) -> Date? {
    usage.sevenDay?.resetsAt
        ?? usage.sevenDaySonnet?.resetsAt
        ?? usage.sevenDayOpus?.resetsAt
        ?? usage.sevenDayOAuthApps?.resetsAt
}

private func resetText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE HH:mm"
    let delta = Int(date.timeIntervalSinceNow)
    guard delta > 0 else { return formatter.string(from: date) }
    return "\(formatter.string(from: date)) · \(relativeResetText(date))"
}

/// Just the relative half of `resetText` — "in 42m" / "in 3h 58m" — used on
/// its own for the team board's compact "resets in Xm" captions, matching the
/// mockup's `.team-reset` (no absolute weekday/time there, unlike the
/// personal hero gauge's fuller "resets Wed 14:15 · in 2h 50m").
private func relativeResetText(_ date: Date) -> String {
    let delta = Int(date.timeIntervalSinceNow)
    guard delta > 0 else { return "now" }
    let days = delta / 86_400
    let hours = (delta % 86_400) / 3_600
    let minutes = (delta % 3_600) / 60
    if days > 0 { return "in \(days)d \(hours)h" }
    if hours > 0 { return "in \(hours)h \(minutes)m" }
    return "in \(minutes)m"
}

/// Formats a duration in seconds as `H:MM` (e.g. `0:26`, `1:23`). Clamps
/// negatives to `0:00`, so an expired window reads as `0:00` rather than a
/// negative/garbage duration.
private func formatHMM(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 3_600, (total % 3_600) / 60)
}

/// Formats the time remaining until `until` (unix time) as `H:MM`, for the
/// "borrowing from … · <countdown>" tag on the team page. Returns `0:00` when
/// `until` is nil or already in the past.
private func borrowCountdownText(until: Int?) -> String {
    guard let until else { return "0:00" }
    return formatHMM(TimeInterval(until - Int(Date().timeIntervalSince1970)))
}

private func relative(_ date: Date) -> String {
    let seconds = max(0, Int(-date.timeIntervalSinceNow))
    if seconds < 60 { return "\(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    return "\(minutes / 60)h ago"
}

/// Discrete green/yellow/terra tiering for single-hue fills (week rows, team
/// rows) — matches the mockup's example data thresholds, as distinct from
/// `gradientColor(for:)`'s continuous system-color ramp used for the menu-bar
/// title/icon (untouched — outside the popover's scope).
private func themeLevelColor(for utilization: Double) -> NSColor {
    if utilization >= 75 { return Theme.terra }
    if utilization >= 40 { return Theme.yellow }
    return Theme.green
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

/// Uppercase, letter-spaced section kicker (mockup `.sec-label`/`.eyebrow-sm`:
/// 11px/700/uppercase/`0.06em`/ink-soft). Uppercases unconditionally so call
/// sites can pass natural-case text.
@MainActor
private func sectionHeaderLabel(_ text: String, tracking: CGFloat = 0.4) -> NSTextField {
    let upper = text.uppercased()
    let font = NSFont.systemFont(ofSize: 11, weight: .bold)
    let field = NSTextField(labelWithString: upper)
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.translatesAutoresizingMaskIntoConstraints = false
    field.attributedStringValue = NSAttributedString(
        string: upper,
        attributes: [
            .font: font,
            .foregroundColor: Theme.inkSoft,
            .kern: tracking
        ]
    )
    return field
}

@MainActor
private func divider() -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.backgroundColor = Theme.lineSoft.cgColor
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

/// Animated header badge (mockup `.pop-badge`): a terra→terra-deep gradient
/// chip with the shimmering Claude sunburst mark. Always brand-terra — not
/// tinted by usage level, since that's already conveyed by the hero gauge and
/// week/team row colors. Animates only while on screen.
final class AnimatedBadgeView: NSView {
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }

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
        let path = NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [Theme.terra, Theme.terraDeep])?.draw(in: badge, angle: -60)
        NSGraphicsContext.restoreGraphicsState()

        let markSize: CGFloat = 15
        let markRect = NSRect(x: badge.midX - markSize / 2, y: badge.midY - markSize / 2, width: markSize, height: markSize)
        drawClaudeMark(in: markRect, color: .white, phase: phase, animated: true)
    }
}
