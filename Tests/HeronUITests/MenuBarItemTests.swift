import AppKit
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

// The menu bar item of the UX redesign: labels per item, the hottest sensor's group tag, DISK,
// digits-only width, plain ink for normal temperatures, and the right-click menu's order.

@MainActor
@Suite struct MenuBarItemTests {
    func snapshot(hottest: Sensor) -> Snapshot {
        var s = Snapshot()
        s.disk = DiskReading(
            volumes: [VolumeReading(name: "Macintosh HD", path: "/", total: 1_000_000_000_000, available: 351_000_000_000, isInternal: true, format: "APFS")],
            readBytesPerSecond: 0, writeBytesPerSecond: 0)
        s.sensors = [hottest, Sensor(id: "x", name: "SSD 1", group: .ssd, celsius: 42, isKnown: true)]
        return s
    }

    func width(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return CGFloat(renderer.cgImage?.width ?? 0) / 2
    }

    /// Stores menu items and the two retired switches the way the previous version did.
    func storeOld(_ d: UserDefaults, barLabels: Bool?, valueLabels: Bool?) {
        // The previous version's JSON: no "label" field.
        let json =
            #"[{"kind":"cpu","enabled":true,"style":"bar"},{"kind":"memory","enabled":true,"style":"text"},"#
            + #"{"kind":"temperature","enabled":true,"style":"hottest"},{"kind":"disk","enabled":true,"style":"free"},"# + #"{"kind":"gpu","enabled":false,"style":"gauge"}]"#
        d.set(Data(json.utf8), forKey: "menuItems")
        if let barLabels { d.set(barLabels, forKey: "barLabels") }
        if let valueLabels { d.set(valueLabels, forKey: "valueLabels") }
    }

    /// The global "Labels on bars" / "Labels on values" become each item's label: off turns the
    /// label off for the items whose look it covered, and the old keys are gone after the launch.
    @Test func oldLabelSwitchesMigrateToEachItem() {
        let both = scratchDefaults("migrate-both")
        storeOld(both, barLabels: false, valueLabels: false)
        let s = AppSettings(defaults: both)
        #expect(!s.showsLabel(.cpu))  // a bar
        #expect(!s.showsLabel(.memory))  // "MEM 77%"
        #expect(!s.showsLabel(.temperature))  // "CPU ▲81°"
        #expect(s.showsLabel(.disk))  // "351 GB free" has no label
        #expect(s.showsLabel(.gpu))  // a gauge has no label
        #expect(both.object(forKey: "barLabels") == nil && both.object(forKey: "valueLabels") == nil)
        let again = AppSettings(defaults: both)  // the migration was saved with the items
        #expect(!again.showsLabel(.cpu) && !again.showsLabel(.temperature) && again.showsLabel(.disk))

        let bars = scratchDefaults("migrate-bars")
        storeOld(bars, barLabels: false, valueLabels: nil)
        let b = AppSettings(defaults: bars)
        #expect(!b.showsLabel(.cpu) && b.showsLabel(.memory) && b.showsLabel(.temperature))

        let values = scratchDefaults("migrate-values")
        storeOld(values, barLabels: true, valueLabels: false)
        let v = AppSettings(defaults: values)
        #expect(v.showsLabel(.cpu) && !v.showsLabel(.memory) && !v.showsLabel(.temperature))

        let none = scratchDefaults("migrate-none")
        storeOld(none, barLabels: nil, valueLabels: nil)
        #expect(MenuItemKind.allCases.allSatisfy(AppSettings(defaults: none).showsLabel))
    }

    /// One item's label changes that item only, survives a relaunch and resets.
    @Test func aLabelBelongsToItsItem() {
        let d = scratchDefaults("label-own")
        let s = AppSettings(defaults: d)
        var snap = Snapshot()
        snap.cpu = CPUReading(user: 0.5, system: 0, idle: 0.5, cores: [], loadAverage: [])
        snap.gpu = GPUReading(device: 0.5)
        func image(_ kind: MenuItemKind) -> NSImage {
            MenuBarRenderer.image(of: MenuBarSegment(kind: kind, style: .bar, snapshot: snap, history: MetricHistory(), settings: s), scale: 2)
        }
        let cpu = image(.cpu), gpu = image(.gpu)
        #expect(sameImage(image(.gpu), gpu))  // the comparison itself is stable
        s.setLabel(.cpu, false)
        #expect(!sameImage(image(.cpu), cpu))
        #expect(sameImage(image(.gpu), gpu))
        #expect(!AppSettings(defaults: d).showsLabel(.cpu) && AppSettings(defaults: d).showsLabel(.gpu))
        s.reset()
        #expect(s.showsLabel(.cpu) && AppSettings(defaults: d).showsLabel(.cpu))
    }

