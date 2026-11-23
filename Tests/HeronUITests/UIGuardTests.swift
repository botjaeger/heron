import AppKit
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

// Guards for UI defect classes found in the Nov 2026 sweep (docs/workstreams/heron-defect-classes.md).

@MainActor
@Suite struct MenuBarWidthTests {
    func snapshot(high: Bool) -> Snapshot {
        var s = Snapshot()
        let f = high ? 1.0 : 0.04
        s.cpu = CPUReading(user: f, system: 0, idle: 1 - f, cores: [], loadAverage: [])
        s.gpu = GPUReading(device: f)
        s.memory = MemoryReading(
            total: 100_000_000_000, app: high ? 99_000_000_000 : 4, wired: 0, compressed: 0, cached: high ? 1_000_000_000 : 0,
            free: high ? 0 : 99_000_000_000, swapUsed: 0, pressure: .normal, pressurePercent: high ? 1 : 0.04)
        s.network = NetworkReading(
            interface: "en0", interfaceKind: "Wi-Fi", localIP: nil, downBytesPerSecond: high ? 999_000 : 3, upBytesPerSecond: high ? 999_000 : 3, sessionDown: 0, sessionUp: 0)
        s.disk = DiskReading(
            volumes: [VolumeReading(name: "HD", path: "/", total: 1_000_000_000_000, available: high ? 999_000_000_000 : 5_000_000_000, isInternal: true, format: "APFS")],
            readBytesPerSecond: 0, writeBytesPerSecond: 0)
        s.fans = [Fan(id: 0, name: "Fan", rpm: high ? 6_900 : 0, minRPM: 0, maxRPM: 7_000)]
        s.battery = BatteryReading(present: true, percent: high ? 1 : 0.05, isCharging: false, onAC: true)
        // Below the 90° warning badge: the badge adds padding on purpose.
        s.sensors = [Sensor(id: "c", name: "CPU 1", group: .cpu, celsius: high ? 89 : 7, isKnown: true)]
        return s
    }

    func settings(_ tag: String) -> AppSettings {
        AppSettings(defaults: scratchDefaults(tag))
    }

    func width(_ s: AppSettings, high: Bool) -> CGFloat {
        MenuBarRenderer.image(for: MenuBarLabel(snapshot: snapshot(high: high), history: MetricHistory(), settings: s), scale: 2).size.width
    }

    /// Class: a value that gains digits must not resize the status item (it jumped sideways).
    /// Every variant of every metric, under every appearance option.
    @Test func everyMetricKeepsItsWidthAsValuesChange() {
        let appearances: [(String, (AppSettings) -> Void)] = [
            ("default", { _ in }), ("labels off", { s in for k in MenuItemKind.allCases { s.setLabel(k, false) } }),
            ("metric colours", { $0.colourMode = .metric }),
            ("compact", { $0.spacing = .compact }),
            (
                "wide, no icon",
                {
                    $0.spacing = .wide; $0.showIcon = false
                }
            ),
            ("hottest named on the card", { $0.nameHottest = true }),
        ]
        for (name, configure) in appearances {
            let s = settings("width")
            configure(s)
            for kind in MenuItemKind.allCases {
                for style in kind.styles {
                    for k in MenuItemKind.allCases { s.setShown(k, k == kind) }
                    s.setStyle(kind, style)
                    let widths = [width(s, high: false), width(s, high: true)]
                    #expect(widths[0] == widths[1], "\(name): \(kind.rawValue) \(style.rawValue): \(widths)")
                }
            }
            for k in MenuItemKind.allCases { s.setShown(k, true) }  // everything at once
            #expect(width(s, high: false) == width(s, high: true), "\(name): everything")
        }
    }

