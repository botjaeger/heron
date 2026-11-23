import AppKit
import HeronCore
import SwiftUI

/// Settings › Menu Bar with AI usage selected: what the item shows (the most urgent limits or the
/// ones you choose, each tile rendered as the menu bar draws it), the chosen limits (tick and
/// drag), how many "most urgent" shows, Always show, providers as logo or name, and the limit's name.
/// Everything is stored in `AppSettings.aiUsage`.
struct AIMenuBarOptions: View {
    var dark: Bool
    var shown: Bool
    @Environment(AppSettings.self) private var settings
    /// Optional: without the service (no accounts yet) the lists are empty, never invented.
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @State private var dragging: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption("Shows").padding(.top, 14)
            HStack(spacing: 10) {
                modeTile(.mostUrgent, "Most urgent")
                modeTile(.chosen, "Chosen limits")
            }
            .padding(2)
            .padding(.top, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Which AI limits show in the menu bar")
            if !shown {
                Text("Hidden from the menu bar. Turn it on in the list to show it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 10)
            }
            SettingsCaption("Chosen limits · tick and drag").padding(.top, 14)
            chosenList.padding(.top, 6)
            options.padding(.top, 10)
        }
    }

    // MARK: Shows

    /// Every limit with a percentage, as the menu bar can show it.
    private var lines: [AILimitLine] { ai?.lines.filter { $0.percentLeft != nil } ?? [] }

    private func modeTile(_ mode: AIUsageSettings.MenuMode, _ title: String) -> some View {
        @Bindable var settings = settings
        let chosen = settings.aiUsage.menuMode == mode
        let accent = Color(nsColor: NSColor(hex: Theme.Palette.accent))
        var options = settings.aiUsage
        options.menuMode = mode
        let image = ai.flatMap { Self.image(AIMenuBarItem(service: $0, options: options, warnRed: settings.warnRed), dark: dark, metric: settings.colourMode == .metric) }
        return Button {
            settings.aiUsage.menuMode = mode
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable().interpolation(.high).scaledToFit()
                            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    } else {
                        Text(lines.isEmpty ? "No accounts yet" : mode == .chosen ? "None chosen" : "Nothing running out")
                            .font(.system(size: 11)).foregroundStyle(MenuBarPane.ink(dark).opacity(0.7))
                    }
                }
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(MenuBarPane.barColor(dark), in: RoundedRectangle(cornerRadius: 5))
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(chosen ? Color.primary : Color.primary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(6)
            .background(Theme.settingsWindow, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(chosen ? accent : Theme.settingsLine, lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The limits as the menu bar draws them in this strip's ink; nil when there is nothing to draw.
    @MainActor
    static func image(_ item: AIMenuBarItem, dark: Bool, metric: Bool = false, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> NSImage? {
        guard !item.isEmpty else { return nil }
        return MenuBarRenderer.image(AIMenuBarView(item: item, ink: MenuBarPane.ink(dark), dark: dark, metric: metric).frame(height: 18).fixedSize(), scale: scale)
    }

    // MARK: Chosen limits

    /// The chosen limits first, in their order, then the others in account order.
    static func listOrder(_ lines: [AILimitLine], chosen: [String]) -> [AILimitLine] {
        chosen.compactMap { id in lines.first { $0.id == id } } + lines.filter { !chosen.contains($0.id) }
    }

    @ViewBuilder
    private var chosenList: some View {
        let rows = Self.listOrder(lines, chosen: settings.aiUsage.menuChosen)
        if rows.isEmpty {
            Text("Add an account in Settings › AI Usage to choose its limits.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { chosenRow($0) }
            }
        }
    }

    private func chosenRow(_ line: AILimitLine) -> some View {
        let id = line.id
        let on = settings.aiUsage.menuChosen.contains(id)
        let initials = ai?.initials(line.account)
        let name = "\(line.account.provider.name)\(initials == nil ? "" : " \(line.account.label)") \(line.metric.title)"
        return HStack(spacing: 8) {
            HeronIconView(.grip, size: 14, weight: 2.6).foregroundStyle(Theme.muted).opacity(on ? 1 : 0.4).accessibilityHidden(true)
            Toggle(name, isOn: Binding(get: { on }, set: { setChosen(id, $0) }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Show \(name) in the menu bar")
            HStack(alignment: .bottom, spacing: 1) {
                ProviderMarkView(line.account.provider, size: 15)
                if let initials {
                    Text(initials).font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.muted).fixedSize().offset(y: 2)
                }
            }
            Text(line.metric.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if initials != nil {
                Text(line.account.label).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
        .help(on ? "Drag to reorder" : "Tick to show it in the menu bar")
        .onDrag {
            dragging = id
            return NSItemProvider(object: id as NSString)
        }
        .onDrop(of: [.text], delegate: AIChosenDropDelegate(target: id, dragging: $dragging, settings: settings))
        .contextMenu {
            Button("Move Up") { step(id, by: -1) }.disabled(!on || settings.aiUsage.menuChosen.first == id)
            Button("Move Down") { step(id, by: 1) }.disabled(!on || settings.aiUsage.menuChosen.last == id)
        }
        .accessibilityAction(named: "Move up") { step(id, by: -1) }
        .accessibilityAction(named: "Move down") { step(id, by: 1) }
    }

    /// Ticking adds the limit at the end of the chosen order; unticking removes it.
    private func setChosen(_ id: String, _ on: Bool) {
        if on { if !settings.aiUsage.menuChosen.contains(id) { settings.aiUsage.menuChosen.append(id) } } else { settings.aiUsage.menuChosen.removeAll { $0 == id } }
    }

    private func step(_ id: String, by offset: Int) {
        settings.aiUsage.menuChosen = OverviewArrange.step(settings.aiUsage.menuChosen, id, by: offset)
    }

    // MARK: The other options

    private var options: some View {
        @Bindable var settings = settings
        let display = settings.aiUsage.display
        let value = lines.first.map { AIMenuBarItem.menuText($0, display) } ?? (display == .left ? "49%" : "51%")
        let tag = lines.first?.metric.title.uppercased() ?? "WEEKLY"
        return VStack(spacing: 0) {
            row("How many", "For Most urgent; more show as “+N”") {
                CompactSegments(
                    title: "How many limits Most urgent shows", selection: $settings.aiUsage.menuCount,
                    options: [(0, "Icon only")] + (1...5).map { ($0, "\($0)") })
            }
            row("Always show", "Pinned, running out, use it or lose it, then used up") {
                SettingsSwitch(title: "Always show limits, not only those running out", isOn: $settings.aiUsage.alwaysShow)
            }
            row("Providers as", nil) {
                CompactSegments(title: "Providers as", selection: $settings.aiUsage.providersAs, options: [(.logo, "Logo"), (.name, "Name")])
            }
            row("Show the limit’s name", "“\(tag) \(value)” or just “\(value)”") {
                SettingsSwitch(title: "Show the limit’s name", isOn: $settings.aiUsage.showLimitName)
            }
        }
    }

    private func row<Control: View>(_ title: String, _ hint: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
    }
}

/// Moves the dragged chosen limit onto the chosen row the pointer enters, so the order follows the drag.
private struct AIChosenDropDelegate: DropDelegate {
    var target: String
    @Binding var dragging: String?
    var settings: AppSettings

    func dropEntered(info: DropInfo) {
        let chosen = settings.aiUsage.menuChosen
        guard let from = dragging, from != target, chosen.contains(from), chosen.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.15)) { settings.aiUsage.menuChosen = OverviewArrange.move(chosen, from, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
