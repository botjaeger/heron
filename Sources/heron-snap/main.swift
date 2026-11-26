import AppKit
import HeronCore
import HeronUI
import SwiftUI
import UniformTypeIdentifiers

// Renders every Heron screen to PNG, in light and dark mode, using live readings.
// Usage:  swift run heron-snap <output-folder>
// Views are hosted in an off-screen window (not ImageRenderer) so AppKit controls such as
// toggles and pickers draw properly.

// `swift run heron-snap --icon packaging/AppIcon.icns` writes the app icon instead.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--icon" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    MainActor.assumeIsolated {
        let pixels = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, pixels.count, nil) else {
            print("could not create", url.path); exit(1)
        }
        for size in pixels {
            let s = CGFloat(size)
            // macOS icons leave a margin around the tile (about 10% on each side).
            let renderer = ImageRenderer(content: HeronMark(size: s * 0.8).frame(width: s, height: s))
            renderer.scale = 1
            if let cg = renderer.cgImage { CGImageDestinationAddImage(destination, cg, nil) }
        }
        print(CGImageDestinationFinalize(destination) ? "wrote \(url.path)" : "failed to write \(url.path)")
    }
    exit(0)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "snapshots")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let monitor = Monitor()
let settings = AppSettings(defaults: UserDefaults(suiteName: "app.heron.snap")!)
settings.showPublicIP = true
let services = AppServices()
services.updaterAvailable = true
services.lastUpdateCheck = Date()
services.lastCheckFoundNothing = true
// The hover panels' state: history rows are clickable, and the renders below open panels and histories.
let panels = DetailPanels()
// AI usage with no account (the renders above as before; the AI renders bring their own preview
// accounts): no network, no Keychain; its defaults suite is removed at the end.
let aiSuite = "app.heron.snap.ai"
let ai = MainActor.assumeIsolated { AIUsageService(defaults: UserDefaults(suiteName: aiSuite)!, tokens: MemoryTokenStore()) }

monitor.start()
// Collect a few samples so rates, graphs and top processes have data.
RunLoop.main.run(until: Date().addingTimeInterval(6))

@MainActor
func render<V: View>(_ view: V, _ name: String, width: CGFloat? = nil, height: CGFloat? = nil) {
    for (mode, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
        let root =
            view
            .environment(monitor).environment(settings).environment(services).environment(ai).environment(panels)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearanceName)
        let fitting = host.fittingSize
        let size = NSSize(width: width ?? fitting.width, height: height ?? fitting.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = output.appendingPathComponent("\(name)-\(mode).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote", url.path, Int(size.width), "x", Int(size.height))
    }
}

/// What a panel's "Copy picture" puts on the pasteboard, in dark and light.
@MainActor
func renderPicture(_ kind: PopoverKind, settings: AppSettings, ai: AIUsageService, _ name: String) {
    for dark in [true, false] {
        guard let image = PopoverView.pictureImage(kind, monitor: monitor, settings: settings, services: services, ai: ai, dark: dark),
            let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { continue }
        let url = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try? png.write(to: url)
        print("wrote", url.path, Int(image.size.width), "x", Int(image.size.height))
    }
}

/// One menu bar item as the status bar shows it, in the light or dark mode it is rendered in.
struct MenuBarRow: View {
    var settings: AppSettings
    var snapshot: Snapshot
    var history: MetricHistory
    var updateWaiting = false
    @Environment(\.colorScheme) private var scheme
    private var label: MenuBarLabel {
        let dark = scheme == .dark
        var label = MenuBarLabel(snapshot: snapshot, history: history, settings: settings, ink: dark ? .white : .black, dark: dark)
        label.updateWaiting = updateWaiting
        return label
    }
    var body: some View {
        let image = MenuBarRenderer.image(for: label)
        Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original).foregroundStyle(.primary)
    }
}
var menuBarSuites: [String] = []

