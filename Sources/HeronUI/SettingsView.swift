import HeronCore
import SwiftUI

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, menuBar, overview, aiUsage, alerts, updates
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .overview: return "Overview"
        case .aiUsage: return "AI Usage"
        case .alerts: return "Alerts"
        case .updates: return "Updates"
        }
    }
}

/// Where Settings opens: a pane and, for Overview, the section it selects (a panel's "Settings…"
/// opens Settings › Overview on that panel's section).
public struct SettingsRoute: Hashable, Sendable {
    public var pane: SettingsPane
    public var section: OverviewPart
    /// Settings › AI Usage: with an account id, that account's sheet opens over the pane (a panel's "Fix").
    public var account: String?
    public init(_ pane: SettingsPane, section: OverviewPart = .cpu) { self.pane = pane; self.section = section }
    public static func overview(_ part: OverviewPart) -> SettingsRoute { SettingsRoute(.overview, section: part) }
    public static func aiUsage(account: String? = nil) -> SettingsRoute { var r = SettingsRoute(.aiUsage); r.account = account; return r }
    /// Settings › AI Usage with the "Add account" sheet open (the panel's "Add account…", the smoke run).
    public static let aiUsageAdd = aiUsage(account: SettingsRoute.addAccount)
    static let addAccount = "+add"
}

/// The Settings window: a sidebar with a search field and one row per pane, the pane beside it.
public struct SettingsView: View {
    @State private var pane: SettingsPane
    @State private var query: String
    /// The item Settings › Menu Bar opens with selected.
    private let menuBarItem: MenuItemKind
    /// The section Settings › Overview opens with selected, and whether its preview starts on the panel.
    private let section: OverviewPart
    private let showsPanel: Bool
    /// The AI account whose sheet Settings › AI Usage opens with.
    private let aiAccount: String?
    public init(
        pane: SettingsPane = .general, query: String = "", menuBarItem: MenuItemKind = .cpu,
        section: OverviewPart = .cpu, showsPanel: Bool = false, aiAccount: String? = nil
    ) {
        self.aiAccount = aiAccount
        _pane = State(initialValue: pane)
        _query = State(initialValue: query)
        self.menuBarItem = menuBarItem
        self.section = section
        self.showsPanel = showsPanel
    }
    public init(route: SettingsRoute) { self.init(pane: route.pane, section: route.section, aiAccount: route.account) }

    /// The window's size, as in the design.
    public static let size = CGSize(width: 900, height: 700)

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $pane, query: $query)
            SettingsPaneView(pane: pane, menuBarItem: menuBarItem, section: section, showsPanel: showsPanel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.settingsWindow)
        .environment(\.settingsNavigate) { pane = $0 }
        .environment(\.settingsAIAccount, aiAccount)
        .frame(minWidth: Self.size.width, idealWidth: Self.size.width, minHeight: Self.size.height, idealHeight: Self.size.height)
        // The sidebar runs up under the title bar, as in System Settings.
        .ignoresSafeArea()
    }
}

/// One pane's content; also used directly by the snapshot tool.
public struct SettingsPaneView: View {
    public var pane: SettingsPane
    var menuBarItem: MenuItemKind
    var section: OverviewPart
    var showsPanel: Bool
    public init(pane: SettingsPane, menuBarItem: MenuItemKind = .cpu, section: OverviewPart = .cpu, showsPanel: Bool = false) {
        self.pane = pane; self.menuBarItem = menuBarItem; self.section = section; self.showsPanel = showsPanel
    }

