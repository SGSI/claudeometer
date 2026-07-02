import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct ActiveBorrowTests {
    let selfId = UUID()
    let otherId = UUID()

    func makeBorrow(start: TimeInterval, revert: TimeInterval) -> ActiveBorrow {
        ActiveBorrow(activeAccountId: otherId, selfAccountId: selfId,
                     startedAt: Date(timeIntervalSince1970: start),
                     revertAt: Date(timeIntervalSince1970: revert))
    }

    @Test func remainingCountsDown() {
        let b = makeBorrow(start: 0, revert: 7200)
        #expect(b.remaining(now: Date(timeIntervalSince1970: 0)) == 7200)
        #expect(b.remaining(now: Date(timeIntervalSince1970: 3600)) == 3600)
    }

    @Test func remainingNeverNegative() {
        let b = makeBorrow(start: 0, revert: 7200)
        #expect(b.remaining(now: Date(timeIntervalSince1970: 9000)) == 0)
    }

    @Test func expiryBoundary() {
        let b = makeBorrow(start: 0, revert: 7200)
        #expect(b.isExpired(now: Date(timeIntervalSince1970: 7199)) == false)
        #expect(b.isExpired(now: Date(timeIntervalSince1970: 7200)) == true)
    }

    @Test func clampToBounds() {
        #expect(BorrowDuration.clamp(10) == BorrowDuration.minInterval)         // below min
        #expect(BorrowDuration.clamp(2 * 3600) == 2 * 3600)                     // in range
        #expect(BorrowDuration.clamp(9 * 3600) == BorrowDuration.maxInterval)   // above cap
    }

    @Test func presetsAreThirtyOneAndTwoHours() {
        #expect(BorrowDuration.presets == [1800, 3600, 7200])
        #expect(BorrowDuration.maxInterval == 14400)
    }

    @Test func codableRoundTrip() throws {
        let b = makeBorrow(start: 100, revert: 7300)
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(ActiveBorrow.self, from: data)
        #expect(back == b)
    }
}
