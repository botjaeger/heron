import Foundation
import HeronCore
import Observation

/// Every user preference, stored in UserDefaults. `@Observable` makes the UI update when a value
/// changes; each property writes itself back to UserDefaults in `didSet`.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public enum Appearance: String, CaseIterable, Codable { case system, light, dark }
    public enum GraphRange: Int, CaseIterable, Codable {
        case oneMinute = 60, tenMinutes = 600, oneHour = 3600, oneDay = 86_400
        public var label: String { [60: "1 min", 600: "10 min", 3600: "1 h", 86_400: "24 h"][rawValue]! }
    }
    public enum SensorChoice: String, CaseIterable, Codable { case hottest, cpu, gpu, ssd }

    // General
    public var appearance: Appearance { didSet { save(appearance.rawValue, "appearance") } }
    public var temperatureUnit: Format.TemperatureUnit { didSet { save(temperatureUnit.rawValue, "temperatureUnit") } }
    public var interval: Double { didSet { save(interval, "interval") } }
    public var slowOnLowBattery: Bool { didSet { save(slowOnLowBattery, "slowOnLowBattery") } }

    // Menu bar
    public var menuItems: [MenuItemConfig] { didSet { saveJSON(menuItems, "menuItems") } }
    /// The Heron icon before the metrics. With no metric shown it is drawn anyway (see `showsIcon`).
    public var showIcon: Bool { didSet { save(showIcon, "showIcon") } }
    public var colourMode: MenuBarColour { didSet { save(colourMode.rawValue, "colourMode") } }
    public var spacing: MenuBarSpacing { didSet { save(spacing.rawValue, "spacing") } }
    /// Values turn red when `Warnings` says so: hot, critical memory pressure, a nearly full startup disk, a low battery.
    public var warnRed: Bool { didSet { save(warnRed, "warnRed") } }

    // Overview
    /// The overview's sections, top to bottom. Always every section exactly once.
    public private(set) var overviewOrder: [OverviewPart] { didSet { save(overviewOrder.map(\.rawValue), "overviewOrder") } }
    /// Sections left out of the overview. Never all of them.
    public private(set) var hiddenSections: Set<OverviewPart> { didSet { save(OverviewPart.allCases.filter(hiddenSections.contains).map(\.rawValue), "hiddenSections") } }

    // Modules
    public var graphRange: GraphRange { didSet { save(graphRange.rawValue, "graphRange") } }
    /// The CPU panel's (and the Battery panel's) top processes by CPU.
    public var showCPUProcesses: Bool { didSet { save(showCPUProcesses, "showCPUProcesses") } }
    /// The Memory panel's top processes by memory.
    public var showMemoryProcesses: Bool { didSet { save(showMemoryProcesses, "showMemoryProcesses") } }
    public var showCores: Bool { didSet { save(showCores, "showCores") } }
    public var networkInBits: Bool { didSet { save(networkInBits, "networkInBits") } }
    public var showPublicIP: Bool { didSet { save(showPublicIP, "showPublicIP") } }
    public var hideDiskImages: Bool { didSet { save(hideDiskImages, "hideDiskImages") } }
    public var hideUnknownSensors: Bool { didSet { save(hideUnknownSensors, "hideUnknownSensors") } }
    /// The temperatures on the overview's Sensors card, in order: one to `SensorCardItem.limit`.
    public var sensorCard: [SensorCardItem] { didSet { save(sensorCard.map(\.rawValue), "sensorCard") } }
    /// The fan glyph and speed in the Sensors card's title row.
    public var sensorCardFans: Bool { didSet { save(sensorCardFans, "sensorCardFans") } }
    /// "Hottest · CPU 6" on the Sensors card. The menu bar never names the sensor: its tooltip does.
    public var nameHottest: Bool { didSet { save(nameHottest, "nameHottest") } }
    /// The sensor the menu bar temperature shows: the temperature item's variant (earlier versions
    /// stored it separately under "menuBarSensor").
    public var menuBarSensor: SensorChoice {
        get { style(of: .temperature).sensor ?? .hottest }
        set { setStyle(.temperature, MenuItemStyle(sensor: newValue)) }
    }
    /// How each overview card draws its value (OverviewCard raw value → CardStyle raw value).
    public var cardStyles: [String: String] { didSet { saveJSON(cardStyles, "cardStyles") } }

    // Alerts
    public var alertRules: [AlertRule] { didSet { saveJSON(alertRules, "alertRules") } }
    public var alertCooldown: Bool { didSet { save(alertCooldown, "alertCooldown") } }

    // AI usage (accounts live in AIUsageService; these are how they show)
    public var aiUsage: AIUsageSettings { didSet { saveJSON(aiUsage, "aiUsage") } }

    // Updates
    public var betaUpdates: Bool { didSet { save(betaUpdates, "betaUpdates") } }

    // First run and changelog
    public var onboardingDone: Bool { didSet { save(onboardingDone, "onboardingDone") } }
    public var lastSeenVersion: String { didSet { save(lastSeenVersion, "lastSeenVersion") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func get<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        func json<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        appearance = Appearance(rawValue: get("appearance", "system")) ?? .system
        temperatureUnit = Format.TemperatureUnit(rawValue: get("temperatureUnit", "celsius")) ?? .celsius
        // Only the intervals the picker offers; anything else (hand-edited defaults) shows no selection.
        interval = Self.intervals.contains(get("interval", 1.0)) ? get("interval", 1.0) : 1.0
        slowOnLowBattery = get("slowOnLowBattery", true)
        // Styles of earlier versions become the variant that shows the same thing; the menu bar
        // sensor, stored on its own before, becomes the temperature item's variant.
        let storedSensor = defaults.string(forKey: "menuBarSensor").flatMap(SensorChoice.init(rawValue:))
        let loadedItems = MenuItemConfig.merged(json("menuItems", MenuItemConfig.defaults))
        // The global "Labels on bars" / "Labels on values" switches of earlier versions became each
        // item's own label: off turns the label off for every item whose look it covered.
        let barLabels = defaults.object(forKey: "barLabels") as? Bool ?? true
        let valueLabels = defaults.object(forKey: "valueLabels") as? Bool ?? true
        menuItems = loadedItems.map { item in
            let style = item.kind.variant(for: item.style, sensor: storedSensor)
            var label = item.label
            switch item.kind.label(of: style) {
            case .bar? where !barLabels: label = false
            case .tag? where !valueLabels: label = false
            default: break
            }
            return MenuItemConfig(kind: item.kind, enabled: item.enabled, style: style, label: label)
        }
        showIcon = get("showIcon", true)
        colourMode = MenuBarColour(rawValue: get("colourMode", "monochrome")) ?? .monochrome
        spacing = MenuBarSpacing(rawValue: get("spacing", "regular")) ?? .regular
        warnRed = get("warnRed", true)
        overviewOrder = OverviewPart.ordered(get("overviewOrder", [String]()))
        let hidden = Set(get("hiddenSections", [String]()).compactMap(OverviewPart.init(rawValue:)))
        // An overview with every section hidden would be empty: show them all again.
        hiddenSections = hidden.count < OverviewPart.allCases.count ? hidden : []
        graphRange = GraphRange(rawValue: get("graphRange", 600)) ?? .tenMinutes
        // One "showTopProcesses" switch of earlier versions became one per panel: both start from it.
        let legacyTop = defaults.object(forKey: "showTopProcesses") as? Bool
        showCPUProcesses = get("showCPUProcesses", legacyTop ?? true)
        showMemoryProcesses = get("showMemoryProcesses", legacyTop ?? true)
        if legacyTop != nil {
            if defaults.object(forKey: "showCPUProcesses") == nil { defaults.set(legacyTop, forKey: "showCPUProcesses") }
            if defaults.object(forKey: "showMemoryProcesses") == nil { defaults.set(legacyTop, forKey: "showMemoryProcesses") }
        }
        showCores = get("showCores", true)
        networkInBits = get("networkInBits", false)
        showPublicIP = get("showPublicIP", false)
        hideDiskImages = get("hideDiskImages", true)
        hideUnknownSensors = get("hideUnknownSensors", true)
        sensorCard = SensorCardItem.cleaned(get("sensorCard", [String]()))
        sensorCardFans = get("sensorCardFans", true)
        nameHottest = get("nameHottest", false)
        cardStyles = json("cardStyles", [:])
        alertRules = json("alertRules", AlertRule.defaults)
        alertCooldown = get("alertCooldown", true)
        aiUsage = json("aiUsage", AIUsageSettings())
        betaUpdates = get("betaUpdates", false)
        onboardingDone = get("onboardingDone", false)
        lastSeenVersion = get("lastSeenVersion", "")
        // Settings of features that no longer exist (fan control, separate menu bar items).
        for key in Self.retiredKeys { defaults.removeObject(forKey: key) }
        // Keep a migration: "menuBarSensor", "barLabels" and "valueLabels" are gone after this launch.
        if menuItems != loadedItems { saveJSON(menuItems, "menuItems") }
    }

    /// Back to factory settings.
    public func reset() {
        // Forget every stored preference except first-run state, then read the defaults back.
        let keep: Set<String> = ["onboardingDone", "lastSeenVersion"]
        for key in Self.keys where !keep.contains(key) { defaults.removeObject(forKey: key) }
        let fresh = AppSettings(defaults: defaults)
        appearance = fresh.appearance; temperatureUnit = fresh.temperatureUnit; interval = fresh.interval
        slowOnLowBattery = fresh.slowOnLowBattery; menuItems = fresh.menuItems
        showIcon = fresh.showIcon; colourMode = fresh.colourMode; spacing = fresh.spacing; warnRed = fresh.warnRed
        overviewOrder = fresh.overviewOrder; hiddenSections = fresh.hiddenSections
        graphRange = fresh.graphRange; showCPUProcesses = fresh.showCPUProcesses; showMemoryProcesses = fresh.showMemoryProcesses; showCores = fresh.showCores
        networkInBits = fresh.networkInBits
        showPublicIP = fresh.showPublicIP; hideDiskImages = fresh.hideDiskImages; hideUnknownSensors = fresh.hideUnknownSensors
        sensorCard = fresh.sensorCard; sensorCardFans = fresh.sensorCardFans; nameHottest = fresh.nameHottest
        cardStyles = fresh.cardStyles
        alertRules = fresh.alertRules; alertCooldown = fresh.alertCooldown; betaUpdates = fresh.betaUpdates
        aiUsage = fresh.aiUsage
    }

    /// Settings › Overview › Restore defaults: every setting that pane holds (`SettingsPane.overview.keys`)
    /// back as Heron ships it; the rest stays.
    public func restoreOverviewDefaults() {
        for key in SettingsPane.overview.keys { defaults.removeObject(forKey: key) }
        let fresh = AppSettings(defaults: defaults)
        overviewOrder = fresh.overviewOrder; hiddenSections = fresh.hiddenSections; cardStyles = fresh.cardStyles
        showCores = fresh.showCores; showCPUProcesses = fresh.showCPUProcesses; showMemoryProcesses = fresh.showMemoryProcesses; networkInBits = fresh.networkInBits
        showPublicIP = fresh.showPublicIP; hideDiskImages = fresh.hideDiskImages; sensorCard = fresh.sensorCard
        sensorCardFans = fresh.sensorCardFans; nameHottest = fresh.nameHottest; hideUnknownSensors = fresh.hideUnknownSensors
    }

    /// Sampling intervals offered in Settings › General.
    public static let intervals: [Double] = [0.5, 1, 2, 5]

    static let keys = [
        "appearance", "temperatureUnit", "interval", "slowOnLowBattery", "menuItems",
        "showIcon", "colourMode", "spacing", "warnRed", "overviewOrder", "hiddenSections", "graphRange",
        "showCPUProcesses", "showMemoryProcesses", "showCores", "networkInBits", "showPublicIP", "hideDiskImages", "hideUnknownSensors",
        "sensorCard", "sensorCardFans", "nameHottest", "cardStyles", "alertRules", "alertCooldown", "aiUsage", "betaUpdates", "onboardingDone", "lastSeenVersion",
    ]

    /// Stored by earlier versions; removed at launch. "menuBarSensor" became the temperature item's
    /// variant; "barLabels" and "valueLabels" became each item's own label; "showTopProcesses" became
    /// "showCPUProcesses" and "showMemoryProcesses".
    static let retiredKeys = ["combineItems", "fanMode", "fanCurve", "fanRiskAccepted", "menuBarSensor", "barLabels", "valueLabels", "showTopProcesses"]

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
    private func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// The style an overview card draws with; a stored style the card doesn't offer falls back to its default.
    public func cardStyle(_ card: OverviewCard) -> CardStyle {
        guard let raw = cardStyles[card.rawValue], let style = CardStyle(rawValue: raw), card.styles.contains(style) else { return card.styles[0] }
        return style
    }
    public func setCardStyle(_ card: OverviewCard, _ style: CardStyle) { cardStyles[card.rawValue] = style.rawValue }

    public func isShown(_ kind: MenuItemKind) -> Bool { menuItems.first { $0.kind == kind }?.enabled ?? false }
    public func style(of kind: MenuItemKind) -> MenuItemStyle {
        let saved = menuItems.first { $0.kind == kind }?.style ?? kind.styles[0]
        return kind.styles.contains(saved) ? saved : kind.styles[0]
    }

    /// The metrics shown inside the Heron menu bar item, in order.
    public var shownItems: [MenuItemConfig] { menuItems.filter(\.enabled) }

    /// Whether the menu bar item draws the Heron icon: with nothing else shown, the icon is the item.
    public var showsIcon: Bool { showIcon || shownItems.isEmpty }

    public func isHidden(_ part: OverviewPart) -> Bool { hiddenSections.contains(part) }

    /// Hides or shows an overview section. The last visible section cannot be hidden; returns
    /// false when the change was refused.
    @discardableResult
    public func setHidden(_ part: OverviewPart, _ hidden: Bool) -> Bool {
        if !hidden { hiddenSections.remove(part); return true }
        guard hiddenSections.contains(part) || hiddenSections.count + 1 < OverviewPart.allCases.count else { return false }
        hiddenSections.insert(part)
        return true
    }

    /// Sets the overview order; duplicates are dropped and missing sections added at the end.
    public func setOverviewOrder(_ order: [OverviewPart]) { overviewOrder = OverviewPart.ordered(order.map(\.rawValue)) }

    public func setShown(_ kind: MenuItemKind, _ shown: Bool) {
        guard let i = menuItems.firstIndex(where: { $0.kind == kind }) else { return }
        menuItems[i].enabled = shown
    }

    public func setStyle(_ kind: MenuItemKind, _ style: MenuItemStyle) {
        guard let i = menuItems.firstIndex(where: { $0.kind == kind }) else { return }
        menuItems[i].style = style
    }

    /// The item's own label ("CPU" over its bar, "CPU" before "34%"). Only drawn by looks that have one.
    public func showsLabel(_ kind: MenuItemKind) -> Bool { menuItems.first { $0.kind == kind }?.label ?? true }

    public func setLabel(_ kind: MenuItemKind, _ shown: Bool) {
        guard let i = menuItems.firstIndex(where: { $0.kind == kind }) else { return }
        menuItems[i].label = shown
    }

    /// Moves an item onto another's place in the menu bar order (Settings › Menu Bar, drag or ⌥⌘↑ ↓).
    public func moveItem(_ kind: MenuItemKind, onto target: MenuItemKind) {
        let order = OverviewArrange.move(menuItems.map(\.kind), kind, onto: target)
        menuItems = order.compactMap { k in menuItems.first { $0.kind == k } }
    }
}

