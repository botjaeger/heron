import Foundation

/// An account's limit resets laid out for the resets panel: when each one runs out over the next
/// 30 days, when each limit a reset can refill refills itself and when it is out, what each kind
/// of reset would give back now, and one sentence on what matters most.
public struct AIResetPlan: Equatable, Sendable {
    /// The strip's length: the next 30 days.
    public static let span: Double = 30 * 86400

    public var now: Date
    /// One per reset that runs out within the span, soonest first.
    public var expiries: [Date]
    /// Resets that run out after the span, soonest first ("› 2 in Mar").
    public var later: [Date]

    /// A limit some reset refills, drawn as its own line under the resets.
    public struct Lane: Equatable, Sendable {
        public var key: String
        public var title: String
        /// Share left now (0...1).
        public var left: Double
        /// When it refills itself within the span, soonest first.
        public var refills: [Date]
        /// The window's length ("5 hours" refills too often to draw one by one).
        public var period: Double?
        /// While it is out within the span: from now (used up) or from when this pace runs it out,
        /// until it refills.
        public var out: ClosedRange<Date>?
    }
    public var lanes: [Lane]

    /// One kind of reset ("Weekly reset × 2").
    public struct Kind: Equatable, Sendable {
        public var kind: AIResetKind
        public var count: Int
        /// One per reset of this kind, soonest first (nil: no expiry given).
        public var expiries: [Date?]
        /// The reset "Use…" spends: one the provider says can be used now, the first to expire.
        public var usable: AIResetGrant?
        /// The limits it refills that this account shows, with what is left of each now.
        public var gains: [Lane]
        public var first: Date? { expiries.compactMap { $0 }.first }
    }
    public var kinds: [Kind]

    /// The sentence under the strip; `urgent` when waiting loses a reset.
    public struct Advice: Equatable, Sendable {
        public var text: String
        public var urgent: Bool
    }
    public var advice: Advice?

    public var count: Int { kinds.reduce(0) { $0 + $1.count } }
    public var usableNow: Int { kinds.filter { $0.usable != nil }.reduce(0) { $0 + $1.count } }
    /// The reset that runs out first.
    public var firstExpiry: Date? { kinds.compactMap(\.first).min() }

    /// One local day of the strip, for the readout under the pointer: how many days away it is and
    /// what happens on it.
    public struct Day: Equatable, Sendable {
        /// Local midnight that starts it, and the next one.
        public var start: Date
        public var end: Date
        /// Calendar days from today (0 today, 1 tomorrow).
        public var daysAway: Int
        public enum Item: Equatable, Sendable {
            /// A reset of this kind runs out at this time.
            case expires(AIResetKind, Date)
            /// The limit refills itself at this time.
            case refills(String, Date)
            /// The limit refills itself every `period` seconds (5 hours: several times a day).
            case refillsEvery(String, Double)
            /// The limit is out: from a time this day (nil: since before it), until a time this
            /// day (nil: past its end), back at `back`.
            case out(String, from: Date?, until: Date?, back: Date)
        }
        public var items: [Item]
    }

