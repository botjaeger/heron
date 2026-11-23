import AppKit
import HeronCore
import SwiftUI

// The AI usage panel beside the overview: one card per account with every limit it reports. The
// rules are pure (`AIText`, `AIRowModel`, `AIAccountGroup`) so tests read them without drawing.

// MARK: - Text

enum AIText {
    /// "4 accounts · 3 providers"; nothing without accounts.
    static func accountsLine(_ accounts: [AIAccount]) -> String {
        guard !accounts.isEmpty else { return "" }
        let n = accounts.count, p = Set(accounts.map(\.provider)).count
        return "\(n) account\(n == 1 ? "" : "s") · \(p) provider\(p == 1 ? "" : "s")"
    }

    /// "$12.40", "$50".
    static func money(_ value: Double) -> String {
        let cents = (value * 100).rounded()
        return cents.truncatingRemainder(dividingBy: 100) == 0 ? "$\(Int(cents / 100))" : String(format: "$%.2f", cents / 100)
    }

    static func number(_ value: Double, _ unit: AIUnit) -> String {
        switch unit {
        case .usd: return money(value)
        case .credits: return "\(Int(value.rounded())) credits"
        case .percent: return "\(Int(value.rounded()))%"
        }
    }

    /// "1.2M tokens", "277.9M tokens", "0 tokens".
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        func short(_ v: Double, _ suffix: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        let text: String
        switch d {
        case ..<1000: text = "\(n)"
        case ..<1_000_000: text = short(d / 1000, "K")
        case ..<1_000_000_000: text = short(d / 1_000_000, "M")
        default: text = short(d / 1_000_000_000, "B")
        }
        return text + " tokens"
    }

    /// The value of a row drawn as text, not a bar: money against a cap ("$0 of $50"), credits,
    /// an amount ("$12.40 left", "$4.12 spent"), resets ("3 available"), tokens.
    static func value(_ v: AIMetricValue, display: AIUsageSettings.Display) -> String {
        switch v {
        case .limit(let used, let limit, let unit, _, _):
            switch unit {
            case .percent:
                return display == .left ? "\(Int(max(0, 100 - used / max(limit, 1) * 100).rounded()))% left" : "\(Int(min(100, used / max(limit, 1) * 100).rounded()))% used"
            case .usd: return "\(money(used)) of \(money(limit))"
            case .credits: return display == .left ? "\(number(max(0, limit - used), .credits)) left" : "\(number(used, .credits)) of \(Int(limit.rounded())) used"
            }
        case .amount(let x, let unit, let label): return "\(number(x, unit)) \(label)"
        case .resets(let count, _): return count == 0 ? "None available" : "\(count) available"
        case .tokens(let n): return tokens(n)
        }
    }

    /// "expires 30 Nov".
    static func expiry(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return "expires \(f.string(from: date))"
    }

    /// An account's label as a copied picture shows it: e-mail addresses left out in Privacy Mode.
    static func label(_ label: String, hidesEmails: Bool) -> String? {
        hidesEmails && label.contains("@") ? nil : label
    }

    static func outcome(_ o: AIUsageService.ClaimOutcome) -> String {
        switch o {
        case .done: return "Done: the limit is refilled."
        case .nothingToReset: return "Nothing to reset: this limit isn’t reached."
        case .noCredit: return "No reset left to use."
        case .unavailable(let why): return why
        case .notPermitted: return "This account may not use resets."
        case .failed(let why): return why
        }
    }
}

// MARK: - Rows

/// How a row warns: the menu bar's own rule (`AIMenuBarItem.tone`), always on in the panel.
enum AITone: Equatable {
    case normal, caution, warning
    var color: Color? {
        switch self {
        case .normal: return nil
        case .caution: return Theme.caution
        case .warning: return Theme.warning
        }
    }
}

/// One bounded limit as a bar row: the bar always fills with the share used; the text says left or
/// used; the reset column says "Out in …" (burning fast), "Resets in …" (use it or lose it) or the
/// reset countdown or clock time.
struct AIRowModel: Equatable, Identifiable {
    var id: String
    var title: String
    var used: Double
    var value: String
    var reset: String?
    var tone: AITone
    /// Where an even pace would be by now (0...1), when pace marks are on.
    var tick: Double?
    var help: String?

