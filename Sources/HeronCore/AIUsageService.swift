import Foundation
import Observation

/// Owns the AI accounts: refreshes them every 5 minutes (hourly for plan, grants and token
/// history), renews Heron's own sign-ins, backs off on failures, signs new accounts in, and
/// spends limit resets. Views read `accounts` and `readings`.
@MainActor @Observable
public final class AIUsageService {
    public private(set) var accounts: [AIAccount] = []
    public private(set) var readings: [String: AIReading] = [:]
    public private(set) var refreshing: Set<String> = []
    public private(set) var nextRefresh: Date?
    /// Called after every refresh pass (alerts and the menu bar hook in here).
    @ObservationIgnored public var onUpdate: (() -> Void)?

    public static let interval: TimeInterval = 5 * 60
    static let hourly: TimeInterval = 3600

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: AITokenStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private(set) var waitUntil: [String: Date] = [:]
    @ObservationIgnored private(set) var lastHourly: [String: Date] = [:]
    @ObservationIgnored private var hourlyCache: [String: (plan: String?, extras: [AIMetric], grants: [AIResetGrant])] = [:]
    /// One refresh per account at a time: a second caller waits for the one in flight.
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    /// One renewal per account at a time: two renewals of one refresh token would have the
    /// provider refuse the second as reused, and that refusal signed the account out.
    @ObservationIgnored private var renewing: [String: Task<AITokens?, Never>] = [:]
    /// Tokens the Keychain refused to store: kept for this session so the next renewal sends the
    /// refresh token the provider issued last, not the stale stored one.
    @ObservationIgnored private var unsaved: [String: AITokens] = [:]
    /// Borrowed sign-ins and the Codex session log (tests replace these; the app reads the CLIs').
    @ObservationIgnored var borrowedTokens: (AIProvider) -> AITokens? = { provider in
        switch provider {
        case .claude: return BorrowedSignIn.claude()
        case .codex: return BorrowedSignIn.codex().map(\.0)
        case .opencode: return nil
        }
    }
    @ObservationIgnored var codexLog: () async -> AIReading? = { await BorrowedSignIn.codexFromLog() }
    /// Today and Yesterday in local days from the Codex session logs (tests replace this).
    @ObservationIgnored var codexDays: (AIAccount) async -> [AIMetric] = { await BorrowedSignIn.codexDayRows(for: $0) }

    public init(defaults: UserDefaults = .standard, tokens: AITokenStore = KeychainTokenStore(), session: URLSession = .shared) {
        self.defaults = defaults; self.tokens = tokens; self.session = session
        if let d = defaults.data(forKey: "aiAccounts"), let a = try? JSONDecoder().decode([AIAccount].self, from: d) { accounts = a }
        if let d = defaults.data(forKey: "aiReadings"), let r = try? JSONDecoder().decode([String: AIReading].self, from: d) { readings = r }
    }

    // MARK: Accounts

    public func add(_ account: AIAccount, tokens t: AITokens?) {
        if let identity = account.extras["identity"], let i = accounts.firstIndex(where: { $0.extras["identity"] == identity }) {
            let id = accounts[i].id
            if let t { store(t, for: id) }
            // The id, not the index: the list can change before the task runs.
            Task { if let a = accounts.first(where: { $0.id == id }) { await refresh(a, force: true) } }
            return
        }
        if let t { store(t, for: account.id) }
        accounts.append(account); saveAccounts()
        Task { await refresh(account, force: true) }
    }

    public func remove(_ id: String) {
        tokens.delete(id); unsaved[id] = nil
        accounts.removeAll { $0.id == id }; readings[id] = nil
        failures[id] = nil; waitUntil[id] = nil; lastHourly[id] = nil; hourlyCache[id] = nil
        claimIDs = claimIDs.filter { !$0.key.hasPrefix(id + "/") }
        saveAccounts(); saveReadings()
    }

    /// Whether the account is still there (a refresh or renewal checks after every wait).
    private func exists(_ id: String) -> Bool { accounts.contains { $0.id == id } }

    /// The account's current tokens: this session's unsaved ones first, else the stored ones.
    private func loadTokens(_ id: String) -> AITokens? { unsaved[id] ?? tokens.load(id) }

