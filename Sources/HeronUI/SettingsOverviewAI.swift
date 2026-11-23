import HeronCore
import SwiftUI

/// Settings › Overview with AI usage selected: what the card shows (most urgent, pinned, or the
/// limits ticked and dragged into order here, all shown), how many rows, and the summary pill. Display
/// options (left or used, reset format, pace marks, logo or name) live in Settings › AI Usage.
struct AIOverviewControls: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @Environment(\.settingsNavigate) private var navigate
    @State private var dragging: String?

    /// The section row's second line: "Most urgent · 3 rows", "Chosen · 4 limits".
    static func hint(_ o: AIUsageSettings) -> String {
        if o.cardShows == .chosen { return "Chosen · \(o.cardChosen.count) limit\(o.cardChosen.count == 1 ? "" : "s")" }
        let source: String
        switch o.cardShows {
        case .mostUrgent: source = "Most urgent"
        case .pinned: source = "Pinned"
        case .chosen: source = "Chosen"
        }
        return "\(source) · \(o.cardRows) row\(o.cardRows == 1 ? "" : "s")"
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 0) {
            ColumnCaption("Card shows")
            // Three choices as radio buttons: as segments they ran past the narrow column.
            Picker("Card shows", selection: $settings.aiUsage.cardShows) {
                Text("Most urgent").tag(AIUsageSettings.CardShows.mostUrgent)
                Text("Pinned").tag(AIUsageSettings.CardShows.pinned)
                Text("Chosen").tag(AIUsageSettings.CardShows.chosen)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if settings.aiUsage.cardShows == .chosen {
                chosenList.padding(.top, 8)
            }
            // Chosen shows every ticked limit, so Rows is only for Most urgent and Pinned.
            if settings.aiUsage.cardShows != .chosen {
                ColumnCaption("Rows").padding(.top, 14)
                CompactSegments(
                    title: "Rows on the card", selection: $settings.aiUsage.cardRows,
                    options: (1...5).map { ($0, "\($0)") }, fill: true)
            }
            OptionCard {
                OptionRow(title: "Summary pill", hint: "“2 running out · 1 used up”", first: true) {
                    SettingsSwitch(title: "Summary pill", isOn: $settings.aiUsage.cardPill)
                }
            }
            .padding(.top, 14)
            Text("Left or used, reset format, pace marks and logo or name apply everywhere.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            SettingsLink(title: "They are in AI Usage ›") { navigate?(.aiUsage) }
                .font(.system(size: 12))
                .padding(.top, 4)
        }
    }

    // MARK: Chosen limits

    /// Every limit, the ticked ones first in their order: tick to add one, drag to reorder.
    @ViewBuilder private var chosenList: some View {
        let lines = (ai?.lines ?? []).filter { $0.limit != nil && !$0.account.hidden.contains($0.metric.key) }
        let rows = AIMenuBarOptions.listOrder(lines, chosen: settings.aiUsage.cardChosen)
        if rows.isEmpty {
            Text("Add an account in Settings › AI Usage to choose its limits.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        } else {
            // Many accounts make a long list: it scrolls, so Rows and the pill stay in the window.
            OptionCard {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, line in chosenRow(line, first: i == 0) }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
    }

    private func chosenRow(_ line: AILimitLine, first: Bool) -> some View {
        let id = line.id
        let on = settings.aiUsage.cardChosen.contains(id)
        let initials = ai?.initials(line.account)
        let name = "\(line.account.provider.name)\(initials.map { " \($0)" } ?? "") \(line.metric.title)"
        return HStack(spacing: 6) {
            HeronIconView(.grip, size: 12, weight: 2.6).foregroundStyle(Theme.muted).opacity(on ? 1 : 0.4).accessibilityHidden(true)
            Toggle(name, isOn: Binding(get: { on }, set: { setChosen(id, $0) }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Show \(name) on the card")
            AIProviderBadge(provider: line.account.provider, initials: initials, size: 13).padding(.trailing, initials == nil ? 0 : 4)
            Text(line.metric.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
        .help(on ? "\(line.account.label): drag to reorder" : "\(line.account.label): tick to show it on the card")
        .onDrag {
            dragging = id
            return NSItemProvider(object: id as NSString)
        }
        .onDrop(of: [.text], delegate: AICardChosenDropDelegate(target: id, dragging: $dragging, settings: settings))
        .contextMenu {
            Button("Move Up") { step(id, by: -1) }.disabled(!on || settings.aiUsage.cardChosen.first == id)
            Button("Move Down") { step(id, by: 1) }.disabled(!on || settings.aiUsage.cardChosen.last == id)
        }
        .accessibilityAction(named: "Move up") { step(id, by: -1) }
        .accessibilityAction(named: "Move down") { step(id, by: 1) }
    }

    /// Ticking adds the limit at the end of the card's order; unticking removes it.
    private func setChosen(_ id: String, _ on: Bool) {
        settings.aiUsage.cardChosen = Self.chosen(settings.aiUsage.cardChosen, id, on)
    }

    static func chosen(_ list: [String], _ id: String, _ on: Bool) -> [String] {
        on ? (list.contains(id) ? list : list + [id]) : list.filter { $0 != id }
    }

    private func step(_ id: String, by offset: Int) {
        settings.aiUsage.cardChosen = OverviewArrange.step(settings.aiUsage.cardChosen, id, by: offset)
    }
}

/// Moves the dragged chosen limit onto the chosen row the pointer enters, so the order follows the drag.
private struct AICardChosenDropDelegate: DropDelegate {
    var target: String
    @Binding var dragging: String?
    var settings: AppSettings

    func dropEntered(info: DropInfo) {
        let chosen = settings.aiUsage.cardChosen
        guard let from = dragging, from != target, chosen.contains(from), chosen.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.15)) { settings.aiUsage.cardChosen = OverviewArrange.move(chosen, from, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
