import AppKit
import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// The AI usage card and panel: when the card shows, what its rows are, the
/// left / used text, the pace mark, hidden limits.
@MainActor
@Suite struct AIPanelTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func limit(_ key: String, used: Double, resetsIn: Double = 3 * 86400, period: Double? = AIPeriod.week, title: String? = nil) -> AIMetric {
        AIMetric(key: key, title: title ?? key.capitalized, value: .limit(used: used, limit: 100, unit: .percent, resetsAt: now.addingTimeInterval(resetsIn), period: period))
    }

    func service(_ accounts: [AIAccount], _ readings: [String: AIReading]) -> AIUsageService {
        let s = AIUsageService(defaults: scratchDefaults("ai-panel"), tokens: MemoryTokenStore())
        s.setPreview(accounts: accounts, readings: readings)
        return s
    }

    // MARK: The card

    @Test func theCardShowsOnlyOnceAnAccountExists() {
        var snapshot = Snapshot()
        snapshot.battery = BatteryReading(present: true, percent: 0.5, isCharging: false, onAC: true)
        let order = OverviewPart.allCases
        #expect(!OverviewSection.parts(order: order, hidden: [], snapshot: snapshot).contains(.ai))
        #expect(OverviewSection.parts(order: order, hidden: [], snapshot: snapshot, ai: true).contains(.ai))
        #expect(!DetailPanels.visibleParts(order: order, hidden: [], snapshot: snapshot).contains(.ai))
        #expect(DetailPanels.visibleParts(order: order, hidden: [], snapshot: snapshot, ai: true) == order)
        // Settings says why it is missing, and where it will be.
        #expect(OverviewPane.position(of: .ai, order: order, hidden: [], snapshot: snapshot) == "Shows once an AI account is added.")
        #expect(OverviewPane.position(of: .ai, order: order, hidden: [], snapshot: snapshot, ai: true) == "6th of 8 in the popover")
    }

    /// Class: the last drawn section must stay. AI usage without an account (or Battery without one)
    /// is not drawn, so it does not keep the popover from going empty.
    @Test func theLastDrawnSectionCannotBeHidden() {
        let order = OverviewPart.allCases
        let others = Set(order.filter { $0 != .cpu && $0 != .ai })
        let noBattery = Snapshot()
        #expect(OverviewPane.isLocked(.cpu, order: order, hidden: others, snapshot: noBattery, ai: false))
        #expect(!OverviewPane.isLocked(.cpu, order: order, hidden: others, snapshot: noBattery, ai: true))
        #expect(OverviewPane.isLocked(.ai, order: order, hidden: others.union([.cpu]), snapshot: noBattery, ai: true))
        #expect(!OverviewPane.isLocked(.ai, order: order, hidden: others, snapshot: noBattery, ai: false))  // not drawn: hiding it empties nothing
        #expect(!OverviewPane.isLocked(.cpu, order: order, hidden: [], snapshot: noBattery, ai: false))
    }

    @Test func aStoredOrderWithoutTheCardGetsItAppended() {
        let d = scratchDefaults("ai-order")
        d.set(["battery", "cpu", "gpu", "memory", "network", "disk", "sensors"], forKey: "overviewOrder")
        #expect(AppSettings(defaults: d).overviewOrder == [.battery, .cpu, .gpu, .memory, .network, .disk, .sensors, .ai])
        #expect(AppSettings(defaults: scratchDefaults("ai-order-new")).overviewOrder == [.cpu, .gpu, .memory, .network, .disk, .ai, .sensors, .battery])
    }

    @Test func cardRowsFollowWhatTheCardShows() {
        var a = AIAccount(id: "a", provider: .claude, label: "Personal", signIn: .oauth)
        a.pinned = ["fine"]
        let metrics = [limit("fine", used: 20), limit("low", used: 80), limit("out", used: 100), limit("lower", used: 95), limit("calm", used: 10)]
        let lines = metrics.map { AILimitLine(account: a, metric: $0) }
        var o = AIUsageSettings()
        o.cardRows = 3
        let urgent = AICardModel(lines: lines, settings: o, now: now)
        #expect(urgent.entries.map(\.line.metric.key) == ["fine", "lower", "low"])  // pinned, then running out by what is left
        #expect(urgent.more == 2 && urgent.footer == "Pinned and running out first · 2 more in the panel")
        #expect(urgent.pill?.text == "2 running out · 1 used up")
        o.cardShows = .pinned
        #expect(AICardModel(lines: lines, settings: o, now: now).entries.map(\.line.metric.key) == ["fine"])
        o.cardShows = .chosen
        o.cardChosen = ["a/calm", "a/out", "gone/weekly"]
        let chosen = AICardModel(lines: lines, settings: o, now: now)
        #expect(chosen.entries.map(\.line.metric.key) == ["calm", "out"])
        #expect(chosen.footer == "Your chosen limits · 3 more in the panel")
        // Chosen ignores Rows: every ticked limit shows (4 ticked with Rows 3 hid one, 2026-11-23).
        o.cardRows = 1
        o.cardChosen = ["a/calm", "a/out", "a/low", "a/fine"]
        #expect(AICardModel(lines: lines, settings: o, now: now).entries.map(\.line.metric.key) == ["calm", "out", "low", "fine"])
        o.cardChosen = []
        #expect(AICardModel(lines: lines, settings: o, now: now).emptyText == "No limits chosen. Pick them in Settings › Overview.")
        #expect(AICardModel(lines: [], settings: AIUsageSettings(), now: now).emptyText == "No account has reported yet.")
    }

    // MARK: Cards

    @Test func everyAccountIsItsOwnCardWithoutHiddenMetrics() {
        var p = AIAccount(id: "p", provider: .claude, label: "Personal", signIn: .oauth)
        p.hidden = ["secret"]
        let w = AIAccount(id: "w", provider: .claude, label: "Work", signIn: .oauth)
        let o = AIAccount(id: "o", provider: .opencode, label: "Go", signIn: .oauth)
        let readings = ["p": AIReading(metrics: [limit("weekly", used: 40), limit("secret", used: 90)]), "w": AIReading(metrics: [limit("weekly", used: 70)])]
        let groups = AIAccountGroup.groups(accounts: [p, o, w], readings: readings)
        #expect(groups.map(\.id) == ["p", "o", "w"])
        #expect(groups[0].metrics.map(\.key) == ["weekly"])
    }

    // MARK: Rows

    @Test func theAmountSaysLeftOrUsedAndTheBarAlwaysFillsWithUsed() {
        let a = AIAccount(id: "a", provider: .claude, label: "P", signIn: .oauth)
        let entry = AIPriorityBoard.Entry(line: AILimitLine(account: a, metric: limit("weekly", used: 51)), reason: nil)
        var o = AIUsageSettings()
        let left = AIRowModel(entry: entry, settings: o, now: now)
        #expect(left?.value == "49% left" && left?.used == 0.51)
        o.display = .used
        let used = AIRowModel(entry: entry, settings: o, now: now)
        #expect(used?.value == "51% used" && used?.used == 0.51)
        #expect(AIText.value(.amount(12.4, unit: .usd, label: "left"), display: .left) == "$12.40 left")
        #expect(AIText.value(.amount(4.12, unit: .usd, label: "spent"), display: .used) == "$4.12 spent")
        #expect(AIText.value(.limit(used: 0, limit: 50, unit: .usd, resetsAt: nil, period: nil), display: .left) == "$0 of $50")
        #expect(AIText.value(.resets(count: 3, expiries: []), display: .left) == "3 available")
        #expect(AIText.value(.tokens(1_200_000), display: .left) == "1.2M tokens")
        #expect(AIText.value(.tokens(277_900_000), display: .left) == "277.9M tokens")
        #expect(AIText.value(.tokens(0), display: .left) == "0 tokens")
        // Not a bar: money and counts have no row model.
        let money = AIPriorityBoard.Entry(line: AILimitLine(account: a, metric: AIMetric(key: "x", title: "X", value: .amount(1, unit: .usd, label: "left"))), reason: nil)
        #expect(AIRowModel(entry: money, settings: o, now: now) == nil)
    }

    /// Class: a fixed column narrower than its widest text. "Resets in 23h 59m" (102 pt) and a
    /// 12-hour "Resets Wed 10:59 PM" overflowed the 78 pt reset column onto the amount; the card's
    /// column now takes its widest row's text, the same for every row.
    @Test func theResetColumnHoldsItsWidestText() {
        let a = AIAccount(id: "a", provider: .claude, label: "P", signIn: .oauth)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let o = AIUsageSettings()
        // 22% used with a day to go: use it or lose it ("Resets in 23h 59m").
        let soon = AIPriorityBoard.Entry(
            line: AILimitLine(account: a, metric: limit("weekly", used: 22, resetsIn: 86_340)), reason: .useItOrLoseIt(resetsAt: now.addingTimeInterval(86_340)))
        let short = AIPriorityBoard.Entry(line: AILimitLine(account: a, metric: limit("sonnet", used: 10, resetsIn: 3 * 86400)), reason: nil)
        let rows = [soon, short].compactMap { AIRowModel(entry: $0, settings: o, now: now) }
        #expect(rows.first?.reset == "Resets in 23h 59m")
        let column = AIRowLayout.resetWidth(rows)
        for row in rows { #expect(width(row.reset ?? "") <= column, "\(row.reset ?? "")") }
        #expect(AIRowLayout.resetWidth([rows[1]]) == AIRowLayout.reset)  // short text keeps the design's width
        // The clock form on a 12-hour locale is wider still.
        var row = rows[0]
        row.reset = "Resets Wed 10:59 PM"
        #expect(width("Resets Wed 10:59 PM") <= AIRowLayout.resetWidth([row]))
    }

    /// The Limit resets row opens the account's resets beside the panel like a history row, and
    /// its count turns amber only while a reset runs out within `Warnings.resetSoon`.
    @Test func theResetsRowOpensTheAccountsResetsAndWarnsBeforeOneIsLost() {
        let a = AIAccount(id: "a", provider: .claude, label: "P", signIn: .oauth)
        let item = AIResetsRow.item(a)
        #expect(item.source == .aiResets(account: "a") && item.part == .ai && item.isAIResets)
        let soon = AIResetGrant(id: "1", expiresAt: now.addingTimeInterval(Warnings.resetSoon - 60), usableNow: true, detail: "", kind: .full)
        let later = AIResetGrant(id: "2", expiresAt: now.addingTimeInterval(Warnings.resetSoon + 60), usableNow: true, detail: "", kind: .weekly)
        let undated = AIResetGrant(id: "3", expiresAt: nil, usableNow: true, detail: "", kind: .weekly)
        #expect(AIResetsRow.color([later, soon], now: now) == Theme.caution)
        #expect(AIResetsRow.color([later, undated], now: now) == .primary)
        #expect(AIResetsRow.color([], now: now) == .primary)
    }

    /// The strip's hover readout: the day and how far it is, then one line per thing on it; a
    /// whole day out says when it is back, and a refill that ends the time out is said once.
    @Test func theHoverReadoutSaysWhatHappensThatDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.startOfDay(for: now), back = start.addingTimeInterval(1.5 * 86400)
        func day(_ away: Int, _ items: [AIResetPlan.Day.Item]) -> AIResetPlan.Day {
            let s = start.addingTimeInterval(Double(away) * 86400)
            return AIResetPlan.Day(start: s, end: s.addingTimeInterval(86400), daysAway: away, items: items)
        }
        #expect(AIResetDayReadout.title(day(0, []), calendar: utc).hasSuffix(" · today"))
        #expect(AIResetDayReadout.title(day(1, []), calendar: utc).hasSuffix(" · tomorrow"))
        #expect(AIResetDayReadout.title(day(16, []), calendar: utc).hasSuffix(" · in 16 days"))
        #expect(AIResetDayReadout.lines(day(4, []), now: now, calendar: utc).isEmpty)

        let clock = AIText.clock(back, calendar: utc)
        let allDay = AIResetDayReadout.lines(day(1, [.out("Weekly", from: nil, until: nil, back: back)]), now: now, calendar: utc)
        #expect(allDay.map(\.text) == ["out all day", "back \(AIDuration.reset(back, absolute: true, now: now, calendar: utc)!)"])
        #expect(allDay[0].out && allDay[1].muted && allDay[1].mark == .none)

        let backDay = AIResetDayReadout.lines(
            day(1, [.out("Weekly", from: nil, until: back, back: back), .refills("Weekly", back), .refills("Fable", back), .refillsEvery("5 hours", AIPeriod.session)]),
            now: now, calendar: utc)
        #expect(backDay.map(\.text) == ["out until \(clock)", "refills \(clock)", "refills every 5h"])
        #expect(backDay.map(\.mark) == [.text("Weekly"), .text("Fable"), .text("5 hours")])

        let lost = AIResetDayReadout.lines(day(16, [.expires(.weekly, back)]), now: now, calendar: utc)
        #expect(lost == [.init(mark: .diamond, text: "Weekly reset runs out \(clock)")])
    }

    /// The pointer within `snap` points of a diamond takes that reset's own moment; further off, the
    /// moment under it.
    @Test func thePointerSnapsToANearbyReset() {
        let a = AIAccount(id: "a", provider: .claude, label: "P", signIn: .oauth)
        let expiry = now.addingTimeInterval(15 * 86400)
        let plan = AIResetPlan.make(
            account: a, reading: AIReading(grants: [AIResetGrant(id: "w", expiresAt: expiry, usableNow: true, detail: "", kind: .weekly)]),
            soon: Warnings.resetSoon, now: now)
        let width: CGFloat = 300, at = 0.5  // the reset sits at half the strip, x 150
        let near = AIResetStrip.moment(plan, pointer: at + Double(AIResetStrip.snap - 1) / Double(width), width: width)
        #expect(near.date == expiry && near.expiry == expiry)
        let off = AIResetStrip.moment(plan, pointer: at + Double(AIResetStrip.snap + 2) / Double(width), width: width)
        #expect(off.expiry == nil && off.date > expiry)
        #expect(AIResetStrip.moment(plan, pointer: 2, width: width).date == now.addingTimeInterval(AIResetPlan.span))  // clamped
    }

    /// A reset's run-out line: local day, date and time, then the countdown.
    @Test func aResetSaysWhenItRunsOutInLocalTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let date = now.addingTimeInterval(15 * 86400 + 10 * 3600)
        let text = AIText.resetDate(date, calendar: calendar)
        let hour = calendar.component(.hour, from: date), minute = calendar.component(.minute, from: date)
        let twelve = hour.isMultiple(of: 12) ? 12 : hour - (hour > 12 ? 12 : 0)
        #expect(text.contains(String(format: "%02d:%02d", hour, minute)) || text.contains("\(twelve):\(String(format: "%02d", minute))"))
        #expect(!text.contains("UTC") && !text.contains("GMT"))
        #expect(AIResetsPage.runsOut(date, now: now).hasSuffix(" · 15d 10h"))
        #expect(AIResetsPage.runsOut(date, now: now).hasPrefix("runs out "))
    }

    @Test func thePaceMarkSitsAtTheShareOfTheWindowGone() {
        let a = AIAccount(id: "a", provider: .claude, label: "P", signIn: .oauth)
        // A week with 30% gone (resets in 70% of a week), 20% used: ahead of pace.
        let entry = AIPriorityBoard.Entry(line: AILimitLine(account: a, metric: limit("weekly", used: 20, resetsIn: AIPeriod.week * 0.7)), reason: nil)
        var o = AIUsageSettings()
        #expect(AIRowModel(entry: entry, settings: o, now: now)?.tick == nil)  // off by default
        o.paceMarks = true
        let left = AIRowModel(entry: entry, settings: o, now: now)
        #expect(abs((left?.tick ?? -1) - 0.3) < 1e-9)
        #expect(left?.help == "~33% left at reset")
        o.display = .used
        #expect(abs((AIRowModel(entry: entry, settings: o, now: now)?.tick ?? -1) - 0.3) < 1e-9)  // same bar, same mark
    }

    @Test func burningFastSaysWhenItRunsOutAndHowLongBeforeTheReset() {
        let a = AIAccount(id: "a", provider: .codex, label: "W", signIn: .oauth)
        // 5 hours, 3 gone, 92% used: out long before the reset in 2 hours.
        let line = AILimitLine(account: a, metric: limit("session", used: 92, resetsIn: 7200, period: AIPeriod.session, title: "5 hours"))
        let board = AIPriorityBoard(lines: [line], now: now)
        let row = AIRowModel(entry: board.runningOut[0], settings: AIUsageSettings(), now: now)
        #expect(row?.reset?.hasPrefix("Out in") == true)
        #expect(row?.tone == .warning)
        #expect(row?.help?.hasPrefix("At this pace: out in") == true && row?.help?.hasSuffix("before it resets") == true)
    }

    @Test func hiddenLimitsAreLeftOutEverywhere() {
        var a = AIAccount(id: "a", provider: .claude, label: "Personal", signIn: .oauth)
        a.hidden = ["low"]
        let reading = AIReading(metrics: [limit("low", used: 95), limit("weekly", used: 10)], fetchedAt: now)
        let lines = reading.metrics.map { AILimitLine(account: a, metric: $0) }
        #expect(AIAccountGroup.groups(accounts: [a], readings: ["a": reading]).first?.metrics.map(\.key) == ["weekly"])
        let card = AICardModel(lines: lines, settings: AIUsageSettings(), now: now)
        #expect(card.entries.isEmpty && card.more == 1 && card.pill == nil)
        var o = AIUsageSettings(); o.cardShows = .chosen; o.cardChosen = ["a/low", "a/weekly"]
        #expect(AICardModel(lines: lines, settings: o, now: now).entries.map(\.line.metric.key) == ["weekly"])
        #expect(AIPriorityBoard(lines: lines, now: now).isEmpty)
    }

    // MARK: Actions and text

    @Test func showInMenuBarChoosesTheLimitOnce() {
        var o = AIUsageSettings()
        o = AIPanelActions.showingInMenuBar("a/weekly", o)
        o = AIPanelActions.showingInMenuBar("a/weekly", o)
        #expect(o.menuChosen == ["a/weekly"] && o.menuMode == .chosen)
        #expect(AIOverviewControls.chosen(["x"], "y", true) == ["x", "y"] && AIOverviewControls.chosen(["x", "y"], "x", false) == ["y"])
        #expect(AIOverviewControls.chosen(["x"], "x", true) == ["x"])
        // Fix opens the account it is about; Accounts… the pane.
        let a = AIAccount(id: "acct", provider: .opencode, label: "Go", signIn: .oauth)
        #expect(AIPanelActions.fixRoute(a).pane == .aiUsage && AIPanelActions.fixRoute(a).account == "acct")
        #expect(AIPanelActions.accountsRoute.pane == .aiUsage && AIPanelActions.accountsRoute.account == nil)
        var c = AIUsageSettings(); c.cardShows = .chosen; c.cardRows = 1; c.cardChosen = ["a/x", "a/y"]
        #expect(AIOverviewControls.hint(AIUsageSettings()) == "Most urgent · 3 rows" && AIOverviewControls.hint(c) == "Chosen · 2 limits")
    }

    @Test func theHeaderAndFooterLines() {
        let a = AIAccount(id: "a", provider: .claude, label: "x@y.com", signIn: .oauth)
        let b = AIAccount(id: "b", provider: .claude, label: "Work", signIn: .oauth)
        let c = AIAccount(id: "c", provider: .codex, label: "Me", signIn: .oauth)
        #expect(AIText.accountsLine([a, b, c]) == "3 accounts · 2 providers" && AIText.accountsLine([a]) == "1 account · 1 provider")
        #expect(AIText.accountsLine([]).isEmpty)
        #expect(AIPanelView.footerText(next: now.addingTimeInterval(4 * 60), refreshing: false, now: now) == "Next update in 4m · ⌘R")
        #expect(AIPanelView.footerText(next: nil, refreshing: true, now: now) == "Updating… · ⌘R")
        #expect(AIText.label("x@y.com", hidesEmails: true) == nil && AIText.label("x@y.com", hidesEmails: false) == "x@y.com")
        #expect(AIText.label("Work", hidesEmails: true) == "Work")
        let stale = AIReading(fetchedAt: now.addingTimeInterval(-12 * 60))
        #expect(AIGroupCard.status([stale], refreshing: false, now: now)?.text == "◷ 12 min old")
        #expect(AIGroupCard.status([AIReading(fetchedAt: now, problem: .offline)], refreshing: false, now: now)?.text == "⚠︎ failed")
        #expect(AIGroupCard.status([stale], refreshing: true, now: now)?.text == "↻ refreshing")
        #expect(AIGroupCard.status([AIReading(fetchedAt: now)], refreshing: false, now: now) == nil)
    }

    @Test func theCardAndPanelReadTheService() {
        let a = AIAccount(id: "a", provider: .claude, label: "Personal", signIn: .oauth)
        let b = AIAccount(id: "b", provider: .claude, label: "Work", signIn: .oauth)
        let ai = service([a, b], ["a": AIReading(metrics: [limit("weekly", used: 95)]), "b": AIReading(metrics: [limit("weekly", used: 10)])])
        let model = AICardModel(ai: ai, settings: AIUsageSettings())
        #expect(model.initials == ["a": "P", "b": "W"] && model.entries.count == 1)
    }

    /// The AI views read no frames at all; any they add must be in a named space.
    @Test func aiViewsReadFramesInNamedSpacesOnly() {
        let files = sourceFiles("HeronUI").filter { $0.name.hasPrefix("AI") || $0.name == "SettingsOverviewAI.swift" }
        #expect(files.count >= 3)
        for file in files { #expect(!file.text.contains(".global"), "\(file.name)") }
    }
}
