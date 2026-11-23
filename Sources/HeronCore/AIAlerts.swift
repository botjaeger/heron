import Foundation

// AI usage notifications: each limit notifies once on the way INTO a state (OpenUsage's
// PaceNotificationLogic), never while it stays there. Pure, so the tests drive it with dates.

/// The four AI usage notifications (the same names as `AIUsageSettings.Alert`).
public enum AIAlertKind: String, Codable, CaseIterable, Sendable {
    case warning, critical, burningFast, useItOrLoseIt
}

public struct AIFiredAlert: Equatable, Sendable {
    public var kind: AIAlertKind
    /// `AILimitLine.id`: "accountID/metricKey".
    public var lineID: String
    public var title: String
    public var body: String
}

public struct AIAlertEngine: Sendable {
    /// What one limit was at its last reading.
    struct Memory: Equatable, Sendable {
        var resetsAt: Date?
        var severity: AISeverity
        /// Burning fast notifies again only once the pace has eased back to ahead.
        var burningArmed: Bool
        var useItSent: Bool
    }
    private var memory: [String: Memory] = [:]

    /// A reset date this much later than the last one is a new window, not drift between reads.
    static let windowStep: TimeInterval = 15 * 60

    public init() {}

    /// Feeds one refresh's limits; returns the notifications to send now. A limit seen for the
    /// first time only primes (no burst at launch or when an account is added). Every state is
    /// tracked whether or not its notification is on, so turning one on never fires at once.
    public mutating func evaluate(
        _ lines: [AILimitLine], thresholds: AIThresholds, enabled: Set<AIAlertKind>,
        hideLabels: Bool = false, now: Date = Date()
    ) -> [AIFiredAlert] {
        var fired: [AIFiredAlert] = []
        var providerCounts: [AIProvider: Set<String>] = [:]
        for l in lines { providerCounts[l.account.provider, default: []].insert(l.account.id) }
        for line in lines where line.percentLeft != nil {
            let severity = line.severity(thresholds)
            let burning = line.isBurningFast(now: now)
            let ahead = line.pace(now: now)?.status == .ahead
            let useIt = line.isUseItOrLoseIt(now: now)
            guard var m = memory[line.id] else {
                memory[line.id] = Memory(resetsAt: line.resetsAt, severity: severity, burningArmed: !burning, useItSent: useIt)
                continue
            }
            if let new = line.resetsAt, let old = m.resetsAt, new > old.addingTimeInterval(Self.windowStep) {
                // A new window: everything re-arms.
                m = Memory(resetsAt: new, severity: .normal, burningArmed: true, useItSent: false)
            } else if m.resetsAt == nil {
                m.resetsAt = line.resetsAt
            }
            var kinds: [AIAlertKind] = []
            if severity == .critical, m.severity != .critical { kinds.append(.critical) } else if severity == .warning, m.severity == .normal { kinds.append(.warning) }
            m.severity = severity
            if burning, m.burningArmed { kinds.append(.burningFast); m.burningArmed = false } else if ahead { m.burningArmed = true }
            if useIt, !m.useItSent { kinds.append(.useItOrLoseIt); m.useItSent = true }
            memory[line.id] = m
            let several = (providerCounts[line.account.provider]?.count ?? 0) > 1
            for kind in kinds where enabled.contains(kind) {
                let (title, body) = Self.text(kind, line, thresholds: thresholds, named: several && !hideLabels, now: now)
                fired.append(AIFiredAlert(kind: kind, lineID: line.id, title: title, body: body))
            }
        }
        // Forget limits that are gone (removed account, metric no longer reported).
        let live = Set(lines.map(\.id))
        memory = memory.filter { live.contains($0.key) }
        return fired
    }

    /// "ChatGPT 5 hours", or "Claude Personal Weekly" when that provider has several accounts.
    public static func name(_ line: AILimitLine, named: Bool) -> String {
        let who = named ? "\(line.account.provider.name) \(line.account.label)" : line.account.provider.name
        return "\(who) \(line.metric.title)"
    }

    /// Title and text: "ChatGPT 5 hours: 8% left, out in 1h 8m" over "Below your critical level (10% left). Resets in 3h 25m."
    public static func text(_ kind: AIAlertKind, _ line: AILimitLine, thresholds: AIThresholds, named: Bool, now: Date) -> (String, String) {
        let name = name(line, named: named)
        let left = "\(line.percentLeft ?? 0)% left"
        let resets = line.resetsAt.flatMap { AIDuration.text(from: now, to: $0) }.map { "Resets in \($0)." } ?? ""
        // "out in …" only when it runs out before the reset at this pace.
        let runway = line.pace(now: now).flatMap { p -> String? in
            guard p.status != .ahead, let at = line.resetsAt, p.runway < at.timeIntervalSince(now) else { return nil }
            return AIDuration.text(seconds: p.runway, now: now)
        }
        let out = runway.map { ", out in \($0)" } ?? ""
        switch kind {
        case .critical:
            return ("\(name): \(left)\(out)", join("Below your critical level (\(thresholds.critical)% left).", resets))
        case .warning:
            return ("\(name): \(left)\(out)", join("Below your warning level (\(thresholds.warning)% left).", resets))
        case .burningFast:
            return ("\(name): burning fast\(out)", join("\(left); at this pace it runs out before it resets.", resets))
        case .useItOrLoseIt:
            let soon = line.resetsAt.flatMap { AIDuration.text(from: now, to: $0) }.map { ", resets in \($0)" } ?? ""
            return ("\(name): \(left)\(soon)", "Use it or lose it: what is left is gone at the reset.")
        }
    }

    private static func join(_ a: String, _ b: String) -> String { b.isEmpty ? a : "\(a) \(b)" }
}
