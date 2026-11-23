import Foundation
import Testing

@testable import HeronCore

// Replies are the shapes heron-probe --ai printed on a real Mac (2026-11-22): numbers as returned,
// strings replaced, unused null keys trimmed.

@Suite struct ClaudeReplyTests {
    let usage =
        #"{"five_hour":null,"seven_day":{"utilization":51,"resets_at":"2026-11-26T18:00:00.180046+00:00"},"seven_day_sonnet":null,"extra_usage":{"is_enabled":false},"limits":[{"group":"weekly","is_active":true,"kind":"all","percent":51,"resets_at":"2026-11-26T18:00:00.180046+00:00"},{"kind":"weekly_scoped","percent":7,"resets_at":"2026-11-26T18:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}"#

    @Test func withoutA5HourWindowItShowsTheWeekAndTheScopedModel() throws {
        let m = ClaudeAPI.map(usage: try #require(AIParse.json(Data(usage.utf8))), plan: "Max")
        try #require(m.map(\.key) == ["weekly", "fable"])
        #expect(m[0].value == .limit(used: 51, limit: 100, unit: .percent, resetsAt: AIParse.date("2026-11-26T18:00:00.180046+00:00"), period: AIPeriod.week))
        #expect(m[1].title == "Fable")
    }

    @Test func extraUsageShowsOnlyWhileOnAndInDollars() throws {
        let on = #"{"extra_usage":{"is_enabled":true,"used_credits":412,"monthly_limit":5000,"decimal_places":2}}"#
        let m = ClaudeAPI.map(usage: try #require(AIParse.json(Data(on.utf8))), plan: "Max")
        #expect(m == [AIMetric(key: "extraUsage", title: "Extra usage", value: .limit(used: 4.12, limit: 50, unit: .usd, resetsAt: nil, period: nil))])
        let off = #"{"extra_usage":{"is_enabled":false,"used_credits":412}}"#
        #expect(ClaudeAPI.map(usage: try #require(AIParse.json(Data(off.utf8))), plan: nil).isEmpty)
    }

    @Test func planNamesFollowTheTier() {
        func plan(_ type: String, _ tier: String) -> String? { ClaudeAPI.plan(profile: ["organization": ["organization_type": type, "rate_limit_tier": tier]]) }
        #expect(plan("claude_max", "default_claude_max_20x") == "Ultra")
        #expect(plan("claude_max", "default_claude_max_5x") == "Max")
        #expect(plan("claude_pro", "default") == "Pro")
    }

    @Test func grantsCountEveryResetLeftAndOnlyUsableOnesCanBeSpent() throws {
        let future = "2099-01-01T00:00:00Z", past = "2000-01-01T00:00:00Z"
        let body: [String: Any] = [
            "cedar_ember": [
                "eligible": true,
                "grants": [
                    ["id": "g1", "resets_left": 2, "ends_at": future, "clears": ["five_hour"], "usable_now": true],
                    ["id": "g2", "resets_left": 1, "ends_at": past, "clears": ["seven_day"], "usable_now": true],
                    ["id": "g3", "resets_left": 1, "ends_at": future, "clears": ["five_hour", "seven_day"], "usable_now": false],
                ],
            ]
        ]
        let (metric, grants) = ClaudeAPI.grants(body)
        guard case .resets(let n, let expiries)? = metric?.value else { Issue.record("no resets row"); return }
        #expect(n == 3 && expiries.count == 3)
        #expect(grants.map(\.id) == ["g1", "g3"] && grants.map(\.usableNow) == [true, false])
        #expect(grants[0].detail == "Refills your 5-hour limit now. This can't be undone.")
        #expect(grants[1].detail == "Refills your 5-hour and weekly limits now. This can't be undone.")
        #expect(ClaudeAPI.grants(["cedar_ember": ["eligible": false, "grants": []]]).0 == nil)
    }

    @Test func aGrantClearingAWindowHeronDoesNotKnowSaysSoPlainly() {
        #expect(ClaudeAPI.detail(clears: ["five_hour", "seven_day_new"], givesBackWeekly: false) == "Immediately reset your usage limits. This can't be undone.")
        #expect(
            ClaudeAPI.detail(clears: ["seven_day_overage_included"], givesBackWeekly: true)
                == "Refills your Fable limit now and gives back what Fable used of your weekly limit. This can't be undone.")
    }
}

@Suite struct CodexReplyTests {
    let usage =
        #"{"plan_type":"plus","rate_limit":{"allowed":true,"primary_window":{"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":1795323075,"used_percent":0},"secondary_window":{"limit_window_seconds":604800,"reset_after_seconds":297845,"reset_at":1795602919,"used_percent":3}},"additional_rate_limits":null,"credits":{"has_credits":false,"balance":"0"},"rate_limit_reset_credits":{"available_count":3}}"#

