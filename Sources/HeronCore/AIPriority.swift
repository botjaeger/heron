import Foundation

// Pace, severity and the urgency ranking for AI limits (OpenUsage's Pace.swift, WidgetData,
// BurningFast, PaceNotificationLogic and PriorityBoard, re-implemented).

public enum AIPace {
    public enum Status: Equatable, Sendable { case ahead, onTrack, behind }

    public struct Reading: Equatable, Sendable {
        public var status: Status
        /// Share of the window elapsed (0...1): where the pace mark sits under "used".
        public var share: Double
        /// Projected used at reset as a share of the limit (1 = exactly the limit).
        public var projectedFraction: Double
        /// Seconds until it runs out at this pace.
        public var runway: Double
    }

    /// Pace for a bounded limit with a window, or nil (no window, too early, fresh session).
    public static func evaluate(used: Double, limit: Double, resetsAt: Date?, period: Double?, now: Date = Date()) -> Reading? {
        guard limit > 0, let resetsAt, let period, period > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard elapsed >= max(60, period * 0.01), now < resetsAt else { return nil }
        let share = elapsed / period
        let projected = used / share
        let status: Status
        if used >= limit { status = .behind } else if projected <= 0.9 * limit { status = .ahead } else if projected <= limit { status = .onTrack } else { status = .behind }
        guard status == .ahead || used / limit >= 0.05 else { return nil }
        let fraction = projected / limit
        let runway = fraction > 0 ? max(0, 1 - used / limit) * period / fraction : .infinity
        return Reading(status: status, share: share, projectedFraction: fraction, runway: runway)
    }

    /// The hover text: "~12% left at reset", "~96% used at reset", "~40% over limit at reset".
    public static func tooltip(_ r: Reading) -> String {
        let p = r.projectedFraction * 100
        switch r.status {
        case .ahead: return "~\(AIParse.int(100 - p) ?? 0)% left at reset"
        case .onTrack: return "~\(AIParse.int(p) ?? 0)% used at reset"
        case .behind: return "~\(AIParse.int(p - 100) ?? 0)% over limit at reset"
        }
    }
}

/// Warning and critical thresholds, in % left (OpenUsage: warning 20–70, critical 5–25, 5-point steps).
public struct AIThresholds: Codable, Equatable, Sendable {
    public var warning: Int
    public var critical: Int
    public static let standard = AIThresholds(warning: 30, critical: 10)
    public static let warningRange = 20...70, criticalRange = 5...25
    public init(warning: Int, critical: Int) {
        let w = min(max(warning, 20), 70), c = min(max(critical, 5), 25)
        self.warning = w; self.critical = min(c, w - 5)
    }
}

public enum AISeverity: Int, Comparable, Sendable {
    case normal, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One limit of one account, ready to rank.
public struct AILimitLine: Equatable, Identifiable, Sendable {
    public var account: AIAccount
    public var metric: AIMetric
    public var id: String { "\(account.id)/\(metric.key)" }
    public init(account: AIAccount, metric: AIMetric) { self.account = account; self.metric = metric }

    public var used: Double? { if case .limit(let u, _, _, _, _) = metric.value { return u } else { return nil } }
    public var limit: Double? { if case .limit(_, let l, _, _, _) = metric.value { return l } else { return nil } }
    public var resetsAt: Date? { if case .limit(_, _, _, let r, _) = metric.value { return r } else { return nil } }
    public var period: Double? { if case .limit(_, _, _, _, let p) = metric.value { return p } else { return nil } }
    public var remainingFraction: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return max(0, 1 - used / limit)
    }
    public var percentLeft: Int? { remainingFraction.flatMap { AIParse.int($0 * 100) } }
    public func pace(now: Date = Date()) -> AIPace.Reading? {
        guard let used, let limit else { return nil }
        return AIPace.evaluate(used: used, limit: limit, resetsAt: resetsAt, period: period, now: now)
    }
    public func severity(_ t: AIThresholds) -> AISeverity {
        guard let left = percentLeft else { return .normal }
        if left <= t.critical { return .critical }
        if left <= t.warning { return .warning }
        return .normal
    }
    public var isUsedUp: Bool { (percentLeft ?? 1) <= 0 }
    /// Would run out before it resets at this pace (OpenUsage keeps it until the pace eases to ahead).
    public func isBurningFast(now: Date = Date()) -> Bool {
        guard let p = pace(now: now), let resetsAt, !isUsedUp else { return false }
        return p.status != .ahead && p.runway < resetsAt.timeIntervalSince(now)
    }
    /// Resets within 24 h with over half left; never a window of a day or less, never money.
    public func isUseItOrLoseIt(now: Date = Date()) -> Bool {
        guard let period, period > AIPeriod.day, let resetsAt, let left = percentLeft else { return false }
        if case .limit(_, _, let unit, _, _) = metric.value, unit == .usd { return false }
        let until = resetsAt.timeIntervalSince(now)
        return until > 0 && until <= AIPeriod.day && left > 50
    }
}