    /// "CPU ▲79°": the hottest sensor shows its group, never its name, and the item reserves only
    /// digits. Whichever CPU sensor is hottest, one or three digits, named on the card or not, the
    /// width stays; the old "MAX CPU P-core 12" reservation is gone.
    @Test func theHottestSensorKeepsTheItemsWidthWithoutReservingItsName() {
        let s = settings("namedhot")
        s.setShown(.temperature, true)
        s.warnRed = false  // red is a colour, not a width
        let names = ["CPU 1", "CPU P-core 12", "CPU E-core 3"]
        var widths: [CGFloat] = []
        for named in [false, true] {
            s.nameHottest = named
            for hot in names.indices {
                for high in [false, true] {
                    var snap = snapshot(high: high)
                    snap.sensorNames = names
                    snap.sensors = names.indices.map { i in
                        Sensor(id: "\(i)", name: names[i], group: .cpu, celsius: i == hot ? (high ? 99 : 9) : 5, isKnown: true)
                    }
                    widths.append(image(s, snap).size.width)
                }
            }
        }
        #expect(Set(widths).count == 1, "\(widths)")
        // No name room: the hottest is as wide as the fixed CPU sensor plus its ▲ (a few points).
        s.setStyle(.temperature, .cpu)
        var snap = snapshot(high: true)
        snap.sensors = [Sensor(id: "0", name: "CPU P-core 12", group: .cpu, celsius: 99, isKnown: true)]
        let fixed = image(s, snap).size.width
        #expect(widths[0] > fixed && widths[0] <= fixed + 10, "hottest \(widths[0]) vs CPU \(fixed)")
    }

