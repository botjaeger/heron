import AppKit
import HeronCore
import SwiftUI

// The Settings window's building blocks, from the Settings design canvas: the sidebar with its
// search, the pane header, captioned cards of rows, the notification banner.

// MARK: - Panes: look, search and the settings each one holds

extension SettingsPane {
    /// The pane's glyph: the same icons as the popover.
    var icon: HeronIcon {
        switch self {
        case .general: return .general
        case .menuBar: return .menuBar
        case .overview: return .overview
        case .aiUsage: return .ai
        case .alerts: return .alerts
        case .updates: return .updates
        }
    }

    /// The tile behind the glyph (the same in light and dark mode, like System Settings).
    var tileHex: UInt32 {
        switch self {
        case .general: return 0x8E8E93
        case .menuBar: return 0x5E5CE6
        case .overview: return 0x3D45A8
        case .aiUsage: return 0xC2408F
        case .alerts: return 0xE0453A
        case .updates: return Theme.Palette.accent
        }
    }

    /// The line under the pane's title.
    var subtitle: String {
        switch self {
        case .general: return "How Heron looks, how often it reads your Mac, and when it starts."
        case .menuBar: return "The one Heron item: what it shows, in which order, and how it looks."
        case .overview: return "The sections of the popover, in order. Select one to set it up."
        case .aiUsage: return "Your AI coding plans: accounts, how usage shows, and when to warn."
        case .alerts: return "Every notification Heron can send, in one list."
        case .updates: return "How Heron keeps itself up to date."
        }
    }

    /// The panes the sidebar lists. About is the About window, opened from the sidebar's footer.
    public static let sidebar: [SettingsPane] = [.general, .menuBar, .overview, .aiUsage, .alerts, .updates]

    /// The names of the options the pane shows, so searching for one finds its pane.
    public var searchTerms: [String] {
        switch self {
        case .general:
            return [
                "Launch at login", "Appearance", "Light", "Dark", "Temperature", "Celsius", "Fahrenheit", "°C", "°F",
                "Update every", "Interval", "Graphs show the last", "Graph history", "Slow down on low battery", "Reset all settings",
            ]
        case .menuBar:
            return [
                "Heron icon", "Colour", "Monochrome", "Metric", "Spacing", "Compact", "Wide", "Red warnings",
                "Items", "Shows as", "Order", "Label above the bar", "Show the label", "Show which sensor", "Hottest",
                "Units", "Bytes", "Bits",
                "AI usage", "Most urgent", "Chosen limits", "How many", "Icon only", "Always show", "Providers as",
                "Show the limit’s name", "Show the limit's name",
            ]
        case .overview:
            return [
                "Popover", "Sections", "Order", "Hide", "Show", "Restore defaults", "Card style", "Panel",
                "CPU", "GPU", "Memory", "Network", "Disk", "Sensors", "Battery", "Fans", "Fan speed",
                "Bars", "Graph", "Ring", "Rings", "Numbers", "Mirrored",
                "Show logical cores", "Show top processes", "Units", "Bytes", "Bits", "Public IP look-up",
                "Hide disk images", "On the card", "Temperatures", "Name the hottest", "Hide unnamed",
                "Charge limit", "Open Battery Settings",
            ]
        case .aiUsage:
            return [
                "Accounts", "Add account", "Sign in", "Browser sign-in", "Device code", "Claude", "ChatGPT", "Codex", "OpenCode", "Claude Code",
                "Show usage as", "Left", "Used", "Reset times", "Pace marks", "Providers as", "Logo", "Name",
                "Thresholds", "Warning", "Critical",
                "Burning fast", "Use it or lose it", "Notify", "Privacy Mode", "Global shortcut", "Command line",
            ]
        case .alerts:
            return [
                "Rules", "Notifications", "Add rule", "Limit repeats", "Repeat", "Battery low", "Battery health",
                "Play a sound", "Open System Settings",
            ]
        case .updates:
            return [
                "Check for updates automatically", "Install updates automatically", "Channel", "Stable", "Beta",
                "Check Now", "What’s New", "What's New", "Version",
            ]
        }
    }