    @Test func windowsPairWithTheirRowsByLength() throws {
        let body = try #require(AIParse.json(Data(usage.utf8)))
        let m = CodexAPI.map(usage: body)
        try #require(m.map(\.key) == ["session", "weekly"])
        #expect(m[1].value == .limit(used: 3, limit: 100, unit: .percent, resetsAt: Date(timeIntervalSince1970: 1_795_602_919), period: AIPeriod.week))
        #expect(CodexAPI.plan(body["plan_type"] as? String) == "Plus")
        #expect(CodexAPI.plan("pro") == "Pro 200")
    }

    @Test func swappedSlotsStillLandOnTheRightRow() {
        let swapped: [String: Any] = [
            "rate_limit": [
                "primary_window": ["limit_window_seconds": 604800, "used_percent": 40, "reset_at": 1_795_602_919],
                "secondary_window": ["limit_window_seconds": 18000, "used_percent": 9, "reset_at": 1_795_323_075],
            ]
        ]
        let m = CodexAPI.map(usage: swapped)
        #expect(m.map(\.key) == ["session", "weekly"])
        #expect(m.map { if case .limit(let u, _, _, _, _) = $0.value { return u } else { return -1 } } == [9, 40])
    }

    @Test func resetCreditsCountFromTheUsageBody() throws {
        let (metric, _) = CodexAPI.resets(usage: try #require(AIParse.json(Data(usage.utf8))), list: nil)
        #expect(metric?.value == .resets(count: 3, expiries: []))
    }

    @Test func dailyTokensSumPerDayAndFillMissingDaysWithZero() throws {
        let body: [String: Any] = [
            "data": [
                ["date": "2026-11-22T00:00:00Z", "totals": ["turns": 3, "text_total_tokens": 1000]],
                ["date": "2026-11-22", "totals": ["turns": 1, "text_total_tokens": 500]],
                ["date": "2026-11-20", "totals": ["turns": 1, "text_total_tokens": 7]],
            ]
        ]
        let days = try #require(CodexAPI.dailyTokens(body))
        let now = try #require(AIParse.date("2026-11-22T12:00:00Z"))
        #expect(CodexAPI.tokenRows(days, now: now).map(\.value) == [.tokens(1507)])
        #expect(CodexAPI.dailyTokens(["data": [["date": "2026-11-22", "totals": [String: Any]()]]]) == nil)
    }

    // The rate_limits of a real "token_count" line from ~/.codex/sessions (2026-11-18), tokens trimmed.
    @Test func aSessionLogLineGivesThe5HourAndWeeklyLimits() throws {
        let line =
            #"{"timestamp":"2026-11-18T10:48:15.563Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":21.0,"window_minutes":300,"resets_at":1795016119},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1795602919},"plan_type":"plus"}}}"#
        let r = try #require(BorrowedSignIn.codexLogLine(Data(line.utf8)))
        try #require(r.metrics.map(\.key) == ["session", "weekly"])
        #expect(r.plan == "Plus")
        #expect(r.metrics[0].value == .limit(used: 21, limit: 100, unit: .percent, resetsAt: Date(timeIntervalSince1970: 1_795_016_119), period: AIPeriod.session))
        #expect(r.fetchedAt == AIParse.date("2026-11-18T10:48:15.563Z"))
    }
}

@Suite struct OpenCodeReplyTests {
    @Test func rollingWeeklyAndMonthlyBecomeRows() throws {
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        let f = ISO8601DateFormatter()
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 12, "resetsAt": f.string(from: captured.addingTimeInterval(3600))],
                "weekly": ["percent": 22, "resetsAt": f.string(from: captured.addingTimeInterval(86400))],
                "monthly": ["percent": 140, "resetsAt": f.string(from: captured.addingTimeInterval(9 * 86400))],
            ]
        ]
        let m = try #require(OpenCodeAPI.map(usage: body, capturedAt: captured))
        #expect(m.map(\.key) == ["session", "weekly", "monthly"])
        #expect(m[2].value == .limit(used: 100, limit: 100, unit: .percent, resetsAt: captured.addingTimeInterval(9 * 86400), period: AIPeriod.month))
    }

    @Test func aSessionAt0PercentResettingIn5HoursHasNotStarted() throws {
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        let body: [String: Any] = ["usage": ["rolling": ["percent": 0, "resetsAt": ISO8601DateFormatter().string(from: captured.addingTimeInterval(AIPeriod.session))]]]
        let m = try #require(OpenCodeAPI.map(usage: body, capturedAt: captured))
        #expect(m[0].value == .limit(used: 0, limit: 100, unit: .percent, resetsAt: nil, period: AIPeriod.session))
    }

    @Test func noGoSubscriptionAndPlans() {
        #expect(OpenCodeAPI.isNoSubscription(status: 403, body: ["error": ["type": "EntitlementError"]]))
        #expect(!OpenCodeAPI.isNoSubscription(status: 403, body: [:]))
        #expect(OpenCodeAPI.plan(status: ["product": "go-plus"]) == "Go Plus")
        #expect(OpenCodeAPI.map(usage: ["usage": ["weekly": ["percent": 3]]]) == nil)
    }
}

