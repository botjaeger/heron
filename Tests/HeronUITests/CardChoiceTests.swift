import AppKit
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

// Mirrored bars (Network and Disk "Mirrored"), the Sensors card's temperatures, naming the hottest
// sensor and the menu bar's "Labels on values".

/// Mirrored bars: 60 one-second slots, newest at the right, one scale with 15% headroom.
@Suite struct MirroredBarsTests {
    let size = CGSize(width: 300, height: 34)

    @Test func fewReadingsSitInTheRightMostSlotsHalfASlotWide() {
        let bars = MirroredBars.bars(up: [1, 2, 3, 4, 5, 6], down: [1, 1, 1, 1, 1, 1], size: size)
        let step = size.width / 60
        #expect(bars.count == 6)
        #expect(abs(bars[0].x - (54 * step + step * 0.25)) < 1e-9)  // slots 0…53 stay empty
        #expect(abs(bars[5].x + bars[5].width - (size.width - step * 0.25)) < 1e-9)  // the newest ends in the last slot
        for bar in bars { #expect(abs(bar.width - step * 0.5) < 1e-9) }
    }

    @Test func moreReadingsThanSlotsKeepTheNewestSixty() {
        let up = (0..<90).map(Double.init)
        let bars = MirroredBars.bars(up: up, down: up.map { _ in 0 }, size: size)
        #expect(bars.count == 60)
        #expect(abs(bars[0].x - size.width / 60 * 0.25) < 1e-9)
        let reach = size.height / 2 - 1
        #expect(abs(bars.last!.up - reach / 1.15) < 1e-9)  // 89, the busiest, at the right
        #expect(abs(bars.first!.up - 30 / (89 * 1.15) * reach) < 1e-9)  // 30 at the left: 0…29 dropped
    }

    @Test func bothHalvesShareOneScaleWithHeadroom() {
        // The busiest second (a write of 20) is 1/1.15 of the half height less the centre line.
        let bars = MirroredBars.bars(up: [10, 0, 0.0001], down: [2, 20, 0], size: size)
        let reach = size.height / 2 - 1
        #expect(abs(bars[1].down - 20 / (20 * 1.15) * reach) < 1e-9)
        #expect(abs(bars[0].up - 10 / (20 * 1.15) * reach) < 1e-9)  // the read on the write's scale
        #expect(bars[1].up == 0 && bars[2].down == 0)  // nothing: no bar
        #expect(bars[2].up == 1)  // a trickle still shows
        #expect(MirroredBars.bars(up: [], down: [], size: size).isEmpty)
        // Series of different lengths line up on the newest value.
        #expect(MirroredBars.bars(up: [5, 5, 5], down: [9], size: size).count == 1)
    }
}

/// Settings › Overview › Sensors › "On the card".
@MainActor
@Suite struct SensorCardTests {
    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.sensors = [
            Sensor(id: "a", name: "CPU 6", group: .cpu, celsius: 79, isKnown: true),
            Sensor(id: "b", name: "CPU 2", group: .cpu, celsius: 71, isKnown: true),
            Sensor(id: "c", name: "Enclosure 3", group: .surface, celsius: 40, isKnown: true),
            Sensor(id: "d", name: "Tp0b", group: .other, celsius: 99, isKnown: false),
        ]
        // The GPU sensor skipped this read; it is still one of this Mac's sensors.
        s.sensorNames = ["CPU 6", "CPU 2", "Enclosure 3", "GPU 1"]
        return s
    }

    @Test func atMostFiveInTheOrderPickedAndOneAlwaysStays() {
        var list: [SensorCardItem] = [.cpu]
        list = SensorCardItem.toggled(list, .cpu)
        #expect(list == [.cpu])  // the last one stays
        for item in [SensorCardItem.ssd, .hottest, .gpu, .battery, .wireless, .enclosure] { list = SensorCardItem.toggled(list, item) }
        #expect(list == [.cpu, .ssd, .hottest, .gpu, .battery])  // the sixth and seventh are refused
        list = SensorCardItem.toggled(list, .ssd)
        #expect(list == [.cpu, .hottest, .gpu, .battery])
        list = SensorCardItem.toggled(list, .ssd)
        #expect(list == [.cpu, .hottest, .gpu, .battery, .ssd])  // picked again: at the end
    }

