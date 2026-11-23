import AppKit
import HeronCore
import HeronUI
import SwiftUI

// The AI usage menu bar item in every variant, and Settings › Menu Bar with it selected, from
// preview accounts (no network, no Keychain). Each variant has its own settings, removed at the end.

/// The menu bar item with AI accounts, as the status bar shows it, in the mode it is rendered in.
private struct AIMenuBarRow: View {
    var settings: AppSettings
    var ai: AIUsageService
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let image = MenuBarRenderer.image(
            for: MenuBarLabel(
                snapshot: Snapshot(), history: MetricHistory(), settings: settings,
                ink: dark ? .white : .black, dark: dark, ai: ai))
        Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original).foregroundStyle(.primary)
    }
}

/// Accounts like the design's: Claude, ChatGPT and OpenCode, with limits running out, burning
/// fast, fine and used up. `twoClaude`: a second Claude account (initials on the marks).
@MainActor
private func aiPreviewService(suite: String, twoClaude: Bool = false) -> AIUsageService {
    let now = Date()
    func limit(_ key: String, _ title: String, left: Double, period: Double? = nil, resetsIn: Double = 3 * 86400) -> AIMetric {
        AIMetric(key: key, title: title, value: .limit(used: 100 - left, limit: 100, unit: .percent, resetsAt: now.addingTimeInterval(resetsIn), period: period))
    }
    let claude = AIAccount(id: "claude-p", provider: .claude, label: "Personal", signIn: .oauth)
    let claude2 = AIAccount(id: "claude-a", provider: .claude, label: "Attention Machine 1", signIn: .oauth)
    let codex = AIAccount(id: "codex", provider: .codex, label: "Work", signIn: .borrowed)
    let opencode = AIAccount(id: "opencode", provider: .opencode, label: "Go", signIn: .oauth)
    var accounts = [claude, codex, opencode]
    var readings: [String: AIReading] = [
        // Weekly: 51% used with 30% of the week gone, burning fast (red although half is left).
        claude.id: AIReading(
            plan: "Max",
            metrics: [
                limit("weekly", "Weekly", left: 49, period: AIPeriod.week, resetsIn: AIPeriod.week * 0.7),
                limit("session", "5 hours", left: 72),
            ]),
        codex.id: AIReading(
            plan: "Plus",
            metrics: [
                limit("session", "5 hours", left: 8), limit("weekly", "Weekly", left: 78),
                limit("spark", "Spark", left: 0),
            ]),
        opencode.id: AIReading(plan: "Go", metrics: [limit("monthly", "Monthly", left: 21), limit("weekly", "Weekly", left: 27)]),
    ]
    if twoClaude {
        accounts.insert(claude2, at: 1)
        readings[claude.id] = AIReading(metrics: [limit("weekly", "Weekly", left: 9)])
        readings[claude2.id] = AIReading(metrics: [limit("session", "5 hours", left: 12)])
    }
    let service = AIUsageService(defaults: UserDefaults(suiteName: suite)!, tokens: MemoryTokenStore())
    service.setPreview(accounts: accounts, readings: readings)
    return service
}

/// Renders "menubar-ai" (every variant) and "settings-menubar-ai-*" (Settings › Menu Bar with AI
/// usage selected), light and dark.
@MainActor
func renderAIMenuBar() {
    var suites: [String] = []
    func scratch(_ name: String) -> UserDefaults {
        let suite = "app.heron.snap.ai-menubar.\(suites.count).\(name)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    let service = aiPreviewService(suite: "app.heron.snap.ai-menubar.service")
    let twoClaude = aiPreviewService(suite: "app.heron.snap.ai-menubar.service2", twoClaude: true)
    suites += ["app.heron.snap.ai-menubar.service", "app.heron.snap.ai-menubar.service2"]

    var rows: [(String, AIMenuBarRow)] = []
    func row(_ name: String, ai: AIUsageService = service, _ configure: (AppSettings) -> Void) {
        let s = AppSettings(defaults: scratch("row"))
        s.setShown(.ai, true)
        configure(s)
        rows.append((name, AIMenuBarRow(settings: s, ai: ai)))
    }
    row("most urgent, 3, +1") { _ in }
    row("most urgent, 1, +3") { $0.aiUsage.menuCount = 1 }
    row("always show, 4, +1") {
        $0.aiUsage.alwaysShow = true; $0.aiUsage.menuCount = 4
    }
    row("two Claude accounts: initials", ai: twoClaude) { _ in }
    row("providers as names") {
        $0.aiUsage.providersAs = .name; $0.aiUsage.menuCount = 2
    }
    row("names, two accounts", ai: twoClaude) { $0.aiUsage.providersAs = .name }
    row("used") { $0.aiUsage.display = .used }
    row("no limit names") { $0.aiUsage.showLimitName = false }
    row("chosen: Claude weekly, ChatGPT 5 hours") { s in
        s.aiUsage.menuMode = .chosen; s.aiUsage.menuChosen = ["claude-p/weekly", "codex/session"]
    }
    row("chosen, stale id skipped") { s in
        s.aiUsage.menuMode = .chosen; s.aiUsage.menuChosen = ["gone/weekly", "codex/weekly", "opencode/weekly"]
    }
    row("red warnings off") { $0.warnRed = false }
    row("with CPU, metric colours") { s in
        s.setShown(.cpu, true); s.setStyle(.cpu, .text); s.colourMode = .metric
    }
    row("icon only (How many: Icon only)") { $0.aiUsage.menuCount = 0 }
    let strip = VStack(alignment: .leading, spacing: 8) {
        ForEach(rows, id: \.0) { row in
            HStack(spacing: 12) {
                Text(row.0).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                row.1
            }
        }
    }.padding(8)
    render(strip, "menubar-ai")

    // Settings › Menu Bar with AI usage selected: most urgent, chosen, names, and no accounts yet.
    let size = CGSize(width: SettingsView.size.width, height: 960)
    func settingsRender(_ name: String, ai: AIUsageService, _ configure: (AppSettings) -> Void) {
        let s = AppSettings(defaults: scratch("settings"))
        s.setShown(.ai, true)
        configure(s)
        render(SettingsView(pane: .menuBar, menuBarItem: .ai).environment(s).environment(ai), "settings-menubar-ai-\(name)", width: size.width, height: size.height)
    }
    settingsRender("most-urgent", ai: service) { _ in }
    settingsRender("chosen", ai: twoClaude) { s in
        s.aiUsage.menuMode = .chosen; s.aiUsage.menuChosen = ["claude-p/weekly", "codex/session"]
        s.aiUsage.providersAs = .name
    }
    settingsRender("hidden-icon-only", ai: service) { s in
        s.setShown(.ai, false); s.aiUsage.menuCount = 0
    }
    let none = AIUsageService(defaults: scratch("none"), tokens: MemoryTokenStore())
    settingsRender("no-accounts", ai: none) { _ in }

    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
}
