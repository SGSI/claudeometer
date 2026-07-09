import Foundation

/// Decides who may borrow from whom, and who has enough headroom to lend.
///
/// Both decisions weigh the 5-hour *and* the 7-day (weekly) window. A teammate
/// whose 5-hour window just reset but whose weekly quota is nearly spent is not
/// a useful lender: their credentials hit the weekly limit as soon as you start
/// working, so the borrow buys you nothing.
public enum BorrowPolicy {
    /// A lender at or above this weekly utilization has no usable quota left to
    /// hand over, however fresh their 5-hour window looks.
    public static let weeklyCeiling: Double = 95

    /// Under this utilization on *both* windows there is comfortable headroom to
    /// lend, which is what `postUsage`'s `availableToLend` flag advertises.
    public static let lendHeadroom: Double = 50

    /// You may request from a teammate when they are strictly less depleted than
    /// you on both the 5-hour and the weekly window, and their weekly window is
    /// not already spent. Both sides must have posted usage.
    ///
    /// `mineSeven`/`lenderSeven` are nil on rows posted by clients that predate
    /// the weekly figure; those fall back to the 5-hour comparison alone rather
    /// than making every older teammate unlendable.
    public static func canBorrow(
        mineFive: Double?,
        mineSeven: Double?,
        lenderFive: Double?,
        lenderSeven: Double?
    ) -> Bool {
        guard let mineFive, let lenderFive, lenderFive < mineFive else { return false }
        guard let mineSeven, let lenderSeven else { return true }
        return lenderSeven < mineSeven && lenderSeven < weeklyCeiling
    }

    /// Heuristic for `postUsage`'s `availableToLend`: comfortably under half of
    /// both windows used means there is headroom to lend to a teammate.
    public static func availableToLend(fiveHourPct: Double, sevenDayPct: Double) -> Bool {
        fiveHourPct < lendHeadroom && sevenDayPct < lendHeadroom
    }
}
