import HeronCore
import SwiftUI

// MARK: - Menu Bar

/// The real menu bar item, live, before the clock, on a light or dark strip of menu bar: Settings ›
/// Menu Bar's preview and the first run's. A wider item than the strip shrinks to fit it.
struct MenuBarStrip: View {
    var dark: Bool
    var height: CGFloat = 32
    @Environment(AppSettings.self) private var settings
    @Environment(Monitor.self) private var monitor
    /// Optional: the first run shows this strip before the app has any AI accounts.
    @Environment(AIUsageService.self) private var ai: AIUsageService?

    var body: some View {
        let ink = MenuBarPane.ink(dark)
        // Coloured items are drawn in this strip's ink; plain ones as the template macOS tints.
        let label = MenuBarLabel(snapshot: monitor.snapshot, history: monitor.history, settings: settings, ink: dark ? .white : .black, dark: dark, ai: ai)
        let preview = MenuBarRenderer.image(for: label)
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: preview)
                .renderingMode(preview.isTemplate ? .template : .original)
                .resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: preview.size.width, maxHeight: preview.size.height)
                .foregroundStyle(ink)
                .accessibilityLabel("Menu bar preview: \(label.spokenValue)")
            HStack(spacing: 8) {
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                Text(Date(), format: .dateTime.hour().minute())
            }
            .font(.system(size: 13, weight: .medium)).monospacedDigit().fixedSize()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(MenuBarPane.barColor(dark), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Settings › Menu Bar: the whole item live on a strip of menu bar with the look every item shares
/// under it; then the items (drag to reorder, switch to show) beside the selected item's looks,
/// rendered as the menu bar draws them, and its own options.
struct MenuBarPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Monitor.self) private var monitor
    @Environment(\.colorScheme) private var colorScheme
    /// The preview's menu bar; nil follows this window's appearance.
    @State private var darkStrip: Bool?
    @State private var selected: MenuItemKind
    @State private var dragging: MenuItemKind?

    init(selected: MenuItemKind = .cpu) { _selected = State(initialValue: selected) }

    var body: some View {
        let dark = darkStrip ?? (colorScheme == .dark)
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader(pane: .menuBar)
            stripCard(dark: dark)
            HStack(alignment: .top, spacing: 16) {
                itemList.frame(width: 260)
                detail(dark: dark).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background { reorderShortcuts }
    }

    /// The menu bar behind the preview, light or dark.
    static func barColor(_ dark: Bool) -> Color {
        Color(nsColor: NSColor(hex: dark ? Theme.Palette.menuBarBackgrounds.dark[0] : Theme.Palette.menuBarBackgrounds.light[0]))
    }

    static func ink(_ dark: Bool) -> Color {
        Theme.resolved(Theme.Palette.menuBarInk, dark: dark)
    }

    // MARK: The whole item and its look

    private func stripCard(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SettingsCaption("In your menu bar")
                Spacer()
                CompactSegments(
                    title: "Preview on a light or dark menu bar", selection: Binding(get: { dark }, set: { darkStrip = $0 }),
                    options: [(false, "Light"), (true, "Dark")])
            }
            .frame(height: 22)
            MenuBarStrip(dark: dark).padding(.top, 8)
            Rectangle().fill(Theme.settingsLine).frame(height: 1).padding(.top, 10)
            appearance.padding(.top, 10)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
    }

    /// What applies to the whole item, in one row.
    private var appearance: some View {
        @Bindable var settings = settings
        let alone = settings.shownItems.isEmpty
        // Every case `MenuBarSegment.isWarning` turns red for, the temperature in the user's unit.
        let hot = Format.temperature(Warnings.hotCelsius, unit: settings.temperatureUnit)
        return HStack(spacing: 0) {
            option("Heron icon") {
                // With nothing shown the icon is the whole item, so it can't be turned off.
                SettingsSwitch(title: "Show the Heron icon", isOn: Binding(get: { settings.showsIcon }, set: { settings.showIcon = $0 }))
                    .disabled(alone)
                    .help(alone ? "Turn on at least one item to hide the icon" : "Show the Heron icon before the items")
            }
            Spacer(minLength: 6)
            option("Colour") {
                CompactSegments(title: "Colour", selection: $settings.colourMode, options: [(.monochrome, "Monochrome"), (.metric, "Metric")])
            }
            Spacer(minLength: 6)
            option("Spacing") {
                CompactSegments(title: "Spacing", selection: $settings.spacing, options: MenuBarSpacing.allCases.map { ($0, $0.title) })
            }
            Spacer(minLength: 6)
            option("Red warnings") { SettingsSwitch(title: "Turn values red when too hot or nearly full", isOn: $settings.warnRed) }
                .help("Turns a value red from \(hot), at critical memory pressure, on a nearly full startup disk and at low battery")
        }
        .controlSize(.mini)
    }

    private func option<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).fixedSize(); control()
        }.fixedSize()
    }

    // MARK: The items

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption("Items · drag to reorder")
            VStack(spacing: 0) {
                ForEach(Array(settings.menuItems.enumerated()), id: \.element.id) { index, item in
                    itemRow(item, first: index == 0)
                }
            }
            .background(Theme.settingsCard)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
        }
    }

    private func itemRow(_ item: MenuItemConfig, first: Bool) -> some View {
        let kind = item.kind
        let on = kind == selected
        let order = settings.menuItems.map(\.kind)
        return HStack(spacing: 6) {
            HeronIconView(.grip, size: 14, weight: 2.6).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Button {
                selected = kind
            } label: {
                HStack(spacing: 8) {
                    kind.tile(battery: monitor.snapshot.battery, size: 22).opacity(item.enabled ? 1 : 0.55)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.title).font(.system(size: 13, weight: on ? .semibold : .medium))
                        Text(Self.subtitle(item, style: settings.style(of: kind), ai: settings.aiUsage)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 43)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
            SettingsSwitch(title: "Show \(kind.title) in the menu bar", isOn: Binding(get: { settings.isShown(kind) }, set: { settings.setShown(kind, $0) }))
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: 44)
        .background(on ? Theme.settingsSelection : .clear)
        .overlay(alignment: .leading) { if on { Rectangle().fill(Color(nsColor: NSColor(hex: Theme.Palette.accent))).frame(width: 3) } }
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
        .help("Drag to reorder, or select it and press ⌥⌘↑ or ⌥⌘↓")
        .onDrag {
            dragging = kind
            return NSItemProvider(object: kind.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: MenuItemDropDelegate(target: kind, dragging: $dragging, settings: settings))
        .contextMenu {
            Button("Move Up") { step(kind, by: -1) }.disabled(order.first == kind)
            Button("Move Down") { step(kind, by: 1) }.disabled(order.last == kind)
        }
        .accessibilityAction(named: "Move up") { step(kind, by: -1) }
        .accessibilityAction(named: "Move down") { step(kind, by: 1) }
    }

    /// The row's second line: the item's look, "· no label", "Hidden · …".
    /// AI usage: which limits ("Most urgent · up to 3", "2 chosen limits", "Icon only").
    static func subtitle(_ item: MenuItemConfig, style: MenuItemStyle, ai: AIUsageSettings = AIUsageSettings()) -> String {
        var text: String
        switch (item.kind, style) {
        case (.ai, _):
            switch ai.menuMode {
            case .mostUrgent: text = ai.menuCount == 0 ? "Icon only" : "Most urgent · up to \(ai.menuCount)"
            case .chosen: text = ai.menuChosen.count == 1 ? "1 chosen limit" : "\(ai.menuChosen.count) chosen limits"
            }
        case (.temperature, .hottest): text = "Hottest sensor"
        case (.temperature, _): text = "\(item.kind.title(of: style)) sensor"
        default: text = item.kind.title(of: style)
        }
        if item.kind.label(of: style) != nil, !item.label { text += " · no label" }
        return item.enabled ? text : "Hidden · " + text
    }

    private func step(_ kind: MenuItemKind, by offset: Int) {
        let order = settings.menuItems.map(\.kind)
        guard let i = order.firstIndex(of: kind), order.indices.contains(i + offset) else { return }
        settings.moveItem(kind, onto: order[i + offset])
    }

    /// ⌥⌘↑ and ⌥⌘↓ move the selected item: the keyboard's way to reorder.
    private var reorderShortcuts: some View {
        ZStack {
            Button("Move \(selected.title) up") { step(selected, by: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move \(selected.title) down") { step(selected, by: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The selected item

    /// Tiles per row of looks.
    static func columns(_ kind: MenuItemKind) -> Int {
        switch kind {
        case .cpu, .gpu, .temperature: return 4
        case .memory, .battery: return 3
        case .network, .disk, .fans: return 2
        case .ai: return 1
        }
    }

    private func detail(dark: Bool) -> some View {
        let kind = selected
        let style = settings.style(of: kind)
        let shown = settings.isShown(kind)
        let rows = optionRows(kind, style)
        return VStack(alignment: .leading, spacing: 6) {
            SettingsCaption("Selected item")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    kind.tile(battery: monitor.snapshot.battery, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.title).font(.system(size: 15, weight: .semibold))
                        Text(hint(kind)).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(shown ? "In the menu bar" : "Hidden")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(shown ? Theme.memory : Theme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(shown ? Theme.memory.opacity(0.14) : Theme.settingsSelection, in: Capsule())
                        .fixedSize()
                }
                if kind == .ai {
                    // Which limits show and how (SettingsMenuBarAI.swift).
                    AIMenuBarOptions(dark: dark, shown: shown)
                } else {
                    SettingsCaption("Shows as").padding(.top, 14)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: Self.columns(kind)), spacing: 10) {
                        ForEach(kind.styles, id: \.self) { lookTile(kind, $0, chosen: $0 == style, dark: dark) }
                    }
                    .padding(2)
                    .padding(.top, 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("How \(kind.title) shows in the menu bar")
                    if !shown {
                        Text("Hidden from the menu bar. Turn it on in the list to show it.")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 10)
                    }
                    VStack(spacing: 0) {
                        ForEach(rows) { optionRow($0, kind: kind) }
                        if rows.isEmpty {
                            Text("Nothing else to set for this look.")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                                .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .padding(14)
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
        }
    }

    /// The look as the menu bar draws it, with this item's label setting and this strip's colours.
    private func lookTile(_ kind: MenuItemKind, _ style: MenuItemStyle, chosen: Bool, dark: Bool) -> some View {
        let image = MenuBarRenderer.image(
            of: MenuBarSegment(
                kind: kind, style: style, snapshot: monitor.snapshot, history: monitor.history,
                settings: settings, ink: Self.ink(dark), dark: dark))
        let accent = Color(nsColor: NSColor(hex: Theme.Palette.accent))
        return Button {
            settings.setStyle(kind, style)
        } label: {
            VStack(spacing: 6) {
                Image(nsImage: image)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Self.barColor(dark), in: RoundedRectangle(cornerRadius: 5))
                Text(kind.title(of: style)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(chosen ? Color.primary : Color.primary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(6)
            .background(Theme.settingsWindow, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(chosen ? accent : Theme.settingsLine, lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title(of: style))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The line under the selected item's name, with this Mac's numbers where they help.
    private func hint(_ kind: MenuItemKind) -> String {
        let s = monitor.snapshot
        switch kind {
        case .cpu: return "How busy the processor is"
        case .gpu: return "How busy the graphics processor is"
        case .memory: return s.memory.map { "How much of the \(Format.bytes($0.total)) is in use" } ?? "How much memory is in use"
        case .temperature: return "The hottest sensor, or one you pick"
        case .network: return "Download and upload speed"
        case .disk: return s.rootVolume.map { "Space on \($0.name)" } ?? "Space on the startup disk"
        case .fans: return "How fast the fans spin"
        case .battery: return s.battery?.chargeLimit.map { "Charge, with the \(Format.percent($0)) limit marked" } ?? "Charge"
        case .ai: return "Limits from Settings › AI Usage accounts"
        }
    }

    /// One of the selected item's options.
    struct OptionRow: Identifiable {
        enum Control { case label, units, info(String) }
        var title: String
        var hint: String
        var control: Control
        var id: String { title }
    }

    /// The selected item's own options: its label (looks with one only), the network's units, and
    /// what Heron reads for it right now. Nothing that applies to every item.
    private func optionRows(_ kind: MenuItemKind, _ style: MenuItemStyle) -> [OptionRow] {
        let s = monitor.snapshot
        let segment = MenuBarSegment(kind: kind, style: style, snapshot: s, history: monitor.history, settings: settings)
        var rows: [OptionRow] = []
        switch kind.label(of: style) {
        case .bar?:
            rows.append(OptionRow(title: "Label above the bar", hint: "“\(segment.labelWord)” written over the bar", control: .label))
        case .tag?:
            let value = segment.taggedValue
            let full = segment.labelWord.isEmpty ? value : "\(segment.labelWord) \(value)"
            rows.append(OptionRow(title: kind == .temperature ? "Show which sensor" : "Show the label", hint: "“\(full)” or just “\(value)”", control: .label))
        case nil: break
        }
        if kind == .temperature, style == .hottest, let name = SensorSummary.hottestName(in: s), let celsius = SensorSummary.value(.hottest, in: s) {
            rows.append(
                OptionRow(
                    title: "Hottest right now", hint: "Changes as your Mac works. The overview names the exact sensor.",
                    control: .info("\(name) · \(Format.temperature(celsius, unit: settings.temperatureUnit))")))
        }
        if kind == .network {
            rows.append(OptionRow(title: "Units", hint: "Bytes like Finder, or bits like your internet plan", control: .units))
        }
        if kind == .disk, let root = s.rootVolume {
            rows.append(OptionRow(title: "Disk", hint: "Your startup disk", control: .info(root.name)))
        }
        if kind == .fans, let average = FanSummary.rpm(s.fans) {
            // "2,567 · 2,779 rpm": the unit once.
            let value =
                s.fans.count <= 2
                ? s.fans.map { Format.rpm($0.rpm).replacingOccurrences(of: " rpm", with: "") }.joined(separator: " · ") + " rpm"
                : "\(s.fans.count) fans · \(Format.rpm(average))"
            rows.append(OptionRow(title: "Fans right now", hint: "The menu bar shows their average; percent is of each fan’s maximum", control: .info(value)))
        }
        if kind == .battery, let b = s.battery, b.present, let limit = b.chargeLimit {
            let held = !b.isCharging && b.percent >= limit - 0.01
            rows.append(
                OptionRow(
                    title: "Charge limit", hint: "The tick on the icon marks the limit set in macOS",
                    control: .info(held ? "Held at \(Format.percent(limit))" : Format.percent(limit))))
        }
        return rows
    }

    private func optionRow(_ row: OptionRow, kind: MenuItemKind) -> some View {
        @Bindable var settings = settings
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .medium))
                Text(row.hint).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch row.control {
            case .label:
                SettingsSwitch(title: "\(row.title) for \(kind.title)", isOn: Binding(get: { settings.showsLabel(kind) }, set: { settings.setLabel(kind, $0) }))
            case .units:
                CompactSegments(title: "Units", selection: $settings.networkInBits, options: [(false, "Bytes"), (true, "Bits")])
            case .info(let value):
                Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
    }
}

/// Moves the dragged menu bar item onto the row the pointer enters, so the order follows the drag.
private struct MenuItemDropDelegate: DropDelegate {
    var target: MenuItemKind
    @Binding var dragging: MenuItemKind?
    var settings: AppSettings

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { settings.moveItem(from, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