public enum MenuItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `ai`: AI plan usage (Claude, ChatGPT, OpenCode limits), drawn from `AIUsageService`.
    case cpu, temperature, network, memory, gpu, disk, fans, battery, ai
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .temperature: return "Temperature"
        case .network: return "Network"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .disk: return "Disk"
        case .fans: return "Fans"
        case .battery: return "Battery"
        case .ai: return "AI usage"
        }
    }
    public var color: MetricColor {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory, .battery: return .memory
        case .network: return .network
        // Red means attention only: a normal temperature is drawn in the plain ink, also with
        // metric colours. `MenuBarSegment.isWarning` turns it red when it is too hot.
        // AI limits are orange or red by severity (`AIMenuBarItem`), else the plain ink.
        case .temperature, .disk, .fans, .ai: return .neutral
        }
    }

    /// What kind of label a look has: a word over the bar, a tag before the value, or none
    /// (graph, gauge, "351 GB free", "2,779 rpm", network, battery).
    public enum LabelKind: Sendable { case bar, tag }

    public func label(of style: MenuItemStyle) -> LabelKind? {
        switch (self, variant(for: style)) {
        case (.cpu, .bar), (.gpu, .bar), (.memory, .bar), (.disk, .bar): return .bar
        case (.cpu, .text), (.gpu, .text), (.memory, .text), (.memory, .pressure), (.temperature, _), (.disk, .percent), (.fans, .percent): return .tag
        default: return nil
        }
    }
    /// What this item can show; the first is the default. Every variant says what its number is.
    public var styles: [MenuItemStyle] {
        switch self {
        case .cpu, .gpu: return [.bar, .text, .graph, .gauge]
        case .memory: return [.bar, .text, .usedGB, .freeGB, .pressure, .graph, .gauge]
        case .disk: return [.free, .used, .percent, .bar]
        case .temperature: return [.hottest, .cpu, .gpu, .ssd]
        case .network: return [.both, .down, .up, .graph]
        case .fans: return [.rpm, .percent]
        case .battery: return [.both, .icon, .percent]
        // One look: which limits it shows is set in Settings › Menu Bar › AI usage (`AIUsageSettings`).
        case .ai: return [.text]
        }
    }

    /// The name of a look under its tile in Settings › Menu Bar › Shows as.
    public func title(of style: MenuItemStyle) -> String {
        switch (self, style) {
        case (.ai, _): return "Limits"
        case (_, .text): return "Percent"
        case (.memory, .usedGB): return "Used"
        case (.memory, .freeGB): return "Available"
        case (.network, .both): return "Both"
        case (.network, .down): return "Download"
        case (.network, .up): return "Upload"
        case (.disk, .free): return "Free space"
        case (.disk, .used): return "Used space"
        case (.fans, .rpm): return "Speed"
        case (.fans, .percent): return "Percent of max"
        case (.battery, .both): return "Icon and %"
        case (.temperature, .cpu), (.temperature, .gpu), (.temperature, .ssd): return style.rawValue.uppercased()
        default: return style.title
        }
    }

    /// The variant a stored style becomes. Styles of earlier versions map to what they showed
    /// (battery "bar" was the icon, "text" the icon and %; temperature "text" showed the separately
    /// stored sensor, CPU by default); a style this item does not offer falls back to the default.
    /// `sensor`: the retired "menuBarSensor" value, when one is still stored.
    func variant(for stored: MenuItemStyle, sensor: AppSettings.SensorChoice? = nil) -> MenuItemStyle {
        switch (self, stored) {
        case (.temperature, _) where sensor != nil: return MenuItemStyle(sensor: sensor!)
        case (.temperature, .text): return .cpu
        case (.battery, .bar): return .icon
        case (.battery, .text): return .both
        default: return styles.contains(stored) ? stored : styles[0]
        }
    }
}

