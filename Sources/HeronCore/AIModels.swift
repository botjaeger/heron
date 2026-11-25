import Foundation

// AI plan usage: the accounts Heron reads (Claude, ChatGPT/Codex, OpenCode), the limits each one
// reports, and the problems a read can hit. The behaviour follows OpenUsage
// (github.com/robinebers/openusage, MIT): same endpoints, same rows, same priority rules.

public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex, opencode
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .opencode: return "OpenCode"
        }
    }
    /// How a new account signs in.
    public var signInKind: String { self == .opencode ? "Device code" : "Browser" }
    /// The provider's status page (checked 2026-11-22: status.anthropic.com moved to status.claude.com).
    public var statusURL: URL {
        switch self {
        case .claude: return URL(string: "https://status.claude.com")!
        case .codex: return URL(string: "https://status.openai.com")!
        case .opencode: return URL(string: "https://status.opencode.ai")!
        }
    }
    /// Where the provider shows the same usage on its own site (opens signed in, in the browser).
    public var dashboardURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .opencode: return URL(string: "https://opencode.ai/console")!
        }
    }
}

/// How Heron holds an account's sign-in.
public enum AISignIn: String, Codable, Sendable {
    /// Heron's own OAuth sign-in; tokens in Heron's Keychain item, renewed by Heron.
    case oauth
    /// Borrowed from Claude Code or the Codex CLI: read each time, never renewed or written back.
    case borrowed
}

public struct AIAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: AIProvider
    public var label: String
    public var signIn: AISignIn
    /// Provider ids the reads need: Claude `org_uuid`, ChatGPT `chatgpt_account_id`, OpenCode `org_id`.
    public var extras: [String: String]
    public var hidden: Set<String>
    public var pinned: Set<String>
    /// Metric keys in the order the user dragged them; keys not listed follow in provider order.
    public var order: [String]
    public init(
        id: String = UUID().uuidString, provider: AIProvider, label: String, signIn: AISignIn,
        extras: [String: String] = [:], hidden: Set<String> = [], pinned: Set<String> = [], order: [String] = []
    ) {
        self.id = id; self.provider = provider; self.label = label; self.signIn = signIn
        self.extras = extras; self.hidden = hidden; self.pinned = pinned; self.order = order
    }

    /// `metrics` in this account's order (the user's first, the rest as the provider sent them).
    public func ordered(_ metrics: [AIMetric]) -> [AIMetric] {
        guard !order.isEmpty else { return metrics }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return metrics.enumerated().sorted { a, b in
            (rank[a.element.key] ?? order.count + a.offset, a.offset) < (rank[b.element.key] ?? order.count + b.offset, b.offset)
        }.map(\.element)
    }

    enum CodingKeys: String, CodingKey { case id, provider, label, signIn, extras, hidden, pinned, order }
    // Accounts saved before `order` existed decode with an empty order.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); provider = try c.decode(AIProvider.self, forKey: .provider)
        label = try c.decode(String.self, forKey: .label); signIn = try c.decode(AISignIn.self, forKey: .signIn)
        extras = try c.decodeIfPresent([String: String].self, forKey: .extras) ?? [:]
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        pinned = try c.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
    }
}

public struct AITokens: Codable, Equatable, Sendable {
    public var access: String
    public var refresh: String?
    public var expiresAt: Date?
    public init(access: String, refresh: String?, expiresAt: Date?) { self.access = access; self.refresh = refresh; self.expiresAt = expiresAt }
    /// OpenUsage renews 5 minutes before expiry.
    public func needsRenewal(now: Date = Date()) -> Bool {
        guard refresh != nil, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(5 * 60)
    }
}

public enum AIUnit: String, Codable, Sendable { case percent, usd, credits }

public enum AIMetricValue: Codable, Equatable, Sendable {
    /// A bounded limit: `used` of `limit` (percent limits are used of 100), with its window.
    case limit(used: Double, limit: Double, unit: AIUnit, resetsAt: Date?, period: Double?)
    /// A value with no limit (a balance, money spent without a cap).
    case amount(Double, unit: AIUnit, label: String)
    /// Rate-limit resets on hand, one expiry per reset.
    case resets(count: Int, expiries: [Date])
    /// Tokens used in a time range.
    case tokens(Int)
}

public struct AIMetric: Codable, Equatable, Identifiable, Sendable {
    /// Stable key within a provider ("session", "weekly", "sonnet", "fable", "extraUsage", "resets", "today"…).
    public var key: String
    public var title: String
    public var value: AIMetricValue
    public var id: String { key }
    public init(key: String, title: String, value: AIMetricValue) { self.key = key; self.title = title; self.value = value }
}

