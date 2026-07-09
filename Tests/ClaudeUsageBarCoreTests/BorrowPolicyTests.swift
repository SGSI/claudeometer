import Testing
@testable import ClaudeUsageBarCore

@Suite("BorrowPolicy.canBorrow")
struct BorrowPolicyCanBorrowTests {
    @Test("lender less depleted on both windows is borrowable")
    func bothWindowsBetter() {
        #expect(BorrowPolicy.canBorrow(mineFive: 80, mineSeven: 60, lenderFive: 20, lenderSeven: 30))
    }

    @Test("lender fresher on the 5-hour window but more spent weekly is not borrowable")
    func weeklyWorseBlocks() {
        #expect(!BorrowPolicy.canBorrow(mineFive: 80, mineSeven: 30, lenderFive: 10, lenderSeven: 70))
    }

    @Test("a near-exhausted weekly window is unusable even when mine is worse")
    func weeklyCeilingBlocks() {
        #expect(!BorrowPolicy.canBorrow(mineFive: 90, mineSeven: 99, lenderFive: 10, lenderSeven: 96))
        #expect(BorrowPolicy.canBorrow(mineFive: 90, mineSeven: 99, lenderFive: 10, lenderSeven: 94))
    }

    @Test("lender at or above my 5-hour usage is never borrowable")
    func fiveHourNotBetter() {
        #expect(!BorrowPolicy.canBorrow(mineFive: 40, mineSeven: 40, lenderFive: 40, lenderSeven: 10))
        #expect(!BorrowPolicy.canBorrow(mineFive: 40, mineSeven: 40, lenderFive: 55, lenderSeven: 10))
    }

    @Test("missing weekly figures fall back to the 5-hour comparison")
    func weeklyNilFallsBack() {
        #expect(BorrowPolicy.canBorrow(mineFive: 80, mineSeven: nil, lenderFive: 20, lenderSeven: 30))
        #expect(BorrowPolicy.canBorrow(mineFive: 80, mineSeven: 60, lenderFive: 20, lenderSeven: nil))
        #expect(!BorrowPolicy.canBorrow(mineFive: 20, mineSeven: nil, lenderFive: 80, lenderSeven: nil))
    }

    @Test("a side that has never posted 5-hour usage is not borrowable")
    func missingFiveHour() {
        #expect(!BorrowPolicy.canBorrow(mineFive: nil, mineSeven: 60, lenderFive: 20, lenderSeven: 30))
        #expect(!BorrowPolicy.canBorrow(mineFive: 80, mineSeven: 60, lenderFive: nil, lenderSeven: 30))
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