/// What a menu bar item shows (its "variant"). `MenuItemKind.styles` lists each kind's own.
public enum MenuItemStyle: String, Codable, CaseIterable, Sendable {
    /// `bar`: a small label over a horizontal meter ("CPU" over ▭).
    case bar, text, graph, gauge
    /// Memory: "27.6 GB used", "8.4 GB available" (free + cached), "Pressure 61%".
    case usedGB = "usedgb", freeGB = "freegb", pressure
    /// Disk: "351 GB free", "644 GB used"; disk and fans: "DISK 65%", "FAN 37%".
    case free, used, percent
    /// Temperature: which sensor.
    case hottest, cpu, gpu, ssd
    /// Network: "↑ / ↓" stacked, download, upload.
    case both, down, up
    /// Fans: "2,779 rpm". Battery: the battery icon.
    case rpm, icon
    public var title: String { rawValue.capitalized }

    /// The temperature variant for a sensor, and back.
    public init(sensor: AppSettings.SensorChoice) {
        switch sensor {
        case .hottest: self = .hottest
        case .cpu: self = .cpu
        case .gpu: self = .gpu
        case .ssd: self = .ssd
        }
    }
    public var sensor: AppSettings.SensorChoice? {
        switch self {
        case .hottest: return .hottest
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .ssd: return .ssd
        default: return nil
        }
    }
}