    /// Items stored without a label field keep every other field (tolerant decoding).
    @Test func anItemWithoutALabelDecodes() throws {
        let item = try JSONDecoder().decode(MenuItemConfig.self, from: Data(#"{"kind":"fans","enabled":true,"style":"percent"}"#.utf8))
        #expect(item == MenuItemConfig(kind: .fans, enabled: true, style: .percent, label: true))
        let off = try JSONDecoder().decode(MenuItemConfig.self, from: Data(#"{"kind":"fans","enabled":true,"style":"percent","label":false}"#.utf8))
        #expect(!off.label)
    }

    /// The hottest temperature is tagged with its sensor's group and marked ▲ ("GPU ▲81°"); the
    /// sensor's own name goes to the item's tooltip, never into the bar.
    @Test func theHottestShowsItsGroupAndTheTooltipItsName() {
        let s = AppSettings(defaults: scratchDefaults("hottest"))
        s.setShown(.temperature, true)
        let snap = snapshot(hottest: Sensor(id: "g", name: "GPU 3", group: .gpu, celsius: 81, isKnown: true))
        let segment = MenuBarSegment(kind: .temperature, style: .hottest, snapshot: snap, history: MetricHistory(), settings: s)
        #expect(segment.labelWord == "GPU")
        #expect(segment.taggedValue == "▲81°")
        #expect(MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s).toolTip == "Hottest sensor: GPU 3 · 81°")
        // Performance-core sensors are the CPU group.
        let pcore = snapshot(hottest: Sensor(id: "p", name: "CPU P-core 12", group: .cpuPerformance, celsius: 90, isKnown: true))
        #expect(MenuBarSegment(kind: .temperature, style: .hottest, snapshot: pcore, history: MetricHistory(), settings: s).labelWord == "CPU")
        // A long name and a short one in the same group draw the same: the name is not in the bar.
        let short = snapshot(hottest: Sensor(id: "a", name: "CPU 1", group: .cpu, celsius: 81, isKnown: true))
        let long = snapshot(hottest: Sensor(id: "b", name: "CPU P-core 12 with a long name", group: .cpu, celsius: 81, isKnown: true))
        s.nameHottest = true
        #expect(
            sameImage(
                MenuBarRenderer.image(for: MenuBarLabel(snapshot: short, history: MetricHistory(), settings: s), scale: 2),
                MenuBarRenderer.image(for: MenuBarLabel(snapshot: long, history: MetricHistory(), settings: s), scale: 2)))
        // A fixed sensor has no tooltip.
        s.setStyle(.temperature, .cpu)
        #expect(MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s).toolTip == nil)
        s.setStyle(.temperature, .hottest); s.setShown(.temperature, false)
        #expect(MenuBarLabel(snapshot: snap, history: MetricHistory(), settings: s).toolTip == nil)
    }

    /// Disk percent and bar are tagged DISK (not SSD).
    @Test func diskLooksAreTaggedDisk() {
        let s = AppSettings(defaults: scratchDefaults("disk"))
        let snap = snapshot(hottest: Sensor(id: "c", name: "CPU 1", group: .cpu, celsius: 50, isKnown: true))
        for style in [MenuItemStyle.percent, .bar] {
            #expect(MenuBarSegment(kind: .disk, style: style, snapshot: snap, history: MetricHistory(), settings: s).labelWord == "DISK")
        }
        // The rendered tag is that word: as wide as "DISK" in the tag font, and gone with the label.
        let on = width(MenuBarSegment(kind: .disk, style: .percent, snapshot: snap, history: MetricHistory(), settings: s))
        s.setLabel(.disk, false)
        let off = width(MenuBarSegment(kind: .disk, style: .percent, snapshot: snap, history: MetricHistory(), settings: s))
        let word = ("DISK" as NSString).size(withAttributes: [.font: MenuBarSegment.tagFont, .kern: MenuBarSegment.tagTracking]).width
        #expect(abs((on - off) - (word + MenuBarSegment.gap)) < 2, "tag \(on - off) vs DISK \(word)")
    }

    /// Red means attention: with metric colours a normal temperature keeps the plain ink; only a
    /// hot one turns red.
    @Test func metricColoursNeverPaintANormalTemperatureRed() {
        let s = AppSettings(defaults: scratchDefaults("temp-colour"))
        s.colourMode = .metric
        var snap = snapshot(hottest: Sensor(id: "c", name: "CPU 1", group: .cpu, celsius: 60, isKnown: true))
        for style in MenuItemKind.temperature.styles {
            let segment = MenuBarSegment(kind: .temperature, style: style, snapshot: snap, history: MetricHistory(), settings: s)
            #expect(!segment.isColoured, "\(style)")
            #expect(segment.valueInk == Color.black)
        }
        snap.sensors[0].celsius = 95
        #expect(MenuBarSegment(kind: .temperature, style: .hottest, snapshot: snap, history: MetricHistory(), settings: s).isWarning)
    }

    /// Settings › Menu Bar's drag and ⌥⌘↑ ↓ move an item onto another's place; it is saved.
    @Test func movingAnItemReordersTheMenuBar() {
        let d = scratchDefaults("move")
        let s = AppSettings(defaults: d)
        s.moveItem(.battery, onto: .cpu)
        #expect(s.menuItems.map(\.kind).first == .battery)
        #expect(Set(s.menuItems.map(\.kind)) == Set(MenuItemKind.allCases) && s.menuItems.count == MenuItemKind.allCases.count)
        #expect(AppSettings(defaults: d).menuItems.first?.kind == .battery)
    }
}

@MainActor
@Suite struct StatusMenuTests {
    /// The right-click menu, ordered by use: Settings… (⌘,), Open Activity Monitor, then Check for
    /// Updates…, What's New, About Heron, then Quit Heron (⌘Q).
    @Test func theRightClickMenuIsOrderedByUse() {
        let target = NSObject()
        let menu = StatusMenu.make(target: target) { $0 == .checkForUpdates ? nil : #selector(NSObject.description) }
        #expect(
            menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                == ["Settings…", "Open Activity Monitor", "—", "Check for Updates…", "What’s New", "About Heron", "—", "Quit Heron"])
        #expect(menu.items.map(\.keyEquivalent) == [",", "", "", "", "", "", "", "q"])
        #expect(menu.items.filter { !$0.keyEquivalent.isEmpty }.allSatisfy { $0.keyEquivalentModifierMask == .command })
        #expect(menu.items.first { $0.title == "Check for Updates…" }?.action == nil)  // a build without updates
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === target })
    }
}

/// Two renders of one view can differ by 1/255 in an edge pixel's alpha (antialiasing), and their
/// TIFF or raw bytes carry row padding that differs too; byte-comparing them failed at random. The
/// same image: the same pixel size and every channel within 2/255.
func sameImage(_ a: NSImage, _ b: NSImage) -> Bool {
    func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:))
    }
    guard let a = bitmap(a), let b = bitmap(b), a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return false }
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            let channels = [
                (p.redComponent, q.redComponent), (p.greenComponent, q.greenComponent),
                (p.blueComponent, q.blueComponent), (p.alphaComponent, q.alphaComponent),
            ]
            if channels.contains(where: { abs($0.0 - $0.1) > 2.0 / 255 }) { return false }
        }
    }
    return true
}

/// Class: an image test that byte-compares renders passes or fails at random. Tests compare
/// rendered images with `sameImage` only.
@Suite struct ImageComparisonGuardTests {
    @Test func noTestByteComparesARenderedImage() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let banned = ["tiff" + "Representation", "dataProvider?.data" + " as Data"]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for token in banned { #expect(!text.contains(token), "\(name) compares image bytes (\(token)); use sameImage") }
        }
    }
}