    /// The memory pressure word ("Normal", "Critical") when the kernel gives no number keeps one width too.
    @Test func thePressureWordKeepsItsWidth() {
        let s = settings("pressure")
        s.setShown(.memory, true); s.setStyle(.memory, .pressure)
        var widths: [CGFloat] = []
        for level in [MemoryReading.Pressure.normal, .warning, .critical] {
            var snap = snapshot(high: true)
            snap.memory?.pressurePercent = nil
            snap.memory?.pressure = level
            s.warnRed = false  // red is a colour, not a width; keep the comparison about text
            widths.append(MenuBarRenderer.image(for: MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s), scale: 2).size.width)
        }
        #expect(Set(widths).count == 1, "\(widths)")
    }

    /// The default is the Heron icon alone; each enabled metric widens the same single item.
    @Test func defaultsShowTheIconAloneAndMetricsJoinTheSameItem() {
        let s = settings("default")
        #expect(s.shownItems.isEmpty)
        let iconOnly = width(s, high: true)
        #expect(iconOnly <= 18)
        s.setShown(.cpu, true)
        let withCPU = width(s, high: true)
        s.setShown(.temperature, true)
        #expect(iconOnly < withCPU && withCPU < width(s, high: true))
        #expect(s.style(of: .cpu) == .bar)
    }

    @Test func aMacWithoutABatteryShowsADashNotZeroPercent() {
        var s = Snapshot()
        s.battery = BatteryReading(present: false, percent: 0, isCharging: false, onAC: true)
        let segment = MenuBarSegment(kind: .battery, style: .text, snapshot: s, history: MetricHistory(), settings: settings("battery"))
        #expect(segment.spokenValue == "No battery")
        #expect(!segment.isWarning)
    }

    @Test func everyMetricHasASpokenValue() {
        let s = settings("spoken")
        // AI usage needs accounts: its spoken values are in MenuBarAITests.
        for kind in MenuItemKind.allCases where kind != .ai {
            let segment = MenuBarSegment(kind: kind, style: .text, snapshot: snapshot(high: true), history: MetricHistory(), settings: s)
            #expect(!segment.spokenValue.isEmpty && segment.spokenValue.rangeOfCharacter(from: .decimalDigits) != nil, "\(kind)")
        }
        #expect(MenuBarLabel(snapshot: snapshot(high: true), history: MetricHistory(), settings: s).spokenValue == "Heron")
        s.setShown(.cpu, true); s.setShown(.gpu, true)
        #expect(MenuBarLabel(snapshot: snapshot(high: true), history: MetricHistory(), settings: s).spokenValue == "CPU 100%, GPU 100%")
    }

    /// The item is redrawn every second: with four metrics it must stay a few milliseconds.
    @Test func redrawingTheItemIsCheap() {
        let s = settings("perf")
        for k in [MenuItemKind.cpu, .gpu, .memory, .temperature] { s.setShown(k, true) }
        let snap = snapshot(high: true)
        _ = MenuBarRenderer.image(for: MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s))
        let start = Date()
        for _ in 0..<30 { _ = MenuBarRenderer.image(for: MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s)) }
        let perImage = Date().timeIntervalSince(start) / 30 * 1000
        print("MENUBAR render \(String(format: "%.2f", perImage)) ms")
        #expect(perImage < 15)
    }

    @Test func aWarningSegmentMakesTheImageNonTemplate() {
        let s = settings("warn")
        s.setShown(.memory, true)
        var snap = snapshot(high: true)
        #expect(MenuBarRenderer.image(for: MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s)).isTemplate)
        snap.memory?.pressure = .critical
        #expect(!MenuBarRenderer.image(for: MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s)).isTemplate)
    }

    func image(_ s: AppSettings, _ snap: Snapshot) -> NSImage {
        MenuBarRenderer.image(for: MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s), scale: 2)
    }

    /// "Turn red when too hot or full": 90° on the chosen sensor, or a nearly full startup disk.
    @Test func valuesTurnRedWhenTooHotOrFullUnlessTurnedOff() {
        let s = settings("red")
        var snap = snapshot(high: true)
        s.setShown(.temperature, true)
        #expect(image(s, snap).isTemplate)  // 89°
        snap.sensors[0].celsius = 90
        #expect(!image(s, snap).isTemplate && MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s).isWarning)
        s.setStyle(.temperature, .ssd)  // the SSD has no reading: not hot
        #expect(image(s, snap).isTemplate)
        s.setShown(.temperature, false); s.setShown(.disk, true)
        #expect(image(s, snap).isTemplate)  // 999 GB free
        snap.disk?.volumes[0].available = 9_000_000_000
        #expect(!image(s, snap).isTemplate)
        s.warnRed = false
        #expect(image(s, snap).isTemplate && !MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s).isWarning)
    }

    /// Metric colours make the image hold colour; neutral metrics (disk, fans) keep the plain ink.
    @Test func metricColoursStopTheImageBeingATemplate() {
        let s = settings("colour")
        s.setShown(.disk, true)
        s.colourMode = .metric
        #expect(image(s, snapshot(high: true)).isTemplate)
        s.setShown(.cpu, true)
        #expect(!image(s, snapshot(high: true)).isTemplate)
        s.colourMode = .monochrome
        #expect(image(s, snapshot(high: true)).isTemplate)
        // The colour follows the menu bar: the light and dark halves of the pair differ.
        s.colourMode = .metric
        let light = MenuBarSegment(kind: .cpu, style: .bar, snapshot: snapshot(high: true), history: MetricHistory(), settings: s, dark: false)
        #expect(NSColor(light.valueInk).usingColorSpace(.sRGB) == NSColor(hex: Theme.Palette.cpu.light).usingColorSpace(.sRGB))
        let dark = MenuBarSegment(kind: .cpu, style: .bar, snapshot: snapshot(high: true), history: MetricHistory(), settings: s, dark: true)
        #expect(NSColor(dark.valueInk).usingColorSpace(.sRGB) == NSColor(hex: Theme.Palette.cpu.dark).usingColorSpace(.sRGB))
    }

    @Test func iconSpacingAndLabelsChangeTheItem() {
        let s = settings("look")
        let snap = snapshot(high: true)
        s.setShown(.cpu, true); s.setShown(.gpu, true)
        let regular = image(s, snap).size.width
        s.spacing = .compact
        let compact = image(s, snap).size.width
        s.spacing = .wide
        #expect(compact < regular && regular < image(s, snap).size.width)
        s.spacing = .regular
        s.showIcon = false
        #expect(image(s, snap).size.width < regular)
        s.showIcon = true
        let withLabels = image(s, snap)
        s.setLabel(.cpu, false)
        #expect(!sameImage(image(s, snap), withLabels))
        for k in MenuItemKind.allCases { s.setShown(k, false) }
        let icon = image(s, snap)
        s.showIcon = false
        #expect(sameImage(image(s, snap), icon))  // nothing shown: the icon stays
    }

    /// Each variant shows the number it names.
    @Test func variantsShowWhatTheySay() {
        let s = settings("say")
        var snap = snapshot(high: true)
        snap.memory = MemoryReading(
            total: 36_000_000_000, app: 20_000_000_000, wired: 5_000_000_000, compressed: 4_600_000_000,
            cached: 4_000_000_000, free: 1_000_000_000, swapUsed: 0, pressure: .warning, pressurePercent: 0.58)
        func spoken(_ kind: MenuItemKind, _ style: MenuItemStyle) -> String {
            MenuBarSegment(kind: kind, style: style, snapshot: snap, history: MetricHistory(), settings: s).spokenValue
        }
        #expect(spoken(.memory, .usedGB) == "Memory \(Format.bytes(29_600_000_000)) used")
        #expect(spoken(.memory, .freeGB) == "Memory \(Format.bytes(5_000_000_000)) available")  // free + cached
        #expect(spoken(.memory, .pressure) == "Memory pressure 58%")
        snap.memory?.pressurePercent = nil
        #expect(spoken(.memory, .pressure) == "Memory pressure warning")
        #expect(spoken(.disk, .used) == "Startup disk 1 GB used" && spoken(.disk, .free) == "Startup disk 999 GB free")
        #expect(spoken(.disk, .percent) == "Startup disk 0% used")
        #expect(spoken(.fans, .percent) == "Fans 99% of maximum" && spoken(.fans, .rpm) == "Fans 6,900 rpm")
        #expect(spoken(.network, .up) == "Network up 999 KB/s" && spoken(.network, .down) == "Network down 999 KB/s")
        #expect(spoken(.temperature, .cpu) == "CPU temperature 89°" && spoken(.temperature, .hottest) == "Hottest temperature 89°")
    }

    /// The charge-limit tick is drawn only when macOS reports a limit, and never widens the item.
    @Test func theBatteryTickAppearsOnlyWithAChargeLimit() {
        let s = settings("limit")
        s.setShown(.battery, true); s.setStyle(.battery, .icon)
        var snap = snapshot(high: false)
        let without = image(s, snap)
        snap.battery?.chargeLimit = 0.8
        let with = image(s, snap)
        #expect(!sameImage(with, without))
        #expect(with.size.width == without.size.width)
    }
}

