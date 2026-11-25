import AppKit
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

// Guards for the two decisions of the 2026-11-25 sweep (docs/workstreams/heron-audit-2026-11-25.md):
// AUD-001 Privacy Mode covers every window, AUD-002 nothing shows a number before the readings.

@MainActor
@Suite struct AuditGuardTests {
    /// Two snapshots still waiting for their readings, one nearly idle and one busy: whatever a
    /// surface draws must not depend on them.
    func waiting(busy: Bool) -> Snapshot {
        var s = Snapshot()
        s.awaitingReadings = true
        let f = busy ? 0.9 : 0.04
        s.cpu = CPUReading(user: f, system: 0, idle: 1 - f, cores: [], loadAverage: [])
        s.gpu = GPUReading(device: f)
        s.memory = MemoryReading(
            total: 100_000_000_000, app: UInt64(f * 90_000_000_000), wired: 0, compressed: 0, cached: 0,
            free: 5_000_000_000, swapUsed: 0, pressure: busy ? .warning : .normal, pressurePercent: f)
        s.network = NetworkReading(
            interface: "en0", interfaceKind: "Wi-Fi", localIP: nil, downBytesPerSecond: f * 1e6, upBytesPerSecond: f * 1e5, sessionDown: 0, sessionUp: 0)
        s.disk = DiskReading(
            volumes: [VolumeReading(name: "HD", path: "/", total: 1_000_000_000_000, available: UInt64((1 - f) * 1e12), isInternal: true, format: "APFS")],
            readBytesPerSecond: f * 1e6, writeBytesPerSecond: 0)
        s.fans = [Fan(id: 0, name: "Fan", rpm: f * 7_000, minRPM: 0, maxRPM: 7_000)]
        s.battery = BatteryReading(present: true, percent: f, isCharging: false, onAC: true)
        s.sensors = [Sensor(id: "c", name: "CPU 1", group: .cpu, celsius: busy ? 90 : 40, isKnown: true)]
        return s
    }

    func image(_ view: some View) -> (bytes: [UInt8], width: Int, height: Int) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return ([], 0, 0) }
        return (Array(UnsafeBufferPointer(start: p, count: CFDataGetLength(data))), cg.width, cg.height)
    }

    /// AUD-002, menu bar: before the readings every item keeps its width and draws nothing (never
    /// "CPU 0%"), and VoiceOver hears no number.
    @Test func menuBarItemsDrawNoNumberBeforeTheReadings() {
        let settings = AppSettings(defaults: scratchDefaults("audit-menubar"))
        for kind in MenuItemKind.allCases where kind != .ai {
            for style in kind.styles {
                let idle = MenuBarSegment(kind: kind, style: style, snapshot: waiting(busy: false), history: MetricHistory(), settings: settings)
                let busy = MenuBarSegment(kind: kind, style: style, snapshot: waiting(busy: true), history: MetricHistory(), settings: settings)
                let a = image(idle), b = image(busy)
                #expect(a.width > 0, "\(kind) \(style) keeps its width")
                // Nothing drawn, give or take render noise under a busy parallel run (as with the
                // cards below); a drawn value is opaque ink, 255.
                let inked = a.bytes.filter { $0 > 8 }
                #expect(inked.isEmpty, "\(kind) \(style) draws nothing before the readings (\(inked.count) bytes, max \(a.bytes.max() ?? 0))")
                #expect(a.width == b.width, "\(kind) \(style)")
                #expect(idle.spokenValue.rangeOfCharacter(from: .decimalDigits) == nil, "\(kind) \(style): \(idle.spokenValue)")
            }
        }
    }

    /// AUD-002, overview: before the readings each card keeps the size it has with readings (no
    /// jump when they arrive) and draws the same pixels whatever the readings are (its title
    /// alone, no number).
    @Test func cardsDrawTheirTitleAloneBeforeTheReadings() {
        let settings = AppSettings(defaults: scratchDefaults("audit-cards"))
        func card(_ part: OverviewPart, _ style: CardStyle, _ s: Snapshot) -> some View {
            OverviewSection(snapshot: s, only: part, style: style).frame(width: 360).environment(Monitor()).environment(settings).environment(AppServices())
        }
        for part in OverviewPart.allCases where part != .ai {
            for style in CardStyle.allCases {
                var settled = waiting(busy: false)
                settled.awaitingReadings = false
                let idle = image(card(part, style, waiting(busy: false))), busy = image(card(part, style, waiting(busy: true)))
                let shown = image(card(part, style, settled))
                #expect(idle.height > 0)
                #expect(idle.height == shown.height, "\(part) \(style): \(idle.height) before the readings, \(shown.height) after")
                // Same pixels, give or take antialiasing: under a busy parallel run the battery
                // tile's edge came out 1/255 apart in 8 bytes (2026-11-26); a drawn digit is ~100.
                #expect(idle.bytes.count == busy.bytes.count, "\(part) \(style): sizes differ before the readings")
                let off = idle.bytes.indices.filter { $0 < busy.bytes.count && abs(Int(idle.bytes[$0]) - Int(busy.bytes[$0])) > 8 }
                let at = off.first.map { "row \($0 / max(1, idle.width * 4) / 2) pt, \(off.count) bytes" } ?? ""
                #expect(off.isEmpty, "\(part) \(style) draws a reading before the readings (\(at))")
                #expect(idle.bytes != shown.bytes, "\(part) \(style) still draws its readings once they arrive")
            }
        }
    }

    /// AUD-001: every file of the app that makes a window also gives it Privacy Mode
    /// (`NSWindow.setPrivate`, which covers its sheet), every sheet follows its parent, and
    /// `applySettings` hands Privacy Mode to both window owners (the status item's and the rest).
    @Test func privacyModeReachesEveryWindow() throws {
        let makers = ["NSWindow(", "NSPopover()", "DetailPanelWindow(", "statusItem(", "NSPanel("]
        let files = sourceFiles("Heron")
        #expect(!files.isEmpty)
        for file in files where makers.contains(where: file.text.contains) && file.name != "DetailPanelWindow.swift" {
            #expect(file.text.contains(".setPrivate("), "\(file.name) makes a window but never gives it Privacy Mode")
        }
        let manager = try #require(files.first { $0.name == "WindowManager.swift" }?.text)
        #expect(manager.contains("willBeginSheetNotification"), "a sheet is a window of its own: it must follow its parent's Privacy Mode")
        #expect(manager.contains("[self, attachedSheet]"), "setPrivate must cover the sheet already on a window")
        let app = try #require(files.first { $0.name == "AppDelegate.swift" }?.text)
        #expect(app.contains("statusBar.privacy = settings.aiUsage.privacyMode"))
        #expect(app.contains("windows.privacy = settings.aiUsage.privacyMode"))
    }
}
