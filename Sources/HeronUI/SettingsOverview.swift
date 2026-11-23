import HeronCore
import SwiftUI

// MARK: - Overview

/// What Settings › Overview shows: the selected section, and whether its preview is the card or
/// the panel. The preview choice is one for every section: moving to another keeps it.
struct OverviewEditorState: Equatable {
    var selected: OverviewPart
    var showsPanel = false
    mutating func select(_ part: OverviewPart) { selected = part }
}

/// Settings › Overview: the popover's sections in order (drag, ⌥⌘↑ ↓ or VoiceOver's actions to
/// move one, the eye to hide it); the selected section beside them with its real card or panel,
/// its card styles drawn as small cards, and its own options.
struct OverviewPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @Environment(\.settingsNavigate) private var navigate
    @Environment(AIUsageService.self) private var ai: AIUsageService?
    @State private var editor: OverviewEditorState
    @State private var dragging: OverviewPart?

    init(selected: OverviewPart, showsPanel: Bool) {
        _editor = State(initialValue: OverviewEditorState(selected: selected, showsPanel: showsPanel))
    }

    /// The controls column and the card preview, as in the design.
    static let controlsWidth: CGFloat = 176
    static let cardWidth: CGFloat = 290
    /// A card's width in the popover (the popover less its padding): cards are drawn at it, then scaled.
    static var popoverCardWidth: CGFloat { PopoverView.width - 2 * PopoverView.overviewPadding }
    /// The panel drawn in the preview: 360 points at 0.8.
    static let panelScale: CGFloat = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(pane: .overview)
            HStack(alignment: .top, spacing: 12) {
                sectionList.frame(width: Self.controlsWidth)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background { reorderShortcuts }
    }

    // MARK: The sections

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnCaption("Sections")
            VStack(spacing: 0) {
                ForEach(settings.overviewOrder) { sectionRow($0) }
            }
            .padding(4)
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
            Text("Drag a section to move it. Hidden sections still feed the menu bar and alerts.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.horizontal, 2)
            Button("Restore defaults") { settings.restoreOverviewDefaults() }
                .controlSize(.small)
                .help("Puts the sections, their order, styles and options back as Heron ships them")
                .padding(.top, 10)
        }
    }

    /// The row's second line: the card style, the number of temperatures, or "Hidden".
    static func hint(_ part: OverviewPart, settings: AppSettings) -> String {
        if settings.isHidden(part) { return "Hidden" }
        if let card = OverviewCard(rawValue: part.rawValue) { return settings.cardStyle(card).title }
        switch part {
        case .sensors: return settings.sensorCard.count == 1 ? "1 temperature" : "\(settings.sensorCard.count) temperatures"
        case .ai: return AIOverviewControls.hint(settings.aiUsage)
        default: return "Charge, health"
        }
    }

    /// Whether the eye may not hide `part`: it is the last section the popover draws (Battery on a
    /// Mac without one, and AI usage without an account, are not drawn, so they never count).
    static func isLocked(_ part: OverviewPart, order: [OverviewPart], hidden: Set<OverviewPart>, snapshot: Snapshot, ai: Bool) -> Bool {
        guard !hidden.contains(part) else { return false }
        return OverviewSection.parts(order: order, hidden: hidden, snapshot: snapshot, ai: ai) == [part]
            || order.filter { !hidden.contains($0) }.count == 1
    }

    private func sectionRow(_ part: OverviewPart) -> some View {
        let on = part == editor.selected
        let hidden = settings.isHidden(part)
        let order = settings.overviewOrder
        // The last visible section can't be hidden: an empty popover would only show the footer.
        // Visible means drawn: Battery on a Mac without one, or AI usage without an account, is not.
        let locked = Self.isLocked(part, order: order, hidden: settings.hiddenSections, snapshot: monitor.snapshot, ai: !(ai?.accounts.isEmpty ?? true))
        let soft: Color = on ? Theme.settingsPickedText : Theme.muted
        return HStack(spacing: 0) {
            Button {
                editor.select(part)
            } label: {
                HStack(spacing: 5) {
                    HeronIconView(.grip, size: 12, weight: 2.6).foregroundStyle(soft).accessibilityHidden(true)
                    IconTile(part: part, battery: monitor.snapshot.battery, size: 22).opacity(hidden ? 0.45 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.title).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(hidden && !on ? Theme.muted : Color.primary)
                        Text(Self.hint(part, settings: settings)).font(.system(size: 11)).foregroundStyle(soft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 2)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hidden ? "\(part.title), hidden" : part.title)
            .accessibilityAddTraits(on ? .isSelected : [])
            Button {
                settings.setHidden(part, !hidden)
            } label: {
                HeronIconView(hidden ? .eyeOff : .eye, size: 15, weight: 1.8)
                    .foregroundStyle(soft)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .opacity(locked ? 0.35 : 1)
            .help(locked ? "At least one section stays in the overview" : (hidden ? "Show \(part.title) in the overview" : "Hide \(part.title) from the overview"))
            .accessibilityLabel(hidden ? "Show \(part.title) in the overview" : "Hide \(part.title) from the overview")
            .padding(.trailing, 2)
        }
        .frame(height: 44)
        .background(on ? Theme.settingsPicked : .clear, in: RoundedRectangle(cornerRadius: 7))
        .help("Drag to reorder, or select it and press ⌥⌘↑ or ⌥⌘↓")
        .onDrag {
            dragging = part
            return NSItemProvider(object: part.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: SectionDropDelegate(target: part, dragging: $dragging, settings: settings))
        .contextMenu {
            Button("Move Up") { step(part, by: -1) }.disabled(order.first == part)
            Button("Move Down") { step(part, by: 1) }.disabled(order.last == part)
            Button(hidden ? "Show in the Overview" : "Hide from the Overview") { settings.setHidden(part, !hidden) }.disabled(locked)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { step(part, by: -1) }
        .accessibilityAction(named: "Move down") { step(part, by: 1) }
    }

    private func step(_ part: OverviewPart, by offset: Int) {
        settings.setOverviewOrder(OverviewArrange.step(settings.overviewOrder, part, by: offset))
    }

    /// ⌥⌘↑ and ⌥⌘↓ move the selected section: the keyboard's way to reorder.
    private var reorderShortcuts: some View {
        let part = editor.selected
        return ZStack {
            Button("Move \(part.title) up") { step(part, by: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move \(part.title) down") { step(part, by: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The selected section

    /// "1st of 6 in the popover"; a hidden section, and Battery on a Mac without one, say why
    /// the popover leaves them out.
    static func position(of part: OverviewPart, order: [OverviewPart], hidden: Set<OverviewPart>, snapshot: Snapshot, ai: Bool = false) -> String {
        if hidden.contains(part) { return "Hidden. The menu bar and alerts still read it." }
        let shown = OverviewSection.parts(order: order, hidden: hidden, snapshot: snapshot, ai: ai)
        guard let index = shown.firstIndex(of: part) else {
            return part == .ai ? "Shows once an AI account is added." : "This Mac has no battery, so the popover leaves it out."
        }
        let ordinals = ["1st", "2nd", "3rd"]
        let place = index < ordinals.count ? ordinals[index] : "\(index + 1)th"
        return "\(place) of \(shown.count) in the popover"
    }

    private var detail: some View {
        let part = editor.selected
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(part.title).font(.system(size: 17, weight: .semibold))
                Text(Self.position(of: part, order: settings.overviewOrder, hidden: settings.hiddenSections, snapshot: monitor.snapshot, ai: !(ai?.accounts.isEmpty ?? true)))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
            }
            .frame(height: 26)
            HStack(alignment: .top, spacing: 12) {
                preview(part).frame(width: Self.cardWidth + 10)
                controls(part).frame(width: Self.controlsWidth, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Card | Panel, then the real card at its design width (the box hugs it) or the real panel at
    /// 0.8, cut off with a fade where it runs past the window.
    private func preview(_ part: OverviewPart) -> some View {
        let noBattery = part == .battery && monitor.snapshot.battery?.present != true
        return VStack(spacing: 8) {
            CompactSegments(title: "Preview", selection: $editor.showsPanel, options: [(false, "Card"), (true, "Panel")], fill: true)
            if !noBattery && !editor.showsPanel {
                ScaledLayout(scale: Self.cardWidth / Self.popoverCardWidth) {
                    OverviewSection(snapshot: monitor.snapshot, only: part)
                        .frame(width: Self.popoverCardWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(Self.cardWidth / Self.popoverCardWidth, anchor: .topLeading)
                }
                .frame(width: Self.cardWidth, alignment: .topLeading)
                .padding(4)
                .allowsHitTesting(false)
                .background(Theme.settingsPanel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Preview of the \(part.title) card")
            } else {
                Theme.settingsPanel
                    .overlay(alignment: .topLeading) {
                        if noBattery {
                            Text("This Mac has no battery, so the overview leaves this section out.")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(14)
                        } else if editor.showsPanel {
                            PopoverView(kind: PopoverKind(part))
                                .frame(width: PopoverView.width)
                                .fixedSize(horizontal: false, vertical: true)
                                .scaleEffect(Self.panelScale, anchor: .topLeading)
                                .frame(width: PopoverView.width * Self.panelScale, alignment: .topLeading)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if editor.showsPanel && !noBattery {
                            LinearGradient(colors: [Theme.settingsPanel.opacity(0), Theme.settingsPanel], startPoint: .top, endPoint: .bottom)
                                .frame(height: 64)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(editor.showsPanel ? "Preview of the \(part.title) panel" : "Preview of the \(part.title) card")
            }
        }
    }

    @ViewBuilder private func controls(_ part: OverviewPart) -> some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 0) {
            if let card = OverviewCard(rawValue: part.rawValue) {
                ColumnCaption("Card style")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(card.styles, id: \.self) { styleTile(part, card, $0) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Card style")
                .padding(.bottom, 14)
            }
            switch part {
            case .cpu:
                ColumnCaption("In the panel")
                OptionCard {
                    OptionRow(title: "Show logical cores", hint: "A ring per core, efficiency and performance apart", first: true) {
                        SettingsSwitch(title: "Show logical cores", isOn: $settings.showCores)
                    }
                    OptionRow(title: "Show top processes", hint: "The five apps using the most CPU") {
                        SettingsSwitch(title: "Show top processes", isOn: $settings.showCPUProcesses)
                    }
                }
            case .gpu:
                note("Nothing else to set for GPU.")
            case .memory:
                ColumnCaption("In the panel")
                OptionCard {
                    OptionRow(title: "Show top processes", hint: "The five apps using the most memory", first: true) {
                        SettingsSwitch(title: "Show top processes", isOn: $settings.showMemoryProcesses)
                    }
                }
            case .network:
                ColumnCaption("Card and panel")
                OptionCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Units").font(.system(size: 13, weight: .medium))
                        SettingsSegments(title: "Units", selection: $settings.networkInBits, options: [(false, "Bytes"), (true, "Bits")])
                        Text(unitHint).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                ColumnCaption("In the panel").padding(.top, 10)
                OptionCard {
                    OptionRow(title: "Public IP look-up", hint: "Adds Look up. Heron asks api.ipify.org only when you click it.", first: true) {
                        SettingsSwitch(title: "Public IP look-up", isOn: $settings.showPublicIP)
                    }
                }
            case .disk:
                ColumnCaption("In the panel")
                OptionCard {
                    OptionRow(title: "Hide disk images", hint: "Installers and mounted .dmg files stay out of the list", first: true) {
                        SettingsSwitch(title: "Hide disk images", isOn: $settings.hideDiskImages)
                    }
                }
            case .sensors:
                sensorControls
            case .battery:
                batteryControls
            case .ai:
                AIOverviewControls()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }

    /// "Bytes per second, like file sizes: 31 KB/s", with this Mac's download speed.
    private var unitHint: String {
        let down = monitor.snapshot.network?.downBytesPerSecond
        let bits = settings.networkInBits
        let base = bits ? "Bits per second, like your internet plan" : "Bytes per second, like file sizes"
        return down.map { "\(base): \(Format.rate($0, bits: bits))" } ?? base
    }

    /// A card style as a small copy of the real card drawn in it.
    private func styleTile(_ part: OverviewPart, _ card: OverviewCard, _ style: CardStyle) -> some View {
        let chosen = settings.cardStyle(card) == style
        let thumb: CGFloat = 70
        return Button {
            settings.setCardStyle(card, style)
        } label: {
            VStack(spacing: 5) {
                OverviewSection(snapshot: monitor.snapshot, only: part, style: style)
                    .frame(width: Self.popoverCardWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(thumb / Self.popoverCardWidth)
                    .frame(width: thumb, height: 44)
                    .clipped()
                    .frame(maxWidth: .infinity)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
                    .allowsHitTesting(false)
                Text(style.title).font(.system(size: 11, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? Color.primary : Theme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 5)
            .frame(height: 72)
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.settingsLine, lineWidth: 1))
            .overlay { if chosen { RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: NSColor(hex: Theme.Palette.accent)), lineWidth: 2).padding(-1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: Sensors and Battery

    @ViewBuilder private var sensorControls: some View {
        @Bindable var settings = settings
        let s = monitor.snapshot
        let unnamed = monitor.unnamedSensorCount
        HStack {
            ColumnCaption("On the card", bottom: 0)
            Spacer(minLength: 4)
            Text("\(settings.sensorCard.count) of \(SensorCardItem.limit)").font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
        }
        .frame(height: 16)
        .padding(.bottom, 6)
        SensorCardPills(available: SensorSummary.cardItems(in: s))
        OptionCard {
            OptionRow(title: "Fan speed", hint: "In the title row", first: true) {
                SettingsSwitch(title: "Show fan speed on the card", isOn: $settings.sensorCardFans)
            }
            OptionRow(title: "Name the hottest", hint: SensorSummary.hottestName(in: s).map { "“Hottest · \($0)”" } ?? "Its name on the card, not in the menu bar") {
                SettingsSwitch(title: "Name the hottest sensor", isOn: $settings.nameHottest)
            }
        }
        .padding(.top, 8)
        ColumnCaption("In the panel").padding(.top, 10)
        OptionCard {
            OptionRow(title: "Hide unnamed", hint: unnamed > 0 ? "\(unnamed) more, such as Tp0b" : "Sensors Heron can’t name, such as Tp0b", first: true) {
                SettingsSwitch(title: "Hide sensors without a name", isOn: $settings.hideUnknownSensors)
            }
            ForEach(s.fans, id: \.id) { fan in
                HStack(spacing: 6) {
                    Text(fan.name).lineLimit(1)
                    Spacer(minLength: 4)
                    (Text(Format.rpm(fan.rpm).replacingOccurrences(of: " rpm", with: "")).fontWeight(.semibold).foregroundStyle(Color.primary)
                        + Text(" rpm" + (fan.maxRPM > 0 ? " · \(Format.percent(fan.rpm / fan.maxRPM))" : "")).foregroundStyle(Theme.muted))
                        .lineLimit(1)
                }
                .font(.system(size: 12)).monospacedDigit()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(minHeight: 32)
                .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
            if !s.fans.isEmpty {
                Text("macOS controls the fans; Heron only reads them.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
            }
        }
    }

    @ViewBuilder private var batteryControls: some View {
        // Only what Heron could read: no charge limit on a Mac without a battery or when the
        // charge-limit setting was unreadable.
        if let b = monitor.snapshot.battery, b.present, b.chargeLimit != nil || b.chargeLimitKnown {
            ColumnCaption("Charge limit")
            OptionCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text(b.chargeLimit.map { Format.percent($0) } ?? "Off").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    Text("Set by macOS in System Settings › Battery › Charging")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Open Battery Settings…") { services.openURL(AppServices.batterySettings) }
                        .controlSize(.small)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .padding(.bottom, 14)
        }
        note("Nothing else to set for Battery.")
        SettingsLink(title: "Battery notifications are in Alerts ›") { navigate?(.alerts) }
            .font(.system(size: 12))
            .accessibilityLabel("Open Alerts for battery notifications")
            .padding(.top, 2)
    }
}

/// "CARD STYLE": the small caps over a column of Settings › Overview.
struct ColumnCaption: View {
    var text: String
    var bottom: CGFloat = 6
    init(_ text: String, bottom: CGFloat = 6) { self.text = text; self.bottom = bottom }
    var body: some View { SettingsCaption(text).frame(height: 16).padding(.bottom, bottom) }
}

/// A card of option rows in Settings › Overview's narrow controls column.
struct OptionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
    }
}

/// A title and hint that wrap in the narrow column, the control on the right.
struct OptionRow<Control: View>: View {
    var title: String
    var hint: String
    var first = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
    }
}

/// Moves the dragged section onto the row the pointer enters, so the order follows the drag.
private struct SectionDropDelegate: DropDelegate {
    var target: OverviewPart
    @Binding var dragging: OverviewPart?
    var settings: AppSettings

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            settings.setOverviewOrder(OverviewArrange.move(settings.overviewOrder, from, onto: target))
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Settings › Overview › Sensors › "On the card": the picked temperatures first, numbered in their
/// order, then the rest with a "+". Up to five; the last one cannot be unpicked.
private struct SensorCardPills: View {
    var available: [SensorCardItem]
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let picked = settings.sensorCard
        let rest = available.filter { !picked.contains($0) }
        WrapLayout(spacing: 6) {
            ForEach(picked.filter(available.contains) + rest, id: \.self) { item in
                let order = picked.firstIndex(of: item)
                let full = order == nil && picked.count >= SensorCardItem.limit
                Button {
                    settings.sensorCard = SensorCardItem.toggled(settings.sensorCard, item)
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title).font(.system(size: 12, weight: .medium))
                        Text(order.map { "\($0 + 1)" } ?? "+").font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .opacity(order == nil ? 1 : 0.85)
                            .foregroundStyle(order == nil ? Theme.muted : .white)
                    }
                    .foregroundStyle(order == nil ? (full ? Theme.muted : Color.primary) : .white)
                    .padding(.horizontal, 10).frame(height: 26)
                    // Radius 10, not a capsule: an outlined capsule this size drew stray edges at its ends.
                    .background {
                        if order == nil {
                            RoundedRectangle(cornerRadius: 10).inset(by: 0.5).stroke(Theme.muted.opacity(0.7), lineWidth: 1)
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: NSColor(hex: Theme.Palette.accent)))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(full)
                .help(full ? "Up to 5 temperatures" : order != nil && picked.count == 1 ? "The card keeps at least one temperature" : "")
                .accessibilityLabel(item.title)
                .accessibilityValue(order.map { "\($0 + 1) of \(picked.count)" } ?? "Not shown")
                .accessibilityAddTraits(order == nil ? [] : .isSelected)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperatures on the card")
    }
}

/// Lays its views out in rows, left to right, starting a new row when the next one would not fit.
/// Its one subview drawn at `scale`, taking the scaled size in the layout (a `scaleEffect` keeps
/// the unscaled size, which leaves an empty band under a shrunk card).
struct ScaledLayout: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 / scale }, height: nil))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(ProposedViewSize(width: bounds.width / scale, height: nil))
        view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat
    /// Space between rows; `spacing` when nil.
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, view) in zip(place(subviews, width: bounds.width), subviews) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        var rowStart = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                center(&frames, from: rowStart, height: row)
                x = 0; y += row + (lineSpacing ?? spacing); row = 0; rowStart = frames.count
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; row = max(row, size.height)
        }
        center(&frames, from: rowStart, height: row)
        return frames
    }

    /// Centres a row's views vertically on the row (words beside 28-point pop-up buttons).
    private func center(_ frames: inout [CGRect], from start: Int, height: CGFloat) {
        for i in frames.indices where i >= start { frames[i].origin.y += (height - frames[i].height) / 2 }
    }
}
