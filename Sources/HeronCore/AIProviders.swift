import Foundation

// The three providers: sign-in constants, requests and response mapping. Endpoints, headers and
// field names follow OpenUsage's Claude, Codex and OpenCode providers.

public enum AIParse {
    /// The largest magnitude a server number may have; anything bigger (or NaN, or infinite) is
    /// not a reading and is dropped, so no later `Int(...)` can trap on it.
    static let maxMagnitude = 1e15

    /// A number (not a Bool) or a numeric string; finite and within `maxMagnitude`, else nil.
    public static func number(_ v: Any?) -> Double? {
        var d: Double?
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { d = n.doubleValue } else if let s = v as? String { d = Double(s.trimmingCharacters(in: .whitespaces)) }
        guard let d, d.isFinite, abs(d) <= maxMagnitude else { return nil }
        return d
    }
    /// A whole number from a Double, rounded; nil for NaN, infinity or a value outside Int.
    public static func int(_ v: Double?, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int? {
        guard let v, v.isFinite else { return nil }
        let r = v.rounded(rule)
        guard r > -9.2e18, r < 9.2e18 else { return nil }
        return Int(exactly: r)
    }
    /// A Retry-After value: delta-seconds ("120") or an HTTP-date ("Wed, 21 Oct 2026 07:28:00 GMT").
    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let seconds = Double(v), seconds.isFinite { return max(0, seconds) }
        return DateFormatter.http.date(from: v).map { max(0, $0.timeIntervalSince(now)) }
    }
    // Shared formatters: both kinds are thread-safe for parsing and formatting, and each keeps
    // its own options (never changed after creation).
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    /// "yyyy-MM-dd" in UTC (ChatGPT's analytics days).
    static let utcDay: DateFormatter = {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    /// ISO 8601 (with or without fractions), or a number of seconds (below 1e10) or milliseconds.
    public static func date(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let d = isoFractional.date(from: s) { return d }
            if let d = iso.date(from: s) { return d }
            return Double(s).flatMap { date($0) }
        }
        guard let n = number(v) else { return nil }
        return Date(timeIntervalSince1970: abs(n) < 1e10 ? n : n / 1000)
    }
    static func clampPercent(_ v: Double) -> Double { min(100, max(0, v)) }
    static func titleCased(_ s: String, separator: Character = "_") -> String {
        s.split(separator: separator).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    static func json(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
}

// MARK: - Claude

public enum ClaudeAPI {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizeURL = "https://claude.ai/oauth/authorize"
    public static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    public static let scopes = "user:profile user:inference"
    public static let profileOnlyScopes = "user:profile"
    public static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    public static let grantsURL = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
    public static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    /// Anthropic refuses old or unknown clients for reset grants (`ineligible_reason`), so Heron
    /// identifies the way Claude Code does, as OpenUsage does.
    public static let userAgent = "claude-cli/2.1.294 (external, cli)"

    public static func request(_ url: String, token: String, method: String = "GET", body: [String: Any]? = nil, claudeCode: Bool = true) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: method == "POST" ? 25 : 10)
        r.httpMethod = method
        r.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if claudeCode {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        return r
    }

    static func window(_ v: Any?, key: String, title: String, period: Double) -> AIMetric? {
        guard let o = v as? [String: Any], let used = AIParse.number(o["utilization"]) else { return nil }
        return AIMetric(key: key, title: title, value: .limit(used: AIParse.clampPercent(used), limit: 100, unit: .percent, resetsAt: AIParse.date(o["resets_at"]), period: period))
    }

    /// Rows from /api/oauth/usage: 5 hours, Weekly, Sonnet, Fable (scoped weekly), Extra usage.
    public static func map(usage body: [String: Any], plan: String?) -> [AIMetric] {
        var m: [AIMetric] = []
        if let w = window(body["five_hour"], key: "session", title: "5 hours", period: AIPeriod.session) { m.append(w) }
        if let w = window(body["seven_day"], key: "weekly", title: "Weekly", period: AIPeriod.week) { m.append(w) }
        if let w = window(body["seven_day_sonnet"], key: "sonnet", title: "Sonnet", period: AIPeriod.week) { m.append(w) }
        if let limits = body["limits"] as? [[String: Any]] {
            for l in limits where (l["kind"] as? String) == "weekly_scoped" {
                let name = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                guard let name, let used = AIParse.number(l["percent"]) else { continue }
                let key = name.lowercased()
                guard !m.contains(where: { $0.key == key }) else { continue }
                m.append(
                    AIMetric(
                        key: key, title: name,
                        value: .limit(used: AIParse.clampPercent(used), limit: 100, unit: .percent, resetsAt: AIParse.date(l["resets_at"]), period: AIPeriod.week)))
            }
        }
        if let e = body["extra_usage"] as? [String: Any], (e["is_enabled"] as? Bool) == true {
            let minor = pow(10, AIParse.number(e["decimal_places"]) ?? 2)
            let used = (AIParse.number(e["used_credits"]) ?? 0).rounded() / minor
            let title = (plan ?? "").hasPrefix("Enterprise") ? "Spend" : "Extra usage"
            if let cap = AIParse.number(e["monthly_limit"]), cap > 0 {
                m.append(AIMetric(key: "extraUsage", title: title, value: .limit(used: used, limit: cap.rounded() / minor, unit: .usd, resetsAt: nil, period: nil)))
            } else {
                m.append(AIMetric(key: "extraUsage", title: title, value: .amount(used, unit: .usd, label: "spent")))
            }
        }
        return m
    }

    /// "Pro", "Max", "Ultra" (Max at 20x), "Pro 5x"…, from the profile's organization.
    public static func plan(profile: [String: Any]) -> String? {
        guard let org = profile["organization"] as? [String: Any], let type = org["organization_type"] as? String else { return nil }
        let tier = ((org["rate_limit_tier"] as? String) ?? "").lowercased()
        let raw = type.hasPrefix("claude_") ? String(type.dropFirst(7)) : type
        let base = AIParse.titleCased(raw)
        if base == "Ultra" || (base == "Max" && (tier.contains("ultra") || tier.contains("20x"))) { return "Ultra" }
        if base == "Max" { return base }
        guard let r = tier.range(of: #"\d+x"#, options: .regularExpression) else { return base }
        return "\(base) \(tier[r])"
    }

    /// Reset grants (cedar_ember): the count row and the grants that can be spent.
    public static func grants(_ body: [String: Any], now: Date = Date()) -> (AIMetric?, [AIResetGrant]) {
        guard let ce = body["cedar_ember"] as? [String: Any], (ce["eligible"] as? Bool) == true,
            let list = ce["grants"] as? [[String: Any]]
        else { return (nil, []) }
        var expiries: [Date] = [], grants: [AIResetGrant] = []
        for g in list {
            // A grant without an id cannot be spent; skip it, keep the others (as Codex does).
            guard let id = g["id"] as? String else { continue }
            // More than 1000 resets left is not a real count (it would fill `expiries`).
            let left = min(1000, AIParse.int(AIParse.number(g["resets_left"]), .down) ?? 0)
            let ends = AIParse.date(g["ends_at"])
            guard left >= 1, ends.map({ $0 > now }) ?? true else { continue }
            expiries += Array(repeating: ends ?? .distantFuture, count: left)
            let usable = (g["usable_now"] as? Bool) == true && (g["paused"] as? Bool) != true
            let clears = g["clears"] as? [String] ?? [], givesBack = (g["gives_back_weekly"] as? Bool) == true
            grants.append(
                AIResetGrant(
                    id: id, expiresAt: ends, usableNow: usable, detail: detail(clears: clears, givesBackWeekly: givesBack),
                    kind: kind(type: g["type"] as? String, clears: clears, givesBackWeekly: givesBack), count: left))
        }
        guard !expiries.isEmpty else { return (nil, []) }
        return (AIMetric(key: "resets", title: "Limit resets", value: .resets(count: expiries.count, expiries: expiries.sorted())), grants)
    }

    /// A grant's kind as OpenUsage (`ClaudeResetGrantStatus`) and Claude Code decide it: giving
    /// back weekly use makes it Fable; else its `type`; else what it `clears`. `label` is never read.
    public static func kind(type: String?, clears: [String], givesBackWeekly: Bool) -> AIResetKind {
        if givesBackWeekly { return .fable }
        switch type {
        case "session": return .fiveHour
        case "weekly": return .weekly
        case "full": return .full
        default: break
        }
        let session = clears.contains("five_hour"), other = clears.contains { $0 != "five_hour" }
        if session && !other { return .fiveHour }
        if other && !session { return .weekly }
        return .full
    }

    static func detail(clears: [String], givesBackWeekly: Bool) -> String {
        let names = ["five_hour": "5-hour", "seven_day": "weekly", "seven_day_overage_included": "Fable"]
        let parts = clears.compactMap { names[$0] }
        guard !parts.isEmpty, parts.count == clears.count else { return "Immediately reset your usage limits. This can't be undone." }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        var s = "Refills your \(list) limit\(parts.count == 1 ? "" : "s") now"
        if givesBackWeekly && !clears.contains("seven_day") { s += " and gives back what Fable used of your weekly limit" }
        return s + ". This can't be undone."
    }

    public static func claimRequest(orgUUID: String, grantID: String, requestID: String, token: String) -> URLRequest {
        request(
            "https://api.anthropic.com/api/organizations/\(orgUUID)/reset_rate_limits", token: token, method: "POST",
            body: ["program": "cedar_ember", "grant_id": grantID, "request_id": requestID])
    }
}

// MARK: - ChatGPT (Codex)

public enum CodexAPI {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    public static let tokenURL = "https://auth.openai.com/oauth/token"
    public static let scopes = "openid profile email offline_access"
    public static let callbackPort: UInt16 = 1455
    public static let callbackPath = "/auth/callback"
    public static let authorizeExtras = [
        URLQueryItem(name: "id_token_add_organizations", value: "true"),
        URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        URLQueryItem(name: "originator", value: "pi"),
    ]
    public static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    public static let creditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    public static let creditUSD = 0.04

    public static func request(_ url: String, token: String, account: String?, method: String = "GET", body: [String: Any]? = nil, resets: Bool = false) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: method == "POST" ? 15 : 10)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Heron", forHTTPHeaderField: "User-Agent")
        if let account, !account.isEmpty { r.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if resets {
            r.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            r.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return r
    }

    public static func accountID(accessToken: String) -> String? {
        (AIAuth.jwtClaims(accessToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }

    static func windows(_ rate: [String: Any]?, now: Date) -> [(used: Double, seconds: Double?, reset: Date?)] {
        ["primary_window", "secondary_window"].compactMap { k in
            guard let w = rate?[k] as? [String: Any], let used = AIParse.number(w["used_percent"]) else { return nil }
            let reset = AIParse.date(w["reset_at"]) ?? AIParse.number(w["reset_after_seconds"]).map { now.addingTimeInterval($0) }
            return (AIParse.clampPercent(used), AIParse.number(w["limit_window_seconds"]), reset)
        }
    }

    /// Pairs windows with the 5-hour and weekly rows by their length, in either slot.
    static func meters(_ rate: [String: Any]?, keys: (String, String), titles: (String, String), now: Date) -> [AIMetric] {
        var ws = windows(rate, now: now)
        var out: [AIMetric] = []
        for (key, title, period) in [(keys.0, titles.0, AIPeriod.session), (keys.1, titles.1, AIPeriod.week)] {
            let i = ws.firstIndex { $0.seconds == period } ?? ws.firstIndex { $0.seconds == nil || ![AIPeriod.session, AIPeriod.week].contains($0.seconds!) }
            guard let i else { continue }
            let w = ws.remove(at: i)
            out.append(AIMetric(key: key, title: title, value: .limit(used: w.used, limit: 100, unit: .percent, resetsAt: w.reset, period: w.seconds ?? period)))
        }
        return out
    }

    public static func map(usage body: [String: Any], now: Date = Date()) -> [AIMetric] {
        var m = meters(body["rate_limit"] as? [String: Any], keys: ("session", "weekly"), titles: ("5 hours", "Weekly"), now: now)
        if let extra = body["additional_rate_limits"] as? [[String: Any]],
            let spark = extra.first(where: { (($0["limit_name"] as? String) ?? ($0["metered_feature"] as? String) ?? "").lowercased().contains("spark") })
        {
            m += meters(spark["rate_limit"] as? [String: Any], keys: ("spark", "sparkWeekly"), titles: ("Spark", "Spark weekly"), now: now)
        }
        if let c = body["credits"] as? [String: Any], (c["has_credits"] as? Bool) != false, let bal = AIParse.number(c["balance"]) {
            m.append(AIMetric(key: "extraUsage", title: "Extra usage", value: .amount(bal.rounded(.down) * creditUSD, unit: .usd, label: "left")))
        }
        if let lim = (body["spend_control"] as? [String: Any])?["individual_limit"] as? [String: Any],
            let used = AIParse.number(lim["used"]), let cap = AIParse.number(lim["limit"]), cap > 0
        {
            m.append(
                AIMetric(key: "creditLimit", title: "Credit limit", value: .limit(used: used, limit: cap, unit: .credits, resetsAt: AIParse.date(lim["reset_at"]), period: nil)))
        }
        return m
    }

    /// "Plus", "Pro 200", "Business Premium"…
    public static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "self_serve_business_prolite": return "Business Premium"
        default: return AIParse.titleCased(raw)
        }
    }

    /// The reset-credit count from the usage body, with expiries from the credits list when it agrees.
    public static func resets(usage: [String: Any], list: [String: Any]?) -> (AIMetric?, [AIResetGrant]) {
        let embedded = usage["rate_limit_reset_credits"] as? [String: Any]
        let count = AIParse.int(AIParse.number(embedded?["available_count"]) ?? AIParse.number(list?["available_count"]), .towardZero) ?? 0
        guard count > 0 else { return (nil, []) }
        let source = (list.map { AIParse.int(AIParse.number($0["available_count"]), .towardZero) == count } ?? false) ? list : embedded
        let credits = ((source?["credits"] as? [[String: Any]]) ?? []).filter { ($0["status"] as? String).map { $0 == "available" } ?? true }
        let grants = credits.compactMap { c -> AIResetGrant? in
            guard let id = c["id"] as? String else { return nil }
            // A ChatGPT credit has no type: it always refills the 5-hour and weekly limits.
            return AIResetGrant(
                id: id, expiresAt: AIParse.date(c["expires_at"]), usableNow: true, detail: "Refills your 5-hour and weekly limits now. This can't be undone.", kind: .full)
        }
        let expiries = grants.compactMap(\.expiresAt).sorted()
        return (AIMetric(key: "resets", title: "Limit resets", value: .resets(count: count, expiries: expiries)), grants)
    }

    /// Daily token counts (UTC days): `[yyyy-MM-dd: tokens]`.
    public static func dailyTokens(_ body: [String: Any]) -> [String: Int]? {
        guard let data = body["data"] as? [[String: Any]] else { return nil }
        var out: [String: Int] = [:]
        for d in data {
            guard let date = (d["date"] as? String)?.prefix(10), let totals = d["totals"] as? [String: Any], AIParse.number(totals["turns"]) != nil else { return nil }
            out[String(date), default: 0] += AIParse.int(AIParse.number(totals["text_total_tokens"]), .towardZero) ?? 0
        }
        return out
    }

    public static func analyticsURL(days: Int = 30, now: Date = Date()) -> String {
        let f = AIParse.utcDay
        let start = f.string(from: now.addingTimeInterval(-Double(days - 1) * 86400)), end = f.string(from: now)
        return "https://chatgpt.com/backend-api/wham/analytics/daily-workspace-usage-counts?start_date=\(start)&end_date=\(end)&group_by=day&workspace_user=true"
    }

    /// The Last 30 days token row (missing days count as 0). The analytics reply has whole UTC days
    /// only ("date": "yyyy-MM-dd", no hours, `group_by` day/week/month only), so it cannot give a
    /// local day: Today and Yesterday come from the Codex session logs (`dayRows`). Over 30 days the
    /// UTC edges barely matter, and this one covers every device.
    public static func tokenRows(_ days: [String: Int], now: Date = Date()) -> [AIMetric] {
        let f = AIParse.utcDay
        let day = { (offset: Int) in days[f.string(from: now.addingTimeInterval(-Double(offset) * 86400))] ?? 0 }
        return [AIMetric(key: "last30", title: "Last 30 days", value: .tokens((0..<30).map(day).reduce(0, +)))]
    }

    /// Today and Yesterday in the user's own days, from per-local-day sums keyed by the day's
    /// start in `calendar` (a day with no events counts as 0).
    public static func dayRows(_ days: [Date: Int], now: Date = Date(), calendar: Calendar = .current) -> [AIMetric] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today).map { calendar.startOfDay(for: $0) } ?? today
        return [
            AIMetric(key: "today", title: "Today", value: .tokens(days[today] ?? 0)),
            AIMetric(key: "yesterday", title: "Yesterday", value: .tokens(days[yesterday] ?? 0)),
        ]
    }
}