@Suite struct AIAuthTests {
    @Test func aPastedCodeMustCarryThisSignInsState() throws {
        #expect(try AIAuth.code(fromPasted: "http://localhost:1455/auth/callback?code=abc&state=S1", expectedState: "S1") == "abc")
        #expect(try AIAuth.code(fromPasted: " abc#S1 ", expectedState: "S1") == "abc")
        #expect(throws: AIAuthError.invalidState) { try AIAuth.code(fromPasted: "abc", expectedState: "S1") }
        #expect(throws: AIAuthError.invalidState) { try AIAuth.code(fromPasted: "abc#S2", expectedState: "S1") }
    }

    @Test func pkceChallengeIsTheVerifiersSHA256() {
        let p = PKCE()
        #expect(p.verifier.count == 43 && !p.verifier.contains("="))
        #expect(p.challenge.count == 43 && p.challenge != p.verifier)
    }

    @Test func onlyRefusedGrantsExpireASignIn() {
        #expect(AIAuth.isExpiredRenewal(status: 400, body: ["error": "invalid_grant"]))
        #expect(AIAuth.isExpiredRenewal(status: 401, body: ["error": ["code": "refresh_token_reused"]]))
        #expect(!AIAuth.isExpiredRenewal(status: 500, body: ["error": "invalid_grant"]))
        #expect(!AIAuth.isExpiredRenewal(status: 400, body: ["error": "invalid_scope"]))
    }

    @Test func renewalStartsFiveMinutesBeforeExpiry() {
        let now = Date()
        #expect(AITokens(access: "a", refresh: "r", expiresAt: now.addingTimeInterval(299)).needsRenewal(now: now))
        #expect(!AITokens(access: "a", refresh: "r", expiresAt: now.addingTimeInterval(301)).needsRenewal(now: now))
        #expect(!AITokens(access: "a", refresh: nil, expiresAt: now).needsRenewal(now: now))
    }
}

