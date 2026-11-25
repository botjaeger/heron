import AppKit
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

// Guards for the defect classes of the redesign sweep (docs/workstreams/heron-redesign-defect-classes.md).

/// Source files of a target, read from the package (tests run from the package root or below it).
func sourceFiles(_ target: String) -> [(name: String, text: String)] {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path), dir.path != "/" { dir.deleteLastPathComponent() }
    let folder = dir.appendingPathComponent("Sources").appendingPathComponent(target)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
        (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
    }
}

@MainActor
@Suite struct MenuBarTightnessTests {
    /// Single-digit readings: the shortest values, which leave the most room in their boxes.
    func lowSnapshot() -> Snapshot {
        var s = Snapshot()
        s.cpu = CPUReading(user: 0.04, system: 0, idle: 0.96, cores: [], loadAverage: [])
        s.gpu = GPUReading(device: 0.04)
        s.memory = MemoryReading(
            total: 100_000_000_000, app: 4_000_000_000, wired: 0, compressed: 0, cached: 0,
            free: 5_000_000_000, swapUsed: 0, pressure: .normal, pressurePercent: 0.04)
        s.network = NetworkReading(interface: "en0", interfaceKind: "Wi-Fi", localIP: nil, downBytesPerSecond: 3, upBytesPerSecond: 3, sessionDown: 0, sessionUp: 0)
        s.disk = DiskReading(
            volumes: [VolumeReading(name: "HD", path: "/", total: 1_000_000_000_000, available: 5_000_000_000, isInternal: true, format: "APFS")],
            readBytesPerSecond: 0, writeBytesPerSecond: 0)
        s.fans = [Fan(id: 0, name: "Fan", rpm: 500, minRPM: 0, maxRPM: 7_000)]
        s.battery = BatteryReading(present: true, percent: 0.05, isCharging: false, onAC: true)
        s.sensors = [Sensor(id: "c", name: "CPU 1", group: .cpu, celsius: 7, isKnown: true)]
        return s
    }

    /// The widest run of empty columns between the segment's first and last inked columns, in points.
    func widestInnerGap(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .infinity }
        let bpp = cg.bitsPerPixel / 8
        let inked = (0..<cg.width).map { x in (0..<cg.height).contains { y in bytes[y * cg.bytesPerRow + x * bpp + (bpp - 1)] > 40 } }
        guard let first = inked.firstIndex(of: true), let last = inked.lastIndex(of: true) else { return 0 }
        var widest = 0, run = 0
        for x in first...last { if inked[x] { run = 0 } else { run += 1; widest = max(widest, run) } }
        return CGFloat(widest) / 2
    }

    /// Class: a value reserved room for its widest form must not push away from its tag or glyph
    /// ("CPU   83°"). Every variant of every metric, with the shortest values.
    @Test func valuesSitNextToTheirTagOrGlyph() {
        var history = MetricHistory()
        var snap = lowSnapshot()
        // A long sensor name elsewhere: the hottest sensor must not reserve room for it.
        snap.sensorNames = ["CPU 1", "CPU P-core 12"]
        for i in 0..<10 { snap.date = Date(timeIntervalSince1970: Double(i)); history.record(snap) }
        let options: [(String, (AppSettings) -> Void)] = [
            ("default", { _ in }), ("hottest named", { $0.nameHottest = true }),
            ("labels off", { s in for k in MenuItemKind.allCases { s.setLabel(k, false) } }),
        ]
        for (name, configure) in options {
            let settings = AppSettings(defaults: scratchDefaults("tight"))
            configure(settings)
            // AI usage draws nothing without accounts: MenuBarAITests.theValueSitsNextToItsMark covers it.
            for kind in MenuItemKind.allCases where kind != .ai {
                for style in kind.styles {
                    let segment = MenuBarSegment(kind: kind, style: style, snapshot: snap, history: history, settings: settings)
                    let gap = widestInnerGap(segment)
                    // A mono space ("5 GB free") is about 8 pt with the glyphs' bearings; the tag gap 5.
                    #expect(gap <= 9.5, "\(name): \(kind.rawValue) \(style.rawValue): \(gap) pt gap")
                }
            }
        }
    }
}

