import AppKit
import HeronCore
import HeronUI
import SwiftUI

// The AI usage card in the overview, its panel (one card per account), the resets list with its
// confirmation, the empty and problem states, and Settings › Overview with AI usage selected, from
// preview accounts (no network, no Keychain). Each render has its own settings, removed at the end.

/// The resets board's accounts: Claude (Weekly 86% used, refilling in 2 d 6 h; one Weekly reset
/// usable, two Fable resets for later) and ChatGPT (both limits out; three credits, two running out
/// this week). `spent`: the Weekly reset used (its limit full) and an account with none left.
@MainActor
private func aiResetsService(_ defaults: UserDefaults, spent: Bool = false) -> AIUsageService {
    let now = Date(), day = 86400.0, week = AIPeriod.week
    func limit(_ key: String, _ title: String, used: Double, period: Double, resetsIn: Double) -> AIMetric {
        AIMetric(key: key, title: title, value: .limit(used: used, limit: 100, unit: .percent, resetsAt: now.addingTimeInterval(resetsIn), period: period))
    }
    func grant(_ id: String, _ kind: AIResetKind, in days: Double, usable: Bool, count: Int = 1, detail: String) -> AIResetGrant {
        AIResetGrant(id: id, expiresAt: now.addingTimeInterval(days * day), usableNow: usable, detail: detail, kind: kind, count: count)
    }
    let claude = AIAccount(id: "claude-r", provider: .claude, label: "Personal", signIn: .oauth)
    let codex = AIAccount(id: "codex-r", provider: .codex, label: "Work", signIn: .oauth)
    let none = AIAccount(id: "none-r", provider: .claude, label: "Team", signIn: .oauth)
    let fable = grant("f", .fable, in: 104, usable: false, count: 2, detail: "Refills your Fable limit now. This can't be undone.")
    var claudeGrants = [fable]
    if !spent { claudeGrants.append(grant("w", .weekly, in: 15.43, usable: true, detail: "Refills your weekly limit now. This can't be undone.")) }
    let full = "Refills your 5-hour and weekly limits now. This can't be undone."
    let readings: [String: AIReading] = [
        claude.id: AIReading(
            plan: "Ultra",
            metrics: [
                limit("weekly", "Weekly", used: spent ? 0 : 86, period: week, resetsIn: 2.25 * day),
                limit("fable", "Fable", used: 0, period: week, resetsIn: 2.25 * day),
            ], grants: claudeGrants, fetchedAt: now),
        codex.id: AIReading(
            plan: "Plus",
            metrics: [
                limit("session", "5 hours", used: 100, period: AIPeriod.session, resetsIn: 5 * 3600),
                limit("weekly", "Weekly", used: 100, period: week, resetsIn: week),
            ],
            grants: [
                grant("a", .full, in: 5.33, usable: true, detail: full), grant("b", .full, in: 6.43, usable: true, detail: full),
                grant("c", .full, in: 17.43, usable: true, detail: full),
            ],
            fetchedAt: now),
        none.id: AIReading(plan: "Team", metrics: [limit("weekly", "Weekly", used: 20, period: week, resetsIn: 3 * day)], fetchedAt: now),
    ]
    let service = AIUsageService(defaults: defaults, tokens: MemoryTokenStore())
    service.setPreview(accounts: [claude, codex, none], readings: readings)
    return service
}