    @Test func storedListsAreCleanedAndDefaultToHottestCPUGPU() {
        #expect(SensorCardItem.cleaned([]) == [.hottest, .cpu, .gpu])
        #expect(SensorCardItem.cleaned(["gpu", "nonsense", "gpu", "cpu", "ssd", "battery", "wireless", "enclosure"]) == [.gpu, .cpu, .ssd, .battery, .wireless])
        #expect(SensorCardItem.cleaned(["nonsense"]) == SensorCardItem.defaults)
        let d = scratchDefaults("sensorcard")
        d.set("hottest", forKey: "sensorCard")  // wrong type
        d.set("yes", forKey: "sensorCardFans")
        let s = AppSettings(defaults: d)
        #expect(s.sensorCard == [.hottest, .cpu, .gpu] && s.sensorCardFans && !s.nameHottest)
        s.sensorCard = [.ssd, .cpu]; s.sensorCardFans = false; s.nameHottest = true
        let again = AppSettings(defaults: d)
        #expect(again.sensorCard == [.ssd, .cpu] && !again.sensorCardFans && again.nameHottest)
        s.reset()
        #expect(s.sensorCard == SensorCardItem.defaults && s.sensorCardFans && !s.nameHottest)
        #expect(AppSettings(defaults: d).sensorCard == SensorCardItem.defaults)
    }

    @Test func onlyTemperaturesThisMacHasAreOffered() {
        let s = snapshot()
        #expect(SensorSummary.cardItems(in: s) == [.hottest, .cpu, .gpu, .enclosure])  // no SSD, battery or wireless
        #expect(SensorSummary.cardItems(in: Snapshot()).isEmpty)
    }

    @Test func theCardShowsThePickedOnesWithAReadingInOrder() {
        let s = snapshot()
        let temps = SensorSummary.cardTemperatures([.enclosure, .gpu, .cpu, .ssd], nameHottest: false, in: s)
        #expect(temps.map(\.item) == [.enclosure, .cpu])  // GPU skipped this read, no SSD: hidden, no dash
        #expect(temps.map(\.label) == ["Enclosure", "CPU"])
        #expect(abs(temps[1].celsius - 75) < 1e-9)  // a component is its average
        #expect(SensorSummary.cardTemperatures([.ssd], nameHottest: false, in: s).map(\.item) == [.hottest])  // keeps one
        #expect(SensorSummary.cardTemperatures([.ssd], nameHottest: false, in: Snapshot()).isEmpty)
    }

    /// One source per reading: "Hottest · CPU 6" on the card is the sensor and value of the menu
    /// bar's MAX, never the unnamed Tp0b at 99°.
    @Test func theNamedHottestIsTheMenuBarsMax() {
        let s = snapshot()
        let settings = AppSettings(defaults: scratchDefaults("namehot"))
        settings.nameHottest = true
        let card = SensorSummary.cardTemperatures([.hottest], nameHottest: true, in: s)
        #expect(card.first?.label == "Hottest · CPU 6")
        #expect(card.first?.celsius == SensorSummary.value(.hottest, in: s))
        #expect(SensorSummary.hottestName(in: s) == s.hottest?.name)
        // The menu bar never names it, whatever the card does: its tooltip does.
        let segment = MenuBarSegment(kind: .temperature, style: .hottest, snapshot: s, history: MetricHistory(), settings: settings)
        #expect(segment.spokenValue == "Hottest temperature 79°")
        settings.setShown(.temperature, true)
        #expect(MenuBarLabel(snapshot: s, history: MetricHistory(), settings: settings).toolTip == "Hottest sensor: CPU 6 · 79°")
        settings.nameHottest = false
        #expect(SensorSummary.cardTemperatures([.hottest], nameHottest: false, in: s).first?.label == "Hottest")
        #expect(MenuBarSegment(kind: .temperature, style: .hottest, snapshot: s, history: MetricHistory(), settings: settings).spokenValue == "Hottest temperature 79°")
    }
}