/// Class: state that outlives the popover. Closing the popover must forget where the pointer was,
/// or the card under the pointer when it closed never opens its panel again on hover.
@Suite struct PanelsForgetThePointerTests {
    @Test func aCardOpensAgainAfterThePopoverWasClosedOverIt() {
        let p = DetailPanels()
        var now = 0.0
        p.clock = { now }
        p.visibleParts = { [.cpu, .gpu] }
        p.reportFrame(.cpu, CGRect(x: 0, y: 0, width: 300, height: 60))
        p.pointerInPopover(CGPoint(x: 10, y: 10))
        now = 0.2
        p.pointerInPanel(false)  // any call runs what is due
        #expect(p.open == .cpu)
        p.closeAll()  // the popover closed with the pointer on the card
        #expect(p.open == nil)
        now = 5
        p.pointerInPopover(CGPoint(x: 10, y: 10))  // reopened: the pointer rests on the same card
        now = 5.2
        p.pointerInPanel(false)
        #expect(p.open == .cpu)
    }
}

/// Class: code orphaned by the redesign (a ring drawing, a tab helper) that still compiles but
/// nothing draws. Every type the UI declares is used somewhere besides its own declaration.
@Suite struct NoOrphanedTypesTests {
    @Test func everyDeclaredTypeIsUsed() throws {
        let files = ["HeronUI", "Heron", "heron-snap"].flatMap(sourceFiles)
        let all = files.map(\.text).joined(separator: "\n")
        let declaration = try Regex(#"(?m)^\s*(?:public |private |fileprivate )?(?:final )?(?:struct|enum|class) ([A-Z][A-Za-z0-9]*)"#)
        var names = Set<String>()
        for file in sourceFiles("HeronUI") { for m in file.text.matches(of: declaration) { if let n = m.output[1].substring { names.insert(String(n)) } } }
        #expect(names.count > 20)
        for name in names.sorted() {
            // Simple word boundaries: "Theme.cpu" is one Unicode word, so the default would miss it.
            let uses = all.matches(of: try Regex("\\b\(name)\\b").wordBoundaryKind(.simple)).count
            #expect(uses > 1, "\(name) is declared but never used")
        }
    }
}

extension NoOrphanedTypesTests {
    /// The same for the theme's colours: a colour nothing paints with (the old divider `line`) is
    /// dead, and its contrast test checks nothing real.
    @Test func everyThemeColourIsUsed() throws {
        let theme = sourceFiles("HeronUI").first { $0.name == "Theme.swift" }?.text ?? ""
        let all = ["HeronUI", "Heron", "heron-snap"].flatMap(sourceFiles).map(\.text).joined(separator: "\n")
        var names = Set<String>()
        for m in theme.matches(of: try Regex(#"static let ([a-zA-Z]+): \(light: UInt32, dark: UInt32\)"#)) { if let n = m.output[1].substring { names.insert(String(n)) } }
        #expect(names.contains("cpu") && names.contains("muted"))
        for name in names.sorted() {
            // Palette.x is read once by the Color it defines (when there is one); a use is one more.
            let uses = all.matches(of: try Regex("\\.\(name)\\b").wordBoundaryKind(.simple)).count
            let definitions = theme.contains("dynamic(Palette.\(name))") ? 1 : 0
            #expect(uses > definitions, "Theme.\(name) is never used")
        }
    }
}

/// Class: colours written as hex where they are used escape the contrast tests. Every colour lives
/// in `Theme.Palette` (the Settings tiles' table excepted: white glyphs on fixed fills, checked below).
@Suite struct PaletteOnlyColoursTests {
    @Test func noHexColourOutsideTheTheme() throws {
        let hex = try Regex(#"0x[0-9A-Fa-f]{6}"#)
        for file in sourceFiles("HeronUI") where file.name != "Theme.swift" {
            for line in file.text.split(separator: "\n") where line.contains(hex) {
                let tileTable = line.contains("return 0x")  // SettingsPane.tileHex
                #expect(tileTable, "\(file.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// The Menu Bar pane's strip ink on the menu bars it is drawn on.
    @Test func menuBarInkMeetsAA() {
        let ink = Theme.Palette.menuBarInk, bgs = Theme.Palette.menuBarBackgrounds
        for bg in bgs.light { #expect(Theme.contrast(ink.light, bg) >= 4.5) }
        for bg in bgs.dark { #expect(Theme.contrast(ink.dark, bg) >= 4.5) }
        #expect(Theme.contrast(Theme.Palette.badge.text, Theme.Palette.badge.fill) >= 4.5)
    }

    /// White glyphs on the fixed fills and on every Settings tile: 3:1 (non-text contrast).
    @Test func whiteGlyphsOnFixedFillsMeetNonTextContrast() {
        for fill in [Theme.Palette.accent, Theme.Palette.success] + SettingsPane.allCases.map(\.tileHex) {
            #expect(Theme.contrast(0xFFFFFF, fill) >= 3, "\(String(fill, radix: 16))")
        }
    }

    /// The accent fill also carries white text (the Updates pane's "Install"): 4.5:1.
    @Test func whiteTextOnTheAccentMeetsTextContrast() {
        #expect(Theme.contrast(0xFFFFFF, Theme.Palette.accent) >= 4.5)
    }
}

/// Class: one reading, two verdicts (red on the card, plain in the menu bar). The "too hot", "nearly
/// full" and "low" thresholds live in `Warnings` alone.
@Suite struct OneWarningRuleTests {
    @Test func thresholdsLiveInWarningsOnly() throws {
        let threshold = try Regex(#">= ?90\b|0\.95\b|percent < 0\.\d|10_000_000_000"#)
        for file in sourceFiles("HeronUI") where file.name != "Warnings.swift" {
            for line in file.text.split(separator: "\n") where line.contains(threshold) {
                Issue.record("\(file.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    @Test func theRulesAgreeAtTheirEdges() {
        #expect(!Warnings.isHot(89.9) && Warnings.isHot(90))
        let big = VolumeReading(name: "HD", path: "/", total: 2_000_000_000_000, available: 90_000_000_000, isInternal: true, format: "APFS")
        #expect(Warnings.isNearlyFull(big))  // 95.5% used
        let small = VolumeReading(name: "HD", path: "/", total: 100_000_000_000, available: 9_000_000_000, isInternal: true, format: "APFS")
        #expect(Warnings.isNearlyFull(small))  // 91% used, under 10 GB
        var b = BatteryReading(present: true, percent: 0.19, isCharging: false, onAC: false)
        #expect(Warnings.isLow(b))
        b.onAC = true
        #expect(!Warnings.isLow(b))
    }
}

/// Class: one quantity, two sources (the menu bar read the first fan, the overview the average;
/// the battery card averaged its sensors, the panel read the battery). Every place asks one helper.
@MainActor
@Suite struct OneSourcePerReadingTests {
    func settings() -> AppSettings { AppSettings(defaults: scratchDefaults("source")) }

    @Test func theMenuBarAndTheOverviewShowTheSameFans() {
        var s = Snapshot()
        s.fans = [Fan(id: 0, name: "Left", rpm: 2_000, minRPM: 0, maxRPM: 6_000), Fan(id: 1, name: "Right", rpm: 4_000, minRPM: 0, maxRPM: 6_000)]
        let set = settings()
        func spoken(_ style: MenuItemStyle) -> String {
            MenuBarSegment(kind: .fans, style: style, snapshot: s, history: MetricHistory(), settings: set).spokenValue
        }
        #expect(FanSummary.rpm(s.fans) == 3_000 && FanSummary.fraction(s.fans) == 0.5)
        #expect(spoken(.rpm) == "Fans 3,000 rpm")
        #expect(spoken(.percent) == "Fans 50% of maximum")
        // No site picks one fan to stand for all of them.
        for file in sourceFiles("HeronUI") { #expect(!file.text.contains("fans.first"), "\(file.name)") }
    }

    @Test func theBatteryCardThePanelAndTheHistoryShowOneTemperature() {
        var s = Snapshot()
        s.battery = BatteryReading(present: true, percent: 0.5, isCharging: false, onAC: false, temperatureC: 33)
        s.sensors = [
            Sensor(id: "a", name: "Battery 1", group: .battery, celsius: 30, isKnown: true),
            Sensor(id: "b", name: "Battery 2", group: .battery, celsius: 40, isKnown: true),
        ]
        func panel() -> String? { PanelRows.battery(s, unit: .celsius).first { $0.key == "Temperature" }?.value }
        func history() -> Double? { var h = MetricHistory(); h.record(s); return h.latest(.metric(.batteryTemperature)) }
        #expect(SensorSummary.batteryCelsius(in: s) == 33 && panel() == "33°" && history() == 33)
        s.battery?.temperatureC = nil  // no reading of its own: its sensors' average
        #expect(SensorSummary.batteryCelsius(in: s) == 35 && panel() == "35°" && history() == 35)
    }
}

/// Class: frames and the pointer in different spaces (`CardFrameSpaceTests` checks the numbers).
/// No view reads a frame in `.global`, the popover window's space.
@Suite struct NoGlobalFramesTests {
    @Test func framesAreReadInANamedSpace() {
        for file in ["HeronUI", "Heron"].flatMap(sourceFiles) {
            #expect(!file.text.contains("frame(in: .global)"), "\(file.name)")
        }
    }
}

/// Class: a removed view left behind by name. The AI panel's Priority view is gone (2026-11-23):
/// no string, label, help or comment in the app says "Priority" (the `AIPriorityBoard` ranking
/// type and `layoutPriority` are other words).
@Suite struct NoPriorityViewTests {
    @Test func nothingInTheAppSaysPriority() throws {
        let word = try Regex("(^|[^A-Za-z])Priority([^A-Za-z]|$)")
        var scanned = 0
        for file in ["HeronUI", "Heron"].flatMap(sourceFiles) {
            scanned += 1
            #expect(!file.text.contains("\"Priority\""), "\(file.name): the string \"Priority\"")
            for (i, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                #expect(line.firstMatch(of: word) == nil, "\(file.name):\(i + 1): \(line)")
            }
        }
        #expect(scanned > 20)
    }
}

/// Class: UTC vs local days. Heron shows the user's own days: no string the app or its core can
/// show says "(UTC)" (heron-snap's fixtures included, so the pictures match).
@Suite struct NoUTCLabelsTests {
    @Test func noVisibleStringSaysUTC() throws {
        let literal = try Regex(#""[^"\n]*\(UTC\)[^"\n]*""#)
        var scanned = 0
        for file in ["HeronCore", "HeronUI", "heron-snap"].flatMap(sourceFiles) {
            scanned += 1
            for (i, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                #expect(line.firstMatch(of: literal) == nil, "\(file.name):\(i + 1): \(line)")
            }
        }
        #expect(scanned > 40)
    }

    /// A formatter given a calendar takes its zone too: `DateFormatter` keeps the system's zone
    /// otherwise, so a date printed for a given calendar shows another zone's time
    /// (`AIText.resetDate`, `AIDuration.reset`).
    @Test func aFormatterGivenACalendarTakesItsZone() {
        var sites = 0
        for file in ["HeronCore", "HeronUI", "Heron", "heron-snap"].flatMap(sourceFiles) {
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() where line.contains(".calendar = calendar") {
                sites += 1
                let after = lines[i..<min(lines.count, i + 5)]
                #expect(after.contains { $0.contains(".timeZone = calendar.timeZone") }, "\(file.name):\(i + 1): set the formatter's timeZone")
            }
        }
        #expect(sites >= 2)
    }
}

/// Class: one reading found several ways. The startup disk is `VolumeReading.isRoot` /
/// `Snapshot.rootVolume`; nothing else compares a volume's path with "/".
@Suite struct RootVolumeTests {
    @Test func theStartupDiskIsFoundInOnePlace() {
        var scanned = 0
        for file in ["HeronCore", "HeronUI", "Heron", "heron-snap", "heron-probe"].flatMap(sourceFiles) where file.name != "Models.swift" {
            scanned += 1
            #expect(!file.text.contains("path == \"/\""), "\(file.name): use rootVolume or isRoot")
        }
        #expect(scanned > 20)
        var s = Snapshot()
        s.disk = DiskReading(
            volumes: [
                VolumeReading(name: "Ext", path: "/Volumes/Ext", total: 1, available: 1, isInternal: false, format: "APFS"),
                VolumeReading(name: "HD", path: "/", total: 2, available: 1, isInternal: true, format: "APFS"),
            ],
            readBytesPerSecond: 0, writeBytesPerSecond: 0)
        #expect(s.rootVolume?.name == "HD")
    }
}

/// Class: a value meant to stand out in the text colour drawn muted. `.foregroundStyle(.primary)`
/// is the hierarchical style, which resolves against the enclosing style: inside a muted line it
/// is muted too ("Read 388 MB/s" all grey). The text colour is `Color.primary`.
@Suite struct TextColourIsAColourTests {
    @Test func noHierarchicalPrimaryInTheUI() {
        for file in sourceFiles("HeronUI") {
            #expect(!file.text.contains("foregroundStyle(.primary)"), "\(file.name)")
        }
    }
}

/// Class: a menu whose label never shows. AppKit draws a `Menu`'s label from its text and images
/// only; the card's "…" was a SwiftUI-drawn glyph and never appeared. A menu label is a `Text` or
/// an `Image`, never `HeronIconView`, a `Canvas` or a shape.
@Suite struct MenuLabelsAreTextOrImagesTests {
    @Test func noDrawnGlyphInAMenuLabel() {
        var labels = 0
        for file in sourceFiles("HeronUI") {
            for menu in file.text.ranges(of: "Menu {") {
                // A SwiftUI `Menu`, not `.contextMenu {` or `enum CardMenu {`.
                guard menu.lowerBound > file.text.startIndex, file.text[file.text.index(before: menu.lowerBound)].isWhitespace else { continue }
                let after = file.text[menu.upperBound...]
                guard let label = after.range(of: "} label: {") else { continue }
                let body = after[label.upperBound...].prefix { $0 != "}" }
                labels += 1
                for drawn in ["HeronIconView", "Canvas", "Shape", "Circle(", "Rectangle("] {
                    #expect(!body.contains(drawn), "\(file.name): a menu label draws \(drawn)")
                }
            }
        }
        #expect(labels > 0)  // the scan found the menus it guards
    }
}

/// Class: a process's CPU in Activity Monitor's per-core percent ("1038%") where nothing says
/// "100% = one core". Every per-core figure sits in a list with that caption; anywhere else a
/// process's CPU is its share of the whole Mac (`ProcessUsage.cpuShare`).
@Suite struct PerCorePercentIsCaptionedTests {
    @Test func everyPerCorePercentHasItsCaption() {
        var found = 0
        for file in sourceFiles("HeronUI") {
            for use in file.text.ranges(of: ".cpu * 100") {
                found += 1
                let before = file.text[..<use.lowerBound].suffix(300)
                #expect(before.contains("caption: \"100% = one core\""), "\(file.name): a per-core percent without its caption")
            }
        }
        #expect(found > 0)
    }
}

/// Class: a time axis that lies. A graph labelled "24 hours ago … now" holding two minutes of
/// data drew those two minutes across the whole day. Graphs under an axis cover only their part.
@Suite struct HonestTimeAxisTests {
    @Test func historyKnowsHowManySecondsItHolds() {
        var h = MetricHistory()
        var s = Snapshot()
        s.cpu = CPUReading(user: 0.1, system: 0, idle: 0.9, cores: [], loadAverage: [])
        s.fans = [Fan(id: 3, name: "Fan", rpm: 1_000, minRPM: 0, maxRPM: 5_000)]
        for i in 0..<125 { s.date = Date(timeIntervalSince1970: Double(i)); h.record(s) }
        #expect(h.seconds(.metric(.cpu)) == 125)  // every-second buffer
        #expect(h.seconds(.metric(.memoryApp)) == 0)  // never reported
        #expect(h.seconds(.item(ItemKey(.fanRPM, id: 3))) == 125)  // tiered: 12 buckets of 10 s + 5 filling
        #expect(TimeAxis.coverage(recorded: 120, range: 86_400) < 0.002)
        #expect(TimeAxis.coverage(recorded: 90_000, range: 86_400) == 1)
        // Past the finest tier's 600 s, the coarser tiers still count the whole span.
        var t = TieredHistory()
        for _ in 0..<1_000 { t.append(1) }
        #expect(t.seconds == 1_000)
    }

    @Test func everyAgoAxisDrawsItsGraphOverTheCoveredPart() {
        var total = 0
        for file in sourceFiles("HeronUI") {
            // The axis labels: "<range> ago" (a `Text` or an `AxisLabels` entry) and `HistoryView.ago`.
            let axes =
                file.text.components(separatedBy: "label) ago\"").count - 1 + file.text.components(separatedBy: "Self.ago(range)").count - 1
                + file.text.components(separatedBy: "lineSeconds) s ago\"").count - 1
            let covered = file.text.components(separatedBy: "TimeCovered(fraction:").count - 1
            #expect(covered >= axes, "\(file.name): \(axes) time axes, \(covered) covered graphs")
            total += axes
        }
        #expect(total >= 5)  // the history, the CPU panel (bars and graph), the GPU line and the network graph

    }
}

/// Class: a new setting that "Reset all settings" forgets. `reset()` copies every stored setting
/// back from fresh defaults, first-run state excepted.
@Suite struct ResetCoversEverySettingTests {
    @Test func resetAssignsEveryStoredSetting() {
        let source = sourceFiles("HeronUI").first { $0.name == "AppSettings.swift" }?.text ?? ""
        guard let start = source.range(of: "public func reset()"), let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            Issue.record("no reset()"); return
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        for key in AppSettings.keys where !SettingsPane.internalKeys.contains(key) {
            #expect(body.contains("\(key) = fresh.\(key)"), "reset() leaves \(key) as it was")
        }
    }
}

/// A private UserDefaults domain for one test, removed when the test process ends. Domains the
/// tests never removed piled up as app.heron.tests.<uuid>.plist files, one per test run.
func scratchDefaults(_ tag: String) -> UserDefaults {
    let name = "app.heron.tests.\(tag).\(UUID().uuidString)"
    ScratchDomains.shared.add(name)
    return UserDefaults(suiteName: name)!
}

/// Nonisolated: the target's default isolation is the main actor, but `atexit` runs on whichever
/// thread calls `exit` (Swift Testing's, not the main one), and a main-actor closure traps there.
nonisolated final class ScratchDomains: @unchecked Sendable {
    static let shared = ScratchDomains()
    private let lock = NSLock()
    private var names: [String] = []

    private init() {
        atexit { ScratchDomains.shared.removeAll() }
    }

    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
        names = []
    }
}

@Suite struct NoLeakedDefaultsTests {
    /// Every test domain is removed: made by `scratchDefaults`, or named and removed by its test.
    @Test func testsRemoveTheirDefaultsDomains() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        dir.deleteLastPathComponent()
        for folder in ["HeronUITests", "HeronCoreTests"] {
            let url = dir.appendingPathComponent(folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasSuffix(".swift") {
                let text = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                #expect(!text.contains("UserDefaults(suiteName: \""), "\(name) makes a domain it never removes")
            }
        }
    }
}

/// Class: a reading this Mac has no source for draws a placeholder ("—", "0 rpm"). The menu bar
/// leaves such an item out, and keeps the Heron glyph when nothing else would draw.
@MainActor
@Suite struct MenuBarNoSourceTests {
    @Test func itemsWithoutASourceAreLeftOut() {
        let settings = AppSettings(defaults: scratchDefaults("nosource"))
        settings.setShown(.battery, true)
        settings.setShown(.fans, true)
        settings.showIcon = false
        var s = Snapshot()
        s.battery = BatteryReading(present: false, percent: 0, isCharging: false, onAC: true)
        s.fans = []
        let none = MenuBarLabel(snapshot: s, history: MetricHistory(), settings: settings)
        #expect(none.segments.isEmpty)
        #expect(none.showsIcon)  // the item never vanishes
        s.battery = BatteryReading(present: true, percent: 0.5, isCharging: false, onAC: true)
        s.fans = [Fan(id: 0, name: "Fan", rpm: 2_000, minRPM: 0, maxRPM: 7_000)]
        let both = MenuBarLabel(snapshot: s, history: MetricHistory(), settings: settings)
        #expect(both.segments.map(\.kind) == [.fans, .battery] || both.segments.map(\.kind) == [.battery, .fans])
        #expect(!both.showsIcon)
    }

    /// A look that needs a reading of its own: fans as a percentage with no fan reporting its
    /// maximum drew "FAN –"; a temperature whose sensor this Mac lacks drew "SSD –".
    @Test func aLookWithoutItsReadingIsLeftOut() {
        let settings = AppSettings(defaults: scratchDefaults("nosource-look"))
        settings.setShown(.fans, true)
        settings.setStyle(.fans, .percent)
        settings.setShown(.temperature, true)
        settings.setStyle(.temperature, .ssd)
        settings.showIcon = false
        var s = Snapshot()
        s.fans = [Fan(id: 0, name: "Fan", rpm: 2_000, minRPM: 0, maxRPM: 0)]
        let none = MenuBarLabel(snapshot: s, history: MetricHistory(), settings: settings)
        #expect(none.segments.isEmpty)
        #expect(none.showsIcon)
        s.fans = [Fan(id: 0, name: "Fan", rpm: 2_000, minRPM: 0, maxRPM: 7_000)]
        settings.setStyle(.temperature, .hottest)
        let hidden = MenuBarLabel(snapshot: s, history: MetricHistory(), settings: settings)
        #expect(hidden.segments.map(\.kind) == [.fans])  // no sensor at all: no hottest either
        for segment in MenuBarLabel(snapshot: s, history: MetricHistory(), settings: settings).segments {
            #expect(!segment.taggedValue.contains("–"))
        }
    }
}