    init?(entry: AIPriorityBoard.Entry, settings o: AIUsageSettings, now: Date = Date()) {
        let line = entry.line
        guard let used = line.used, let limit = line.limit, limit > 0, line.remainingFraction != nil else { return nil }
        id = line.id
        title = line.metric.title
        self.used = min(1, max(0, used / limit))
        value = AIMenuBarItem.valueText(line, o.display)
        let clock = o.resetFormat == .clock
        if case .useItOrLoseIt(let at)? = entry.reason, clock, let time = AIDuration.reset(at, absolute: true, now: now) {
            reset = "Resets \(time)"
        } else {
            reset = entry.note(now: now) ?? AIDuration.reset(line.resetsAt, absolute: clock, now: now)
        }
        switch AIMenuBarItem.tone(line, o, warnRed: true, now: now) {
        case .plain: tone = .normal
        case .caution: tone = .caution
        case .warning: tone = .warning
        }
        let pace = line.pace(now: now)
        tick = o.paceMarks ? pace.map { Self.tickPosition($0) } : nil
        if let out = entry.note(now: now), out.hasPrefix("Out in"), let reset = line.resetsAt, let p = pace,
            let spare = AIDuration.text(seconds: reset.timeIntervalSince(now) - p.runway, now: now)
        {
            help = "At this pace: \(out.lowercased()), \(spare) before it resets"
        } else if o.paceMarks, let p = pace {
            help = AIPace.tooltip(p)
        }
    }

    /// The pace mark sits where an even pace would have used the limit by now: the share of the
    /// window elapsed, on the same bar of used share in either display.
    static func tickPosition(_ pace: AIPace.Reading) -> Double { min(1, max(0, pace.share)) }
}

/// The line a row stands for, with its menu: Pin or Unpin,
/// Hide, Show in menu bar.
struct AILimitMenu: View {
    var targets: [AILimitLine]
    @Environment(AppSettings.self) private var settings
    @Environment(AIUsageService.self) private var ai: AIUsageService?

    var body: some View {
        if let key = targets.first?.metric.key {
            let pinned = targets.allSatisfy { $0.account.pinned.contains(key) }
            Button(pinned ? "Unpin" : "Pin") {
                for t in targets where t.account.pinned.contains(key) == pinned { ai?.togglePin(t.account.id, key) }
            }
            Button("Hide") {
                for t in targets where !t.account.hidden.contains(key) { ai?.toggleHidden(t.account.id, key) }
            }
            Button("Show in menu bar") { settings.aiUsage = AIPanelActions.showingInMenuBar(targets[0].id, settings.aiUsage) }
        }
    }
}

enum AIPanelActions {
    /// "Show in menu bar": the limit joins the chosen list (once) and the menu bar shows the chosen ones.
    static func showingInMenuBar(_ id: String, _ settings: AIUsageSettings) -> AIUsageSettings {
        var s = settings
        if !s.menuChosen.contains(id) { s.menuChosen.append(id) }
        s.menuMode = .chosen
        return s
    }

    /// Settings › AI Usage: "Accounts…", "Manage accounts…".
    static var accountsRoute: SettingsRoute { .aiUsage() }
    /// "Add account…": the pane with its add sheet open.
    static var addRoute: SettingsRoute { .aiUsageAdd }
    /// A problem's Fix: Settings › AI Usage with that account selected.
    static func fixRoute(_ account: AIAccount) -> SettingsRoute { .aiUsage(account: account.id) }
}

