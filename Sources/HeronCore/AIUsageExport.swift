import Foundation

/// `Heron usage --json`: the last readings Heron saved ("aiAccounts" and "aiReadings"), as JSON.
/// Never refreshes and never reads a token, so it answers at once and offline.
public enum AIUsageExport {
    public static let schema = "heron.usage.v1"
    /// Exit status when no account has a reading yet.
    public static let nothingFetched: Int32 = 4

    /// The JSON text and the exit status (0, or `nothingFetched`).
    public static func run(defaults: UserDefaults, now: Date = Date()) -> (json: String, status: Int32) {
        let accounts = (defaults.data(forKey: "aiAccounts")).flatMap { try? JSONDecoder().decode([AIAccount].self, from: $0) } ?? []
        let readings = (defaults.data(forKey: "aiReadings")).flatMap { try? JSONDecoder().decode([String: AIReading].self, from: $0) } ?? [:]
        let iso = ISO8601DateFormatter()
        func date(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }
        var fetched = false
        let list: [[String: Any]] = accounts.compactMap { a in
            guard let r = readings[a.id] else { return nil }
            fetched = true
            var entry: [String: Any] = [
                "id": a.id, "provider": a.provider.rawValue, "label": a.label, "plan": r.plan ?? NSNull(),
                "fetchedAt": date(r.fetchedAt), "stale": r.isStale(now: now), "metrics": r.metrics.map { metric($0, grants: r.grants, date: date) },
            ]
            if let p = r.problem { entry["problem"] = p.message }
            return entry
        }
        let root: [String: Any] = ["schema": schema, "generatedAt": iso.string(from: now), "accounts": list]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return (String(decoding: data, as: UTF8.self), fetched ? 0 : nothingFetched)
    }

    static func metric(_ m: AIMetric, grants: [AIResetGrant] = [], date: (Date?) -> Any) -> [String: Any] {
        var out: [String: Any] = ["key": m.key, "title": m.title]
        switch m.value {
        case .limit(let used, let limit, let unit, let resetsAt, let period):
            out["kind"] = "limit"; out["used"] = used; out["limit"] = limit; out["unit"] = unit.rawValue
            out["percentLeft"] = (limit > 0 ? AIParse.int(max(0, 1 - used / limit) * 100) : nil).map { $0 as Any } ?? NSNull()
            out["resetsAt"] = date(resetsAt); out["periodSeconds"] = period ?? NSNull()
        case .amount(let value, let unit, let label):
            out["kind"] = "amount"; out["value"] = value; out["unit"] = unit.rawValue; out["label"] = label
        case .resets(let count, let expiries):
            out["kind"] = "resets"; out["count"] = count; out["expiries"] = expiries.map { date($0) }
            // Each reset as the panel lists it: what it refills ("fable", "five_hour"…) and its expiry.
            out["resets"] = AIResetGrant.list(grants).map { ["kind": $0.kind.rawValue, "title": $0.kind.title, "expiresAt": date($0.expiresAt)] as [String: Any] }
        case .tokens(let n):
            out["kind"] = "tokens"; out["tokens"] = n
        }
        return out
    }
}