public struct MenuItemConfig: Codable, Equatable, Identifiable, Sendable {
    public var kind: MenuItemKind
    public var enabled: Bool
    public var style: MenuItemStyle
    /// The item's label ("CPU" over the bar, "CPU" before "34%"), for looks that have one (`MenuItemKind.label(of:)`).
    public var label: Bool
    public var id: String { kind.rawValue }

    public init(kind: MenuItemKind, enabled: Bool, style: MenuItemStyle, label: Bool = true) {
        self.kind = kind; self.enabled = enabled; self.style = style; self.label = label
    }

    /// A stored style this version does not know (hand-edited, or from a newer version) becomes
    /// the item's default instead of throwing away every saved item. Items saved before labels
    /// were per item have no `label`: on (the global switches are migrated in `AppSettings.init`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(MenuItemKind.self, forKey: .kind)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        style = (try? c.decode(MenuItemStyle.self, forKey: .style)) ?? kind.styles[0]
        label = (try? c.decodeIfPresent(Bool.self, forKey: .label)) ?? true
    }

    /// Heron has ONE menu bar item. By default it is the Heron icon alone; each enabled
    /// metric is drawn inside that item, after the icon, in this order.
    public static let defaults: [MenuItemConfig] = [
        .init(kind: .cpu, enabled: false, style: .bar),
        .init(kind: .gpu, enabled: false, style: .bar),
        .init(kind: .memory, enabled: false, style: .bar),
        .init(kind: .temperature, enabled: false, style: .hottest),
        .init(kind: .network, enabled: false, style: .both),
        .init(kind: .disk, enabled: false, style: .free),
        .init(kind: .fans, enabled: false, style: .rpm),
        .init(kind: .battery, enabled: false, style: .both),
        .init(kind: .ai, enabled: false, style: .text),
    ]

    /// Keeps saved order and adds any item kinds introduced by a newer version.
    static func merged(_ saved: [MenuItemConfig]) -> [MenuItemConfig] {
        var seen = Set<MenuItemKind>()
        // One entry per kind: a duplicate would create two status items and two rows in Settings.
        var result = saved.filter { seen.insert($0.kind).inserted }
        for item in defaults where !result.contains(where: { $0.kind == item.kind }) { result.append(item) }
        return result
    }
}