/// A thin bar of the share used, in the AI colour (or the warning colour), with the pace mark.
struct AIBar: View {
    var used: Double
    var color: Color
    var tick: Double?
    var body: some View {
        GeometryReader { geo in
            // The bar keeps its 6 pt height; the taller pace mark is drawn over it, never sizing it.
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: geo.size.width * used)
            }
            .frame(height: geo.size.height)
            .overlay(alignment: .leading) {
                if let tick {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.muted)
                        .frame(width: 2, height: 12)
                        .offset(x: min(max(0, geo.size.width * tick - 1), geo.size.width - 2))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Column widths of the bar rows, as in the design.
enum AIRowLayout {
    static let mark: CGFloat = 22
    static let name: CGFloat = 64
    /// The panel's account cards have no mark column: the name gets its room.
    static let wideName: CGFloat = 96
    /// "100% used" whole.
    static let value: CGFloat = 70
    static let reset: CGFloat = 78
    /// "Claude A1 5 hours" in one column when providers show as names: the mark's and the name's
    /// room together, so the bar keeps its width.
    static var namedTitle: CGFloat { mark + 6 + name }
}

/// A bar row: (mark,) name, bar, amount, reset. Clicking the amount flips left / used everywhere;
/// clicking the reset flips countdown / clock time.
struct AILimitRowView: View {
    var row: AIRowModel
    var targets: [AILimitLine]
    /// The provider column (the overview card); nil in the panel, whose card names the account.
    var provider: AIProvider?
    var initials: String?
    /// Several accounts as one (unified): the hover lists each account's value.
    var perAccount: String?
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let asName = settings.aiUsage.providersAs == .name
        HStack(spacing: 6) {
            if let provider, asName {
                (Text(provider.name + (initials.map { " \($0)" } ?? "") + " ").font(.system(size: 11, weight: .semibold)) + Text(row.title))
                    .foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    .frame(width: AIRowLayout.namedTitle, alignment: .leading)
            } else {
                if let provider {
                    AIProviderBadge(provider: provider, initials: initials, size: 14).frame(width: AIRowLayout.mark, alignment: .leading)
                }
                Text(row.title).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    .frame(width: provider == nil ? AIRowLayout.wideName : AIRowLayout.name, alignment: .leading)
            }
            AIBar(used: row.used, color: row.tone.color ?? Theme.ai, tick: row.tick).frame(maxWidth: .infinity)
            Button {
                settings.aiUsage.display = settings.aiUsage.display == .left ? .used : .left
            } label: {
                Text(row.value).font(Theme.number(12.5, weight: .semibold)).foregroundStyle(row.tone.color ?? Color.primary).lineLimit(1).fixedSize()
            }
            .buttonStyle(.plain)
            .frame(width: AIRowLayout.value, alignment: .trailing)
            .help(settings.aiUsage.display == .left ? "Show used" : "Show left")
            Button {
                settings.aiUsage.resetFormat = settings.aiUsage.resetFormat == .clock ? .countdown : .clock
            } label: {
                Text(row.reset ?? "").font(Theme.number(11.5, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            }
            .buttonStyle(.plain)
            .frame(width: AIRowLayout.reset, alignment: .trailing)
            .help(settings.aiUsage.resetFormat == .clock ? "Show the time left" : "Show the reset time")
        }
        .font(.system(size: 12.5))
        .frame(minHeight: 25)
        .contentShape(Rectangle())
        .help([row.help, perAccount].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu { AILimitMenu(targets: targets) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.map { "\($0.name) " } ?? "")\(row.title), \(row.value)\(row.reset.map { ", \($0)" } ?? "")")
    }
}

/// The provider's mark, with the account's initials when the provider has several accounts.
struct AIProviderBadge: View {
    var provider: AIProvider
    var initials: String?
    var size: CGFloat = 14
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ProviderMarkView(provider, size: size)
            if let initials {
                Text(initials).font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Theme.card)
                    .padding(.horizontal, 2)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
                    .offset(x: 5, y: 4)
            }
        }
        // The initials hang past the mark: room for them, so the name after it is not covered.
        .padding(.trailing, initials == nil ? 0 : 6)
        .accessibilityLabel(provider.name + (initials.map { " \($0)" } ?? ""))
    }
}

/// "2 running out · 1 used up", red when something is used up, critical or burning fast.
struct AIPill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .lineLimit(1).fixedSize()
    }
}

/// A panel card: one account.
struct AIAccountGroup: Identifiable, Equatable {
    var provider: AIProvider
    var accounts: [AIAccount]
    /// The metrics shown, hidden ones left out.
    var metrics: [AIMetric]
    var id: String { accounts[0].id }

