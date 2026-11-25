import HeronCore
import SwiftUI

/// An AI account's limit resets, beside the AI panel like a history (opened from its "Limit
/// resets" row): the next 30 days as a strip — when each reset runs out, when each limit it can
/// refill refills itself and when it is out — one sentence on what matters most, each kind of
/// reset with what it would give back now and "Use…" with its confirmation, and the totals.
public struct AIResetsPage: View {
    var accountID: String
    var hover: Date?
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @Environment(AppSettings.self) private var settings
    @Environment(\.aiHidesEmails) private var hidesEmails
    /// The kind whose confirmation is shown.
    @State private var picked: AIResetKind?
    @State private var working = false
    @State private var result: String?

    /// `confirming`, `outcome` and `hover` (a moment under the pointer): heron-snap's way into states a render cannot reach.
    public init(accountID: String, confirming: AIResetKind? = nil, outcome: String? = nil, hover: Date? = nil) {
        self.accountID = accountID
        _picked = State(initialValue: confirming)
        _result = State(initialValue: outcome)
        self.hover = hover
    }

    public var body: some View {
        if let ai, let account = ai.accounts.first(where: { $0.id == accountID }) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(ai, account, AIResetPlan.make(account: account, reading: ai.readings[account.id], soon: Warnings.resetSoon, now: context.date))
            }
        }
    }

    private func content(_ ai: AIUsageService, _ account: AIAccount, _ plan: AIResetPlan) -> some View {
        let soon = Warnings.isResetExpiringSoon(plan.firstExpiry, now: plan.now)
        return VStack(alignment: .leading, spacing: 10) {
            header(account)
            // swiftlint:disable:next empty_count - `count` is the reset count, an Int
            if plan.count > 0 {
                Card(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Next 30 days").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ai)
                        Spacer(minLength: 8)
                        BigNumber(
                            number: "\(plan.count)", unit: "available", size: 24, unitSize: 13,
                            color: soon ? Theme.caution : .primary, unitColor: soon ? Theme.caution : .primary)
                    }
                    // Above its siblings: the hover readout may hang over the key and the advice.
                    AIResetStrip(plan: plan, hover: hover).zIndex(1)
                    legend(plan)
                    if let advice = plan.advice {
                        Text(advice.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(advice.urgent ? Theme.Tint.caution.fill : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Card(spacing: 0) {
                    ForEach(Array(plan.kinds.enumerated()), id: \.element.kind) { i, kind in
                        self.kind(kind, plan: plan, ai: ai, account: account)
                            .overlay(alignment: .top) {
                                if i > 0 { Rectangle().fill(Theme.track).frame(height: 1) }
                            }
                    }
                }
                stats(plan, soon: soon)
            } else {
                Card {
                    Text("No limit resets left.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            if let result {
                Text(result).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Limit resets")
    }

    private func header(_ account: AIAccount) -> some View {
        HStack(spacing: 10) {
            IconTile(part: .ai, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Limit resets").font(.system(size: 15, weight: .bold))
                Text(([account.provider.name] + [AIText.label(account.label, hidesEmails: hidesEmails)].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 2)
    }

    private func legend(_ plan: AIResetPlan) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Diamond().fill(Theme.ai).frame(width: 9, height: 9)
                Text("expires")
            }
            HStack(spacing: 4) {
                Capsule().fill(Color.primary).frame(width: 2, height: 9)
                Text("refills itself")
            }
            if plan.lanes.contains(where: { $0.out != nil }) {
                HStack(spacing: 4) {
                    Capsule().fill(Theme.warning).frame(width: 12, height: 6)
                    Text("out")
                }
            }
            if let first = plan.later.first {
                Text("› \(plan.later.count) in \(Self.month.string(from: first))")
            }
        }
        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()

    private func kind(_ k: AIResetPlan.Kind, plan: AIResetPlan, ai: AIUsageService, account: AIAccount) -> some View {
        let soon = Warnings.isResetExpiringSoon(k.first, now: plan.now)
        var seen: Set<Date> = []
        let rest = k.expiries.dropFirst().compactMap { $0 }.filter { $0 != k.first && seen.insert($0).inserted }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    (Text(k.kind.title).fontWeight(.semibold) + Text(" × \(k.count)").foregroundStyle(Theme.muted)).font(.system(size: 12.5))
                    if let first = k.first {
                        Text(Self.runsOut(first, now: plan.now)).font(.system(size: 11)).foregroundStyle(soon ? Theme.caution : Theme.muted).monospacedDigit()
                    }
                    if !rest.isEmpty {
                        Text("then " + rest.prefix(2).map { AIText.resetDate($0) }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                if k.usable != nil, picked == nil {
                    Button("Use…") {
                        result = nil; picked = k.kind
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Use a \(k.kind.title)…")
                }
            }
            ForEach(k.gains, id: \.key) { gain(lane: $0) }
            if picked == k.kind, let grant = k.usable {
                VStack(alignment: .leading, spacing: 8) {
                    Text(grant.detail).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Spacer()
                        Button("Cancel") { picked = nil }.controlSize(.small)
                        Button("Use now") {
                            working = true
                            Task {
                                result = AIText.outcome(await ai.claim(account, grant))
                                working = false; picked = nil
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(working)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 8)
        .opacity(picked != nil && picked != k.kind ? 0.4 : 1)
    }

    /// "runs out Fri 11 Dec, 06:00 · 15d 10h".
    static func runsOut(_ date: Date, now: Date) -> String {
        "runs out \(AIText.resetDate(date))" + (AIDuration.text(from: now, to: date).map { " · \($0)" } ?? "")
    }

    /// "Weekly ▬▬▬━━━━━ 14% → 100%": what is left now, and the full bar a reset gives back.
    private func gain(lane: AIResetPlan.Lane) -> some View {
        let full = lane.left >= 0.995
        let line = AILimitLine(
            account: AIAccount(id: "", provider: .claude, label: "", signIn: .oauth),
            metric: AIMetric(key: lane.key, title: lane.title, value: .limit(used: (1 - lane.left) * 100, limit: 100, unit: .percent, resetsAt: nil, period: nil)))
        let tone: Color
        switch line.severity(settings.aiUsage.thresholds) {
        case .critical: tone = Theme.warning
        case .warning: tone = Theme.caution
        case .normal: tone = Theme.ai
        }
        return HStack(spacing: 8) {
            Text(lane.title).foregroundStyle(Theme.muted).lineLimit(1).frame(width: AIResetStrip.label, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.ai.opacity(full ? 1 : 0.28))
                    if !full { Capsule().fill(tone).frame(width: geo.size.width * lane.left) }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(full ? "full already" : "\(Int((lane.left * 100).rounded()))% → 100%")
                .font(Theme.number(11.5, weight: full ? .regular : .semibold))
                .foregroundStyle(full ? Theme.muted : .primary).fixedSize()
        }
        .font(.system(size: 11.5))
        .accessibilityElement(children: .combine)
    }

    private func stats(_ plan: AIResetPlan, soon: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            stat("Available", "\(plan.count)", soon ? Theme.caution : .primary)
            stat("Usable now", "\(plan.usableNow)", .primary)
            if let first = plan.firstExpiry, let left = AIDuration.text(from: plan.now, to: first) {
                stat("First to expire", left, soon ? Theme.caution : .primary)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
        .padding(.horizontal, 2)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
            BigNumber(number: value, size: 15, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The 30-day strip: a line of reset expiries (diamonds, amber when soon), then one line per limit
/// a reset refills (its own refills as ticks, red while it is out), week guides and their labels.
struct AIResetStrip: View {
    var plan: AIResetPlan
    static let label: CGFloat = 52
    static let lane: CGFloat = 24
    /// How close to a diamond (in points) the pointer snaps to its day.
    static let snap: CGFloat = 6
    /// The room above the lines inside the card: its title row and spacing.
    static let roomAbove: CGFloat = 44
    /// Where the pointer is across the lines (0 now, 1 thirty days on); nil when it is off them.
    @State private var pointer: Double?

    /// `hover`: heron-snap's way to draw the readout for a moment.
    init(plan: AIResetPlan, hover: Date? = nil) {
        self.plan = plan
        _pointer = State(initialValue: hover.map { $0.timeIntervalSince(plan.now) / AIResetPlan.span })
    }

    /// The moment under the pointer: a diamond's own time when the pointer is within `snap` of it.
    static func moment(_ plan: AIResetPlan, pointer: Double, width: CGFloat) -> (date: Date, expiry: Date?) {
        let f = min(max(pointer, 0), 1)
        let near = plan.expiries.min { abs($0.timeIntervalSince(plan.now) / AIResetPlan.span - f) < abs($1.timeIntervalSince(plan.now) / AIResetPlan.span - f) }
        if let near, width > 0, abs(CGFloat(near.timeIntervalSince(plan.now) / AIResetPlan.span - f)) * width <= snap { return (near, near) }
        return (plan.now.addingTimeInterval(f * AIResetPlan.span), nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                row("Resets") { ctx, size, hover in resets(ctx, size, ring: hover?.expiry) }
                ForEach(plan.lanes, id: \.key) { lane in
                    row(lane.title) { ctx, size, _ in limit(lane, ctx, size) }
                }
            }
            // One hover area over every line (beside their titles), so moving between lines never
            // clears the readout.
            .overlay {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let p):
                                let width = geo.size.width - Self.label
                                pointer = p.x < Self.label || width <= 0 ? nil : Double((p.x - Self.label) / width)
                            case .ended: pointer = nil
                            }
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if let pointer {
                    GeometryReader { geo in
                        let total = geo.size.width, width = total - Self.label, lines = geo.size.height, room = Self.roomAbove
                        let moment = Self.moment(plan, pointer: pointer, width: width)
                        let x = Self.label + width * CGFloat(moment.date.timeIntervalSince(plan.now) / AIResetPlan.span)
                        // An overlay keeps the lines' frame, so the readout can sit above them.
                        Color.clear.overlay(alignment: .topLeading) {
                            AIResetDayReadout(day: plan.day(at: moment.date))
                                .fixedSize()
                                // Above the lines when it fits beside the card's title row, else
                                // under them (over the axis and key), never over the panel's header.
                                .alignmentGuide(.top) { d in d.height <= room ? d[.bottom] + 4 : -(lines + 18) }
                                .alignmentGuide(.leading) { d in -min(max(x - d.width / 2, 0), max(0, total - d.width)) }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.label, height: 1)
                GeometryReader { geo in axis(geo.size.width) }.frame(height: 14)
            }
            .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
            .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(plan))
    }

    /// "now", "1 wk" … "4 wk"; while hovering, the day's number at the pointer in place of the
    /// labels it would cover.
    @ViewBuilder private func axis(_ width: CGFloat) -> some View {
        let hovered: (x: CGFloat, day: Int)? = pointer.map { p in
            let date = Self.moment(plan, pointer: p, width: width).date
            return (width * CGFloat(date.timeIntervalSince(plan.now) / AIResetPlan.span), Calendar.current.component(.day, from: date))
        }
        let labels: [(String, CGFloat)] = [("now", 11)] + (1..<5).map { ("\($0) wk", min(width * CGFloat($0 * 7) / 30, width - 14)) }
        ForEach(labels, id: \.0) { text, x in
            if hovered.map({ abs($0.x - x) > 22 }) ?? true { Text(text).fixedSize().position(x: x, y: 7) }
        }
        if let hovered {
            Text("\(hovered.day)").fontWeight(.semibold).foregroundStyle(Color.primary).fixedSize()
                .position(x: min(max(hovered.x, 8), width - 8), y: 7)
        }
    }

    /// What the strip shows, for VoiceOver.
    static func summary(_ plan: AIResetPlan) -> String {
        var parts = ["\(plan.expiries.count) of \(plan.count) resets run out in the next 30 days"]
        for lane in plan.lanes {
            if let out = lane.out { parts.append("\(lane.title) is out from \(AIText.resetDate(out.lowerBound)) to \(AIText.resetDate(out.upperBound))") }
        }
        return parts.joined(separator: "; ")
    }

    /// One line: its title, then its drawing over the week guides; while hovering, the day under the
    /// pointer lit as a column and a thin line at the pointer, as on a history chart.
    private func row(_ title: String, _ draw: @escaping (GraphicsContext, CGSize, (date: Date, expiry: Date?)?) -> Void) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: Self.label, alignment: .leading)
            Canvas { [plan, pointer] ctx, size in
                let hover = pointer.map { Self.moment(plan, pointer: $0, width: size.width) }
                if let hover {
                    let day = plan.day(at: hover.date)
                    let a = max(0, x(day.start, size.width)), b = min(size.width, x(day.end, size.width))
                    if b > a { ctx.fill(Path(CGRect(x: a, y: 0, width: b - a, height: size.height)), with: .color(Color.primary.opacity(0.07))) }
                }
                guides(ctx, size)
                draw(ctx, size, hover)
                if let hover {
                    let px = x(hover.date, size.width).rounded() + 0.5
                    ctx.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: size.height))
                        }, with: .color(Color.primary.opacity(0.45)), lineWidth: 1)
                }
            }
            .frame(height: Self.lane)
        }
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        width * CGFloat(date.timeIntervalSince(plan.now) / AIResetPlan.span)
    }

    private func guides(_ ctx: GraphicsContext, _ size: CGSize) {
        for week in 1...4 {
            let x = (size.width * CGFloat(week * 7) / 30).rounded() + 0.5
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(Theme.track), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    /// `ring`: the reset the pointer snapped to, drawn larger with a ring in the text colour.
    private func resets(_ ctx: GraphicsContext, _ size: CGSize, ring: Date?) {
        let w = size.width, mid = size.height / 2
        if plan.expiries.contains(where: { Warnings.isResetExpiringSoon($0, now: plan.now) }) {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w * CGFloat(Warnings.resetSoon / AIResetPlan.span), height: size.height)), with: .color(Theme.caution.opacity(0.10)))
        }
        ctx.stroke(
            Path { p in
                p.move(to: CGPoint(x: 0, y: mid)); p.addLine(to: CGPoint(x: w, y: mid))
            }, with: .color(Theme.track), lineWidth: 1)
        for date in plan.expiries {
            let cx = min(max(x(date, w), 6), w - 6)
            let r: CGFloat = date == ring ? 7 : 6
            let shape = Diamond().path(in: CGRect(x: cx - r, y: mid - r, width: r * 2, height: r * 2))
            ctx.fill(shape, with: .color(Warnings.isResetExpiringSoon(date, now: plan.now) ? Theme.caution : Theme.ai))
            ctx.stroke(shape, with: .color(date == ring ? Color.primary : Theme.card), lineWidth: 1.5)
        }
        if !plan.later.isEmpty {
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: w - 7, y: mid - 4)); p.addLine(to: CGPoint(x: w - 2, y: mid)); p.addLine(to: CGPoint(x: w - 7, y: mid + 4))
                }, with: .color(Theme.muted), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }

    private func limit(_ lane: AIResetPlan.Lane, _ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, mid = size.height / 2
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: mid - 3, width: w, height: 6), cornerRadius: 3), with: .color(Theme.track))
        if let out = lane.out {
            let a = min(max(x(out.lowerBound, w), 0), w), b = min(max(x(out.upperBound, w), 0), w)
            if b > a { ctx.fill(Path(CGRect(x: a, y: mid - 3, width: max(2, b - a), height: 6)), with: .color(Theme.warning)) }
        }
        func tick(_ x: CGFloat, _ half: CGFloat) {
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: x, y: mid - half)); p.addLine(to: CGPoint(x: x, y: mid + half))
                }, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        if let period = lane.period, period < AIPeriod.day, let first = lane.refills.first {
            // Refills every few hours: too close to draw one by one, so a dotted line after the first.
            tick(min(max(x(first, w), 1), w - 1), 4)
            let start = x(first, w) + 4
            if start < w {
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: start, y: mid)); p.addLine(to: CGPoint(x: w, y: mid))
                    }, with: .color(Color.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 3.4]))
            }
        } else {
            for date in lane.refills { tick(min(max(x(date, w), 1), w - 1), 7) }
        }
    }
}

