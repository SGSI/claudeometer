import AppKit
import Foundation
import UserNotifications

private let keychainService = "Claude Code-credentials"
private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
private let settingsURL = URL(string: "https://claude.ai/settings/usage")!

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
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
            onRefresh: { [weak self] in self?.refresh() },
            onOpenSettings: { NSWorkspace.shared.open(settingsURL) },
            onLogin: { Self.openClaudeLogin() },
            onQuit: { NSApp.terminate(nil) }
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

    init(
        snapshot: UsageSnapshot?,
        hotSessions: [LocalSessionSummary],
        status: String?,
        accent: NSColor,
        history: [UsageHistoryPoint],
        onRefresh: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onLogin: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
        self.onLogin = onLogin
        self.onQuit = onQuit
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 480))
        build(snapshot: snapshot, hotSessions: hotSessions, status: status, accent: accent, history: history)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(snapshot: UsageSnapshot?, hotSessions: [LocalSessionSummary], status: String?, accent: NSColor, history: [UsageHistoryPoint]) {
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

        addFullWidth(footer(snapshot: snapshot), to: root)
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

    @objc private func overflowTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open usage", action: #selector(openTapped), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let loginItem = NSMenuItem(title: "Login", action: #selector(loginTapped), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
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

    private func readCredentials() throws -> OAuthCredentials {
        let process = Process()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
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