    /// The cards in account order.
    static func groups(accounts: [AIAccount], readings: [String: AIReading]) -> [AIAccountGroup] {
        var result: [AIAccountGroup] = []
        for a in accounts {
            let metrics = (readings[a.id]?.metrics ?? []).filter { !a.hidden.contains($0.key) }
            result.append(AIAccountGroup(provider: a.provider, accounts: [a], metrics: metrics))
        }
        return result
    }

    /// The lines a metric row stands for: the metric in each account that has it.
    func targets(_ key: String, readings: [String: AIReading]) -> [AILimitLine] {
        accounts.compactMap { a in readings[a.id]?.metrics.first { $0.key == key }.map { AILimitLine(account: a, metric: $0) } }
    }
}

// MARK: - The panel

/// The AI usage panel's content under its header (the header is `PopoverView`'s): the account
/// cards and the footer.
struct AIPanelView: View {
    /// heron-snap: the first resets list open (and its confirmation shown).
    var openResets = false
    var confirmReset = false
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let ai, !ai.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                AIPanelContent(openResets: openResets, confirmReset: confirmReset)
                footer(ai)
            }
        } else {
            AINoAccounts()
        }
    }

    private func footer(_ ai: AIUsageService) -> some View {
        HStack(spacing: 6) {
            Button {
                ai.refreshAll(force: true)
            } label: {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.footerText(next: ai.nextRefresh, refreshing: !ai.refreshing.isEmpty, now: context.date))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh every account now")
            Spacer(minLength: 6)
            Button("Copy picture") {
                AIPicture.copy(AIPanelPicture(), settings: settings, ai: ai, services: services, scheme: scheme)
            }
            Button("Accounts…") { services.openSettings(AIPanelActions.accountsRoute) }
        }
        .buttonStyle(FooterButtonStyle())
        .padding(.top, 2)
    }

    /// "Next update in 4m · ⌘R"; "Updating… · ⌘R" while a read is under way.
    static func footerText(next: Date?, refreshing: Bool, now: Date = Date()) -> String {
        if refreshing { return "Updating… · ⌘R" }
        guard let next, let left = AIDuration.text(from: now, to: next) else { return "Refresh · ⌘R" }
        return "Next update in \(left) · ⌘R"
    }
}

/// heron-snap's way into states a render cannot click to: the first resets list open, its
/// confirmation shown.
public struct AIPanelDebug {
    public var openResets: Bool
    public var confirmReset: Bool
    public init(openResets: Bool = false, confirmReset: Bool = false) {
        self.openResets = openResets; self.confirmReset = confirmReset
    }
}

/// One card per account.
struct AIPanelContent: View {
    var openResets = false
    var confirmReset = false
    @Environment(AIUsageService.self) private var ai: AIUsageService?

    var body: some View {
        if let ai {
            let groups = AIAccountGroup.groups(accounts: ai.accounts, readings: ai.readings)
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                AIGroupCard(
                    group: group, openResets: openResets && i == groups.firstIndex { g in g.metrics.contains { if case .resets = $0.value { return true } else { return false } } },
                    confirmReset: confirmReset)
            }
        }
    }
}

/// The header, then the account cards: what "Copy picture" puts on the pasteboard.
struct AIPanelPicture: View {
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IconTile(part: .ai, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI usage").font(.system(size: 15, weight: .bold))
                    Text(AIText.accountsLine(ai?.accounts ?? [])).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            AIPanelContent()
        }
    }
}

