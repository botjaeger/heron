import HeronCore
import SwiftUI

/// The overview's AI usage card: up to `cardRows` limits from the source Settings › Overview
/// picks (most urgent or pinned), or every limit ticked under Chosen; the summary pill, and how many more the panel has.
struct AICardModel {
    var entries: [AIPriorityBoard.Entry]
    /// Bounded limits the card leaves to the panel.
    var more: Int
    var runningOut: Int
    var usedUp: Int
    /// Something used up, critical or burning fast: the pill turns red.
    var urgent: Bool
    var source: AIUsageSettings.CardShows
    /// Initials by account id, for providers with several accounts.
    var initials: [String: String]
    /// No limit reported by any account yet.
    var nothingReported: Bool

    init(lines: [AILimitLine], initials: [String: String] = [:], settings o: AIUsageSettings, now: Date = Date()) {
        let board = AIPriorityBoard(lines: lines, options: o.boardOptions, now: now)
        let visible = lines.filter { $0.limit != nil && !$0.account.hidden.contains($0.metric.key) }
        let pool: [AIPriorityBoard.Entry]
        switch o.cardShows {
        case .mostUrgent: pool = board.menuBar(alwaysShow: true)
        case .pinned: pool = board.pinned
        case .chosen:
            pool = o.cardChosen.compactMap { id in visible.first { $0.id == id } }
                .map { AIPriorityBoard.Entry(line: $0, reason: AIPriorityBoard.reason($0, o.boardOptions, now: now)) }
        }
        // Chosen shows every ticked limit: the ticks are the choice (a Rows cap hid the 4th, 2026-11-23).
        entries = o.cardShows == .chosen ? pool : Array(pool.prefix(min(5, max(1, o.cardRows))))
        more = max(0, visible.count - entries.count)
        runningOut = board.runningOut.count
        usedUp = board.usedUp.count
        urgent = usedUp > 0 || board.runningOut.contains { AIMenuBarItem.tone($0.line, o, warnRed: true, now: now) == .warning }
        source = o.cardShows
        self.initials = initials
        nothingReported = visible.isEmpty
    }

    @MainActor init(ai: AIUsageService, settings o: AIUsageSettings, now: Date = Date()) {
        self.init(lines: ai.lines, initials: Self.initials(ai), settings: o, now: now)
    }

    /// The badge letters for each account whose provider has several accounts.
    @MainActor static func initials(_ ai: AIUsageService) -> [String: String] {
        var result: [String: String] = [:]
        for a in ai.accounts { result[a.id] = ai.initials(a) }
        return result
    }

    /// "2 running out · 1 used up"; nil when nothing is.
    var pill: (text: String, color: Color)? {
        let parts = [runningOut > 0 ? "\(runningOut) running out" : nil, usedUp > 0 ? "\(usedUp) used up" : nil].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return (parts.joined(separator: " · "), urgent ? Theme.warning : Theme.caution)
    }

    /// "Pinned and running out first · 8 more in the panel" (the panel lists every limit).
    var footer: String {
        let lead: String
        switch source {
        case .mostUrgent: lead = "Pinned and running out first"
        case .pinned: lead = "Pinned limits"
        case .chosen: lead = "Your chosen limits"
        }
        return more > 0 ? "\(lead) · \(more) more in the panel" : lead
    }

    /// What the card says when it has no row to show.
    var emptyText: String {
        if nothingReported { return "No account has reported yet." }
        switch source {
        case .mostUrgent: return "All clear: nothing is running low."
        case .pinned: return "Nothing pinned. Right-click a limit in the panel to pin it."
        case .chosen: return "No limits chosen. Pick them in Settings › Overview."
        }
    }

    /// VoiceOver: "2 running out, 1 used up" or "nothing running low".
    var spoken: String { pill.map { $0.text.replacingOccurrences(of: " · ", with: ", ") } ?? (nothingReported ? "no limits reported yet" : "nothing running low") }
}

/// The card's rows and footer, under the title row `OverviewSection` draws.
struct AICardBody: View {
    var model: AICardModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let rows = model.entries.compactMap { e in AIRowModel(entry: e, settings: settings.aiUsage).map { (e, $0) } }
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Text(model.emptyText).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows, id: \.1.id) { entry, row in
                AILimitRowView(row: row, targets: [entry.line], provider: entry.line.account.provider, initials: model.initials[entry.line.account.id])
            }
            Text(model.footer).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 2)
        }
    }
}