@MainActor
@Suite struct MainMenuTests {
    /// Class: editing shortcuts in a menu bar app only work through a main menu.
    @Test func editingAndWindowShortcutsAreRouted() {
        let menu = AppMenu.make()
        func has(_ key: String, _ action: Selector) -> Bool {
            menu.items.contains { $0.submenu?.items.contains { $0.keyEquivalent == key && $0.action == action && $0.keyEquivalentModifierMask == .command } ?? false }
        }
        #expect(has("c", #selector(NSText.copy(_:))))
        #expect(has("v", #selector(NSText.paste(_:))))
        #expect(has("x", #selector(NSText.cut(_:))))
        #expect(has("a", #selector(NSText.selectAll(_:))))
        #expect(has("w", #selector(NSWindow.performClose(_:))))
        #expect(has("q", #selector(NSApplication.terminate(_:))))
    }

    @Test func commandAReachesAFocusedTextField() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(string: "95")
        field.frame = NSRect(x: 10, y: 10, width: 100, height: 24)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        else {
            Issue.record("no key event"); return
        }
        #expect(AppMenu.make().performKeyEquivalent(with: event))  // handled: a menu item took it
        #expect(!NSMenu().performKeyEquivalent(with: event))  // control: no menu, nothing handles ⌘A
    }
}