    private func store(_ t: AITokens, for id: String) {
        if tokens.save(t, for: id) { unsaved[id] = nil } else { unsaved[id] = t }
    }

    private func deleteTokens(_ id: String) { tokens.delete(id); unsaved[id] = nil }

    public func update(_ account: AIAccount) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account; saveAccounts()
        if var r = readings[account.id], account.ordered(r.metrics) != r.metrics { r.metrics = account.ordered(r.metrics); readings[account.id] = r }
    }

    /// Moves one of an account's limits (the account sheet's drag); every surface follows the new order.
    public func moveMetric(_ accountID: String, _ key: String, before target: String?) {
        guard var a = accounts.first(where: { $0.id == accountID }) else { return }
        var keys = (readings[accountID]?.metrics ?? []).map(\.key)
        for k in a.order where !keys.contains(k) { keys.append(k) }
        keys = a.ordered(keys.map { AIMetric(key: $0, title: $0, value: .tokens(0)) }).map(\.key)
        keys.removeAll { $0 == key }
        keys.insert(key, at: target.flatMap { keys.firstIndex(of: $0) } ?? keys.count)
        a.order = keys
        update(a)
    }

    /// Moves accounts the way a SwiftUI list reports a drag (indices before the move, destination in the old list).
    public func move(from: IndexSet, to: Int) {
        let moving = from.map { accounts[$0] }
        let before = from.filter { $0 < to }.count
        accounts = accounts.enumerated().filter { !from.contains($0.offset) }.map(\.element)
        accounts.insert(contentsOf: moving, at: to - before)
        saveAccounts()
    }

    public func togglePin(_ accountID: String, _ key: String) {
        guard var a = accounts.first(where: { $0.id == accountID }) else { return }
        if a.pinned.contains(key) { a.pinned.remove(key) } else { a.pinned.insert(key); a.hidden.remove(key) }
        update(a)
    }

    public func toggleHidden(_ accountID: String, _ key: String) {
        guard var a = accounts.first(where: { $0.id == accountID }) else { return }
        if a.hidden.contains(key) { a.hidden.remove(key) } else { a.hidden.insert(key); a.pinned.remove(key) }
        update(a)
    }

    /// Every limit of every account, in account order, for the urgency ranking (the overview card and the menu bar).
    public var lines: [AILimitLine] {
        accounts.flatMap { a in (readings[a.id]?.metrics ?? []).map { AILimitLine(account: a, metric: $0) } }
    }

    /// Initials for accounts that share a provider ("Personal" → P, "Attention Machine 1" → A1).
    public func initials(_ account: AIAccount) -> String? {
        guard accounts.filter({ $0.provider == account.provider }).count > 1 else { return nil }
        let words = account.label.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        // The first word's letter, then a trailing number when there is one ("Attention Machine 1" → A1),
        // else the second word's letter ("jane@example.com" → JE).
        let second = words.count > 1 ? (words.last?.allSatisfy(\.isNumber) == true ? words.last! : words[1]) : nil
        let letters = ([words.first] + [second]).compactMap { $0 }.compactMap { w in w.first.map { $0.isNumber ? String(w) : String($0).uppercased() } }
        return words.count > 1 ? letters.joined() : String(account.label.prefix(1)).uppercased()
    }

    // MARK: Refresh

    public func start() {
        guard timer == nil else { return }
        refreshAll(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll(force: false) }
        }
        timer?.tolerance = Self.interval * 0.1  // like the sampler's: lets macOS batch wake-ups
    }

    public func stop() { timer?.invalidate(); timer = nil }

    /// ⌘R: skips the failure wait (a provider's own Retry-After still holds).
    public func refreshAll(force: Bool) {
        nextRefresh = Date().addingTimeInterval(Self.interval)
        Task {
            await withTaskGroup(of: Void.self) { g in
                for a in accounts { g.addTask { await self.refresh(a, force: force) } }
            }
            onUpdate?()
        }
    }

    public func refresh(_ account: AIAccount, force: Bool) async {
        // Removed before it began (a claim's refresh, a Refresh button on a closing sheet): read nothing.
        guard exists(account.id) else { return }
        let now = Date()
        if let until = waitUntil[account.id], until > now {
            // ⌘R skips Heron's own backoff, never a provider's Retry-After.
            var rateLimited = false
            if case .rateLimited? = readings[account.id]?.problem { rateLimited = true }
            if !force || rateLimited { return }
        }
        // Single flight: the timer, the Refresh buttons, add() and claim() can all ask at once.
        if let running = inFlight[account.id] { await running.value; return }
        let task = Task { await self.performRefresh(account, force: force, now: now) }
        inFlight[account.id] = task
        refreshing.insert(account.id)
        await task.value
        if inFlight[account.id] == task { inFlight[account.id] = nil }
        refreshing.remove(account.id)
    }

    private func performRefresh(_ account: AIAccount, force: Bool, now: Date) async {
        let result = await read(account, forceHourly: force)
        // Removed while it was being read: write nothing back for it.
        guard exists(account.id) else { return }
        var reading = result
        if let problem = result.problem {
            if let old = readings[account.id] {
                // Keep the last good values; show the problem beside them.
                reading = AIReading(plan: old.plan, metrics: old.metrics, grants: old.grants, fetchedAt: old.fetchedAt, problem: problem)
            }
            // The backoff follows the problem, first failure included (a first-ever 429 keeps its Retry-After).
            let n = (failures[account.id] ?? 0) + 1
            failures[account.id] = n
            if case .rateLimited(let until) = problem {
                waitUntil[account.id] = until
            }
            // Heron's own sign-in refused even after a renewal: an hour (it needs signing in again).
            // A borrowed sign-in is renewed by its CLI, not by Heron: it retries on the normal backoff.
            else if problem == .signInExpired && account.signIn == .oauth {
                waitUntil[account.id] = now.addingTimeInterval(Self.hourly)
            } else {
                waitUntil[account.id] = now.addingTimeInterval(min(Self.hourly, Self.interval * pow(2, Double(n - 1))))
            }
        } else {
            failures[account.id] = nil; waitUntil[account.id] = nil
        }
        reading.metrics = (accounts.first { $0.id == account.id } ?? account).ordered(reading.metrics)
        readings[account.id] = reading
        // Saved with every refresh, not only the timer's: `heron usage --json` reads what is saved,
        // and a reset spent here (its refresh) must not still show as on hand there.
        saveReadings()
    }

    /// Whether a limit refilled before its window ended: its use fell by 5 points or more while the
    /// last reading's reset time is still ahead. Only a spent limit reset does that.
    static func refilledEarly(old: [AIMetric], new: [AIMetric], now: Date) -> Bool {
        new.contains { m in
            guard case .limit(let used, _, .percent, _, _) = m.value,
                let before = old.first(where: { $0.key == m.key }), case .limit(let was, _, .percent, let resetsAt?, _) = before.value
            else { return false }
            return resetsAt > now.addingTimeInterval(60) && was - used >= 5
        }
    }

    /// One account's read, with renewal and the hourly secondary reads.
    public func read(_ a: AIAccount, forceHourly: Bool) async -> AIReading {
        guard var t = await usableTokens(a) else {
            if a.provider == .codex, a.signIn == .borrowed, let log = await codexLog() { return log }
            return AIReading(problem: .signInExpired)
        }
        let now = Date()
        let hourlyDue =
            forceHourly ? (lastHourly[a.id].map { now.timeIntervalSince($0) > 15 * 60 } ?? true) : (lastHourly[a.id].map { now.timeIntervalSince($0) > Self.hourly } ?? true)
        do {
            var (status, body, http) = try await get(usageRequest(a, t))
            if status == 401, a.signIn == .oauth, let renewed = await renew(a, t, force: true) {
                t = renewed; (status, body, http) = try await get(usageRequest(a, t))
            }
            if status == 401 || status == 403 && a.provider != .opencode {
                if a.provider == .codex, a.signIn == .borrowed, let log = await codexLog() { return log }
                return AIReading(problem: .signInExpired)
            }
            if status == 429 {
                let wait = AIParse.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"), now: now) ?? Self.interval
                return AIReading(problem: .rateLimited(until: now.addingTimeInterval(min(wait, Self.hourly))))
            }
            if a.provider == .opencode, OpenCodeAPI.isNoSubscription(status: status, body: body) {
                return AIReading(problem: .noSubscription("No OpenCode Go subscription on this account."))
            }
            guard status == 200 else { return AIReading(problem: .http(status)) }
            // A reset spent outside Heron (Claude Code, the website) refills a limit before its
            // window ends: read the resets again now, not up to an hour later.
            let fresh = a.provider == .claude ? ClaudeAPI.map(usage: body, plan: nil) : a.provider == .codex ? CodexAPI.map(usage: body, now: now) : []
            let spent = Self.refilledEarly(old: readings[a.id]?.metrics ?? [], new: fresh, now: now)
            if hourlyDue || spent {
                await readHourly(a, t, usage: body)
                // Removed during the hourly read: leave nothing behind for it.
                if exists(a.id) { lastHourly[a.id] = now }
            }
            let cache = hourlyCache[a.id]
            var metrics: [AIMetric]
            var grants = cache?.grants ?? []
            switch a.provider {
            case .claude: metrics = ClaudeAPI.map(usage: body, plan: cache?.plan)
            case .codex:
                metrics = CodexAPI.map(usage: body, now: now)
                let (resets, g) = CodexAPI.resets(usage: body, list: nil)
                if let resets, !(cache?.extras.contains { $0.key == "resets" } ?? false) { metrics.append(resets); if grants.isEmpty { grants = g } }
                metrics += await codexDays(a)
            case .opencode:
                let captured = http?.value(forHTTPHeaderField: "Date").flatMap { DateFormatter.http.date(from: $0) } ?? now
                guard let m = OpenCodeAPI.map(usage: body, capturedAt: captured) else { return AIReading(problem: .unreadable) }
                metrics = m
            }
            metrics += cache?.extras.filter { e in !metrics.contains { $0.key == e.key } } ?? []
            return AIReading(plan: cache?.plan, metrics: metrics, grants: grants, fetchedAt: now)
        } catch {
            if a.provider == .codex, a.signIn == .borrowed, let log = await codexLog() { return log }
            return AIReading(problem: .offline)
        }
    }

    private func readHourly(_ a: AIAccount, _ t: AITokens, usage: [String: Any]) async {
        // A secondary read that fails keeps what the last one gave (offline for a moment, a 5xx):
        // it never empties the resets or token rows until the next hourly read.
        let old = hourlyCache[a.id]
        var plan = old?.plan, extras: [AIMetric] = [], grants: [AIResetGrant] = []
        func keep(_ key: String) { extras += old?.extras.filter { $0.key == key } ?? [] }
        switch a.provider {
        case .claude:
            if let (s, p, _) = try? await get(ClaudeAPI.request(ClaudeAPI.profileURL, token: t.access, claudeCode: false)), s == 200 {
                plan = ClaudeAPI.plan(profile: p)
                // The account as it is now: `a` was captured before the wait and may be renamed or reordered since.
                if let org = ClaudeAPI.orgUUID((p["organization"] as? [String: Any])?["uuid"]), var b = accounts.first(where: { $0.id == a.id }), b.extras["org_uuid"] != org {
                    b.extras["org_uuid"] = org; update(b)
                }
            }
            if let (s, g, _) = try? await get(ClaudeAPI.request(ClaudeAPI.grantsURL, token: t.access)), s == 200 {
                let (m, list) = ClaudeAPI.grants(g); if let m { extras.append(m) }; grants = list
            } else {
                keep("resets"); grants = old?.grants ?? []
            }
        case .codex:
            plan = CodexAPI.plan(usage["plan_type"] as? String)
            if let (s, list, _) = try? await get(CodexAPI.request(CodexAPI.creditsURL, token: t.access, account: a.extras["chatgpt_account_id"], resets: true)), s == 200 {
                let (m, g) = CodexAPI.resets(usage: usage, list: list); if let m { extras.append(m) }; grants = g
            } else {
                keep("resets"); grants = old?.grants ?? []
            }
            if let (s, body, _) = try? await get(CodexAPI.request(CodexAPI.analyticsURL(), token: t.access, account: a.extras["chatgpt_account_id"])), s == 200,
                let days = CodexAPI.dailyTokens(body)
            {
                extras += CodexAPI.tokenRows(days)
            } else {
                keep("last30")
            }
        case .opencode:
            if a.signIn == .oauth, let (s, b, _) = try? await get(OpenCodeAPI.request(OpenCodeAPI.statusURL, token: t.access, org: a.extras["org_id"], orgHeader: "x-org-id")),
                s == 200
            {
                plan = OpenCodeAPI.plan(status: b)
            }
        }
        guard exists(a.id) else { return }
        hourlyCache[a.id] = (plan, extras, grants)
    }

    private func usageRequest(_ a: AIAccount, _ t: AITokens) -> URLRequest {
        switch a.provider {
        case .claude: return ClaudeAPI.request(ClaudeAPI.usageURL, token: t.access)
        case .codex: return CodexAPI.request(CodexAPI.usageURL, token: t.access, account: a.extras["chatgpt_account_id"])
        case .opencode: return OpenCodeAPI.request(OpenCodeAPI.usageURL, token: t.access, org: a.extras["org_id"])
        }
    }

    /// Status, JSON body and the response (headers are read through `value(forHTTPHeaderField:)`,
    /// which ignores case: a server may send "retry-after").
    private func get(_ r: URLRequest) async throws -> (Int, [String: Any], HTTPURLResponse?) {
        let (data, response) = try await session.data(for: r)
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, AIParse.json(data) ?? [:], http)
    }

    /// The tokens to read with: borrowed ones fresh from the CLI; Heron's own, renewed when near expiry.
    private func usableTokens(_ a: AIAccount) async -> AITokens? {
        switch a.signIn {
        case .borrowed:
            return borrowedTokens(a.provider)
        case .oauth:
            guard let t = loadTokens(a.id) else { return nil }
            if t.needsRenewal(), let r = await renew(a, t, force: false) { return r }
            return t
        }
    }

    /// Renews a Heron sign-in. Keeps the current token if an early renewal fails while it is still valid.
    /// One renewal per account runs at a time; a caller that comes while one is in flight gets its result.
    func renew(_ a: AIAccount, _ t: AITokens, force: Bool) async -> AITokens? {
        if let running = renewing[a.id] {
            let renewed = await running.value
            return renewed ?? (force ? nil : t)
        }
        let task = Task { await self.performRenew(a, t) }
        renewing[a.id] = task
        let renewed = await task.value
        if renewing[a.id] == task { renewing[a.id] = nil }
        return renewed ?? (force ? nil : t)
    }

    /// One renewal: the new tokens, or nil when it failed.
    private func performRenew(_ a: AIAccount, _ t: AITokens) async -> AITokens? {
        guard let refresh = t.refresh else { return nil }
        do {
            var status: Int, body: [String: Any]
            switch a.provider {
            case .claude:
                (status, body) = try await AIAuth.postJSON(
                    ClaudeAPI.tokenURL, ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": ClaudeAPI.clientID, "scope": ClaudeAPI.scopes], session: session)
                if status == 400, AIAuth.errorCode(body) == "invalid_scope" {
                    (status, body) = try await AIAuth.postJSON(
                        ClaudeAPI.tokenURL, ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": ClaudeAPI.clientID, "scope": ClaudeAPI.profileOnlyScopes],
                        session: session)
                }
            case .codex:
                (status, body) = try await AIAuth.postForm(
                    CodexAPI.tokenURL, [("grant_type", "refresh_token"), ("client_id", CodexAPI.clientID), ("refresh_token", refresh)], session: session)
            case .opencode:
                (status, body) = try await AIAuth.postForm(
                    OpenCodeAPI.tokenURL, [("client_id", OpenCodeAPI.clientID), ("grant_type", "refresh_token"), ("refresh_token", refresh)], session: session)
            }
            guard (200..<300).contains(status), var new = AIAuth.tokens(from: body, jwtExpiry: a.provider == .codex) else {
                // Sign out only when the refused refresh token is still the one stored: a stale
                // caller's refusal must not wipe tokens another renewal just saved.
                if AIAuth.isExpiredRenewal(status: status, body: body), exists(a.id), loadTokens(a.id)?.refresh == refresh { deleteTokens(a.id) }
                return nil
            }
            if new.refresh == nil { new.refresh = refresh }
            // Removed while renewing: never save tokens back for it.
            guard exists(a.id) else { return nil }
            store(new, for: a.id)
            return new
        } catch { return nil }
    }

    // MARK: Limit resets

    public enum ClaimOutcome: Equatable, Sendable { case done, nothingToReset, noCredit, unavailable(String), notPermitted, failed(String) }

    /// "accountID/grantID" → the request id a retry reuses until the claim settles.
    @ObservationIgnored private(set) var claimIDs: [String: String] = [:]

    /// Spends one reset (asks first in the UI). Retries reuse the same request id until it settles.
    public func claim(_ account: AIAccount, _ grant: AIResetGrant) async -> ClaimOutcome {
        guard let t = await usableTokens(account) else { return .failed("Sign-in expired") }
        // Removed during the renewal: spend nothing, remember no request id.
        guard exists(account.id) else { return .failed("Account removed") }
        let key = "\(account.id)/\(grant.id)"
        let requestID = claimIDs[key] ?? UUID().uuidString
        claimIDs[key] = requestID
        let outcome: ClaimOutcome
        do {
            switch account.provider {
            case .claude:
                // Only a UUID goes into the URL path (a sign-in saved before the check may hold anything).
                guard let org = ClaudeAPI.orgUUID(account.extras["org_uuid"]) else { return .failed("Organization unknown yet; try after the next refresh") }
                let (s, b, _) = try await get(ClaudeAPI.claimRequest(orgUUID: org, grantID: grant.id, requestID: requestID, token: t.access))
                if s == 401 || s == 403 { outcome = .notPermitted; break }
                let result = (b["result"] as? String) == "unavailable" ? b["reason"] as? String : b["result"] as? String
                switch result {
                case "reset", "already_used": outcome = .done
                case "not_limited": outcome = .nothingToReset
                case "ineligible", "no_grant", "unknown_grant": outcome = .noCredit
                case "not_next_grant": outcome = .unavailable("Use the reset that expires first")
                case "cooldown", "paused", "low_priority_active": outcome = .unavailable("Not available right now")
                default: outcome = .failed("Not confirmed; try again")
                }
            case .codex:
                let body: [String: Any] = ["credit_id": grant.id, "redeem_request_id": requestID]
                let (s, b, _) = try await get(
                    CodexAPI.request(CodexAPI.creditsURL + "/consume", token: t.access, account: account.extras["chatgpt_account_id"], method: "POST", body: body, resets: true))
                if s == 401 || s == 403 { outcome = .notPermitted; break }
                switch b["code"] as? String {
                case "reset", "already_redeemed": outcome = .done
                case "nothing_to_reset": outcome = .nothingToReset
                case "no_credit": outcome = .noCredit
                default: outcome = .failed("Refused")
                }
            case .opencode: outcome = .noCredit
            }
        } catch { return .failed("Not reachable") }
        // Removed while the claim was out: `remove` already forgot its request ids; keep nothing.
        guard exists(account.id) else { return outcome }
        if case .failed = outcome {} else { claimIDs[key] = nil }
        if outcome == .done || outcome == .nothingToReset { lastHourly[account.id] = nil; await refresh(account, force: true) }
        return outcome
    }

    // MARK: Persistence

    private func saveAccounts() { if let d = try? JSONEncoder().encode(accounts) { defaults.set(d, forKey: "aiAccounts") } }
    private func saveReadings() { if let d = try? JSONEncoder().encode(readings) { defaults.set(d, forKey: "aiReadings") } }

    /// For heron-snap and tests: show these accounts and readings without any network.
    public func setPreview(accounts a: [AIAccount], readings r: [String: AIReading]) { accounts = a; readings = r }
}

extension DateFormatter {
    static let http: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return f
    }()
}