/// How an overview card draws its value.
public enum CardStyle: String, CaseIterable, Codable, Sendable {
    /// `rings`: two rings side by side, memory pressure and memory used.
    /// `mirrored`: one bar per second, the first series up from a centre line, the second down.
    case stacked, bar, ring, graph, text, rings, mirrored
    public var title: String {
        switch self {
        case .rings: return "Rings"
        case .mirrored: return "Mirrored"
        case .stacked: return "Bars"
        case .bar: return "Bar"
        case .ring: return "Ring"
        case .graph: return "Graph"
        case .text: return "Numbers"
        }
    }
}

/// The overview cards whose look can be chosen in Settings.
public enum OverviewCard: String, CaseIterable, Sendable {
    case cpu, gpu, memory, network, disk

    /// Styles this card offers; the first is the default (today's look; memory: the two rings).
    public var styles: [CardStyle] {
        switch self {
        case .cpu: return [.stacked, .graph, .ring]
        case .gpu: return [.bar, .ring, .graph]
        case .memory: return [.rings, .bar, .ring, .graph]
        case .network: return [.text, .graph, .mirrored]
        case .disk: return [.bar, .ring, .mirrored]
        }
    }

    /// The card a section of Settings › Overview controls.
    public init?(_ kind: MenuItemKind) { self.init(rawValue: kind.rawValue) }
}

