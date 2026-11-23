import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// A panel row whose reading this Mac does not give is left out, never shown with a placeholder.
@Suite struct PanelRowsTests {
    static func keys(_ rows: [PanelRow]) -> [String] { rows.map(\.key) }

    @Test func aSnapshotWithoutReadingsHasNoRows() {
        let s = Snapshot()
        #expect(PanelRows.cpuDetails(s, unit: .celsius).isEmpty)
        #expect(PanelRows.gpuDetails(s, unit: .celsius).isEmpty)
        #expect(PanelRows.memoryParts(s).isEmpty)
        #expect(PanelRows.diskTotals(s).isEmpty)
        #expect(PanelRows.networkAddress(s).isEmpty)
        #expect(PanelRows.networkSession(s).isEmpty)
        #expect(PanelRows.fans(s).isEmpty)
        #expect(PanelRows.power(s).isEmpty)
        #expect(PanelRows.battery(s, unit: .celsius).isEmpty)
    }

    @Test func readingsWithNilPartsDropOnlyThoseRows() {
        var s = Snapshot()
        s.cpu = CPUReading(user: 0.1, system: 0.1, idle: 0.8, cores: [], loadAverage: [])
        s.gpu = GPUReading(device: 0.3, renderer: nil, tiler: nil, name: nil)
        s.disk = DiskReading(volumes: [], readBytesPerSecond: 0, writeBytesPerSecond: 0)
        s.network = NetworkReading(interface: nil, interfaceKind: "Offline", localIP: nil, downBytesPerSecond: 0, upBytesPerSecond: 0, sessionDown: 0, sessionUp: 0)
        s.power = PowerReading(cpu: 2, gpu: nil, ane: nil, dram: nil)
        s.battery = BatteryReading(present: true, percent: 0.5, isCharging: false, onAC: true)
        #expect(PanelRows.cpuDetails(s, unit: .celsius).map(\.key) == ["Power"])  // no load average, clocks or temperature
        #expect(PanelRows.gpuDetails(s, unit: .celsius).isEmpty)
        #expect(PanelRows.diskTotals(s).isEmpty)
        #expect(Self.keys(PanelRows.networkAddress(s)) == ["Interface"])  // offline: no local IP row
        #expect(Self.keys(PanelRows.power(s)) == ["Package", "CPU"])  // no Display row
        #expect(Self.keys(PanelRows.battery(s, unit: .celsius)) == ["Power adapter"])  // charge limit unknown: hidden
    }

    @Test func aFullSnapshotHasEveryRow() {
        var s = Snapshot()
        s.cpu = CPUReading(user: 0.1, system: 0.1, idle: 0.8, cores: [], loadAverage: [3.51, 4.29, 8.28])
        s.clocks = ClockReading(efficiencyMHz: 2049, performanceMHz: 3311)
        s.disk = DiskReading(volumes: [], readBytesPerSecond: 0, writeBytesPerSecond: 0, bytesReadSinceBoot: 2_000_000_000, bytesWrittenSinceBoot: 1_000_000_000)
        s.power = PowerReading(cpu: 2, gpu: 1, ane: 0, dram: 0.5, display: 0.47)
        s.fans = [Fan(id: 0, name: "Left", rpm: 2341, minRPM: 2317, maxRPM: 6898), Fan(id: 1, name: "Right", rpm: 2499, minRPM: 2502, maxRPM: 7450)]
        var b = BatteryReading(present: true, percent: 0.79, isCharging: false, onAC: true)
        b.watts = -31; b.maxCapacityFraction = 0.846; b.cycleCount = 239; b.temperatureC = 31; b.chargeLimit = 0.8; b.chargeLimitKnown = true
        s.battery = b
        let cpu = PanelRows.cpuDetails(s, unit: .celsius)
        #expect(Self.keys(cpu) == ["Load average", "Clocks", "Power"])
        #expect(cpu[1].value == "E 2.0 · P 3.3 GHz" && cpu[0].value == "3.51 · 4.29 · 8.28" && cpu[0].hint == "1, 5, 15 min")
        #expect(cpu[0].history?.source == .metric(.loadAverage))
        #expect(Self.keys(PanelRows.diskTotals(s)) == ["Read since boot", "Written since boot"])
        #expect(Self.keys(PanelRows.power(s)) == ["Package", "CPU", "Memory", "GPU", "Neural Engine", "Display"])
        #expect(PanelRows.power(s).map(\.indented) == [false, true, true, true, true, false])
        #expect(PanelRows.power(s).last?.history?.source == .metric(.displayPower))
        let fans = PanelRows.fans(s)
        #expect(Self.keys(fans) == ["Left", "Right"])
        #expect(fans.map { $0.history?.source } == [.item(ItemKey(.fanRPM, id: 0)), .item(ItemKey(.fanRPM, id: 1))])
        let battery = PanelRows.battery(s, unit: .celsius)
        #expect(Self.keys(battery) == ["Health", "Cycle count", "Charging at", "Power adapter", "Temperature"])  // the set limit is on the charge bar
        #expect(battery[3].value == "Connected · not charging")
        #expect(battery.compactMap { $0.history?.source } == [.metric(.batteryHealth), .metric(.batteryCycles), .metric(.batteryPower), .metric(.batteryTemperature)])
    }

    @Test func theChargeLimitRowReadsOffOnlyWhenHeronCouldReadTheSetting() {
        var s = Snapshot()
        var b = BatteryReading(present: true, percent: 0.5, isCharging: false, onAC: true)
        s.battery = b
        #expect(!Self.keys(PanelRows.battery(s, unit: .celsius)).contains("Charge limit"))
        b.chargeLimitKnown = true
        s.battery = b
        #expect(PanelRows.battery(s, unit: .celsius).first { $0.key == "Charge limit" }?.value == "Off")
    }

    @Test func noBatteryMeansNoBatteryRows() {
        var s = Snapshot()
        var b = BatteryReading(present: false, percent: 0, isCharging: false, onAC: true)
        b.cycleCount = 12; b.chargeLimitKnown = true
        s.battery = b
        #expect(PanelRows.battery(s, unit: .celsius).isEmpty)
    }
}
