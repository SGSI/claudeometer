import Foundation

/// Presence/freshness classification for one team-board row, derived purely from
/// its `postedAt` (unix seconds of the teammate's last usage post) and an injected
/// "now". Kept in Core — with no AppKit — so it is unit-testable, mirroring
/// `ActiveBorrow`.
///
/// The app posts usage every 3–5 min while running (`pollInterval`), so a recent
/// `postedAt` reliably means "their app is posting right now", and a stale one
/// means the percentage on their row is old and should not be trusted (e.g. they
/// closed their laptop at 25%).
public enum TeamActivity: Equatable, Sendable {
    /// Posted within `onlineWithin` — online; the number is current.
    case active
    /// Posted between `onlineWithin` and `staleAfter` — recently stepped away;
    /// the number is still roughly current, so it is not dimmed.
    case idle
    /// Posted longer ago than `staleAfter` — the number is no longer trustworthy.
    case stale
    /// Never posted usage (`postedAt == nil`) — enrolled but no data yet.
    case neverPosted

    /// Posted no longer than this ago ⇒ `.active`. 10 min tolerates one missed
    /// 3–5 min post before a running app flips to `.idle`.
    public static let onlineWithin: TimeInterval = 10 * 60
    /// Posted longer than this ago ⇒ `.stale`. 15 min ≈ three missed posts.
    public static let staleAfter: TimeInterval = 15 * 60

    /// Classifies a row from its `postedAt`. Non-positive ages (a `postedAt`
    /// slightly in the future from clock skew) count as `.active`.
    public static func classify(postedAt: Int?, now: Date) -> TeamActivity {
        guard let postedAt else { return .neverPosted }
        let age = now.timeIntervalSince1970 - TimeInterval(postedAt)
        if age <= onlineWithin { return .active }
        if age <= staleAfter { return .idle }
        return .stale
    }

    /// True only when online (green dot).
    public var isOnline: Bool { self == .active }
    /// True only when the displayed number should be de-emphasized.
    public var isStale: Bool { self == .stale }

    /// Compact "Xs/Xm/Xh ago" for how long ago the teammate last posted, or nil
    /// when they never have. Mirrors the app's `relative(_:)` phrasing so the
    /// caption reads consistently. Clamps non-positive ages to `0s ago`.
    public static func agoText(postedAt: Int?, now: Date) -> String? {
        guard let postedAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince1970) - postedAt)
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    /// Builds the row's caption from an already-formatted reset phrase (e.g.
    /// "resets in 1h 17m", or nil when the row has no reset time) plus the
    /// freshness suffix, and reports whether the row is stale so the caller can
    /// color it amber. Returns nil text when there is nothing to show (a
    /// never-posted row with no reset).
    ///
    /// Examples: `("resets in 1h 17m", 2m-old) → "resets in 1h 17m · 2m ago"`;
    /// `(nil, 2m-old) → "2m ago"`; `(nil, never) → nil`.
    public static func caption(
        resetText: String?,
        postedAt: Int?,
        now: Date
    ) -> (text: String?, isStale: Bool) {
        let activity = classify(postedAt: postedAt, now: now)
        let parts = [resetText, agoText(postedAt: postedAt, now: now)].compactMap { $0 }
        return (parts.isEmpty ? nil : parts.joined(separator: " · "), activity.isStale)
    }
}

/// Ordering policy for the team board's rows.
public enum TeamBoardSort {
    /// Orders rows for display so the best borrow candidates float to the top:
    /// online (`.active`) teammates rank above everyone else, and within each
    /// group the least-depleted (lowest 5-hour usage) comes first. Rows with no
    /// posted usage sink to the bottom of their group; ties break by display
    /// name so the order is stable across refreshes.
    public static func forDisplay(_ rows: [BoardRow], now: Date) -> [BoardRow] {
        rows
            .map { (row: $0, online: TeamActivity.classify(postedAt: $0.postedAt, now: now).isOnline) }
            .sorted { lhs, rhs in
                if lhs.online != rhs.online { return lhs.online }  // online first
                let lPct = lhs.row.fiveHourPct ?? .greatestFiniteMagnitude
                let rPct = rhs.row.fiveHourPct ?? .greatestFiniteMagnitude
                if lPct != rPct { return lPct < rPct }              // least usage first
                return lhs.row.displayName.localizedCaseInsensitiveCompare(rhs.row.displayName) == .orderedAscending
            }
            .map(\.row)
    }
}