    public var body: some View {
        if pane == .overview {
            // Sized to the window: the previews fill the height, cut off with a fade.
            OverviewPane(selected: section, showsPanel: showsPanel)
                .padding(.top, 22).padding(.horizontal, 12).padding(.bottom, 16)
        } else {
            ScrollView {
                content
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: GeneralPane()
        case .menuBar: MenuBarPane(selected: menuBarItem)
        case .overview: OverviewPane(selected: section, showsPanel: showsPanel)
        case .aiUsage: AIUsagePane()
        case .alerts: AlertsPane()
        case .updates: UpdatesPane()
        }
    }
}

// MARK: - General

/// Settings › General: Display, Readings and Startup, each row saying what its choice means on
/// this Mac right now; then Reset, which asks first.
private struct GeneralPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(Monitor.self) private var monitor
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(pane: .general)
            SettingsGroup("Display") {
                SettingsRow(title: "Appearance", subtitle: Self.appearanceHint(settings.appearance), first: true, minHeight: 52) {
                    SettingsSegments(
                        title: "Appearance", selection: $settings.appearance,
                        options: [(.system, "System"), (.light, "Light"), (.dark, "Dark")])
                }
                SettingsRow(title: "Temperature", subtitle: temperatureHint, minHeight: 52) {
                    SettingsSegments(
                        title: "Temperature", selection: $settings.temperatureUnit,
                        options: [(Format.TemperatureUnit.celsius, "°C"), (.fahrenheit, "°F")])
                }
                SettingsRow(
                    title: "Copy picture",
                    subtitle: settings.copyPicture ? "A button on every panel copies it as a picture" : "Off: panels have no Copy picture button", minHeight: 52
                ) {
                    SettingsSwitch(title: "Copy picture", isOn: $settings.copyPicture)
                }
            }
            SettingsGroup("Readings") {
                SettingsRow(title: "Update every", subtitle: Self.intervalHint(settings.interval), first: true, minHeight: 52) {
                    SettingsSegments(title: "Update every", selection: $settings.interval, options: AppSettings.intervals.map { ($0, Self.seconds($0)) })
                }
                SettingsRow(title: "Graphs show the last", subtitle: "In the overview and every panel", minHeight: 52) {
                    SettingsSegments(title: "Graphs show the last", selection: $settings.graphRange, options: AppSettings.GraphRange.allCases.map { ($0, $0.label) })
                }
                SettingsRow(
                    title: "Slow down on low battery",
                    subtitle: settings.slowOnLowBattery ? "Reads every 5 s when on battery below 20%" : "Keeps the same pace on battery", minHeight: 52
                ) {
                    SettingsSwitch(title: "Slow down on low battery", isOn: $settings.slowOnLowBattery)
                }
            }
            SettingsGroup("Startup") {
                SettingsRow(
                    title: "Launch at login",
                    subtitle: services.launchAtLogin ? "Heron starts when you log in" : "Off: you start Heron yourself after each login",
                    first: true, minHeight: 52
                ) {
                    SettingsSwitch(title: "Launch at login", isOn: Binding(get: { services.launchAtLogin }, set: { services.setLaunchAtLogin($0) }))
                }
            }
            SettingsCard {
                SettingsRow(title: "Reset all settings", subtitle: "Puts every setting back to its default. Heron asks before it does.", first: true, minHeight: 52) {
                    Button {
                        confirmReset = true
                    } label: {
                        Text("Reset…").foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(.top, 18)
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { services.resetSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Menu bar items, alerts and every other setting go back to their defaults.")
        }
    }

    /// 0.5 → "0.5 s", 1 → "1 s".
    static func seconds(_ value: Double) -> String { (value == value.rounded() ? String(Int(value)) : String(value)) + " s" }

    static func appearanceHint(_ appearance: AppSettings.Appearance) -> String {
        switch appearance {
        case .system: return "Follows macOS, light or dark"
        case .light: return "Always light"
        case .dark: return "Always dark"
        }
    }

    /// What each reading interval costs and gives.
    static func intervalHint(_ interval: Double) -> String {
        switch interval {
        case ..<1: return "Smoothest graphs; uses the most energy"
        case ..<2: return "A good balance of detail and energy"
        case ..<5: return "Lighter on energy"
        default: return "Lightest; graphs move in steps"
        }
    }

    /// "CPU is at 79 °C right now", in the unit picked; without a CPU reading, what the unit is for.
    private var temperatureHint: String {
        guard let celsius = SensorSummary.value(.cpu, in: monitor.snapshot) else { return "For every temperature Heron shows" }
        let unit = settings.temperatureUnit
        return "CPU is at \(Int(Format.converted(celsius, to: unit).rounded())) \(unit == .celsius ? "°C" : "°F") right now"
    }
}
