import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct TeamBoardSortTests {
    /// Fixed reference "now". 2026-07-07T00:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_783_555_200)

    /// Builds a board row posting `pct` usage `postedAgoSeconds` ago (nil = never
    /// posted). Only the fields the sort reads are meaningful.
    private func row(_ name: String, pct: Double?, postedAgo postedAgoSeconds: Int?) -> BoardRow {
        BoardRow(
            userId: name.lowercased(),
            displayName: name,
            fiveHourPct: pct,
            sevenDayPct: nil,
            resetAt: nil,
            availableToLend: nil,
            lastSeen: Int(now.timeIntervalSince1970),
            postedAt: postedAgoSeconds.map { Int(now.timeIntervalSince1970) - $0 }
        )
    }

    private func order(_ rows: [BoardRow]) -> [String] {
        TeamBoardSort.forDisplay(rows, now: now).map(\.displayName)
    }

    @Test func onlineRanksAboveOfflineEvenWithHigherUsage() {
        // Online at 90% should still rank above an offline teammate at 5%.
        let onlineBusy = row("OnlineBusy", pct: 90, postedAgo: 60)
        let offlineIdle = row("OfflineIdle", pct: 5, postedAgo: 60 * 60)
        #expect(order([offlineIdle, onlineBusy]) == ["OnlineBusy", "OfflineIdle"])
    }

    @Test func leastUsageFirstWithinOnlineGroup() {
        let high = row("High", pct: 70, postedAgo: 60)
        let low = row("Low", pct: 8, postedAgo: 120)
        let mid = row("Mid", pct: 38, postedAgo: 30)
        #expect(order([high, mid, low]) == ["Low", "Mid", "High"])
    }

    @Test func leastUsageFirstWithinOfflineGroup() {
        let high = row("High", pct: 70, postedAgo: 60 * 60)
        let low = row("Low", pct: 8, postedAgo: 60 * 60)
        #expect(order([high, low]) == ["Low", "High"])
    }

    @Test func neverPostedSinksToBottomOfOnlineGroup() {
        // A never-posted user is offline; a posted-but-idle-usage online user
        // outranks them. Compare within a single group instead:
        let online = row("Online", pct: 50, postedAgo: 60)
        let onlineNoUsage = row("OnlineNoUsage", pct: nil, postedAgo: 60)
        // Both posted recently (online), but the one with no usage number sinks.
        #expect(order([onlineNoUsage, online]) == ["Online", "OnlineNoUsage"])
    }

    @Test func fullBoardOrdersOnlineLowUsageToOfflineHighUsage() {
        let rows = [
            row("OfflineHigh", pct: 95, postedAgo: 30 * 60),
            row("OnlineHigh", pct: 80, postedAgo: 60),
            row("OnlineLow", pct: 10, postedAgo: 60),
            row("OfflineLow", pct: 20, postedAgo: 30 * 60),
        ]
        #expect(order(rows) == ["OnlineLow", "OnlineHigh", "OfflineLow", "OfflineHigh"])
    }

    @Test func tiesBreakByDisplayNameForStableOrder() {
        let bravo = row("Bravo", pct: 25, postedAgo: 60)
        let alpha = row("Alpha", pct: 25, postedAgo: 60)
        #expect(order([bravo, alpha]) == ["Alpha", "Bravo"])
    }
}
