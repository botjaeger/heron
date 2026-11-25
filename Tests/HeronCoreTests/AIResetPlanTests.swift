import Foundation
import Testing

@testable import HeronCore

/// The resets panel's plan: the 30-day strip, each limit's own refills and time out, the kinds
/// with what they give back, the reset "Use…" spends, and the one sentence.
@Suite struct AIResetPlanTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = 86400.0
    let week = AIPeriod.week
    let soon = 7 * 86400.0
    let claude = AIAccount(id: "c", provider: .claude, label: "P", signIn: .oauth)

    func limit(_ key: String, _ title: String, used: Double, resetsIn: Double?, period: Double?) -> AIMetric {
        AIMetric(key: key, title: title, value: .limit(used: used, limit: 100, unit: .percent, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, period: period))
    }
    func grant(_ id: String, _ kind: AIResetKind, in days: Double?, usable: Bool, count: Int = 1, refills: [String]? = nil) -> AIResetGrant {
        AIResetGrant(id: id, expiresAt: days.map { now.addingTimeInterval($0 * day) }, usableNow: usable, detail: "d-\(id)", kind: kind, count: count, refills: refills)
    }
    func plan(_ metrics: [AIMetric], _ grants: [AIResetGrant]) -> AIResetPlan {
        AIResetPlan.make(account: claude, reading: AIReading(metrics: metrics, grants: grants, fetchedAt: now), soon: soon, now: now)
    }

    @Test func eachLaneRefillsOnItsOwnWindowWithinThirtyDays() {
        let p = plan(
            [
                limit("session", "5 hours", used: 10, resetsIn: 3600, period: AIPeriod.session),
                limit("weekly", "Weekly", used: 10, resetsIn: 2.25 * day, period: week),
                limit("sonnet", "Sonnet", used: 10, resetsIn: 2.25 * day, period: week),  // no reset refills it: no lane
            ],
            [grant("f", .full, in: 15, usable: true)])
        #expect(p.lanes.map(\.key) == ["session", "weekly"])
        #expect(p.lanes[1].refills.map { $0.timeIntervalSince(now) / day } == [2.25, 9.25, 16.25, 23.25])
        let sessions = p.lanes[0].refills
        #expect(sessions.first == now.addingTimeInterval(3600) && sessions.allSatisfy { $0 > now && $0 <= now.addingTimeInterval(AIResetPlan.span) })
        #expect(sessions.count == Int((AIResetPlan.span - 3600) / AIPeriod.session) + 1)
    }

    @Test func aStaleResetTimeNeverDrawsARefillInThePast() {
        let p = plan([limit("weekly", "Weekly", used: 10, resetsIn: -3600, period: nil)], [grant("w", .weekly, in: 15, usable: true)])
        #expect(p.lanes.first?.refills.isEmpty == true)
        let q = plan([limit("weekly", "Weekly", used: 10, resetsIn: -3600, period: week)], [grant("w", .weekly, in: 15, usable: true)])
        #expect(q.lanes.first?.refills.first == now.addingTimeInterval(week - 3600))
    }

    @Test func aLaneIsOutFromNowWhenUsedUpAndFromItsRunwayWhenBurningFast() throws {
        let usedUp = plan([limit("weekly", "Weekly", used: 100, resetsIn: 3 * day, period: week)], [grant("w", .weekly, in: 15, usable: true)])
        #expect(usedUp.lanes[0].out == now...now.addingTimeInterval(3 * day))
        // 86% used with 2.25 of 7 days left: runs out in about 18 h, back in 2.25 days.
        let burning = plan([limit("weekly", "Weekly", used: 86, resetsIn: 2.25 * day, period: week)], [grant("w", .weekly, in: 15, usable: true)])
        let out = try #require(burning.lanes[0].out)
        #expect(abs(out.lowerBound.timeIntervalSince(now) / 3600 - 18.5) < 0.5)
        #expect(out.upperBound == now.addingTimeInterval(2.25 * day))
        let calm = plan([limit("weekly", "Weekly", used: 10, resetsIn: 2.25 * day, period: week)], [grant("w", .weekly, in: 15, usable: true)])
        #expect(calm.lanes[0].out == nil)
    }

    @Test func theStripHoldsThirtyDaysAndCountsTheRest() {
        let p = plan(
            [],
            [grant("w", .weekly, in: 15, usable: true), grant("f", .fable, in: 104, usable: false, count: 2), grant("n", .full, in: nil, usable: false)])
        #expect(p.expiries == [now.addingTimeInterval(15 * day)])
        #expect(p.later == [now.addingTimeInterval(104 * day), now.addingTimeInterval(104 * day)])
        #expect(p.count == 4)  // the undated one still counts
        #expect(p.firstExpiry == now.addingTimeInterval(15 * day))
    }

    @Test func kindsAreGroupedWithTheirCountAndUseSpendsTheFirstUsableToExpire() {
        let p = plan(
            [limit("weekly", "Weekly", used: 86, resetsIn: 2.25 * day, period: week), limit("fable", "Fable", used: 0, resetsIn: 2.25 * day, period: week)],
            [
                grant("f", .fable, in: 104, usable: false, count: 2),
                grant("w2", .weekly, in: 20, usable: true),
                grant("w0", .weekly, in: 5, usable: false),
                grant("w1", .weekly, in: 10, usable: true),
            ])
        #expect(p.kinds.map(\.kind) == [.weekly, .fable])
        #expect(p.kinds.map(\.count) == [3, 2])
        #expect(p.kinds[0].usable?.id == "w1")  // w0 expires first but can't be used now
        #expect(p.kinds[1].usable == nil)
        #expect(p.kinds[0].gains.map(\.key) == ["weekly"] && abs(p.kinds[0].gains[0].left - 0.14) < 1e-9)
        #expect(p.kinds[1].gains.map(\.key) == ["fable"] && p.kinds[1].gains[0].left == 1)
        #expect(p.usableNow == 3)
    }

    // MARK: A reset spent outside Heron

    /// A limit that refills before its window ends means a reset was spent (in Claude Code, on the
    /// website): the next refresh reads the resets again instead of waiting for the hourly read.
    @MainActor @Test func aLimitRefilledBeforeItsWindowEndsRereadsTheResets() {
        let before = [limit("weekly", "Weekly", used: 86, resetsIn: 2 * day, period: week)]
        #expect(AIUsageService.refilledEarly(old: before, new: [limit("weekly", "Weekly", used: 1, resetsIn: week, period: week)], now: now))
        // Its own window ended: a natural refill, not a reset.
        let ended = [limit("weekly", "Weekly", used: 86, resetsIn: -60, period: week)]
        #expect(!AIUsageService.refilledEarly(old: ended, new: [limit("weekly", "Weekly", used: 0, resetsIn: week, period: week)], now: now))
        // Use only rising, or a small dip: nothing spent.
        #expect(!AIUsageService.refilledEarly(old: before, new: [limit("weekly", "Weekly", used: 90, resetsIn: 2 * day, period: week)], now: now))
        #expect(!AIUsageService.refilledEarly(old: before, new: [limit("weekly", "Weekly", used: 83, resetsIn: 2 * day, period: week)], now: now))
        // A first reading has nothing to compare.
        #expect(!AIUsageService.refilledEarly(old: [], new: before, now: now))
    }

    // MARK: A day under the pointer

    /// The hover readout's day: its distance in calendar days, and on it the resets running out,
    /// the time out (from, until or all day, with when it is back), each refill, and a 5-hour
    /// window as one "every 5 hours" line.
    @Test func aDayListsWhatHappensOnIt() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let p = plan(
            [
                limit("session", "5 hours", used: 10, resetsIn: 3600, period: AIPeriod.session),
                limit("weekly", "Weekly", used: 86, resetsIn: 2.25 * day, period: week),
            ],
            [grant("w", .weekly, in: 15.43, usable: true), grant("f", .full, in: 15.43, usable: false)])
        let out = try #require(p.lanes[1].out)
        let refill = now.addingTimeInterval(2.25 * day), expiry = now.addingTimeInterval(15.43 * day)

        let today = p.day(at: now, calendar: utc)
        #expect(today.daysAway == 0 && today.start == utc.startOfDay(for: now))

        let first = p.day(at: out.lowerBound, calendar: utc)  // the day it runs out
        #expect(first.daysAway == 1)
        #expect(first.items == [.refillsEvery("5 hours", AIPeriod.session), .out("Weekly", from: out.lowerBound, until: nil, back: refill)])

        let back = p.day(at: refill, calendar: utc)  // out since before midnight, back during the day
        #expect(back.items == [.refillsEvery("5 hours", AIPeriod.session), .out("Weekly", from: nil, until: refill, back: refill), .refills("Weekly", refill)])

        let lost = p.day(at: expiry, calendar: utc)  // two kinds run out: both, in the plan's kind order
        #expect(lost.items.prefix(2) == [.expires(.full, expiry), .expires(.weekly, expiry)])
        #expect(lost.daysAway == utc.dateComponents([.day], from: utc.startOfDay(for: now), to: utc.startOfDay(for: expiry)).day)
    }

    @Test func aWholeDayOutHasNeitherEnd() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let p = plan([limit("weekly", "Weekly", used: 100, resetsIn: 3 * day, period: week)], [grant("w", .weekly, in: 15, usable: true)])
        let middle = p.day(at: now.addingTimeInterval(1.5 * day), calendar: utc)
        #expect(middle.items == [.out("Weekly", from: nil, until: nil, back: now.addingTimeInterval(3 * day))])
        let quiet = p.day(at: now.addingTimeInterval(5 * day), calendar: utc)
        #expect(quiet.items.isEmpty)
    }

    // MARK: Advice, one branch each

    @Test func resetsAboutToBeLostWhileTheLimitsAreOutSayUseOneNow() {
        let p = plan(
            [limit("session", "5 hours", used: 100, resetsIn: 5 * 3600, period: AIPeriod.session), limit("weekly", "Weekly", used: 100, resetsIn: week, period: week)],
            [grant("a", .full, in: 5.33, usable: true), grant("b", .full, in: 6.43, usable: true), grant("c", .full, in: 17.43, usable: true)])
        #expect(p.advice == .init(text: "Two resets run out within 7 days, and 5 hours and Weekly are out now. Using one refills them at once.", urgent: true))
    }

    @Test func aResetAboutToBeLostWithNothingOutSaysUseItWhenLow() {
        let p = plan([limit("weekly", "Weekly", used: 40, resetsIn: 3 * day, period: week)], [grant("a", .weekly, in: 3, usable: true)])
        #expect(p.advice == .init(text: "A reset runs out within 7 days. Use it when a limit runs low, or it is lost.", urgent: true))
        // Not usable now: nothing to act on, so nothing urgent.
        let q = plan([limit("weekly", "Weekly", used: 40, resetsIn: 3 * day, period: week)], [grant("a", .weekly, in: 3, usable: false)])
        #expect(q.advice?.urgent != true)
    }

    @Test func aLimitOutNowNamesTheResetThatRefillsIt() {
        let p = plan([limit("weekly", "Weekly", used: 100, resetsIn: 3 * day, period: week)], [grant("a", .weekly, in: 15, usable: true)])
        let at = AIDuration.reset(now.addingTimeInterval(3 * day), absolute: true, now: now)!
        #expect(p.advice == .init(text: "Weekly is out until \(at). A Weekly reset refills it now.", urgent: false))
    }

    @Test func aLimitThisPaceRunsOutSaysHowLongTheWaitIs() throws {
        let p = plan([limit("weekly", "Weekly", used: 86, resetsIn: 2.25 * day, period: week)], [grant("a", .weekly, in: 15, usable: true)])
        let out = try #require(p.lanes[0].out)
        let runs = AIDuration.text(from: now, to: out.lowerBound)!, wait = AIDuration.text(from: out.lowerBound, to: out.upperBound)!
        let at = AIDuration.reset(out.upperBound, absolute: true, now: now)!
        #expect(p.advice == .init(text: "At this pace Weekly runs out in \(runs) and stays out \(wait), until \(at). Use the Weekly reset then to skip the wait.", urgent: false))
    }

    @Test func fullLimitsSayThereIsNothingToRefill() {
        let p = plan([limit("fable", "Fable", used: 0, resetsIn: 2 * day, period: week)], [grant("f", .fable, in: 104, usable: true, count: 2)])
        #expect(p.advice == .init(text: "Every limit a reset refills is full: nothing to refill now.", urgent: false))
    }

    @Test func otherwiseItCountsTheRefillsBeforeTheFirstResetRunsOut() {
        let p = plan([limit("weekly", "Weekly", used: 30, resetsIn: 2.25 * day, period: week)], [grant("w", .weekly, in: 15, usable: false)])
        #expect(p.advice == .init(text: "Weekly refills itself two times before your first Weekly reset runs out. Keep it for a week you run dry early.", urgent: false))
        // A reset whose limit this account does not show: no lane, no sentence.
        let q = plan([], [grant("w", .weekly, in: 15, usable: true)])
        #expect(q.advice == nil && q.lanes.isEmpty)
    }
}