/// Accounts like the design's panel: two Claude accounts (initials on the marks), ChatGPT with
/// tokens and resets, OpenCode with a reading 12 minutes old (its Weekly "Resets in 23h 50m", the
/// widest reset text: the card's reset column widens for it).
@MainActor
private func aiPanelService(_ defaults: UserDefaults, problem: Bool = false) -> AIUsageService {
    let now = Date()
    func limit(_ key: String, _ title: String, used: Double, period: Double?, resetsIn: Double) -> AIMetric {
        AIMetric(key: key, title: title, value: .limit(used: used, limit: 100, unit: .percent, resetsAt: now.addingTimeInterval(resetsIn), period: period))
    }
    let week = AIPeriod.week, session = AIPeriod.session
    let personal = AIAccount(id: "claude-p", provider: .claude, label: "Personal", signIn: .oauth)
    let machine = AIAccount(id: "claude-a", provider: .claude, label: "Attention Machine 1", signIn: .oauth)
    var codex = AIAccount(id: "codex", provider: .codex, label: "Work", signIn: .borrowed)
    codex.pinned = ["weekly"]
    let opencode = AIAccount(id: "opencode", provider: .opencode, label: "Acme workspace", signIn: .oauth)
    let expiries = [14.0, 21, 28, 42].map { now.addingTimeInterval($0 * 86400) }
    // One grant of each kind, listed by expiry; the weekly one holds two resets.
    let grants = [
        AIResetGrant(id: "g3", expiresAt: expiries[2], usableNow: false, detail: "", kind: .fiveHour),
        AIResetGrant(id: "g1", expiresAt: expiries[0], usableNow: true, detail: "Refills your weekly limit now. This can't be undone.", kind: .weekly, count: 2),
        AIResetGrant(id: "g2", expiresAt: expiries[1], usableNow: false, detail: "", kind: .fable),
        AIResetGrant(id: "g4", expiresAt: expiries[3], usableNow: false, detail: "", kind: .full),
    ]
    let credits = expiries.prefix(2).enumerated().map { i, e in
        AIResetGrant(id: "c\(i)", expiresAt: e, usableNow: true, detail: "Refills your 5-hour and weekly limits now. This can't be undone.", kind: .full)
    }
    let readings: [String: AIReading] = [
        personal.id: AIReading(
            plan: "Max",
            metrics: [
                limit("weekly", "Weekly", used: 51, period: week, resetsIn: week * 0.68),
                limit("sonnet", "Sonnet", used: 12, period: week, resetsIn: week * 0.68),
                limit("fable", "Fable", used: 0, period: week, resetsIn: week * 0.68),
                AIMetric(key: "extraUsage", title: "Extra usage", value: .limit(used: 0, limit: 50, unit: .usd, resetsAt: nil, period: nil)),
                AIMetric(key: "resets", title: "Limit resets", value: .resets(count: 5, expiries: [expiries[0]] + expiries)),
            ], grants: grants, fetchedAt: now),
        machine.id: AIReading(
            plan: "Pro",
            metrics: [
                limit("session", "5 hours", used: 74, period: session, resetsIn: 6000),
                limit("weekly", "Weekly", used: 40, period: week, resetsIn: 2 * 86400 + 3 * 3600),
                limit("sonnet", "Sonnet", used: 40, period: week, resetsIn: 2 * 86400 + 3 * 3600),
            ], fetchedAt: now),
        codex.id: AIReading(
            plan: "Plus",
            metrics: [
                limit("session", "5 hours", used: 92, period: session, resetsIn: 7200),
                limit("weekly", "Weekly", used: 3, period: week, resetsIn: 3 * 86400 + 10 * 3600),
                limit("spark", "Spark", used: 100, period: session, resetsIn: 2 * 3600 + 600),
                AIMetric(key: "extraUsage", title: "Extra usage", value: .amount(12.4, unit: .usd, label: "left")),
                AIMetric(key: "resets", title: "Limit resets", value: .resets(count: 2, expiries: Array(expiries.prefix(2)))),
                AIMetric(key: "today", title: "Today", value: .tokens(1_200_000)),
                AIMetric(key: "yesterday", title: "Yesterday", value: .tokens(0)),
                AIMetric(key: "last30", title: "Last 30 days", value: .tokens(277_900_000)),
            ], grants: credits, fetchedAt: now),
        opencode.id: AIReading(
            plan: "Go Plus",
            metrics: [
                limit("session", "5 hours", used: 12, period: session, resetsIn: 3 * 3600),
                limit("weekly", "Weekly", used: 22, period: week, resetsIn: 23 * 3600 + 50 * 60),
                limit("monthly", "Monthly", used: 79, period: AIPeriod.month, resetsIn: 11 * 86400),
            ], fetchedAt: now.addingTimeInterval(-12 * 60), problem: problem ? .signInExpired : nil),
    ]
    let service = AIUsageService(defaults: defaults, tokens: MemoryTokenStore())
    service.setPreview(accounts: [personal, machine, codex, opencode], readings: readings)
    return service
}

