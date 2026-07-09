import Foundation

/// Decides who may borrow from whom, and who has enough headroom to lend.
///
/// While a borrow is active the Claude Code item holds the *lender's* blob, so
/// every request spends the lender's 5-hour quota and the lender's weekly quota.
/// The borrower's own windows sit idle. Eligibility therefore compares *usable
/// capacity* — how much work each account can still do before either of its two
/// windows binds — rather than comparing the two 5-hour figures alone.
///
/// The borrower's weekly percentage matters only through its effect on their own
/// capacity (i.e. whether they need to borrow at all); it is never spent during
/// the borrow, so a lender is not disqualified merely for having used more of
/// their week than you have.
public enum BorrowPolicy {
    /// Capacity a lender must add over the borrower's own before a borrow is
    /// worth its cost: a credential swap, and being locked into the lent account
    /// for the whole window (only the lender can end it early). Without this,
    /// a 5-point difference would surface a "Request 2h" button.
    public static let minimumGain: Double = 10

    /// Under this utilization on *both* windows there is comfortable headroom to
    /// lend, which is what `postUsage`'s `availableToLend` flag advertises.
    public static let lendHeadroom: Double = 50

    /// One side's posted usage. `sevenPct` is nil on rows written by clients that
    /// predate the weekly figure; `fiveResetsAt` is nil until a window has been
    /// reported. Only the 5-hour reset crosses the relay, so the weekly window is
    /// always valued at its current percentage.
    public struct Usage: Equatable, Sendable {
        public let fivePct: Double?
        public let sevenPct: Double?
        public let fiveResetsAt: Date?

        public init(fivePct: Double?, sevenPct: Double?, fiveResetsAt: Date? = nil) {
            self.fivePct = fivePct
            self.sevenPct = sevenPct
            self.fiveResetsAt = fiveResetsAt
        }
    }

    /// Work an account can still do over `horizon`, as a percentage of a full
    /// window. Both limits bind at once, so capacity is whichever window runs out
    /// first. A 5-hour window that rolls over inside `horizon` is worth its full
    /// allowance, not its current reading — a lender sitting at 90% with 10
    /// minutes left on the clock is a better bet over a 2-hour borrow than the
    /// raw number suggests.
    ///
    /// Returns nil when the 5-hour figure is missing: that side has never posted
    /// usage and nothing can be concluded. An unknown weekly figure is treated as
    /// unconstrained rather than exhausted, so it never binds.
    public static func capacity(_ usage: Usage, horizon: TimeInterval, now: Date) -> Double? {
        guard let fivePct = usage.fivePct else { return nil }
        let rollsOver = usage.fiveResetsAt.map { $0 <= now.addingTimeInterval(horizon) } ?? false
        let effectiveFive = rollsOver ? 0 : clampPercent(fivePct)
        let effectiveSeven = clampPercent(usage.sevenPct ?? 0)
        return min(100 - effectiveFive, 100 - effectiveSeven)
    }

    /// You may request from a teammate when borrowing their account buys you
    /// materially more room than you have yourself, over the `horizon` you intend
    /// to borrow for. Both sides must have posted usage.
    ///
    /// When you have no capacity left at all, any capacity the lender has is an
    /// improvement, so `minimumGain` is not applied — otherwise a fully depleted
    /// user could never borrow from a nearly depleted one, which is exactly when
    /// the scraps are worth having.
    public static func canBorrow(
        mine: Usage,
        lender: Usage,
        horizon: TimeInterval,
        now: Date
    ) -> Bool {
        guard let mineCapacity = capacity(mine, horizon: horizon, now: now),
              let lenderCapacity = capacity(lender, horizon: horizon, now: now) else { return false }
        if mineCapacity <= 0 { return lenderCapacity > 0 }
        return lenderCapacity - mineCapacity >= minimumGain
    }

    /// Heuristic for `postUsage`'s `availableToLend`: comfortably under half of
    /// both windows used means there is headroom to lend to a teammate.
    public static func availableToLend(fiveHourPct: Double, sevenDayPct: Double) -> Bool {
        fiveHourPct < lendHeadroom && sevenDayPct < lendHeadroom
    }

    /// Utilization arrives from the API and the relay, neither of which promises
    /// 0...100 — a percentage above 100 must not turn into negative capacity.
    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