/// A temperature the overview's Sensors card can show (Settings › Overview › Sensors › On the card).
/// "Hottest" is the hottest named sensor, the menu bar's ▲; the others are component averages.
public enum SensorCardItem: String, CaseIterable, Codable, Sendable {
    case hottest, cpu, gpu, ssd, battery, wireless, enclosure
    public var title: String {
        switch self {
        case .hottest: return "Hottest"
        case .cpu, .gpu, .ssd: return rawValue.uppercased()
        default: return rawValue.capitalized
        }
    }

    /// The card shows at most this many.
    public static let limit = 5
    public static let defaults: [SensorCardItem] = [.hottest, .cpu, .gpu]

    /// A stored list made whole: unknown names and repeats dropped, at most `limit`; an empty list
    /// becomes the default (the card keeps at least one temperature).
    static func cleaned(_ stored: [String]) -> [SensorCardItem] {
        var result: [SensorCardItem] = []
        for item in stored.compactMap(SensorCardItem.init(rawValue:)) where !result.contains(item) && result.count < limit { result.append(item) }
        return result.isEmpty ? defaults : result
    }

    /// Picks `item` (at the end, while fewer than `limit` are picked) or unpicks it (unless it is
    /// the last one left).
    public static func toggled(_ list: [SensorCardItem], _ item: SensorCardItem) -> [SensorCardItem] {
        if list.contains(item) { return list.count > 1 ? list.filter { $0 != item } : list }
        return list.count < limit ? list + [item] : list
    }
}

