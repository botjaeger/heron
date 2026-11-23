import AppKit
import HeronCore
import HeronUI
import SwiftUI

// Settings › AI Usage and its sheets (design: SettingsAIUsage, AIAccounts), from preview accounts
// (no network, no Keychain). Each render has its own settings, removed at the end.

/// The design's four accounts: Claude Personal (Heron's sign-in, Max), Claude Code's borrowed
/// sign-in (Pro), Codex's (Plus), and OpenCode whose sign-in expired.
enum AISettingsSample {
    @MainActor
    static func service(_ defaults: UserDefaults, accounts: Bool = true) -> AIUsageService {
        let service = AIUsageService(defaults: defaults, tokens: MemoryTokenStore())
        guard accounts else { return service }
        let now = Date()
        func limit(_ key: String, _ title: String, used: Double, period: Double, resetsIn: Double) -> AIMetric {
            AIMetric(key: key, title: title, value: .limit(used: used, limit: 100, unit: .percent, resetsAt: now.addingTimeInterval(resetsIn), period: period))
        }
        var personal = AIAccount(id: "s-claude-p", provider: .claude, label: "Personal", signIn: .oauth)
        personal.pinned = ["weekly"]; personal.hidden = ["fable"]
        let machine = AIAccount(id: "s-claude-a", provider: .claude, label: "Attention Machine 1", signIn: .borrowed, extras: ["identity": "borrowed:claude"])
        let codex = AIAccount(id: "s-codex", provider: .codex, label: "you@example.com", signIn: .borrowed, extras: ["identity": "borrowed:codex"])
        let opencode = AIAccount(id: "s-opencode", provider: .opencode, label: "Acme workspace", signIn: .oauth)
        let week = AIPeriod.week, session = AIPeriod.session
        service.setPreview(
            accounts: [personal, machine, codex, opencode],
            readings: [
                personal.id: AIReading(
                    plan: "Max",
                    metrics: [
                        limit("session", "5 hours", used: 22, period: session, resetsIn: 3 * 3600 + 25 * 60),
                        limit("weekly", "Weekly", used: 51, period: week, resetsIn: 4 * 86400),
                        limit("sonnet", "Sonnet", used: 12, period: week, resetsIn: 4 * 86400),
                        limit("fable", "Fable", used: 0, period: week, resetsIn: 4 * 86400),
                        AIMetric(key: "extraUsage", title: "Extra usage", value: .limit(used: 4.12, limit: 50, unit: .usd, resetsAt: nil, period: nil)),
                        AIMetric(key: "resets", title: "Limit resets", value: .resets(count: 2, expiries: [now.addingTimeInterval(14 * 86400)])),
                    ], fetchedAt: now),
                machine.id: AIReading(plan: "Pro", metrics: [limit("weekly", "Weekly", used: 40, period: week, resetsIn: 2 * 86400)], fetchedAt: now),
                codex.id: AIReading(
                    plan: "Plus",
                    metrics: [
                        limit("session", "5 hours", used: 92, period: session, resetsIn: 7200),
                        limit("weekly", "Weekly", used: 3, period: week, resetsIn: 3 * 86400),
                    ], fetchedAt: now),
                opencode.id: AIReading(
                    plan: "Go Plus", metrics: [limit("monthly", "Monthly", used: 79, period: AIPeriod.month, resetsIn: 11 * 86400)],
                    fetchedAt: now.addingTimeInterval(-3600), problem: .signInExpired),
            ])
        return service
    }
}

/// Renders "settings-aiusage-*" and "sheet-ai-*".
@MainActor
func renderAISettings() {
    var suites: [String] = []
    func defaults(_ name: String) -> UserDefaults {
        let suite = "app.heron.snap.ai-settings.\(suites.count).\(name)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    let cli = AICLIPresence(claudeCode: true, codex: true)
    let service = AISettingsSample.service(defaults("service"))
    let empty = AISettingsSample.service(defaults("empty"), accounts: false)
    let size = SettingsView.size
    // The pane taller than the window shows every section at once.
    let full = CGSize(width: size.width, height: 1500)

    func pane(_ name: String, ai: AIUsageService = service, cli: AICLIPresence = cli, height: CGFloat = size.height, _ configure: (AppSettings) -> Void = { _ in }) {
        let s = AppSettings(defaults: defaults(name))
        configure(s)
        render(
            SettingsView(pane: .aiUsage).environment(s).environment(ai).environment(\.aiCLIPresence, cli),
            "settings-aiusage-\(name)", width: size.width, height: height)
    }
    pane("window")
    pane("full", height: full.height)
    // Every option away from its default; notifications on while macOS has them off.
    services.notificationPermission = .denied
    pane("options-full", height: full.height) { s in
        s.aiUsage.display = .used; s.aiUsage.resetFormat = .clock; s.aiUsage.paceMarks = true; s.aiUsage.providersAs = .name
        s.aiUsage.thresholds = AIThresholds(warning: 50, critical: 20)
        s.aiUsage.notify = [.warning, .critical, .burningFast]
        s.aiUsage.privacyMode = true; s.aiUsage.shortcut = "⌥⌘U"
    }
    services.notificationPermission = .allowed
    // No account yet, and neither CLI on this Mac: no borrow buttons.
    pane("empty", ai: empty, cli: AICLIPresence(claudeCode: false, codex: false))
    pane("empty-codex-only", ai: empty, cli: AICLIPresence(claudeCode: false, codex: true))

    // The sheets, as they sit over the pane.
    let flow = AISignInFlow(service: service, openURL: { _ in })
    let s = AppSettings(defaults: defaults("sheets"))
    func sheet<V: View>(_ view: V, _ name: String) {
        render(view.environment(s).environment(service).background(Color(nsColor: .windowBackgroundColor)), "sheet-ai-\(name)")
    }
    sheet(AIAccountSheet(accountID: "s-claude-p", flow: flow) {}, "account")
    sheet(AIAccountSheet(accountID: "s-opencode", flow: flow) {}, "account-expired")
    sheet(AIAccountSheet(accountID: "s-codex", flow: flow) {}, "account-borrowed")
    sheet(AIAddAccountSheet(flow: flow) {}, "add")
    func step(_ step: AISignInFlow.Step, _ name: String) {
        sheet(AISignInStepView(step: step, flow: nil, retry: {}, done: {}).padding(18).frame(width: 380), "signin-\(name)")
    }
    step(.browser(.claude, URL(string: "https://claude.ai/oauth/authorize")!), "browser")
    if let code = OpenCodeAPI.deviceCode(["device_code": "d", "user_code": "KQ7M-2XWD", "verification_uri_complete": "https://opencode.ai/console/auth/device?code=KQ7M-2XWD"]) {
        step(.device(code), "device")
    }
    step(.failed("Port 1455 is busy (Codex may be signing in). Close it and try again."), "failed")
    step(.failed("Codex is not signed in on this Mac."), "borrow-failed")
    step(.done("you@example.com"), "done")

    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
}
