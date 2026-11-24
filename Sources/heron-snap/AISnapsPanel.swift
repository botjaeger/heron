import AppKit
import HeronCore
import HeronUI
import SwiftUI

// The AI usage card in the overview, its panel (one card per account), the resets list with its
// confirmation, the empty and problem states, and Settings › Overview with AI usage selected, from
// preview accounts (no network, no Keychain). Each render has its own settings, removed at the end.

/// Accounts like the design's panel: two Claude accounts (initials on the marks), ChatGPT with
/// tokens and resets, OpenCode with a reading 12 minutes old.
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
                limit("weekly", "Weekly", used: 22, period: week, resetsIn: 9 * 3600),
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
    func panel(_ name: String, ai: AIUsageService = service, debug: AIPanelDebug? = nil, _ configure: (AppSettings) -> Void = { _ in }) {
        render(PopoverView(kind: .ai, aiDebug: debug).environment(settings(configure)).environment(ai), "ai-panel-\(name)")
    }
    panel("all")
    renderPicture(.ai, settings: settings(), ai: service, "picture-ai")
    renderPicture(.ai, settings: settings { $0.aiUsage.privacyMode = true }, ai: service, "picture-ai-privacy")
    panel("all-used-pace-clock-names") { s in
        s.aiUsage.display = .used; s.aiUsage.paceMarks = true; s.aiUsage.resetFormat = .clock; s.aiUsage.providersAs = .name
    }
    panel("all-problem", ai: troubled)
    panel("all-resets-confirm", debug: AIPanelDebug(openResets: true, confirmReset: true))
    panel("all-resets-list", debug: AIPanelDebug(openResets: true))
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
