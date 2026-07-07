import Testing
import Foundation
@testable import ClaudeUsageBarCore

@Suite struct TeamActivityTests {
    /// Fixed reference "now" so ages are exact. 2026-07-07T00:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_783_555_200)

    private func postedAgo(_ seconds: Int) -> Int {
        Int(now.timeIntervalSince1970) - seconds
    }

    // MARK: classify

    @Test func nilPostedIsNeverPosted() {
        #expect(TeamActivity.classify(postedAt: nil, now: now) == .neverPosted)
    }

    @Test func justPostedIsActive() {
        #expect(TeamActivity.classify(postedAt: postedAgo(0), now: now) == .active)
    }

    @Test func futureTimestampIsActive() {
        // Clock skew can put postedAt slightly ahead of now.
        #expect(TeamActivity.classify(postedAt: postedAgo(-30), now: now) == .active)
    }

    @Test func justUnderOnlineThresholdIsActive() {
        #expect(TeamActivity.classify(postedAt: postedAgo(9 * 60 + 59), now: now) == .active)
    }

    @Test func exactlyOnlineThresholdIsActive() {
        #expect(TeamActivity.classify(postedAt: postedAgo(10 * 60), now: now) == .active)
    }

    @Test func justPastOnlineThresholdIsIdle() {
        #expect(TeamActivity.classify(postedAt: postedAgo(10 * 60 + 1), now: now) == .idle)
    }

    @Test func exactlyStaleThresholdIsIdle() {
        #expect(TeamActivity.classify(postedAt: postedAgo(15 * 60), now: now) == .idle)
    }

    @Test func justPastStaleThresholdIsStale() {
        #expect(TeamActivity.classify(postedAt: postedAgo(15 * 60 + 1), now: now) == .stale)
    }

    @Test func hoursOldIsStale() {
        #expect(TeamActivity.classify(postedAt: postedAgo(3 * 60 * 60), now: now) == .stale)
    }

    // MARK: derived flags

    @Test func onlyActiveIsOnline() {
        #expect(TeamActivity.active.isOnline)
        #expect(!TeamActivity.idle.isOnline)
        #expect(!TeamActivity.stale.isOnline)
        #expect(!TeamActivity.neverPosted.isOnline)
    }

    @Test func onlyStaleIsStaleFlag() {
        #expect(TeamActivity.stale.isStale)
        #expect(!TeamActivity.active.isStale)
        #expect(!TeamActivity.idle.isStale)
        #expect(!TeamActivity.neverPosted.isStale)
    }

    // MARK: agoText

    @Test func agoTextSeconds() {
        #expect(TeamActivity.agoText(postedAt: postedAgo(5), now: now) == "5s ago")
    }

    @Test func agoTextMinutes() {
        #expect(TeamActivity.agoText(postedAt: postedAgo(2 * 60 + 10), now: now) == "2m ago")
    }

    @Test func agoTextHours() {
        #expect(TeamActivity.agoText(postedAt: postedAgo(3 * 60 * 60), now: now) == "3h ago")
    }

    @Test func agoTextNilWhenNeverPosted() {
        #expect(TeamActivity.agoText(postedAt: nil, now: now) == nil)
    }

    @Test func agoTextClampsFutureToZero() {
        #expect(TeamActivity.agoText(postedAt: postedAgo(-30), now: now) == "0s ago")
    }

    // MARK: caption

    @Test func captionCombinesResetAndAgo() {
        let (text, isStale) = TeamActivity.caption(
            resetText: "resets in 1h 17m", postedAt: postedAgo(2 * 60), now: now)
        #expect(text == "resets in 1h 17m · 2m ago")
        #expect(!isStale)
    }

    @Test func captionAgoOnlyWhenNoReset() {
        let (text, _) = TeamActivity.caption(resetText: nil, postedAt: postedAgo(2 * 60), now: now)
        #expect(text == "2m ago")
    }

    @Test func captionNilWhenNeverPostedAndNoReset() {
        let (text, isStale) = TeamActivity.caption(resetText: nil, postedAt: nil, now: now)
        #expect(text == nil)
        #expect(!isStale)
    }

    @Test func captionIsStaleFlagFlipsPastStaleThreshold() {
        let fresh = TeamActivity.caption(resetText: "resets now", postedAt: postedAgo(60), now: now)
        #expect(!fresh.isStale)
        let old = TeamActivity.caption(resetText: "resets now", postedAt: postedAgo(20 * 60), now: now)
        #expect(old.isStale)
    }
}