// MARK: - OpenCode (Go)

public enum OpenCodeAPI {
    public static let clientID = "opencode-cli"
    public static let deviceCodeURL = "https://opencode.ai/console/auth/device/code"
    public static let tokenURL = "https://opencode.ai/console/auth/device/token"
    public static let usageURL = "https://opencode.ai/zen/go/v1/usage"
    public static let statusURL = "https://opencode.ai/console/api/go/status"
    public static let userURL = "https://opencode.ai/console/api/user"

    public static func request(_ url: String, token: String, org: String?, orgHeader: String = "x-opencode-org-id") -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let org, !org.isEmpty { r.setValue(org, forHTTPHeaderField: orgHeader) }
        return r
    }

    /// Session (rolling 5 h), Weekly and Monthly. A session at 0% resetting exactly 5 h from now has not started.
    public static func map(usage body: [String: Any], capturedAt: Date = Date()) -> [AIMetric]? {
        guard let u = body["usage"] as? [String: Any] else { return nil }
        var out: [AIMetric] = []
        for (k, key, title, period) in [
            ("rolling", "session", "5 hours", AIPeriod.session), ("weekly", "weekly", "Weekly", AIPeriod.week), ("monthly", "monthly", "Monthly", AIPeriod.month),
        ] {
            guard let w = u[k] as? [String: Any] else { continue }
            guard let p = AIParse.number(w["percent"]), let reset = AIParse.date(w["resetsAt"]) else { return nil }
            let used = AIParse.clampPercent(p)
            let notStarted = key == "session" && used == 0 && abs(reset.timeIntervalSince(capturedAt) - AIPeriod.session) <= 2
            out.append(AIMetric(key: key, title: title, value: .limit(used: used, limit: 100, unit: .percent, resetsAt: notStarted ? nil : reset, period: period)))
        }
        return out
    }

    public static func plan(status body: [String: Any]) -> String? {
        switch body["product"] as? String {
        case "go": return "Go"
        case "go-plus": return "Go Plus"
        case "go-teams": return "Go Teams"
        default: return nil
        }
    }

    public static func isNoSubscription(status: Int, body: [String: Any]) -> Bool {
        status == 403 && ((body["error"] as? [String: Any])?["type"] as? String) == "EntitlementError"
    }

    public static func deviceCode(_ body: [String: Any]) -> AIDeviceCode? {
        guard let device = body["device_code"] as? String, let user = body["user_code"] as? String else { return nil }
        let base = URL(string: deviceCodeURL)!
        let url = [body["verification_uri_complete"], body["verification_uri"]].compactMap { ($0 as? String).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } }
            .first { $0.scheme == "https" }
        guard let url else { return nil }
        return AIDeviceCode(
            userCode: user, verificationURL: url, deviceCode: device, interval: AIParse.number(body["interval"]) ?? 5, expiresIn: AIParse.number(body["expires_in"]) ?? 900)
    }
}