/// A section of the overview popover, in Settings › Overview order. `ai`: AI plan usage, shown
/// only once an AI account exists (a stored order without it gets it appended, like any new part).
public enum OverviewPart: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, gpu, memory, network, disk, ai, sensors, battery
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu, .gpu: return rawValue.uppercased()
        case .ai: return "AI usage"
        default: return rawValue.capitalized
        }
    }

    /// A stored order made whole: unknown names dropped, duplicates merged (first one wins),
    /// missing sections added at the end in default order.
    static func ordered(_ stored: [String]) -> [OverviewPart] {
        var result: [OverviewPart] = []
        for part in stored.compactMap(OverviewPart.init(rawValue:)) where !result.contains(part) { result.append(part) }
        return result + allCases.filter { !result.contains($0) }
    }
}

/// Menu bar item colour: one ink like every other menu bar item, or each metric in its colour.
public enum MenuBarColour: String, CaseIterable, Codable, Sendable {
    case monochrome, metric
    public var title: String { self == .monochrome ? "Monochrome" : "Metric colours" }
}

/// Space between the parts of the menu bar item.
public enum MenuBarSpacing: String, CaseIterable, Codable, Sendable {
    case compact, regular, wide
    public var title: String { rawValue.capitalized }
    public var gap: CGFloat {
        switch self {
        case .compact: return 5
        case .regular: return 10
        case .wide: return 16
        }
    }
}

public enum PopoverKind: String, CaseIterable, Identifiable {
    /// `ai`: the AI usage panel (the overview part of the same name).
    case overview, cpu, gpu, memory, disk, network, sensors, battery, ai
    public var id: String { rawValue }

    /// Page heading.
    public var title: String {
        switch self {
        case .overview: return "Heron"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .sensors: return "Sensors"
        case .battery: return "Battery"
        case .ai: return "AI usage"
        }
    }
}