/// Renders "ai-*": the popover with the AI card, the panel's states, and Settings ›
/// Overview with AI usage selected, light and dark.
@MainActor
func renderAIPanel() {
    var suites: [String] = []
    func scratch(_ name: String) -> UserDefaults {
        let suite = "app.heron.snap.ai-panel.\(suites.count).\(name)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    func settings(_ configure: (AppSettings) -> Void = { _ in }) -> AppSettings {
        let s = AppSettings(defaults: scratch("settings"))
        configure(s)
        return s
    }
    let service = aiPanelService(scratch("service"))
    let troubled = aiPanelService(scratch("troubled"), problem: true)

    // The popover with the card, moved up so it is in view, and its options.
    func popover(_ name: String, _ configure: @escaping (AppSettings) -> Void = { _ in }) {
        let s = settings { s in
            s.setOverviewOrder([.cpu, .ai]); configure(s)
        }
        render(PopoverView(kind: .overview).environment(s).environment(service), "ai-popover-\(name)")
    }
    popover("card")
    popover("card-pinned-no-pill") { s in
        s.aiUsage.cardShows = .pinned; s.aiUsage.cardPill = false
    }
    popover("card-chosen-five") { s in
        s.aiUsage.cardShows = .chosen; s.aiUsage.cardRows = 5
        s.aiUsage.cardChosen = ["opencode/monthly", "claude-p/weekly", "codex/spark", "claude-a/session", "opencode/weekly"]
    }
    let none = AIUsageService(defaults: scratch("none"), tokens: MemoryTokenStore())
    render(PopoverView(kind: .overview).environment(settings { $0.setOverviewOrder([.cpu, .ai]) }).environment(none), "ai-popover-no-accounts")

    // The panel.
    func panel(_ name: String, ai: AIUsageService = service, _ configure: (AppSettings) -> Void = { _ in }) {
        render(PopoverView(kind: .ai).environment(settings(configure)).environment(ai), "ai-panel-\(name)")
    }
    panel("all")
    renderPicture(.ai, settings: settings(), ai: service, "picture-ai")
    renderPicture(.ai, settings: settings { $0.aiUsage.privacyMode = true }, ai: service, "picture-ai-privacy")
    panel("all-used-pace-clock-names") { s in
        s.aiUsage.display = .used; s.aiUsage.paceMarks = true; s.aiUsage.resetFormat = .clock; s.aiUsage.providersAs = .name
    }
    panel("all-problem", ai: troubled)
    // The resets beside the panel (the mockup's "Limit resets" board): Claude with a Weekly reset
    // to use and two Fable resets for March; ChatGPT with two credits running out this week.
    let resets = aiResetsService(scratch("resets"))
    func page(_ name: String, _ id: String, confirming: AIResetKind? = nil, outcome: String? = nil, hover: Double? = nil, ai: AIUsageService = resets) {
        render(
            AIResetsPage(accountID: id, confirming: confirming, outcome: outcome, hover: hover.map { Date().addingTimeInterval($0 * 86400) })
                .padding(14).frame(width: HistoryPage.width)
                .environment(settings()).environment(ai),
            "ai-resets-\(name)")
    }
    page("claude", "claude-r")
    // Hovering the strip (the "hover a day" board): a day Weekly is out, the day it refills, the
    // day the Weekly reset runs out (the pointer a little off the diamond snaps to it).
    page("claude-hover-out", "claude-r", hover: 1.5)
    page("claude-hover-refill", "claude-r", hover: 2.25)
    page("claude-hover-expiry", "claude-r", hover: 15.5)
    page("claude-confirm", "claude-r", confirming: .weekly)
    page("chatgpt-soon", "codex-r")
    let spent = aiResetsService(scratch("spent"), spent: true)
    page("claude-done", "claude-r", outcome: "Done: the limit is refilled.", ai: spent)
    page("none", "none-r", ai: spent)
    panel("no-accounts", ai: none)
    // No reported limits: an account that has not been read yet.
    let waiting = AIUsageService(defaults: scratch("waiting"), tokens: MemoryTokenStore())
    waiting.setPreview(accounts: [AIAccount(id: "c", provider: .claude, label: "Personal", signIn: .oauth)], readings: [:])
    panel("no-reported", ai: waiting)

    // Settings › Overview with AI usage selected.
    let size = CGSize(width: SettingsView.size.width, height: SettingsView.size.height)
    func settingsRender(_ name: String, ai: AIUsageService = service, panel: Bool = false, _ configure: (AppSettings) -> Void = { _ in }) {
        render(
            SettingsView(pane: .overview, section: .ai, showsPanel: panel).environment(settings(configure)).environment(ai),
            "ai-settings-overview-\(name)", width: size.width, height: size.height)
    }
    settingsRender("most-urgent")
    settingsRender("chosen") { s in
        s.aiUsage.cardShows = .chosen; s.aiUsage.cardChosen = ["codex/weekly", "claude-p/weekly"]; s.aiUsage.cardRows = 2
    }
    settingsRender("panel", panel: true)
    settingsRender("no-accounts", ai: none)

    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
}