@Suite struct AIPriorityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func line(_ key: String, used: Double, resetIn: Double?, period: Double?, pinned: Bool = false, account: String = "a") -> AILimitLine {
        let a = AIAccount(id: account, provider: .claude, label: account, signIn: .oauth, pinned: pinned ? [key] : [])
        return AILimitLine(
            account: a,
            metric: AIMetric(key: key, title: key, value: .limit(used: used, limit: 100, unit: .percent, resetsAt: resetIn.map { now.addingTimeInterval($0) }, period: period)))
    }

    @Test func paceComparesUseWithTheShareOfTheWindowGone() throws {
        // Half the week gone, 30% used: ahead; 49% at 51% gone: on track; 80% at half: behind.
        let ahead = try #require(AIPace.evaluate(used: 30, limit: 100, resetsAt: now.addingTimeInterval(AIPeriod.week / 2), period: AIPeriod.week, now: now))
        #expect(ahead.status == .ahead && abs(ahead.share - 0.5) < 1e-9)
        #expect(AIPace.evaluate(used: 49, limit: 100, resetsAt: now.addingTimeInterval(AIPeriod.week * 0.49), period: AIPeriod.week, now: now)?.status == .onTrack)
        let behind = try #require(AIPace.evaluate(used: 80, limit: 100, resetsAt: now.addingTimeInterval(AIPeriod.week / 2), period: AIPeriod.week, now: now))
        #expect(behind.status == .behind && AIPace.tooltip(behind) == "~60% over limit at reset")
        // Too early in the window, or no window: no pace.
        #expect(AIPace.evaluate(used: 5, limit: 100, resetsAt: now.addingTimeInterval(AIPeriod.week - 30), period: AIPeriod.week, now: now) == nil)
        #expect(AIPace.evaluate(used: 5, limit: 100, resetsAt: nil, period: AIPeriod.week, now: now) == nil)
    }

    @Test func thresholdsStayInRangeAndCriticalUnderWarning() {
        #expect(AIThresholds(warning: 90, critical: 1) == AIThresholds(warning: 70, critical: 5))
        #expect(AIThresholds(warning: 20, critical: 25) == AIThresholds(warning: 20, critical: 15))
    }

    @Test func theBoardSortsEachLimitIntoItsSection() {
        let lines = [
            line("weekly", used: 51, resetIn: AIPeriod.week * 0.68, period: AIPeriod.week, pinned: true),  // pinned
            line("session", used: 92, resetIn: 3600, period: AIPeriod.session, account: "b"),  // critical, burning
            line("monthly", used: 75, resetIn: 20 * 86400, period: AIPeriod.month, account: "c"),  // warning (25% left)
            line("spark", used: 100, resetIn: 7200, period: AIPeriod.session, account: "d"),  // used up
            line("opus", used: 20, resetIn: 9 * 3600, period: AIPeriod.week, account: "e"),  // use it or lose it
            line("calm", used: 10, resetIn: AIPeriod.week / 2, period: AIPeriod.week, account: "f"),  // nothing
        ]
        let b = AIPriorityBoard(lines: lines, now: now)
        #expect(b.pinned.map(\.line.metric.key) == ["weekly"])
        #expect(b.runningOut.map(\.line.metric.key) == ["session", "monthly"])
        #expect(b.usedUp.map(\.line.metric.key) == ["spark"])
        #expect(b.useItOrLoseIt.map(\.line.metric.key) == ["opus"])
        #expect(b.useItOrLoseIt[0].note(now: now) == "Resets in 9h")
        #expect(b.menuBar(alwaysShow: false).map(\.line.metric.key) == ["session", "monthly"])
        #expect(b.menuBar(alwaysShow: true).map(\.line.metric.key) == ["weekly", "session", "monthly", "opus", "spark"])
        // Use it or lose it off: the opus line drops out.
        #expect(AIPriorityBoard(lines: lines, options: .init(useItOrLoseIt: false), now: now).useItOrLoseIt.isEmpty)
    }

    @Test func aPinnedLimitUsedUpMovesToUsedUp() {
        let b = AIPriorityBoard(lines: [line("weekly", used: 100, resetIn: 3600, period: AIPeriod.week, pinned: true)], now: now)
        #expect(b.pinned.isEmpty && b.usedUp.count == 1)
    }

    @Test func aFiveHourWindowIsNeverUseItOrLoseIt() {
        #expect(!line("session", used: 5, resetIn: 3600, period: AIPeriod.session).isUseItOrLoseIt(now: now))
    }

    @Test func countdownShowsTheTwoLargestUnitsRoundedUpToTheMinute() {
        let cal = Calendar(identifier: .gregorian)
        func d(_ s: Double) -> String? { AIDuration.text(from: now, to: now.addingTimeInterval(s), calendar: cal) }
        #expect(d(45 * 60) == "45m")
        #expect(d(4 * 3600 + 11 * 60 + 10) == "4h 12m")
        #expect(d(2 * 86400 + 5 * 3600) == "2d 5h")
        #expect(d(17 * 86400) == "17d")
        #expect(d(0) == nil)
        #expect(AIDuration.reset(now.addingTimeInterval(120), absolute: false, now: now) == "soon")
    }
}