@Suite struct ContrastTests {
    /// Class: every text colour meets WCAG AA (4.5:1) on every surface it is drawn on.
    @Test func textColoursMeetAAInBothModes() {
        let bgs = Theme.Palette.textBackgrounds
        for (i, pair) in Theme.Palette.text.enumerated() {
            for bg in bgs.light { #expect(Theme.contrast(pair.light, bg) >= 4.5, "light #\(i) \(String(pair.light, radix: 16)) on \(String(bg, radix: 16))") }
            for bg in bgs.dark { #expect(Theme.contrast(pair.dark, bg) >= 4.5, "dark #\(i) \(String(pair.dark, radix: 16)) on \(String(bg, radix: 16))") }
        }
        #expect(abs(Theme.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)  // the formula itself
    }

    /// The menu bar item's metric colours and warning red, on light and dark menu bars.
    @Test func menuBarColoursMeetAAInBothModes() {
        let bgs = Theme.Palette.menuBarBackgrounds
        for metric in [MetricColor.cpu, .gpu, .memory, .network, .warning] {
            guard let pair = Theme.Palette.pair(for: metric) else { Issue.record("\(metric) has no colour"); continue }
            for bg in bgs.light { #expect(Theme.contrast(pair.light, bg) >= 4.5, "light \(metric) on \(String(bg, radix: 16))") }
            for bg in bgs.dark { #expect(Theme.contrast(pair.dark, bg) >= 4.5, "dark \(metric) on \(String(bg, radix: 16))") }
        }
        #expect(Theme.Palette.pair(for: .neutral) == nil)
    }

    /// Settings › Overview's selected section row: its hint text, and primary names (near-black
    /// and near-white), on the selection fill.
    @Test func textOnTheSelectedSectionRowMeetsAA() {
        let fill = Theme.Palette.settingsPicked, text = Theme.Palette.settingsPickedText
        #expect(Theme.contrast(text.light, fill.light) >= 4.5)
        #expect(Theme.contrast(text.dark, fill.dark) >= 4.5)
        #expect(Theme.contrast(0x1D1D1F, fill.light) >= 4.5)
        #expect(Theme.contrast(0xECEEF7, fill.dark) >= 4.5)
    }
}

@Suite struct SettingsGuardTests {
    func fresh() -> (AppSettings, UserDefaults) {
        let d = scratchDefaults("guard")
        return (AppSettings(defaults: d), d)
    }

    @Test func anIntervalThePickerCannotShowFallsBackToOneSecond() {
        let (_, d) = fresh()
        d.set(3.0, forKey: "interval")
        #expect(AppSettings(defaults: d).interval == 1)
        d.set(0.5, forKey: "interval")
        #expect(AppSettings(defaults: d).interval == 0.5)
    }

    @Test func duplicateMenuItemsAreMerged() {
        let saved = [MenuItemConfig(kind: .cpu, enabled: true, style: .gauge), MenuItemConfig(kind: .cpu, enabled: false, style: .text)]
        let merged = MenuItemConfig.merged(saved)
        #expect(merged.filter { $0.kind == .cpu }.count == 1)
        #expect(merged.first?.style == .gauge)
        #expect(merged.count == MenuItemKind.allCases.count)
    }

    /// A panel's "Settings…" opens Settings › Overview on that panel's section; the overview's opens General.
    @Test func eachPopoverOpensItsOwnSettingsPane() {
        let routes = PopoverKind.allCases.map { PopoverView(kind: $0).settingsRoute }
        #expect(Set(routes).count == PopoverKind.allCases.count)
        #expect(PopoverView(kind: .sensors).settingsRoute == .overview(.sensors))
        #expect(PopoverView(kind: .overview).settingsRoute == SettingsRoute(.general))
        for part in OverviewPart.allCases {
            #expect(PopoverView(kind: PopoverKind(part)).settingsRoute == SettingsRoute(.overview, section: part), "\(part)")
        }
    }
}

/// The mark is drawn from one geometry (`HeronShape`) at icon and menu bar proportions.
@Suite struct MarkGeometryTests {
    @Test func theMarkStaysInsideItsTileAndTheBeakInsideTheDial() {
        for glyph in [false, true] {
            let p = HeronShape.parts(glyph: glyph)
            let bounds = [p.track, p.value, p.head, p.beak].map(\.boundingBoxOfPath).reduce(CGRect.null) { $0.union($1) }
            #expect(bounds.minX >= 2 && bounds.minY >= 2 && bounds.maxX <= 98 && bounds.maxY <= 98, "glyph \(glyph): \(bounds)")
            // A beak that touches the dial reads as a second needle crossing it.
            #expect(!p.beak.intersects(p.track), "glyph \(glyph): beak touches the dial")
        }
    }
}

/// Settings › <module> › Overview style.
@Suite struct CardStyleTests {
    @Test func everyCardOffersAStyleAndDefaultsToTodaysLook() {
        for card in OverviewCard.allCases { #expect(!card.styles.isEmpty && Set(card.styles).count == card.styles.count) }
        #expect(OverviewCard.cpu.styles[0] == .stacked && OverviewCard.gpu.styles[0] == .bar && OverviewCard.network.styles[0] == .text)
        #expect(OverviewCard.network.styles == [.text, .graph, .mirrored] && OverviewCard.disk.styles == [.bar, .ring, .mirrored])
        #expect(CardStyle.mirrored.title == "Mirrored")
        for kind in MenuItemKind.allCases where [.cpu, .gpu, .memory, .network, .disk].contains(kind) { #expect(OverviewCard(kind) != nil) }
    }

    @Test func aChoiceSurvivesARelaunchAndAStyleTheCardLacksFallsBack() {
        let name = "app.heron.tests.cards.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        s.setCardStyle(.gpu, .ring)
        #expect(AppSettings(defaults: d).cardStyle(.gpu) == .ring)
        s.cardStyles["network"] = "ring"  // the network card has no ring
        s.cardStyles["disk"] = "nonsense"
        #expect(s.cardStyle(.network) == .text && s.cardStyle(.disk) == .bar)
        s.reset()
        #expect(AppSettings(defaults: d).cardStyle(.gpu) == .bar)
    }
}

/// The CPU graph: user at the bottom, system stacked on top.
@Suite struct UserSystemBarsTests {
    @Test func stacksSplitTotalIntoUserAndSystemAndNeverOverflow() {
        let s = UserSystemBars.stacks(total: [0.5, 0.9, 1.4, 0.2], system: [0.1, 0.3, 0.5, 0.6])
        #expect(s.count == 4)
        #expect(abs(s[0].user - 0.4) < 1e-9 && abs(s[0].system - 0.1) < 1e-9)
        #expect(abs(s[2].user + s[2].system - 1) < 1e-9)  // a total above 100% is drawn as 100%
        #expect(s[3].user == 0 && abs(s[3].system - 0.2) < 1e-9)  // system never pokes above the total
        for x in s { #expect(x.user >= 0 && x.system >= 0 && x.user + x.system <= 1 + 1e-9) }
    }

    @Test func fewReadingsFillFromTheRightInsteadOfStretching() {
        #expect(UserSystemBars.firstSlot(count: 6, slots: 60) == 54)  // fresh launch: 6 thin bars at the right
        #expect(UserSystemBars.firstSlot(count: 60, slots: 60) == 0)
        #expect(UserSystemBars.firstSlot(count: 90, slots: 60) == 0)
    }

    @Test func seriesOfDifferentLengthsLineUpOnTheNewestValue() {
        let s = UserSystemBars.stacks(total: [0.1, 0.2, 0.8], system: [0.3])
        #expect(s.count == 1 && abs(s[0].user - 0.5) < 1e-9)
    }
}

/// CPU › Show logical cores: a ring per core in the CPU tab.
@MainActor
@Suite struct CoreRingsTests {
    @Test func ringsWrapIntoEvenRowsOfAtMostEight() {
        #expect(CoreRings.columns(for: 0) == 1)
        #expect(CoreRings.columns(for: 8) == 8)  // M1/M2: one row
        #expect(CoreRings.columns(for: 10) == 5)  // 2 rows of 5
        #expect(CoreRings.columns(for: 14) == 7)  // M3 Max: 2 rows of 7
        #expect(CoreRings.columns(for: 24) == 8)  // Ultra: 3 rows of 8
        for n in 1...32 { #expect(CoreRings.columns(for: n) <= 8) }
    }

    @Test func theOptionIsOnByDefaultSurvivesARelaunchAndResets() {
        let name = "app.heron.tests.cores.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: d)
        #expect(s.showCores)
        s.showCores = false
        #expect(!AppSettings(defaults: d).showCores)
        s.reset()
        #expect(s.showCores && AppSettings(defaults: d).showCores)
    }
}

/// Defect class "setting forgotten by Reset": every key AppSettings saves must be listed in
/// `AppSettings.keys`, or Reset leaves it behind.
@Suite struct SettingsKeyListTests {
    @Test func everySavedKeyIsInTheResetList() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/HeronUI/AppSettings.swift"), encoding: .utf8)
        let saved = try NSRegularExpression(pattern: #"save(?:JSON)?\([^,]+,\s*"([A-Za-z]+)"\)"#)
            .matches(in: source, range: NSRange(source.startIndex..., in: source))
            .map { String(source[Range($0.range(at: 1), in: source)!]) }
        #expect(saved.count >= 15, "the scan found too few save calls: \(saved)")
        for key in saved { #expect(AppSettings.keys.contains(key), "\(key) is saved but Reset does not clear it") }
    }
}