public enum AIProblem: Codable, Equatable, Sendable {
    case signInExpired
    case noSubscription(String)
    case rateLimited(until: Date)
    case http(Int)
    case offline
    case unreadable
    public var message: String {
        switch self {
        case .signInExpired: return "Sign-in expired"
        case .noSubscription(let s): return s
        case .rateLimited: return "Asked to wait; trying again later"
        case .http(let code): return "The server answered \(code)"
        case .offline: return "Not reachable"
        case .unreadable: return "An answer Heron does not understand"
        }
    }
}

/// What a reset refills, as OpenUsage and Claude Code name it.
public enum AIResetKind: String, Codable, CaseIterable, Sendable {
    case weekly, fable, fiveHour = "five_hour", full
    /// "Weekly reset", "Fable reset", "5-hour reset", "Full reset".
    public var title: String {
        switch self {
        case .weekly: return "Weekly reset"
        case .fable: return "Fable reset"
        case .fiveHour: return "5-hour reset"
        case .full: return "Full reset"
        }
    }
    /// One line under the title in the resets list.
    public var summary: String {
        switch self {
        case .weekly: return "Refills your weekly limit"
        case .fable: return "Refills Fable and gives back its weekly use"
        case .fiveHour: return "Refills your 5-hour limit"
        case .full: return "Refills your 5-hour and weekly limits"
        }
    }
    /// The metric keys a reset of this kind refills, when the provider does not list them.
    public var refills: [String] {
        switch self {
        case .weekly: return ["weekly"]
        case .fable: return ["fable"]
        case .fiveHour: return ["session"]
        case .full: return ["session", "weekly"]
        }
    }
}

/// A reset grant Heron can spend (Claude cedar_ember grant or ChatGPT reset credit).
public struct AIResetGrant: Codable, Equatable, Sendable {
    public var id: String
    public var expiresAt: Date?
    public var usableNow: Bool
    /// What it refills, for the confirmation: "Refills your session limit now. This can't be undone."
    public var detail: String
    public var kind: AIResetKind
    /// Resets this grant holds (Claude's `resets_left`; one per ChatGPT credit).
    public var count: Int
    /// The metric keys it refills ("session", "weekly", "fable"); `kind`'s keys when not given.
    public var refills: [String]
    public init(id: String, expiresAt: Date?, usableNow: Bool, detail: String, kind: AIResetKind = .full, count: Int = 1, refills: [String]? = nil) {
        self.id = id; self.expiresAt = expiresAt; self.usableNow = usableNow; self.detail = detail; self.kind = kind; self.count = count
        self.refills = refills ?? kind.refills
    }
    // Readings saved before kinds existed have no `kind` / `count`: Full and one, until the next read.
    // Readings saved before `refills` existed take their kind's keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        usableNow = try c.decode(Bool.self, forKey: .usableNow)
        detail = try c.decode(String.self, forKey: .detail)
        kind = try c.decodeIfPresent(AIResetKind.self, forKey: .kind) ?? .full
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        refills = try c.decodeIfPresent([String].self, forKey: .refills) ?? kind.refills
    }

    /// One entry per reset on hand (a grant with `count` 3 is three), soonest expiry first; no expiry last.
    public static func list(_ grants: [AIResetGrant]) -> [(kind: AIResetKind, expiresAt: Date?)] {
        grants.flatMap { g in Array(repeating: (kind: g.kind, expiresAt: g.expiresAt), count: max(0, g.count)) }
            .enumerated()
            .sorted { a, b in
                let x = a.element.expiresAt ?? .distantFuture, y = b.element.expiresAt ?? .distantFuture
                return x == y ? a.offset < b.offset : x < y
            }
            .map(\.element)
    }
}

public struct AIReading: Codable, Equatable, Sendable {
    public var plan: String?
    public var metrics: [AIMetric]
    public var grants: [AIResetGrant]
    public var fetchedAt: Date
    public var problem: AIProblem?
    public init(plan: String? = nil, metrics: [AIMetric] = [], grants: [AIResetGrant] = [], fetchedAt: Date = Date(), problem: AIProblem? = nil) {
        self.plan = plan; self.metrics = metrics; self.grants = grants; self.fetchedAt = fetchedAt; self.problem = problem
    }
    /// Older than two refresh cycles (10 minutes): shown with a clock.
    public func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(fetchedAt) > 600 }
}

public enum AIPeriod {
    public static let session: Double = 5 * 3600
    public static let week: Double = 7 * 86400
    public static let month: Double = 30 * 86400
    public static let day: Double = 86400
}
