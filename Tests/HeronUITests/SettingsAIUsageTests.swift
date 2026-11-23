import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// Settings › AI Usage: its pane, thresholds, the borrow buttons, the shortcut, the command line.
@Suite struct SettingsAIUsageTests {
    @Test func thePaneIsListedAfterOverviewAndOwnsTheSetting() {
        #expect(SettingsPane.sidebar.firstIndex(of: .aiUsage) == SettingsPane.sidebar.firstIndex(of: .overview).map { $0 + 1 })
        #expect(SettingsPane.aiUsage.keys.contains("aiUsage"))
        #expect(SettingsPane.aiUsage.title == "AI Usage")
        #expect(SettingsPane.matching("privacy mode") == [.aiUsage])
        #expect(SettingsPane.matching("device code").isEmpty == false)
        #expect(SettingsRoute.aiUsage(account: "x").pane == .aiUsage && SettingsRoute.aiUsage(account: "x").account == "x")
    }

    /// Settings saved before the Priority view was removed still load: "priority" and
    /// "panelOpensOn" are ignored and every other field keeps its saved value.
    @Test func oldSettingsWithThePriorityKeysStillDecode() throws {
        let old = """
            {"display":"used","resetFormat":"clock","paceMarks":true,"providersAs":"name","panelOpensOn":"priority",
             "thresholds":{"warning":50,"critical":20},"priority":["warning","critical"],"notify":["burningFast"],
             "privacyMode":true,"shortcut":"⌥⌘U","menuMode":"chosen","menuCount":2,"menuChosen":["a/weekly"],
             "cardShows":"pinned","cardRows":4,"cardPill":false,"cardChosen":["a/session"]}
            """
        let s = try JSONDecoder().decode(AIUsageSettings.self, from: Data(old.utf8))
        #expect(s.display == .used && s.resetFormat == .clock && s.paceMarks && s.providersAs == .name)
        #expect(s.thresholds == AIThresholds(warning: 50, critical: 20) && s.notify == [.burningFast])
        #expect(s.privacyMode && s.shortcut == "⌥⌘U")
        #expect(s.menuMode == .chosen && s.menuCount == 2 && s.menuChosen == ["a/weekly"])
        #expect(s.cardShows == .pinned && s.cardRows == 4 && !s.cardPill && s.cardChosen == ["a/session"])
        // The ranking keeps burning fast and use it or lose it, whatever the old switches said.
        #expect(s.boardOptions == AIPriorityBoard.Options(thresholds: AIThresholds(warning: 50, critical: 20), burningFast: true, useItOrLoseIt: true))
        let encoded = try #require(String(data: JSONEncoder().encode(s), encoding: .utf8))
        #expect(!encoded.contains("panelOpensOn") && !encoded.contains("\"priority\""))
    }

    /// Every stepper press leaves Warning in 20…70, Critical in 5…25 and at least 5 under Warning.
    @Test func thresholdsStayValidWhateverIsStepped() {
        func valid(_ t: AIThresholds) -> Bool {
            AIThresholds.warningRange.contains(t.warning) && AIThresholds.criticalRange.contains(t.critical) && t.critical <= t.warning - 5
        }
        for w in stride(from: 0, through: 90, by: 5) {
            for c in stride(from: 0, through: 40, by: 5) {
                let start = AIThresholds(warning: w, critical: c)
                #expect(valid(start))
                for step in [-5, 5] {
                    #expect(valid(AIUsagePane.settingWarning(start, to: start.warning + step)), "\(start) warning \(step)")
                    #expect(valid(AIUsagePane.settingCritical(start, to: start.critical + step)), "\(start) critical \(step)")
                }
            }
        }
        // Lowering Warning to 20 pulls Critical under it.
        #expect(AIUsagePane.settingWarning(AIThresholds(warning: 30, critical: 25), to: 20) == AIThresholds(warning: 20, critical: 15))
    }