/// The readout over the strip while hovering: the day ("Fri 27 Nov · in 2 days") and what happens
/// on it, in the history chart's readout box.
struct AIResetDayReadout: View {
    var day: AIResetPlan.Day

    /// One line of the readout: a label column (a line's title, or a diamond for a reset) and what happens.
    struct Line: Equatable {
        enum Mark: Equatable { case text(String), diamond, none }
        var mark: Mark
        var text: String
        var out = false
        var muted = false
    }

    /// "Fri 27 Nov · in 2 days", "today", "tomorrow".
    static func title(_ day: AIResetPlan.Day, calendar: Calendar = .current) -> String {
        let away: String
        switch day.daysAway {
        case 0: away = "today"
        case 1: away = "tomorrow"
        default: away = "in \(day.daysAway) days"
        }
        return "\(AIText.dayTitle(day.start, calendar: calendar)) · \(away)"
    }

    static func lines(_ day: AIResetPlan.Day, now: Date = Date(), calendar: Calendar = .current) -> [Line] {
        func clock(_ d: Date) -> String { AIText.clock(d, calendar: calendar) }
        var lines: [Line] = []
        for item in day.items {
            switch item {
            case .expires(let kind, let at):
                lines.append(Line(mark: .diamond, text: "\(kind.title) runs out \(clock(at))"))
            case .refills(let title, let at):
                // "out until 03:58" already says when it is back.
                if day.items.contains(where: { if case .out(title, _, at?, _) = $0 { return true } else { return false } }) { continue }
                lines.append(Line(mark: .text(title), text: "refills \(clock(at))"))
            case .refillsEvery(let title, let period):
                lines.append(Line(mark: .text(title), text: "refills every \(AIDuration.text(seconds: period) ?? "")"))
            case .out(let title, let from, let until, let back):
                switch (from, until) {
                case (nil, nil):
                    lines.append(Line(mark: .text(title), text: "out all day", out: true))
                    if let at = AIDuration.reset(back, absolute: true, now: now, calendar: calendar) {
                        lines.append(Line(mark: .none, text: "back \(at)", muted: true))
                    }
                case (let from?, nil): lines.append(Line(mark: .text(title), text: "out from \(clock(from))", out: true))
                case (nil, let until?): lines.append(Line(mark: .text(title), text: "out until \(clock(until))", out: true))
                case (let from?, let until?): lines.append(Line(mark: .text(title), text: "out \(clock(from))–\(clock(until))", out: true))
                }
            }
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.title(day)).font(.system(size: 11)).foregroundStyle(Theme.muted)
            ForEach(Array(Self.lines(day).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Group {
                        switch line.mark {
                        case .text(let t): Text(t).foregroundStyle(Theme.muted)
                        case .diamond: Diamond().fill(Theme.muted).frame(width: 8, height: 8)
                        case .none: Color.clear.frame(width: 1, height: 1)
                        }
                    }
                    .frame(minWidth: 44, alignment: .leading)
                    Text(line.text)
                        .font(line.muted ? .system(size: 12) : Theme.number(12, weight: .semibold))
                        .foregroundStyle(line.out ? Theme.warning : line.muted ? Theme.muted : Color.primary)
                }
                .font(.system(size: 12))
                .lineLimit(1)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.settingsSelection, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.settingsLine, lineWidth: 1))
    }
}

/// A diamond (a square on its corner): one reset on the strip.
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
        }
    }
}