MainActor.assumeIsolated {
    for kind in PopoverKind.allCases { render(PopoverView(kind: kind), "popover-\(kind.rawValue)") }
    // The overview in every card style: second style of each card, then third and fourth where there is one.
    for (index, name) in [(1, "alt"), (2, "alt2"), (3, "alt3")] {
        for card in OverviewCard.allCases { settings.setCardStyle(card, card.styles[min(index, card.styles.count - 1)]) }
        render(PopoverView(kind: .overview), "popover-overview-\(name)")
    }
    settings.cardStyles = [:]
    // A custom order with a hidden section (Settings › Overview).
    settings.setOverviewOrder([.sensors, .battery, .memory, .cpu, .network, .gpu, .disk])
    settings.setHidden(.network, true)
    render(PopoverView(kind: .overview), "popover-overview-order-hidden")
    // A short screen: the cards scroll between the fixed header and footer.
    panels.popoverMaxHeight = 480
    render(PopoverRoot(), "popover-overview-capped")
    panels.popoverMaxHeight = nil
    settings.setOverviewOrder(OverviewPart.allCases)
    settings.setHidden(.network, false)
    // Edge cases: a hot CPU, critical pressure without a number, a battery held at a charge limit.
    var edge = monitor.snapshot
    for i in edge.sensors.indices where edge.sensors[i].isKnown && [.cpu, .cpuPerformance, .cpuEfficiency].contains(edge.sensors[i].group) {
        edge.sensors[i].celsius = 96
    }
    edge.memory?.pressure = .critical
    edge.memory?.pressurePercent = nil
    if var battery = edge.battery {
        battery.present = true; battery.isCharging = false; battery.onAC = true; battery.percent = 0.8; battery.chargeLimit = 0.8
        edge.battery = battery
    }
    render(PopoverView(kind: .overview, snapshot: edge), "popover-overview-edge")
    // The warning board: a hot CPU and critical pressure with its number (red pill "+1", red
    // borders, "Top:" lines); and pressure at Warning alone (amber pill and chip).
    var warning = edge
    warning.memory?.pressurePercent = 0.92
    render(PopoverView(kind: .overview, snapshot: warning), "popover-overview-warning")
    panels.openNow(.memory)
    render(PopoverView(kind: .memory, snapshot: warning), "panel-memory-critical")
    panels.closeAll()
    var caution = monitor.snapshot
    caution.memory?.pressure = .warning
    caution.memory?.pressurePercent = 0.61
    render(PopoverView(kind: .overview, snapshot: caution), "popover-overview-caution")
    // Launch, before the readings (`Snapshot.awaitingReadings`): each card its title alone, at its
    // full size; no status pill, no number.
    var awaiting = monitor.snapshot
    awaiting.awaitingReadings = true
    render(PopoverView(kind: .overview, snapshot: awaiting), "popover-overview-awaiting")
    panels.openNow(.memory)
    render(PopoverView(kind: .memory, snapshot: caution), "panel-memory-warning")
    panels.closeAll()

    // Adversarial: °F, ten fans, very long process and fan names, huge rates, a full disk, no battery.
    var wild = monitor.snapshot
    if let fan = wild.fans.first {
        wild.fans = (0..<10).map { i in
            var f = fan
            f.id = 100 + i; f.name = i == 0 ? "Left exhaust fan behind the display hinge" : "Fan \(i + 1)"; f.rpm = 7_400
            return f
        }
    }
    for i in wild.topCPU.indices { wild.topCPU[i].name = "com.example.AVeryLongHelperProcessNameThatNeverEnds.XPCService.\(i)" }
    for i in wild.topMemory.indices { wild.topMemory[i].name = "Another Exceedingly Long Application Name (Renderer) \(i)" }
    wild.network?.downBytesPerSecond = 1_234_000_000
    wild.network?.upBytesPerSecond = 987_000_000
    wild.disk?.readBytesPerSecond = 7_654_000_000
    if var disk = wild.disk, let i = disk.volumes.firstIndex(where: \.isRoot) {
        disk.volumes[i].available = 2_000_000_000
        disk.volumes[i].name = "Macintosh HD with a long volume name"
        wild.disk = disk
    }
    for i in wild.sensors.indices where wild.sensors[i].isKnown { wild.sensors[i].celsius = 104 }
    wild.battery?.present = false
    settings.temperatureUnit = .fahrenheit
    render(PopoverView(kind: .overview, snapshot: wild), "wild-overview")
    for kind in [PopoverKind.sensors, .disk, .network, .cpu, .memory, .battery] {
        render(PopoverView(kind: kind, snapshot: wild), "wild-panel-\(kind.rawValue)")
    }
    settings.temperatureUnit = .celsius

    // Hover panels, each at its real width as the panel window shows it: once per style of its
    // overview card (the panel's main chart follows it), sections without styles once.
    panels.openNow(.cpu)
    render(PopoverView(kind: .overview), "popover-overview-open")
    for part in OverviewPart.allCases {
        panels.openNow(part)
        if let card = OverviewCard(rawValue: part.rawValue) {
            for style in card.styles {
                settings.setCardStyle(card, style)
                render(PopoverView(kind: PopoverKind(part)), "panel-\(part.rawValue)-\(style.rawValue)")
            }
        } else {
            render(PopoverView(kind: PopoverKind(part)), "panel-\(part.rawValue)")
        }
    }
    // What each panel's "Copy picture" puts on the pasteboard (drawn by ImageRenderer, not a window).
    // (The AI usage panel's, with its fixture accounts: `renderAIPanel`.)
    for kind in PopoverKind.allCases where kind != .overview && kind != .ai {
        renderPicture(kind, settings: settings, ai: ai, "picture-\(kind.rawValue)")
    }
    settings.cardStyles = [:]
    panels.openNow(.battery)
    render(PopoverView(kind: .battery, snapshot: edge), "panel-battery-limit")
    // A row's history (its own panel beside the open one), once per range; and a row kept at
    // falling resolution (`TieredHistory`).
    panels.openNow(.network)
    let download = HistoryItem(part: .network, metric: .networkDown, title: "Download", unit: .networkRate, color: Theme.network)
    panels.showHistory(download)
    for range in AppSettings.GraphRange.allCases {
        panels.historyRange = range
        render(HistoryPage(item: download), "panel-history-download-\(range.rawValue)s")
    }
    // The pointer on the chart, 60% across: the crosshair and its readout.
    panels.historyRange = .oneMinute
    panels.historyHover = 0.6
    render(HistoryPage(item: download), "panel-history-download-hover")
    panels.historyHover = nil
    panels.openNow(.cpu)
    let cpuTemperature = HistoryItem(part: .cpu, metric: .cpuTemperature, title: "CPU temperature", unit: .temperature, color: Theme.warning)
    panels.showHistory(cpuTemperature)
    panels.historyRange = .oneMinute
    render(HistoryPage(item: cpuTemperature), "panel-history-cpu-temperature-60s")
    // The panel while that history is open: its row stays lit, like a menu item with its submenu.
    render(PopoverView(kind: .cpu), "panel-cpu-history-open")
    panels.closeAll()
    // Settings, every pane at the window's size. Then Overview with a custom order and a hidden
    // section (the last one moved outlined is not shown: that is per-window state), a search that
    // filters the sidebar, and one that matches nothing.
    let settingsSize = SettingsView.size
    // The design's sample menu bar: three bars, the hottest sensor, free disk space.
    for kind in [MenuItemKind.cpu, .gpu, .memory, .temperature, .disk] { settings.setShown(kind, true) }
    for pane in SettingsPane.allCases {
        render(SettingsView(pane: pane), "settings-\(pane.rawValue)", width: settingsSize.width, height: settingsSize.height)
    }
    // Settings › Overview: each section selected, with its card and with its panel.
    for part in OverviewPart.allCases {
        render(SettingsView(pane: .overview, section: part), "settings-overview-\(part.rawValue)-card", width: settingsSize.width, height: settingsSize.height)
        render(SettingsView(pane: .overview, section: part, showsPanel: true), "settings-overview-\(part.rawValue)-panel", width: settingsSize.width, height: settingsSize.height)
    }
    settings.setOverviewOrder([.cpu, .memory, .gpu, .network, .disk, .sensors, .battery])
    settings.setHidden(.disk, true)
    render(SettingsView(pane: .overview, section: .disk), "settings-overview-hidden", width: settingsSize.width, height: settingsSize.height)
    render(SettingsView(pane: .overview, section: .gpu), "settings-overview-moved", width: settingsSize.width, height: settingsSize.height)
    settings.setOverviewOrder(OverviewPart.allCases)
    settings.setHidden(.disk, false)
    // Mirrored bars: the Network and Disk sections with their card and panel in that style.
    settings.setCardStyle(.network, .mirrored); settings.setCardStyle(.disk, .mirrored)
    render(SettingsView(pane: .overview, section: .network, showsPanel: true), "settings-overview-network-mirrored", width: settingsSize.width, height: settingsSize.height)
    render(SettingsView(pane: .overview, section: .disk), "settings-overview-disk-mirrored", width: settingsSize.width, height: settingsSize.height)
    settings.cardStyles = [:]
    // The Sensors card with five temperatures, no fan speed and the hottest sensor named.
    settings.sensorCard = Array(SensorSummary.cardItems(in: monitor.snapshot).prefix(SensorCardItem.limit))
    settings.sensorCardFans = false
    settings.nameHottest = true
    render(PopoverView(kind: .overview), "popover-overview-sensors-five-named")
    render(SettingsView(pane: .overview, section: .sensors), "settings-overview-sensors-five-named", width: settingsSize.width, height: settingsSize.height)
    // Alerts: notifications turned off, and never asked; a rule that is off selected first.
    services.notificationPermission = .denied
    render(SettingsView(pane: .alerts), "settings-alerts-denied", width: settingsSize.width, height: settingsSize.height)
    services.notificationPermission = .notAsked
    settings.alertRules = [AlertRule.defaults[4]] + AlertRule.defaults.prefix(4)
    render(SettingsView(pane: .alerts), "settings-alerts-not-asked-off-rule", width: settingsSize.width, height: settingsSize.height)
    settings.alertRules = AlertRule.defaults
    services.notificationPermission = .allowed
    // Updates: checks off (installing off and disabled), checking now, and a build without Sparkle.
    services.automaticallyChecksForUpdates = false
    render(SettingsView(pane: .updates), "settings-updates-checks-off", width: settingsSize.width, height: settingsSize.height)
    services.automaticallyChecksForUpdates = true
    services.automaticallyDownloadsUpdates = true
    services.checkingForUpdates = true
    render(SettingsView(pane: .updates), "settings-updates-checking-installs", width: settingsSize.width, height: settingsSize.height)
    services.checkingForUpdates = false
    services.automaticallyDownloadsUpdates = false
    services.lastCheckFoundNothing = false
    services.lastUpdateCheck = Date().addingTimeInterval(-86_400 * 3)
    render(SettingsView(pane: .updates), "settings-updates-last-checked", width: settingsSize.width, height: settingsSize.height)
    services.updaterAvailable = false
    render(SettingsView(pane: .updates), "settings-updates-off-in-build", width: settingsSize.width, height: settingsSize.height)
    services.updaterAvailable = true
    services.lastCheckFoundNothing = true
    services.lastUpdateCheck = Date()
    // An update through its states (`UpdateState`): Settings › Updates, the update window, the
    // overview's strip, About and the menu bar dot. The notes are the 1.0.0 entry's, as the feed
    // carries them; version, size and date are an example.
    let offer = UpdateOffer(
        version: "1.1.0", size: 4_485_730, date: Date(timeIntervalSince1970: 1_796_342_400),
        notes: ReleaseNotes.parse(ReleaseNotes.html(for: Changelog.entries[0].version) ?? ""))
    let updateStates: [(String, UpdateState)] = [
        ("available", .available(offer)), ("downloading", .downloading(offer, received: 2_900_000, expected: 4_485_730)),
        ("ready", .ready(offer)), ("failed", .failed("The network connection was lost.")),
    ]
    for (name, state) in updateStates {
        services.update = state
        render(SettingsView(pane: .updates), "settings-updates-\(name)", width: settingsSize.width, height: settingsSize.height)
        if state.offer != nil { render(UpdateView(), "update-window-\(name)") }
    }
    services.update = .available(offer)
    render(PopoverView(kind: .overview), "popover-overview-update")
    render(AboutView(), "about-update")
    render(MenuBarRow(settings: settings, snapshot: monitor.snapshot, history: monitor.history, updateWaiting: true).padding(6), "menubar-update")
    services.update = .ready(offer)
    render(PopoverView(kind: .overview), "popover-overview-update-ready")
    services.update = .idle
    // Settings › Menu Bar with each item selected (Temperature: the design's second board); then
    // CPU without its label, a hidden item selected, and metric colours.
    for kind in MenuItemKind.allCases where kind != .cpu {
        render(SettingsView(pane: .menuBar, menuBarItem: kind), "settings-menubar-\(kind.rawValue)", width: settingsSize.width, height: settingsSize.height)
    }
    settings.setLabel(.cpu, false)
    render(SettingsView(pane: .menuBar), "settings-menubar-cpu-no-label", width: settingsSize.width, height: settingsSize.height)
    settings.setLabel(.cpu, true)
    settings.colourMode = .metric
    render(SettingsView(pane: .menuBar, menuBarItem: .fans), "settings-menubar-fans-hidden-metric", width: settingsSize.width, height: settingsSize.height)
    settings.colourMode = .monochrome
    settings.sensorCard = SensorCardItem.defaults; settings.sensorCardFans = true; settings.nameHottest = false
    render(SettingsView(pane: .menuBar, query: "spac"), "settings-search-spacing", width: settingsSize.width, height: settingsSize.height)
    render(SettingsView(pane: .general, query: "zzz"), "settings-search-none", width: settingsSize.width, height: settingsSize.height)
    // Larger than the minimum, and °F with red on (the Menu Bar caption names the unit).
    settings.temperatureUnit = .fahrenheit
    render(SettingsView(pane: .menuBar), "settings-menubar-large-fahrenheit", width: 1200, height: 900)
    render(SettingsView(pane: .general), "settings-general-fahrenheit", width: settingsSize.width, height: settingsSize.height)
    settings.temperatureUnit = .celsius
    // The first run: welcome; the items all ticked (as "Continue" leaves them), the design's
    // sample, an item wide enough for the notch advice, and none (the icon alone); the alerts with
    // their rules on, and with every rule off ("Finish", no "Not now").
    render(OnboardingView(), "onboarding")
    for kind in MenuItemKind.allCases { settings.setShown(kind, true) }
    render(OnboardingView(step: 1), "onboarding-items")
    settings.spacing = .wide
    settings.setStyle(.memory, .usedGB)
    render(OnboardingView(step: 1), "onboarding-items-notch")
    settings.spacing = .regular
    settings.setStyle(.memory, .bar)
    for kind in MenuItemKind.allCases { settings.setShown(kind, [.cpu, .gpu, .memory, .temperature].contains(kind)) }
    render(OnboardingView(step: 1), "onboarding-items-sample")
    for kind in MenuItemKind.allCases { settings.setShown(kind, false) }
    render(OnboardingView(step: 1), "onboarding-items-none")
    render(OnboardingView(step: 2), "onboarding-alerts")
    settings.alertRules = AlertRule.defaults.map {
        var r = $0; r.enabled = false; return r
    }
    render(OnboardingView(step: 2), "onboarding-alerts-off")
    settings.alertRules = AlertRule.defaults
    render(ChangelogView(), "changelog")
    // About: up to date (checked just now), last checked days ago, a build without Sparkle; and
    // its Acknowledgements sheet.
    render(AboutView(), "about")
    services.lastCheckFoundNothing = false
    services.lastUpdateCheck = Date().addingTimeInterval(-86_400 * 3)
    render(AboutView(), "about-last-checked")
    services.updaterAvailable = false
    render(AboutView(), "about-updates-off")
    services.updaterAvailable = true
    services.lastCheckFoundNothing = true
    services.lastUpdateCheck = Date()
    render(AboutView(noticesOnly: true), "about-acknowledgements")
    // The card's "…" menu drawn open; the CPU panel with every core at 100% (the legend keeps
    // "10 Performance 100%" whole); the new histories: GPU renderer and swap.
    render(PopoverView(kind: .overview, debugMenu: .cpu), "popover-overview-card-menu")
    var busy = monitor.snapshot
    if var cpu = busy.cpu {
        for i in cpu.cores.indices { cpu.cores[i].load = 1 }
        cpu.user = 0.7; cpu.system = 0.3; cpu.idle = 0
        busy.cpu = cpu
    }
    panels.openNow(.cpu)
    render(PopoverView(kind: .cpu, snapshot: busy), "panel-cpu-full-load")
    panels.openNow(.gpu)
    let renderer = HistoryItem(part: .gpu, metric: .gpuRenderer, title: "GPU renderer", unit: .percent, color: Theme.gpu)
    panels.showHistory(renderer)
    panels.historyRange = .oneMinute
    render(HistoryPage(item: renderer), "panel-history-gpu-renderer")
    panels.openNow(.memory)
    let swap = HistoryItem(part: .memory, metric: .swapUsed, title: "Swap used", unit: .bytes, color: Theme.memory)
    panels.showHistory(swap)
    render(HistoryPage(item: swap), "panel-history-swap")
    panels.closeAll()
    render(AlertRuleEditor(rule: AlertRule.defaults[0], onSave: { _ in }, onDelete: { _ in }), "sheet-alert-rule")
    render(AlertRuleEditor(rule: AlertRule.defaults[1], onSave: { _ in }, onDelete: { _ in }), "sheet-alert-rule-pressure")
    render(AlertRuleEditor(rule: AlertRule(subject: .diskFreeGB, comparison: .below, threshold: 10, seconds: 60), onSave: { _ in }, onDelete: nil), "sheet-alert-rule-new-disk")
    render(AlertRuleEditor(rule: AlertRule.defaults[0], unit: .fahrenheit, onSave: { _ in }, onDelete: nil), "sheet-alert-rule-new-fahrenheit")

    // Menu bar: the one Heron item in every configuration, drawn the way the status bar draws it
    // (a template image tinted by the menu bar; with warning red or metric colours, the menu bar's
    // own ink and the colours for that menu bar). Row 1: icon alone (the default). Then labelled
    // bars, every variant of every metric, then each appearance option. Each row has its own
    // settings, removed at the end.
    var rows: [(String, MenuBarRow)] = []
    @MainActor func row(_ name: String, snapshot: Snapshot = monitor.snapshot, _ configure: (AppSettings) -> Void) {
        let suite = "app.heron.snap.menubar.\(rows.count)"
        menuBarSuites.append(suite)
        let s = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        configure(s)
        rows.append((name, MenuBarRow(settings: s, snapshot: snapshot, history: monitor.history)))
    }
    // The design's sample set: three bars, the hottest sensor, free disk space.
    @MainActor func sample(_ s: AppSettings) {
        for k in [MenuItemKind.cpu, .gpu, .memory, .temperature, .disk] { s.setShown(k, true) }
    }
    var hot = monitor.snapshot
    // Heat the known sensors (readings' initialisers are internal to HeronCore, so edit live ones).
    for i in hot.sensors.indices where hot.sensors[i].isKnown { hot.sensors[i].celsius = max(hot.sensors[i].celsius, 95) }
    if var disk = hot.disk, let i = disk.volumes.firstIndex(where: \.isRoot) {
        disk.volumes[i].available = 6_000_000_000
        hot.disk = disk
    }
    var limited = monitor.snapshot
    if var battery = limited.battery {
        battery.present = true
        battery.chargeLimit = 0.8
        limited.battery = battery
    }
    var wordy = monitor.snapshot
    wordy.memory?.pressurePercent = nil

    row("icon") { _ in }
    row("bars") { s in
        for k in [MenuItemKind.cpu, .gpu, .memory] { s.setShown(k, true); s.setStyle(k, .bar) }
        s.setShown(.temperature, true)
    }
    for kind in MenuItemKind.allCases {
        for style in kind.styles {
            row("\(kind.rawValue)-\(style.rawValue)") { s in
                s.setShown(kind, true); s.setStyle(kind, style)
            }
        }
    }
    row("memory-pressure (level word)", snapshot: wordy) { s in
        s.setShown(.memory, true); s.setStyle(.memory, .pressure)
    }
    row("battery-icon (charge limit)", snapshot: limited) { s in
        s.setShown(.battery, true); s.setStyle(.battery, .icon)
    }
    row("battery-both (charge limit)", snapshot: limited) { s in s.setShown(.battery, true) }
    row("sample") { sample($0) }
    row("metric colours") { s in
        for k in MenuItemKind.allCases { s.setShown(k, true) }; s.colourMode = .metric
    }
    // Labels are per item: the bars and the hottest sensor without theirs, then every tagged look
    // with and without its tag. "Name the hottest sensor" changes the Sensors card only, never the bar.
    row("labels off: bars, hottest") { s in
        sample(s); for k in [MenuItemKind.cpu, .gpu, .memory, .temperature] { s.setLabel(k, false) }
    }
    row("labels off: CPU bar only") { s in
        sample(s); s.setLabel(.cpu, false)
    }
    row("tagged looks") { s in
        for k in MenuItemKind.allCases { s.setShown(k, true) }; s.setStyle(.cpu, .text); s.setStyle(.memory, .pressure); s.setStyle(.fans, .percent); s.setStyle(.disk, .percent)
    }
    row("tagged looks, labels off") { s in
        for k in MenuItemKind.allCases { s.setShown(k, true); s.setLabel(k, false) }
        s.setStyle(.cpu, .text); s.setStyle(.memory, .pressure); s.setStyle(.fans, .percent); s.setStyle(.disk, .percent)
    }
    row("hottest, name the hottest on") { s in
        sample(s); s.nameHottest = true
    }
    row("spacing compact") { s in
        sample(s); s.spacing = .compact
    }
    row("spacing wide") { s in
        sample(s); s.spacing = .wide
    }
    row("no icon") { s in
        sample(s); s.showIcon = false
    }
    row("no icon, nothing shown") { s in s.showIcon = false }
    row("hot + nearly full: red", snapshot: hot) { s in
        s.setShown(.temperature, true); s.setShown(.disk, true)
    }
    row("hot + nearly full: red off", snapshot: hot) { s in
        s.setShown(.temperature, true); s.setShown(.disk, true); s.warnRed = false
    }
    row("hot + nearly full: red, metric colours", snapshot: hot) { s in
        sample(s); s.colourMode = .metric
    }
    row("wild: °F, huge rates, full disk, 10 fans", snapshot: wild) { s in
        for k in MenuItemKind.allCases { s.setShown(k, true) }; s.temperatureUnit = .fahrenheit; s.networkInBits = true
    }
    let strip = VStack(alignment: .leading, spacing: 8) {
        ForEach(rows, id: \.0) { row in
            HStack(spacing: 12) {
                Text(row.0).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
                row.1
            }
        }
    }.padding(8)
    render(strip, "menubar")
    for kind in MenuItemKind.allCases { settings.setShown(kind, [.cpu, .gpu, .memory].contains(kind)) }
    render(PopoverRoot(), "popover-root")

    // AI usage: the menu bar item, the card and panel, Settings › AI Usage and its sheets.
    renderAIMenuBar()
    renderAIPanel()
    renderAISettings()
}
UserDefaults.standard.removePersistentDomain(forName: "app.heron.snap")
UserDefaults.standard.removePersistentDomain(forName: aiSuite)
for suite in menuBarSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
exit(0)