public struct AIPriorityBoard: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case low(AISeverity, remaining: Double, runway: Double?)
        case burningFast(runway: Double)
        case usedUp(resetsAt: Date?)
        case useItOrLoseIt(resetsAt: Date)
    }
    public struct Entry: Equatable, Identifiable, Sendable {
        public var line: AILimitLine
        public var reason: Reason?
        public var id: String { line.id }
        public init(line: AILimitLine, reason: Reason?) { self.line = line; self.reason = reason }
        /// "Out in 1h 8m" for a limit burning fast, "Resets in 18h" for use it or lose it, else nil.
        public func note(now: Date = Date()) -> String? {
            switch reason {
            case .burningFast(let r), .low(_, _, let r?):
                guard let reset = line.resetsAt, r < reset.timeIntervalSince(now) else { return nil }
                return AIDuration.text(seconds: r).map { "Out in \($0)" }
            case .useItOrLoseIt(let at): return AIDuration.text(from: now, to: at).map { "Resets in \($0)" }
            default: return nil
            }
        }
    }
    public var pinned: [Entry] = []
    public var runningOut: [Entry] = []
    public var useItOrLoseIt: [Entry] = []
    public var usedUp: [Entry] = []

    public var isEmpty: Bool { pinned.isEmpty && runningOut.isEmpty && useItOrLoseIt.isEmpty && usedUp.isEmpty }

    public struct Options: Equatable, Sendable {
        public var thresholds = AIThresholds.standard
        public var burningFast = true
        public var useItOrLoseIt = true
        public init(thresholds: AIThresholds = .standard, burningFast: Bool = true, useItOrLoseIt: Bool = true) {
            self.thresholds = thresholds; self.burningFast = burningFast; self.useItOrLoseIt = useItOrLoseIt
        }
    }

    public static func reason(_ l: AILimitLine, _ o: Options, now: Date) -> Reason? {
        guard l.limit != nil, let remaining = l.remainingFraction else { return nil }
        if l.isUsedUp { return .usedUp(resetsAt: l.resetsAt) }
        let sev = l.severity(o.thresholds)
        let pace = l.pace(now: now)
        if sev != .normal { return .low(sev, remaining: remaining, runway: (o.burningFast && l.isBurningFast(now: now)) ? pace?.runway : nil) }
        if o.burningFast, l.isBurningFast(now: now), let r = pace?.runway { return .burningFast(runway: r) }
        if o.useItOrLoseIt, l.isUseItOrLoseIt(now: now), let at = l.resetsAt { return .useItOrLoseIt(resetsAt: at) }
        return nil
    }

    /// Ranks every line (lines come in the user's account and metric order, which breaks ties).
    public init(lines: [AILimitLine], options: Options = Options(), now: Date = Date()) {
        func rank(_ r: Reason) -> (Int, Double) {
            switch r {
            case .low(_, _, let runway?): return (0, runway)
            case .burningFast(let runway): return (0, runway)
            case .low(_, let remaining, nil): return (1, remaining)
            case .usedUp(let at): return (2, at?.timeIntervalSince1970 ?? .infinity)
            case .useItOrLoseIt(let at): return (3, at.timeIntervalSince1970)
            }
        }
        var ranked: [(Int, Entry)] = []
        for (i, l) in lines.enumerated() where !l.account.hidden.contains(l.metric.key) {
            let r = Self.reason(l, options, now: now)
            let e = Entry(line: l, reason: r)
            if l.account.pinned.contains(l.metric.key), l.limit != nil, !(r.map { if case .usedUp = $0 { return true } else { return false } } ?? false) {
                pinned.append(e); continue
            }
            if r != nil { ranked.append((i, e)) }
        }
        ranked.sort { a, b in
            let ra = rank(a.1.reason!), rb = rank(b.1.reason!)
            return ra != rb ? (ra.0, ra.1) < (rb.0, rb.1) : a.0 < b.0
        }
        for (_, e) in ranked {
            switch e.reason! {
            case .low, .burningFast: runningOut.append(e)
            case .usedUp: usedUp.append(e)
            case .useItOrLoseIt: useItOrLoseIt.append(e)
            }
        }
    }

    /// What the menu bar shows in "most urgent": running out only, or (always show) every
    /// section in order: pinned, running out, use it or lose it, used up.
    public func menuBar(alwaysShow: Bool) -> [Entry] {
        alwaysShow ? pinned + runningOut + useItOrLoseIt + usedUp : runningOut
    }
}

/// OpenUsage's countdown: the two largest units, rounded up to the minute ("4h 12m", "2d 5h", "3mo 17d").
public enum AIDuration {
    public static func text(from start: Date, to end: Date, calendar: Calendar = .current) -> String? {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite, seconds > 0 else { return nil }
        let end = start.addingTimeInterval((seconds / 60).rounded(.up) * 60)
        let months = calendar.dateComponents([.year, .month], from: start, to: end)
        let monthsEnd = calendar.date(byAdding: months, to: start) ?? start
        let minutes = Int((end.timeIntervalSince(monthsEnd) / 60).rounded())
        let parts = [(months.year ?? 0, "y"), (months.month ?? 0, "mo"), (minutes / 1440, "d"), (minutes % 1440 / 60, "h"), (minutes % 60, "m")]
        guard let first = parts.firstIndex(where: { $0.0 > 0 }) else { return nil }
        return parts[first...].prefix(2).filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }
    public static func text(seconds: Double, now: Date = Date()) -> String? {
        guard seconds.isFinite else { return nil }
        return text(from: now, to: now.addingTimeInterval(seconds))
    }
    /// A row's reset text: countdown ("4d 18h"), or the clock ("16:00", "Wed 16:00", "Nov 30"); "soon" once passed.
    public static func reset(_ at: Date?, absolute: Bool, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let at else { return nil }
        if at <= now.addingTimeInterval(5 * 60) { return "soon" }
        guard absolute else { return text(from: now, to: at, calendar: calendar) }
        let f = DateFormatter()
        f.calendar = calendar
        // The calendar's own zone: a formatter keeps the system's otherwise, and the day test above
        // would then disagree with the time printed.
        f.timeZone = calendar.timeZone
        if calendar.isDate(at, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jmm")
        } else if at.timeIntervalSince(now) < 7 * 86400 {
            f.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMM d")
        }
        return f.string(from: at)
    }
}