    @Test func borrowButtonsShowOnlyForACLISignedInHereAndNotYetAdded() {
        let none = AICLIPresence(claudeCode: false, codex: false), both = AICLIPresence(claudeCode: true, codex: true)
        #expect(AIUsagePane.borrowable(none, accounts: []).isEmpty)
        #expect(AIUsagePane.borrowable(AICLIPresence(claudeCode: true, codex: false), accounts: []) == [.claude])
        #expect(AIUsagePane.borrowable(AICLIPresence(claudeCode: false, codex: true), accounts: []) == [.codex])
        #expect(AIUsagePane.borrowable(both, accounts: []) == [.claude, .codex])
        let borrowed = AIAccount(provider: .claude, label: "Claude Code", signIn: .borrowed, extras: ["identity": "borrowed:claude"])
        #expect(AIUsagePane.borrowable(both, accounts: [borrowed]) == [.codex])
        let codex = AIAccount(provider: .codex, label: "Codex", signIn: .borrowed, extras: ["identity": "borrowed:codex"])
        #expect(AIUsagePane.borrowable(both, accounts: [codex]) == [.claude])
        // Heron's own Claude sign-in does not hide the borrow button.
        let own = AIAccount(provider: .claude, label: "me@example.com", signIn: .oauth, extras: ["identity": "u/o"])
        #expect(AIUsagePane.borrowable(both, accounts: [own]) == [.claude, .codex])
    }

    @Test func accountRowsSayHowTheySignInAndTheirState() {
        let claude = AIAccount(provider: .claude, label: "Personal", signIn: .oauth)
        #expect(AIUsagePane.subtitle(claude, plan: "Max") == "Browser sign-in · Max")
        #expect(AIUsagePane.subtitle(AIAccount(provider: .opencode, label: "Acme", signIn: .oauth), plan: nil) == "Device code sign-in")
        #expect(AIUsagePane.subtitle(AIAccount(provider: .codex, label: "Codex", signIn: .borrowed), plan: "Plus") == "Codex CLI’s sign-in (borrowed, read-only) · Plus")
        #expect(AIUsagePane.status(AIReading(problem: .signInExpired), refreshing: false) == ("Sign-in expired", true))
        #expect(AIUsagePane.status(nil, refreshing: true) == ("Checking…", false))
        #expect(AIUsagePane.status(AIReading(), refreshing: false) == ("OK", false))
    }

    @Test func shortcutsRoundTripAndNeedAModifier() throws {
        let s = try #require(AIShortcut(keyCode: 32, flags: [.option, .command]))  // U
        #expect(s.string == "⌥⌘U")
        #expect(AIShortcut(string: "⌥⌘U") == s)
        #expect(s.carbonModifiers == 0x900)
        #expect(AIShortcut(string: "⌃⇧Space")?.keyCode == 49)
        #expect(AIShortcut(keyCode: 32, flags: [.shift]) == nil)  // ⇧U alone would steal typing
        #expect(AIShortcut(string: "U") == nil)
        #expect(AIShortcut(string: "⌘é") == nil)  // not a key Heron can register
        for (code, _) in AIShortcut.keys {
            let k = try #require(AIShortcut(keyCode: code, flags: [.control]))
            #expect(AIShortcut(string: k.string) == k, "\(k.string)")
        }
    }

    @Test func theCommandIsTheAppsOwnBinaryQuotedWhenNeeded() {
        #expect(AIUsagePane.command(executable: "/Applications/Heron.app/Contents/MacOS/Heron") == "/Applications/Heron.app/Contents/MacOS/Heron usage --json")
        #expect(AIUsagePane.command(executable: "/Users/me/My Apps/Heron.app/Contents/MacOS/Heron") == "'/Users/me/My Apps/Heron.app/Contents/MacOS/Heron' usage --json")
    }
}