/// The panel with no account: what to do about it.
struct AINoAccounts: View {
    @Environment(AppServices.self) private var services
    var body: some View {
        Card(spacing: 6) {
            Text("NO ACCOUNTS").font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(Theme.muted)
            Text("Add a Claude, ChatGPT or OpenCode account to see its plan limits here.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button("Add account…") { services.openSettings(AIPanelActions.addRoute) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

// MARK: - Account cards

/// One account's card (or a unified provider's): its header, then each metric by kind.
struct AIGroupCard: View {
    var group: AIAccountGroup
    var openResets = false
    var confirmReset = false
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var scheme
    @Environment(\.aiHidesEmails) private var hidesEmails
    @State private var renaming: String?

    var body: some View {
        Card(spacing: 2) {
            header.padding(.bottom, 2)
            if let ai {
                let o = settings.aiUsage
                ForEach(group.metrics) { metric in
                    let targets = group.targets(metric.key, readings: ai.readings)
                    switch metric.value {
                    case .limit(_, _, .percent, _, _):
                        let line = AILimitLine(account: group.accounts[0], metric: metric)
                        let entry = AIPriorityBoard.Entry(line: line, reason: AIPriorityBoard.reason(line, o.boardOptions, now: Date()))
                        if let row = AIRowModel(entry: entry, settings: o) {
                            AILimitRowView(row: row, targets: targets)
                        }
                    case .resets(let count, _):
                        AIResetsRow(
                            title: metric.title, count: count, accounts: group.accounts,
                            open: openResets, confirming: confirmReset)
                    default:
                        KeyValueRow(key: metric.title, value: AIText.value(metric.value, display: o.display))
                            .font(.system(size: 12.5))
                            .frame(minHeight: 25)
                    }
                }
            }
        }
    }

    private var header: some View {
        let first = group.accounts[0]
        let readings = group.accounts.compactMap { ai?.readings[$0.id] }
        let plans = Array(NSOrderedSet(array: readings.compactMap(\.plan))) as? [String] ?? []
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                if settings.aiUsage.providersAs == .logo {
                    AIProviderBadge(provider: group.provider, initials: ai?.initials(first), size: 16)
                }
                Text(group.provider.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .contentShape(Rectangle())
            .contextMenu { providerMenu }
            if renaming == first.id {
                RenameField(account: first) { renaming = nil }
            } else if let label = AIText.label(first.label, hidesEmails: hidesEmails) {
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    .contentShape(Rectangle())
                    .contextMenu { accountMenu(first) }
            }
            Spacer(minLength: 4)
            if let status = Self.status(group.accounts.map { ai?.readings[$0.id] }, refreshing: group.accounts.contains { ai?.refreshing.contains($0.id) ?? false }) {
                Text(status.text).font(.system(size: 11)).foregroundStyle(status.problem ? Theme.caution : Theme.muted).lineLimit(1).fixedSize()
                    .help(readings.compactMap { $0.problem?.message }.joined(separator: "\n"))
            }
            if !plans.isEmpty {
                Text(plans.joined(separator: " · ")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .lineLimit(1).fixedSize()
            }
        }
        .frame(minHeight: 26)
    }

    /// ↻ refreshing, ⚠︎ failed (the menu and the hover say why), ◷ older than two refreshes.
    static func status(_ readings: [AIReading?], refreshing: Bool, now: Date = Date()) -> (text: String, problem: Bool)? {
        if refreshing { return ("↻ refreshing", false) }
        if readings.contains(where: { $0?.problem != nil }) { return ("⚠︎ failed", true) }
        if let stale = readings.compactMap({ $0 }).filter({ $0.isStale(now: now) }).map(\.fetchedAt).min() {
            return ("◷ \(Int(now.timeIntervalSince(stale) / 60)) min old", false)
        }
        return nil
    }

    @ViewBuilder private var providerMenu: some View {
        let accounts = group.accounts
        Button("Refresh") { for a in accounts { Task { await ai?.refresh(a, force: true) } } }
        Button("Manage accounts…") { services.openSettings(AIPanelActions.accountsRoute) }
        Button("Copy picture") { copy() }
        Divider()
        Button("Status page") { services.openURL(group.provider.statusURL) }
        Button("Usage dashboard") { services.openURL(group.provider.dashboardURL) }
    }

    @ViewBuilder private func accountMenu(_ account: AIAccount) -> some View {
        if let problem = ai?.readings[account.id]?.problem {
            Text("⚠︎ \(problem.message)")
            Divider()
        }
        Button("Refresh") { Task { await ai?.refresh(account, force: true) } }
        Button("Rename") { renaming = account.id }
        Button("Copy picture") { copy() }
    }

    private func copy() {
        guard let ai else { return }
        AIPicture.copy(AIGroupCard(group: group), settings: settings, ai: ai, services: services, scheme: scheme)
    }
}

/// The account's name, edited where it is shown; Return keeps it, Esc leaves it.
private struct RenameField: View {
    var account: AIAccount
    var done: () -> Void
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .font(.system(size: 11))
            .focused($focused)
            .onAppear {
                text = account.label; focused = true
            }
            .onSubmit {
                let name = text.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, var a = ai?.accounts.first(where: { $0.id == account.id }) { a.label = name; ai?.update(a) }
                done()
            }
            .onExitCommand { done() }
    }
}

/// "Limit resets   3 available": click for each reset's kind and expiry and, when the provider
/// says one is usable now, "Use one now…" with its confirmation before anything is spent.
struct AIResetsRow: View {
    var title: String
    var count: Int
    var accounts: [AIAccount]
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @State private var open: Bool
    @State private var confirming: Bool
    @State private var working = false
    @State private var outcome: String?

    init(title: String, count: Int, accounts: [AIAccount], open: Bool = false, confirming: Bool = false) {
        self.title = title; self.count = count; self.accounts = accounts
        _open = State(initialValue: open); _confirming = State(initialValue: confirming)
    }

    /// One line of the list: "Fable reset", "Refills Fable and gives back its weekly use", "expires 11 Dec".
    struct Line: Equatable {
        var title: String
        var summary: String
        var expiry: String?
    }

    /// Every reset the accounts hold (a grant with three resets left is three lines), soonest expiry first.
    static func lines(_ accounts: [AIAccount], readings: [String: AIReading]) -> [Line] {
        AIResetGrant.list(accounts.flatMap { readings[$0.id]?.grants ?? [] }).map {
            Line(title: $0.kind.title, summary: $0.kind.summary, expiry: $0.expiresAt.map(AIText.expiry))
        }
    }

    /// The reset to spend: one Anthropic or OpenAI says is usable now, the one that expires first.
    static func usable(_ accounts: [AIAccount], readings: [String: AIReading]) -> (AIAccount, AIResetGrant)? {
        let all = accounts.flatMap { a in (readings[a.id]?.grants ?? []).filter(\.usableNow).map { (a, $0) } }
        return all.min { ($0.1.expiresAt ?? .distantFuture) < ($1.1.expiresAt ?? .distantFuture) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                open.toggle()
            } label: {
                KeyValueRow(key: title, value: AIText.value(.resets(count: count, expiries: []), display: .left))
                    .font(.system(size: 12.5)).frame(minHeight: 25).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // swiftlint:disable:next empty_count - `count` is the reset count, an Int
            .disabled(count == 0)
            .accessibilityHint(open ? "Hides the resets" : "Shows each reset, what it refills and when it expires")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(Self.lines(accounts, readings: ai?.readings ?? [:]).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(line.summary).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if let expiry = line.expiry {
                                Text(expiry).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let ai, let (account, grant) = Self.usable(accounts, readings: ai.readings) {
                        if confirming {
                            Text(grant.detail).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Spacer()
                                Button("Cancel") { confirming = false }.controlSize(.small)
                                Button("Use one now") {
                                    working = true
                                    Task {
                                        outcome = AIText.outcome(await ai.claim(account, grant))
                                        working = false; confirming = false
                                    }
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small).disabled(working)
                            }
                        } else {
                            HStack {
                                Spacer()
                                Button("Use one now…") {
                                    outcome = nil; confirming = true
                                }.controlSize(.small)
                            }
                        }
                    }
                    if let outcome { Text(outcome).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }
                .padding(8)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Copy picture

private struct AIHidesEmailsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// A copied picture in Privacy Mode: account labels that are e-mail addresses are left out.
    var aiHidesEmails: Bool {
        get { self[AIHidesEmailsKey.self] }
        set { self[AIHidesEmailsKey.self] = newValue }
    }
}

enum AIPicture {
    /// Draws `view` at the panel's width, in the current appearance, and puts it on the pasteboard.
    @MainActor static func copy<V: View>(_ view: V, settings: AppSettings, ai: AIUsageService, services: AppServices, scheme: ColorScheme) {
        let content =
            view
            .padding(14)
            .frame(width: PopoverView.width)
            .background(Theme.settingsPanel)
            .environment(settings).environment(ai).environment(services)
            .environment(\.aiHidesEmails, settings.aiUsage.privacyMode)
            .environment(\.colorScheme, scheme)
        guard let image = MenuBarRenderer.image(content, scale: NSScreen.main?.backingScaleFactor ?? 2) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
