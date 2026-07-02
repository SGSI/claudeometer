import Foundation

/// Records which account is currently written into the Claude Code credential
/// item and which account to restore when the window ends.
public struct ActiveBorrow: Codable, Equatable, Sendable {
    public let activeAccountId: UUID
    public let selfAccountId: UUID
    public let startedAt: Date
    public let revertAt: Date

    public init(activeAccountId: UUID, selfAccountId: UUID, startedAt: Date, revertAt: Date) {
        self.activeAccountId = activeAccountId
        self.selfAccountId = selfAccountId
        self.startedAt = startedAt
        self.revertAt = revertAt
    }

    public func remaining(now: Date) -> TimeInterval {
        max(0, revertAt.timeIntervalSince(now))
    }

    public func isExpired(now: Date) -> Bool {
        now >= revertAt
    }
}

/// Borrow-window duration policy.
public enum BorrowDuration {
    public static let minInterval: TimeInterval = 60          // 1 minute
    public static let maxInterval: TimeInterval = 4 * 60 * 60 // 4 hours
    public static let presets: [TimeInterval] = [30 * 60, 60 * 60, 120 * 60]

    public static func clamp(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, minInterval), maxInterval)
    }
}