/// `Heron usage --json`: the cached readings, never a refresh or a token.
@Suite struct UsageExportTests {
    @Test func printsTheSavedReadingsInTheV1Shape() throws {
        let d = scratchDefaults("usage-export")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = AIAccount(id: "acc1", provider: .codex, label: "you@example.com", signIn: .borrowed)
        let b = AIAccount(id: "acc2", provider: .claude, label: "Never read", signIn: .oauth)
        let reading = AIReading(
            plan: "Plus",
            metrics: [
                AIMetric(key: "session", title: "5 hours", value: .limit(used: 92, limit: 100, unit: .percent, resetsAt: now.addingTimeInterval(3600), period: AIPeriod.session)),
                AIMetric(key: "today", title: "Today", value: .tokens(1234)),
            ], fetchedAt: now.addingTimeInterval(-900))
        d.set(try JSONEncoder().encode([a, b]), forKey: "aiAccounts")
        d.set(try JSONEncoder().encode(["acc1": reading]), forKey: "aiReadings")
        let (json, status) = AIUsageExport.run(defaults: d, now: now)
        #expect(status == 0)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(root["schema"] as? String == "heron.usage.v1")
        #expect(root["generatedAt"] as? String == ISO8601DateFormatter().string(from: now))
        let accounts = try #require(root["accounts"] as? [[String: Any]])
        try #require(accounts.count == 1)  // the unread account is left out
        let acc = accounts[0]
        #expect(acc["id"] as? String == "acc1" && acc["provider"] as? String == "codex" && acc["label"] as? String == "you@example.com")
        #expect(acc["plan"] as? String == "Plus")
        #expect(acc["stale"] as? Bool == true)  // 15 minutes old
        #expect(acc["fetchedAt"] as? String == ISO8601DateFormatter().string(from: now.addingTimeInterval(-900)))
        let metrics = try #require(acc["metrics"] as? [[String: Any]])
        #expect(metrics.map { $0["key"] as? String } == ["session", "today"])
        #expect(metrics[0]["kind"] as? String == "limit" && metrics[0]["percentLeft"] as? Int == 8 && metrics[0]["used"] as? Double == 92)
        #expect(metrics[0]["resetsAt"] as? String == ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)))
        #expect(metrics[1]["kind"] as? String == "tokens" && metrics[1]["tokens"] as? Int == 1234)
    }

    /// Everywhere or nowhere: the export lists each reset's kind as the panel does, in expiry order.
    @Test func resetsCarryTheirKindInExpiryOrder() throws {
        let d = scratchDefaults("usage-export-kinds")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = AIAccount(id: "acc1", provider: .claude, label: "Me", signIn: .oauth)
        let late = now.addingTimeInterval(9 * 86400), soon = now.addingTimeInterval(2 * 86400)
        let reading = AIReading(
            metrics: [AIMetric(key: "resets", title: "Limit resets", value: .resets(count: 3, expiries: [soon, late, late]))],
            grants: [
                AIResetGrant(id: "w", expiresAt: late, usableNow: true, detail: "", kind: .weekly, count: 2),
                AIResetGrant(id: "f", expiresAt: soon, usableNow: true, detail: "", kind: .fable),
            ],
            fetchedAt: now)
        d.set(try JSONEncoder().encode([a]), forKey: "aiAccounts")
        d.set(try JSONEncoder().encode(["acc1": reading]), forKey: "aiReadings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(AIUsageExport.run(defaults: d, now: now).json.utf8)) as? [String: Any])
        let metric = try #require(((root["accounts"] as? [[String: Any]])?.first?["metrics"] as? [[String: Any]])?.first)
        let resets = try #require(metric["resets"] as? [[String: Any]])
        #expect(resets.map { $0["kind"] as? String } == ["fable", "weekly", "weekly"])
        #expect(resets.first?["expiresAt"] as? String == ISO8601DateFormatter().string(from: soon))
    }

    /// Readings saved before reset kinds existed still load (Full, one reset each).
    @Test func grantsSavedWithoutAKindStillDecode() throws {
        let old = #"{"id":"g","usableNow":true,"detail":"x"}"#
        let g = try JSONDecoder().decode(AIResetGrant.self, from: Data(old.utf8))
        #expect(g.kind == .full && g.count == 1)
    }

    @Test func nothingFetchedExitsFour() throws {
        let d = scratchDefaults("usage-export-empty")
        let (json, status) = AIUsageExport.run(defaults: d)
        #expect(status == 4)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((root["accounts"] as? [Any])?.isEmpty == true)
        d.set(try JSONEncoder().encode([AIAccount(provider: .claude, label: "x", signIn: .oauth)]), forKey: "aiAccounts")
        #expect(AIUsageExport.run(defaults: d).status == 4)  // an account, but never read
    }
}