    /// The local day holding `date`: resets running out on it, then each line's refills and
    /// time out, in the strip's order.
    public func day(at date: Date, calendar: Calendar = .current) -> Day {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let away = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: start).day ?? 0
        func within(_ d: Date) -> Bool { d >= start && d < end }
        var items: [Day.Item] = []
        for kind in kinds {
            for d in kind.expiries.compactMap({ $0 }) where within(d) && !items.contains(.expires(kind.kind, d)) {
                items.append(.expires(kind.kind, d))
            }
        }
        items.sort {
            if case .expires(_, let a) = $0, case .expires(_, let b) = $1 { return a < b }
            return false
        }
        for lane in lanes {
            if let out = lane.out, out.lowerBound < end, out.upperBound > start {
                items.append(
                    .out(lane.title, from: out.lowerBound > start ? out.lowerBound : nil, until: out.upperBound < end ? out.upperBound : nil, back: out.upperBound))
            }
            if let period = lane.period, period < AIPeriod.day {
                if lane.refills.contains(where: within) { items.append(.refillsEvery(lane.title, period)) }
            } else {
                for d in lane.refills where within(d) { items.append(.refills(lane.title, d)) }
            }
        }
        return Day(start: start, end: end, daysAway: away, items: items)
    }

    /// `soon`: how far ahead a reset counts as running out soon (`Warnings.resetSoon`).
    public static func make(account: AIAccount, reading: AIReading?, soon: TimeInterval, now: Date = Date()) -> AIResetPlan {
        let grants = reading?.grants ?? []
        let end = now.addingTimeInterval(span)
        let all = AIResetGrant.list(grants)
        let dated = all.compactMap(\.expiresAt)
        let metrics = account.ordered(reading?.metrics ?? [])
        let wanted = Set(grants.flatMap(\.refills))
        let lanes = metrics.filter { wanted.contains($0.key) }.compactMap { lane(AILimitLine(account: account, metric: $0), until: end, now: now) }

        var kinds: [Kind] = []
        for kind in AIResetKind.allCases {
            // swiftlint:disable:next empty_count - `count` is a grant's reset count, an Int
            let of = grants.filter { $0.kind == kind && $0.count > 0 }
            guard !of.isEmpty else { continue }
            let expiries = AIResetGrant.list(of).map(\.expiresAt)
            let usable = of.filter(\.usableNow).min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            var keys: [String] = []
            for k in of.flatMap(\.refills) where !keys.contains(k) { keys.append(k) }
            kinds.append(Kind(kind: kind, count: expiries.count, expiries: expiries, usable: usable, gains: keys.compactMap { k in lanes.first { $0.key == k } }))
        }
        kinds.sort { ($0.first ?? .distantFuture, $0.kind.title) < ($1.first ?? .distantFuture, $1.kind.title) }

        var plan = AIResetPlan(
            now: now, expiries: dated.filter { $0 <= end }, later: dated.filter { $0 > end }, lanes: lanes, kinds: kinds, advice: nil)
        plan.advice = advice(plan, soon: soon)
        return plan
    }

    static func lane(_ line: AILimitLine, until end: Date, now: Date) -> Lane? {
        guard case .limit(_, _, .percent, _, _) = line.metric.value, let left = line.remainingFraction else { return nil }
        // A window under a minute is not a real one: a server's 1e-10 s never moved `t` on and hung the
        // main thread. A reset time long past is moved on in one step, not window by window.
        let period = line.period.flatMap { $0 >= 60 ? $0 : nil }
        var refills: [Date] = []
        if var t = line.resetsAt {
            if let p = period, t <= now { t = t.addingTimeInterval(((now.timeIntervalSince(t) / p).rounded(.down) + 1) * p) }
            while t <= end {
                if t > now { refills.append(t) }
                guard let p = period else { break }
                t = t.addingTimeInterval(p)
            }
        }
        var out: ClosedRange<Date>?
        if let back = refills.first {
            if line.isUsedUp {
                out = now...back
            } else if line.isBurningFast(now: now), let runway = line.pace(now: now)?.runway {
                out = now.addingTimeInterval(runway)...back
            }
        }
        return Lane(key: line.metric.key, title: line.metric.title, left: left, refills: refills, period: period, out: out)
    }

    // MARK: Advice

    static func advice(_ plan: AIResetPlan, soon: TimeInterval) -> Advice? {
        let now = plan.now
        let usable = plan.kinds.filter { $0.usable != nil }
        let soonCount = plan.kinds.flatMap(\.expiries).compactMap { $0 }.filter { $0.timeIntervalSince(now) <= soon }.count
        let days = Int((soon / 86400).rounded())
        let outNow = usable.flatMap(\.gains).filter { $0.left <= 0 }
        let outNames = names(unique(outNow).map(\.title))

        // Waiting loses a reset.
        if soonCount > 0, plan.kinds.contains(where: { k in k.usable != nil && (k.first.map { $0.timeIntervalSince(now) <= soon } ?? false) }) {
            let lead = soonCount == 1 ? "A reset runs out" : "\(number(soonCount).capitalized) resets run out"
            if !outNow.isEmpty {
                let them = unique(outNow).count == 1 ? "it" : "them"
                return Advice(
                    text: "\(lead) within \(days) days, and \(outNames) \(unique(outNow).count == 1 ? "is" : "are") out now. Using one refills \(them) at once.", urgent: true)
            }
            return Advice(
                text: "\(lead) within \(days) days. Use \(soonCount == 1 ? "it" : "them") when a limit runs low, or \(soonCount == 1 ? "it is" : "they are") lost.", urgent: true)
        }
        // A limit a usable reset refills is out now.
        if let lane = outNow.first, let kind = usable.first(where: { $0.gains.contains(lane) }) {
            let back = lane.refills.first.flatMap { AIDuration.reset($0, absolute: true, now: now) }
            return Advice(text: "\(lane.title) is out\(back.map { " until \($0)" } ?? ""). A \(kind.kind.title) refills it now.", urgent: false)
        }
        // A limit a usable reset refills runs out at this pace before it refills.
        for kind in usable {
            for lane in kind.gains {
                guard let out = lane.out, let back = lane.refills.first,
                    let runs = AIDuration.text(from: now, to: out.lowerBound), let wait = AIDuration.text(from: out.lowerBound, to: back),
                    let at = AIDuration.reset(back, absolute: true, now: now)
                else { continue }
                return Advice(
                    text: "At this pace \(lane.title) runs out in \(runs) and stays out \(wait), until \(at). Use the \(kind.kind.title) then to skip the wait.",
                    urgent: false)
            }
        }
        // Nothing to refill.
        let gains = unique(plan.kinds.flatMap(\.gains))
        if !gains.isEmpty, gains.allSatisfy({ $0.left >= 0.995 }) {
            return Advice(text: "Every limit a reset refills is full: nothing to refill now.", urgent: false)
        }
        // How often it refills itself before the first reset runs out.
        if let kind = plan.kinds.first, let first = kind.first, let lane = kind.gains.first {
            let n = lane.refills.filter { $0 < first }.count
            guard n > 0 else { return nil }
            return Advice(
                text: "\(lane.title) refills itself \(n == 1 ? "once" : "\(number(n)) times") before your first \(kind.kind.title) runs out. Keep it for a week you run dry early.",
                urgent: false)
        }
        return nil
    }

    private static func unique(_ lanes: [Lane]) -> [Lane] {
        var seen: Set<String> = []
        return lanes.filter { seen.insert($0.key).inserted }
    }

    /// "Weekly", "5 hours and Weekly", "5 hours, Weekly and Fable".
    static func names(_ titles: [String]) -> String {
        guard let last = titles.last else { return "" }
        return titles.count == 1 ? last : titles.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "Two", "three"… up to ten, then digits.
    static func number(_ n: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n < words.count ? words[n] : String(n)
    }
}