    /// The AppSettings keys the pane has a control for. Every user-facing key is in exactly one
    /// list or more (a guard test checks this against `AppSettings.keys`).
    public var keys: [String] {
        switch self {
        case .general: return ["appearance", "temperatureUnit", "interval", "graphRange", "slowOnLowBattery"]
        case .menuBar: return ["menuItems", "showIcon", "colourMode", "spacing", "warnRed", "networkInBits", "aiUsage"]
        case .overview:
            return [
                "overviewOrder", "hiddenSections", "cardStyles", "showCores", "showCPUProcesses", "showMemoryProcesses", "networkInBits",
                "showPublicIP", "hideDiskImages", "sensorCard", "sensorCardFans", "nameHottest", "hideUnknownSensors",
            ]
        case .aiUsage: return ["aiUsage"]
        case .alerts: return ["alertRules", "alertCooldown"]
        case .updates: return ["betaUpdates"]
        }
    }

    /// Stored keys with no control: first-run and changelog state, which Heron keeps for itself.
    public static let internalKeys = ["onboardingDone", "lastSeenVersion"]

    /// The panes the sidebar lists for a search: every pane for an empty query, otherwise those
    /// whose title or one of whose options contains the query (ignoring case), in pane order.
    public static func matching(_ query: String) -> [SettingsPane] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sidebar }
        return allCases.filter { pane in
            ([pane.title] + pane.searchTerms).contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// The overview order as Settings › Overview edits it (and the menu bar order Settings › Menu Bar
/// edits): drag one onto another, or step it up and down. Pure, so the tests can check it.
enum OverviewArrange {
    /// `part` takes `target`'s place; the sections in between shift by one. Dragging down past a
    /// section and up past one both work, as the pointer enters each row.
    static func move<Part: Equatable>(_ order: [Part], _ part: Part, onto target: Part) -> [Part] {
        guard part != target, let to = order.firstIndex(of: target), order.contains(part) else { return order }
        var result = order.filter { $0 != part }
        result.insert(part, at: min(to, result.count))
        return result
    }

    /// One place up (-1) or down (+1); at either end nothing changes.
    static func step<Part: Equatable>(_ order: [Part], _ part: Part, by offset: Int) -> [Part] {
        guard let i = order.firstIndex(of: part), order.indices.contains(i + offset) else { return order }
        var result = order
        result.swapAt(i, i + offset)
        return result
    }
}

// MARK: - Navigation

private struct SettingsNavigateKey: EnvironmentKey {
    static var defaultValue: ((SettingsPane) -> Void)? { nil }
}

extension EnvironmentValues {
    /// Switches the Settings window to another pane ("Battery notifications are in Alerts ›"). Nil outside the window.
    var settingsNavigate: ((SettingsPane) -> Void)? {
        get { self[SettingsNavigateKey.self] }
        set { self[SettingsNavigateKey.self] = newValue }
    }
}

// MARK: - Sidebar

/// The pane's glyph in white on its coloured tile.
struct SettingsTile: View {
    var pane: SettingsPane
    var size: CGFloat

    var body: some View {
        let big = size >= 30
        let shape = RoundedRectangle(cornerRadius: size / 4)
        shape.fill(Color(nsColor: NSColor(hex: pane.tileHex)))
            .overlay(shape.strokeBorder(Color.white.opacity(big ? 0.2 : 0.18), lineWidth: 0.5))
            .overlay(HeronIconView(pane.icon, size: size * (big ? 0.6 : 0.65), weight: big ? 1.9 : 2.2).foregroundStyle(.white))
            .frame(width: size, height: size)
            .compositingGroup()
            .shadow(color: .black.opacity(big ? 0.3 : 0), radius: 3, y: 2)
            .accessibilityHidden(true)
    }
}

/// The search field, one row per pane with the selected one highlighted, and the footer
/// "Heron 1.0.0 · About" that opens the About window.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    @Binding var query: String
    @FocusState private var searching: Bool
    @Environment(AppServices.self) private var services

    static let width: CGFloat = 200

    var body: some View {
        let shown = SettingsPane.matching(query)
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 52)
            searchField.padding(.horizontal, 12)
            Color.clear.frame(height: 14)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { row($0) }
            }
            .padding(.horizontal, 8)
            if shown.isEmpty {
                Text("No settings match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.settingsSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.settingsLine).frame(width: 1) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            HeronIconView(.search, size: 14, weight: 2).foregroundStyle(Theme.muted)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .accessibilityLabel("Search settings")
                // Return opens the first pane that matches.
                .onSubmit { if let first = SettingsPane.matching(query).first { selection = first } }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.settingsPreview, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searching ? Color.accentColor : Theme.settingsLine, lineWidth: searching ? 2 : 1))
    }

    private func row(_ pane: SettingsPane) -> some View {
        let on = pane == selection
        return Button {
            selection = pane
        } label: {
            HStack(spacing: 9) {
                SettingsTile(pane: pane, size: 20)
                Text(pane.title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(on ? Theme.settingsSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The version, and About: the About window is its one home.
    private var footer: some View {
        HStack(spacing: 6) {
            Text("Heron \(services.appVersion)").monospacedDigit()
            Text("·").accessibilityHidden(true)
            SettingsLink(title: "About") { services.showAbout() }
                .accessibilityLabel("About Heron")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
    }
}

// MARK: - Pane parts

/// The pane's tile, title and the line under it.
struct PaneHeader: View {
    var pane: SettingsPane
    var body: some View {
        HStack(spacing: 12) {
            SettingsTile(pane: pane, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(.system(size: 20, weight: .bold)).tracking(-0.2)
                Text(pane.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded group of rows, a line between each.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
    }
}

/// A title (and a note under it) on the left, a control on the right. Every row but the first
/// in its card draws the line above it.
struct SettingsRow<Control: View>: View {
    var title: String
    var subtitle: String?
    var first = false
    var minHeight: CGFloat = 44
    /// The control on its own line under the text: a wide control next to a long note would
    /// squeeze the note into a narrow column.
    var stacked = false
    /// Extra room on the left for a row that depends on the one above it (Install needs Check).
    var indent: CGFloat = 0
    @ViewBuilder var control: Control

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).fixedSize()
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            if !stacked { Spacer(minLength: 8) }
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14 + indent).padding(.trailing, 14).padding(.vertical, 8)
        .frame(minHeight: minHeight)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
    }
}

/// A switch whose spoken name is the row's title.
struct SettingsSwitch: View {
    var title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().accessibilityLabel(title)
    }
}

/// A segmented control sized to its segments.
struct SettingsSegments<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(Value, String)]
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.1).tag(option.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A segmented control whose segments are as wide as their words (the native one makes every
/// segment as wide as the widest): Settings › Menu Bar's one-row Appearance needs the room.
/// `fill`: the segments share the width they are given (Settings › Overview's Card | Panel).
struct CompactSegments<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(Value, String)]
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1).font(.system(size: fill ? 12 : 11, weight: .medium)).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, fill ? 3 : 2)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .background(on ? Theme.settingsSegment : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.settingsPreview, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.settingsLine, lineWidth: 1))
        .fixedSize(horizontal: !fill, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// "PREVIEW · CPU PANEL": a small caption in capitals.
struct SettingsCaption: View {
    var text: String
    var size: CGFloat = 11
    init(_ text: String, size: CGFloat = 11) { self.text = text; self.size = size }
    var body: some View {
        Text(text.uppercased()).font(.system(size: size, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
    }
}

/// "DISPLAY" over a card of rows: a group in a Settings pane.
struct SettingsGroup<Content: View>: View {
    var title: String
    var top: CGFloat = 18
    @ViewBuilder var content: Content
    init(_ title: String, top: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.title = title; self.top = top; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(title)
            SettingsCard { content }
        }
        .padding(.top, top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A link in the CPU colour: "Battery notifications are in Alerts ›".
struct SettingsLink: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).foregroundStyle(Theme.cpu).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
    }
}

/// A notification as macOS shows it: the Heron icon, a bold title and "now", the text under it.
struct NotificationBanner: View {
    var title: String
    var message: String
    var width: CGFloat? = 340

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HeronMark(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("now").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Text(message).font(.system(size: 12)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(Theme.settingsSelection, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.settingsLine, lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 9, y: 4)
        .accessibilityElement(children: .combine)
    }
}