@Suite struct AILoopbackServerTests {
    func hit(_ server: AILoopbackServer, _ query: String) async throws -> (Int, String) {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)\(server.path)?\(query)")!)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test func theRedirectsCodeArrivesWhenHeronIsAlreadyWaiting() async throws {
        let server = try AILoopbackServer(state: "S1")
        try await server.start()
        async let code = server.code()
        try await Task.sleep(nanoseconds: 100_000_000)
        let (status, page) = try await hit(server, "code=abc&state=S1")
        #expect(status == 200 && page.contains("Sign-in complete"))
        #expect(try await code == "abc")
        server.stop()
    }

    // The browser can come back before Heron starts waiting: the code must not be lost.
    @Test func aRedirectBeforeHeronWaitsIsKept() async throws {
        let server = try AILoopbackServer(state: "S1")
        try await server.start()
        _ = try await hit(server, "code=early&state=S1")
        #expect(try await server.code() == "early")
        server.stop()
    }

    @Test func aRedirectForAnotherSignInIsRefused() async throws {
        let server = try AILoopbackServer(state: "S1")
        try await server.start()
        let (status, page) = try await hit(server, "code=abc&state=OTHER")
        #expect(status == 400 && page.contains("does not match"))
        server.stop()
    }

    @Test func errorRepliesReadAsSentences() {
        #expect(AIAuth.errorMessage(["error": ["type": "rate_limit_error", "message": "Rate limited. Please try again later."]]) == "Rate limited. Please try again later.")
        #expect(AIAuth.errorMessage(["error": "invalid_grant", "error_description": "Code expired"]) == "Code expired")
        #expect(AIAuth.errorMessage(["error": ["type": "authentication_error"]]) == "authentication_error")
    }
}

@Suite struct AIPinTests {
    /// Only a limit with a bar can be pinned; a pinned count or token figure (an older setting, or
    /// any path that slips past the UI) never lands in Pinned.
    @Test func onlyLimitsArePinned() {
        let a = AIAccount(id: "a", provider: .codex, label: "a", signIn: .oauth, pinned: ["weekly", "today", "resets"])
        let lines = [
            AIMetric(key: "weekly", title: "Weekly", value: .limit(used: 10, limit: 100, unit: .percent, resetsAt: nil, period: nil)),
            AIMetric(key: "today", title: "Today", value: .tokens(5)),
            AIMetric(key: "resets", title: "Limit resets", value: .resets(count: 3, expiries: [])),
        ].map { AILimitLine(account: a, metric: $0) }
        #expect(AIPriorityBoard(lines: lines).pinned.map(\.line.metric.key) == ["weekly"])
    }
}
