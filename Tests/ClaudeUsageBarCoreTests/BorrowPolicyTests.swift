import Foundation
import Testing
@testable import ClaudeUsageBarCore

/// Fixed clock — `Date()` in a test would make the reset-window cases flaky.
private let now = Date(timeIntervalSince1970: 1_893_456_000)
private let horizon: TimeInterval = 2 * 3600

private func usage(_ five: Double?, _ seven: Double?, resetsIn: TimeInterval? = nil) -> BorrowPolicy.Usage {
    BorrowPolicy.Usage(
        fivePct: five,
        sevenPct: seven,
        fiveResetsAt: resetsIn.map { now.addingTimeInterval($0) }
    )
}

private func canBorrow(mine: BorrowPolicy.Usage, lender: BorrowPolicy.Usage) -> Bool {
    BorrowPolicy.canBorrow(mine: mine, lender: lender, horizon: horizon, now: now)
}

@Suite("BorrowPolicy.capacity")
struct BorrowPolicyCapacityTests {
    @Test("capacity is bounded by whichever window binds first")
    func bindingWindow() {
        #expect(BorrowPolicy.capacity(usage(10, 60), horizon: horizon, now: now) == 40)
        #expect(BorrowPolicy.capacity(usage(90, 10), horizon: horizon, now: now) == 10)
    }

    @Test("a 5-hour window that rolls over inside the horizon is worth its full allowance")
    func resetInsideHorizon() {
        #expect(BorrowPolicy.capacity(usage(90, 20, resetsIn: 600), horizon: horizon, now: now) == 80)
    }

    @Test("a 5-hour window that rolls over after the horizon is worth its current reading")
    func resetOutsideHorizon() {
        #expect(BorrowPolicy.capacity(usage(90, 20, resetsIn: 4 * 3600), horizon: horizon, now: now) == 10)
    }

    @Test("an unknown weekly figure does not bind")
    func unknownWeekly() {
        #expect(BorrowPolicy.capacity(usage(30, nil), horizon: horizon, now: now) == 70)
    }

    @Test("a missing 5-hour figure yields no capacity at all")
    func unknownFiveHour() {
        #expect(BorrowPolicy.capacity(usage(nil, 30), horizon: horizon, now: now) == nil)
    }

    @Test("utilization above 100 does not produce negative capacity")
    func clampsOverflow() {
        #expect(BorrowPolicy.capacity(usage(140, 10), horizon: horizon, now: now) == 0)
        #expect(BorrowPolicy.capacity(usage(10, 140), horizon: horizon, now: now) == 0)
    }
}

@Suite("BorrowPolicy.canBorrow")
struct BorrowPolicyCanBorrowTests {
    // Case 1 — the reported bug: my weekly is lower than the lender's, but I am
    // out of 5-hour room and they are not. Their weekly is what I'd spend, and
    // 40 points of it remain.
    @Test("lender with a higher weekly is still borrowable when they have more capacity")
    func higherWeeklyStillBorrowable() {
        #expect(canBorrow(mine: usage(95, 50), lender: usage(10, 60)))
    }

    // Case 2
    @Test("lender fresher on both windows is borrowable")
    func fresherEverywhere() {
        #expect(canBorrow(mine: usage(80, 60), lender: usage(20, 30)))
    }

    // Case 3 — a spent weekly window makes a fresh 5-hour window worthless.
    @Test("lender with a spent weekly window is not borrowable")
    func lenderWeeklySpent() {
        #expect(!canBorrow(mine: usage(80, 60), lender: usage(10, 96)))
    }

    // Case 4
    @Test("two nearly-spent weeklies produce no worthwhile gain")
    func bothWeekliesSpent() {
        #expect(!canBorrow(mine: usage(80, 97), lender: usage(10, 96)))
    }

    // Case 5
    @Test("lender more depleted on the 5-hour window is not borrowable")
    func lenderFiveHourWorse() {
        #expect(!canBorrow(mine: usage(40, 40), lender: usage(55, 10)))
    }

    // Case 6 — a swap locks you into the lent account for the whole window.
    @Test("a marginal capacity gain does not justify a borrow")
    func marginalGainRejected() {
        #expect(!canBorrow(mine: usage(60, 50), lender: usage(55, 50)))
    }

    @Test("a gain of exactly minimumGain is enough")
    func gainAtThreshold() {
        // capacities 40 and 50 — exactly 10 apart.
        #expect(canBorrow(mine: usage(60, 50), lender: usage(50, 50)))
    }

    // Case 7 — with nothing left, any headroom beats none.
    @Test("a fully depleted borrower may take whatever the lender has left")
    func depletedTakesScraps() {
        #expect(canBorrow(mine: usage(100, 100), lender: usage(90, 92)))
        #expect(!canBorrow(mine: usage(100, 100), lender: usage(100, 100)))
    }

    // Case 8 — my own window comes back before the borrow would even end.
    @Test("no borrow when my own 5-hour window resets inside the horizon")
    func myWindowResetsSoon() {
        #expect(!canBorrow(mine: usage(95, 20, resetsIn: 600), lender: usage(10, 20)))
    }

    // Case 9 — the lender's raw percentage understates them.
    @Test("a lender whose 5-hour window resets inside the horizon is borrowable")
    func lenderWindowResetsSoon() {
        #expect(canBorrow(mine: usage(95, 20), lender: usage(90, 20, resetsIn: 600)))
    }

    // Case 10 / 11 — clients that predate the weekly figure.
    @Test("a missing weekly figure never blocks a borrow")
    func missingWeeklyFallsBack() {
        #expect(canBorrow(mine: usage(80, 60), lender: usage(20, nil)))
        #expect(canBorrow(mine: usage(80, nil), lender: usage(20, 30)))
    }

    // Case 12
    @Test("a side that has never posted 5-hour usage is not borrowable")
    func missingFiveHour() {
        #expect(!canBorrow(mine: usage(nil, 60), lender: usage(20, 30)))
        #expect(!canBorrow(mine: usage(80, 60), lender: usage(nil, 30)))
    }
}

@Suite("BorrowPolicy.availableToLend")
struct BorrowPolicyAvailableToLendTests {
    @Test("headroom on both windows advertises lending")
    func bothUnderHeadroom() {
        #expect(BorrowPolicy.availableToLend(fiveHourPct: 10, sevenDayPct: 20))
    }

    @Test("a spent weekly window withdraws the lending offer")
    func weeklySpent() {
        #expect(!BorrowPolicy.availableToLend(fiveHourPct: 10, sevenDayPct: 80))
    }

    @Test("a spent 5-hour window withdraws the lending offer")
    func fiveHourSpent() {
        #expect(!BorrowPolicy.availableToLend(fiveHourPct: 70, sevenDayPct: 5))
    }

    @Test("the headroom bound is exclusive")
    func boundIsExclusive() {
        #expect(!BorrowPolicy.availableToLend(fiveHourPct: 50, sevenDayPct: 5))
        #expect(!BorrowPolicy.availableToLend(fiveHourPct: 5, sevenDayPct: 50))
    }
}
