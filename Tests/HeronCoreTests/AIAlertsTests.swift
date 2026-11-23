import Foundation
import Testing

@testable import HeronCore

/// AI usage notifications fire on the way into a state, once, and re-arm as OpenUsage's do.
@Suite struct AIAlertsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let all = Set(AIAlertKind.allCases)

    /// A 5-hour limit `used`% used, `elapsed` seconds into its window (reset at `windowStart + 5 h`).
    func line(
        used: Double, at now: Date, windowStart: Date? = nil, account: String = "a", label: String = "Personal",
        provider: AIProvider = .codex, key: String = "session", title: String = "5 hours", period: Double = AIPeriod.session
    ) -> AILimitLine {
        let begin = windowStart ?? start
        let a = AIAccount(id: account, provider: provider, label: label, signIn: .oauth)
        return AILimitLine(
            account: a,
            metric: AIMetric(
                key: key, title: title,
                value: .limit(used: used, limit: 100, unit: .percent, resetsAt: begin.addingTimeInterval(period), period: period)))
    }

    @Test func theFirstReadingOnlyPrimes() {
        var e = AIAlertEngine()
        // Already critical and burning at launch: nothing.
        #expect(e.evaluate([line(used: 95, at: start.addingTimeInterval(3600))], thresholds: .standard, enabled: all, now: start.addingTimeInterval(3600)).isEmpty)
        // Still critical on the next pass: still nothing (no edge).
        #expect(e.evaluate([line(used: 96, at: start.addingTimeInterval(3900))], thresholds: .standard, enabled: all, now: start.addingTimeInterval(3900)).isEmpty)
    }

    @Test func warningThenCriticalEachFireOnceOnTheirEdge() {
        var e = AIAlertEngine()
        let t0 = start.addingTimeInterval(4 * 3600)  // late in the window: an even pace is 80%
        _ = e.evaluate([line(used: 50, at: t0)], thresholds: .standard, enabled: [.warning, .critical], now: t0)
        let w = e.evaluate([line(used: 72, at: t0)], thresholds: .standard, enabled: [.warning, .critical], now: t0.addingTimeInterval(60))
        #expect(w.map(\.kind) == [.warning])
        #expect(e.evaluate([line(used: 75, at: t0)], thresholds: .standard, enabled: [.warning, .critical], now: t0.addingTimeInterval(120)).isEmpty)
        let c = e.evaluate([line(used: 92, at: t0)], thresholds: .standard, enabled: [.warning, .critical], now: t0.addingTimeInterval(180))
        #expect(c.map(\.kind) == [.critical])
        #expect(c.first?.title.hasPrefix("ChatGPT 5 hours: 8% left") == true)
        #expect(e.evaluate([line(used: 93, at: t0)], thresholds: .standard, enabled: [.warning, .critical], now: t0.addingTimeInterval(240)).isEmpty)
    }

    @Test func jumpingStraightToCriticalSendsOnlyCritical() {
        var e = AIAlertEngine()
        let t = start.addingTimeInterval(4 * 3600)
        _ = e.evaluate([line(used: 40, at: t)], thresholds: .standard, enabled: all, now: t)
        let fired = e.evaluate([line(used: 95, at: t)], thresholds: .standard, enabled: [.warning, .critical], now: t)
        #expect(fired.map(\.kind) == [.critical])
    }

    @Test func burningFastReArmsOnlyOnceThePaceIsAheadAgain() {
        var e = AIAlertEngine()
        let t1 = start.addingTimeInterval(3600)  // 20% of the window gone
        _ = e.evaluate([line(used: 10, at: t1)], thresholds: .standard, enabled: [.burningFast], now: t1)
        let burning = e.evaluate([line(used: 40, at: t1)], thresholds: .standard, enabled: [.burningFast], now: t1.addingTimeInterval(60))
        #expect(burning.map(\.kind) == [.burningFast])
        #expect(burning.first?.title.contains("burning fast, out in") == true)
        // On track (not ahead, not burning): stays disarmed, so burning again does not repeat.
        let t2 = start.addingTimeInterval(2 * 3600)
        _ = e.evaluate([line(used: 39, at: t2)], thresholds: .standard, enabled: [.burningFast], now: t2)
        #expect(e.evaluate([line(used: 60, at: t2)], thresholds: .standard, enabled: [.burningFast], now: t2.addingTimeInterval(60)).isEmpty)
        // Ahead again (well under an even pace), then burning: fires again.
        let t3 = start.addingTimeInterval(3 * 3600)
        _ = e.evaluate([line(used: 50, at: t3)], thresholds: .standard, enabled: [.burningFast], now: t3)
        let again = e.evaluate([line(used: 85, at: t3)], thresholds: .standard, enabled: [.burningFast], now: t3.addingTimeInterval(60))
        #expect(again.map(\.kind) == [.burningFast])
    }

    @Test func useItOrLoseItNeverRepeatsInOneWindow() {
        var e = AIAlertEngine()
        let week = AIPeriod.week
        func weekly(_ used: Double, _ now: Date, begin: Date) -> AILimitLine {
            line(used: used, at: now, windowStart: begin, key: "weekly", title: "Weekly", period: week)
        }
        let begin = start
        let early = begin.addingTimeInterval(3 * 86400)
        _ = e.evaluate([weekly(20, early, begin: begin)], thresholds: .standard, enabled: [.useItOrLoseIt], now: early)
        let lastDay = begin.addingTimeInterval(week - 12 * 3600)
        let fired = e.evaluate([weekly(30, lastDay, begin: begin)], thresholds: .standard, enabled: [.useItOrLoseIt], now: lastDay)
        #expect(fired.map(\.kind) == [.useItOrLoseIt])
        #expect(fired.first?.title == "ChatGPT Weekly: 70% left, resets in 12h")
        // Dips under half, then back over it: no second notification this window.
        _ = e.evaluate([weekly(55, lastDay, begin: begin)], thresholds: .standard, enabled: [.useItOrLoseIt], now: lastDay.addingTimeInterval(600))
        #expect(e.evaluate([weekly(30, lastDay, begin: begin)], thresholds: .standard, enabled: [.useItOrLoseIt], now: lastDay.addingTimeInterval(1200)).isEmpty)
    }

    @Test func aNewWindowReArmsEverything() {
        var e = AIAlertEngine()
        let t = start.addingTimeInterval(4 * 3600)
        _ = e.evaluate([line(used: 50, at: t)], thresholds: .standard, enabled: all, now: t)
        #expect(e.evaluate([line(used: 95, at: t)], thresholds: .standard, enabled: [.critical], now: t).map(\.kind) == [.critical])
        // The reading arrives late, still at 95%, but the reset moved 5 hours on: a new window, so
        // critical fires again.
        let next = start.addingTimeInterval(AIPeriod.session)
        let later = next.addingTimeInterval(4 * 3600)
        #expect(e.evaluate([line(used: 95, at: later, windowStart: next)], thresholds: .standard, enabled: [.critical], now: later).map(\.kind) == [.critical])
        // A reset date that drifts by seconds between reads is the same window.
        let drift = line(used: 96, at: later, windowStart: next.addingTimeInterval(30))
        #expect(e.evaluate([drift], thresholds: .standard, enabled: [.critical], now: later).isEmpty)
    }

    @Test func onlyEnabledAlertsAreSentButEveryStateIsTracked() {
        var e = AIAlertEngine()
        let t = start.addingTimeInterval(4 * 3600)
        _ = e.evaluate([line(used: 50, at: t)], thresholds: .standard, enabled: [], now: t)
        #expect(e.evaluate([line(used: 95, at: t)], thresholds: .standard, enabled: [.warning], now: t).isEmpty)  // critical is off
        // Turning critical on while it is already critical sends nothing: no edge.
        #expect(e.evaluate([line(used: 96, at: t)], thresholds: .standard, enabled: all, now: t.addingTimeInterval(60)).isEmpty)
    }

    @Test func severalAccountsOfOneProviderAreNamedUnlessPrivate() {
        var e = AIAlertEngine()
        let t = start.addingTimeInterval(4 * 3600)
        let other = line(used: 10, at: t, account: "b", label: "Work")
        _ = e.evaluate([line(used: 50, at: t), other], thresholds: .standard, enabled: all, now: t)
        let named = e.evaluate([line(used: 95, at: t), other], thresholds: .standard, enabled: [.critical], now: t)
        #expect(named.first?.title.hasPrefix("ChatGPT Personal 5 hours: 5% left") == true)
        var p = AIAlertEngine()
        _ = p.evaluate([line(used: 50, at: t), other], thresholds: .standard, enabled: all, hideLabels: true, now: t)
        let hidden = p.evaluate([line(used: 95, at: t), other], thresholds: .standard, enabled: [.critical], hideLabels: true, now: t)
        #expect(hidden.first?.title.hasPrefix("ChatGPT 5 hours: 5% left") == true)
    }
}