/// Settings › Menu Bar › each item's label, and the bar meters.
@MainActor
@Suite struct MenuBarLabelsTests {
    func width(_ kind: MenuItemKind, _ style: MenuItemStyle, _ settings: AppSettings) -> CGFloat {
        var s = Snapshot()
        s.cpu = CPUReading(user: 0.5, system: 0, idle: 0.5, cores: [], loadAverage: [])
        s.memory = MemoryReading(total: 100, app: 50, wired: 0, compressed: 0, cached: 0, free: 50, swapUsed: 0, pressure: .normal, pressurePercent: 0.5)
        s.disk = DiskReading(
            volumes: [VolumeReading(name: "HD", path: "/", total: 100, available: 50, isInternal: true, format: "APFS")], readBytesPerSecond: 0, writeBytesPerSecond: 0)
        s.fans = [Fan(id: 0, name: "Fan", rpm: 3_000, minRPM: 0, maxRPM: 6_000)]
        s.sensors = [Sensor(id: "c", name: "CPU 1", group: .cpu, celsius: 60, isKnown: true)]
        let segment = MenuBarSegment(kind: kind, style: style, snapshot: s, history: MetricHistory(), settings: settings)
        let renderer = ImageRenderer(content: segment)
        renderer.scale = 2
        return CGFloat(renderer.cgImage?.width ?? 0) / 2
    }

    /// Each item's own label off drops the tag of every tagged look, and changes no look without one.
    /// (Replaces the global "Labels on values" switch.)
    @Test func offDropsEveryTagAndNothingElse() {
        let on = AppSettings(defaults: scratchDefaults("tags-on"))
        let off = AppSettings(defaults: scratchDefaults("tags-off"))
        for kind in MenuItemKind.allCases {
            #expect(on.showsLabel(kind))  // on by default
            off.setLabel(kind, false)
        }
        let tagged: [(MenuItemKind, MenuItemStyle)] = [
            (.cpu, .text), (.gpu, .text), (.memory, .text), (.memory, .pressure),
            (.temperature, .hottest), (.temperature, .cpu), (.temperature, .gpu), (.temperature, .ssd),
            (.disk, .percent), (.fans, .percent),
        ]
        for kind in MenuItemKind.allCases {
            for style in kind.styles {
                switch kind.label(of: style) {
                case .tag?:
                    #expect(tagged.contains { $0 == (kind, style) }, "\(kind.rawValue) \(style.rawValue)")
                    #expect(width(kind, style, off) < width(kind, style, on) - 8, "\(kind.rawValue) \(style.rawValue) kept its tag")
                case nil:
                    // Looks without a label look the same either way.
                    #expect(width(kind, style, off) == width(kind, style, on), "\(kind.rawValue) \(style.rawValue)")
                case .bar?: break
                }
            }
        }
        #expect(tagged.allSatisfy { $0.0.label(of: $0.1) == .tag })
    }

    /// The load fills the track; above zero it is never thinner than the capsule is tall.
    @Test func theMeterIsAFilledCapsuleNeverThinnerThanItsHeight() {
        #expect(LabelledBar.size == CGSize(width: 26, height: 5))
        #expect(LabelledBar.fill(0) == 0)
        #expect(LabelledBar.fill(0.01) == 5)
        #expect(LabelledBar.fill(0.5) == 13)
        #expect(LabelledBar.fill(1.7) == 26)
    }
}
