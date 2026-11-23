import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// The redesigned overview and panels: the rules behind what they show.
@Suite struct PopoverPanelTests {
    func hot(cpu: Double, pressure: MemoryReading.Pressure) -> Snapshot {
        var s = Snapshot()
        s.sensors = [Sensor(id: "a", name: "CPU 1", group: .cpuPerformance, celsius: cpu, isKnown: true)]
        s.memory = MemoryReading(total: 1, app: 0, wired: 0, compressed: 0, cached: 0, free: 1, swapUsed: 0, pressure: pressure)
        s.cpu = CPUReading(user: 0.5, system: 0.2, idle: 0.3, cores: (0..<14).map { CoreLoad(id: $0, kind: $0 < 4 ? .efficiency : .performance, load: 0.7) }, loadAverage: [])
        s.topCPU = [ProcessUsage(pid: 1, name: "Virtual Machine Service", cpu: 10.38, memory: 0, count: 1), ProcessUsage(pid: 2, name: "Safari", cpu: 0.2, memory: 0)]
        s.topMemory = [ProcessUsage(pid: 3, name: "Microsoft Edge", cpu: 0, memory: 3_100_000_000, count: 6)]
        return s
    }

    @Test func aCauseLineOnlyUnderAHotCPUOrCriticalMemory() {
        let calm = hot(cpu: 70, pressure: .warning)
        #expect(OverviewSection.cause(.cpu, in: calm) == nil)
        #expect(OverviewSection.cause(.memory, in: calm) == nil)  // Warning is not critical
        let s = hot(cpu: 96, pressure: .critical)
        #expect(OverviewSection.cause(.cpu, in: s)?.name == "Virtual Machine Service")
        // The card has no "100% = one core" caption: 1038% of one core is 74% of a 14-core Mac.
        #expect(OverviewSection.cause(.cpu, in: s)?.value == "74% of CPU")
        var noCores = s
        noCores.cpu = nil
        #expect(OverviewSection.cause(.cpu, in: noCores) == nil)  // no core count: no share to give
        #expect(OverviewSection.cause(.memory, in: s)?.name == "Microsoft Edge (6)")
        #expect(OverviewSection.cause(.gpu, in: s) == nil)
        var empty = s
        empty.topCPU = []
        #expect(OverviewSection.cause(.cpu, in: empty) == nil)  // never an invented app
    }

    @Test func hotCardsFollowTheWarnings() {
        let s = hot(cpu: 96, pressure: .critical)
        #expect(OverviewSection.isHot(.cpu, in: s) && OverviewSection.isHot(.memory, in: s) && OverviewSection.isHot(.sensors, in: s))
        #expect(!OverviewSection.isHot(.network, in: s) && !OverviewSection.isHot(.gpu, in: s))
        #expect(!OverviewSection.isHot(.cpu, in: hot(cpu: 89, pressure: .warning)))
        #expect(!OverviewSection.isHot(.memory, in: hot(cpu: 89, pressure: .warning)))  // Warning is amber, not hot
    }

    @Test func theCardMenuOpensItsSectionAndNeverHidesTheLastCard() {
        #expect(CardMenu.route(.disk) == SettingsRoute(.overview, section: .disk))
        #expect(CardMenu.route(.cpu).pane == .overview)
        #expect(CardMenu.canHide(.cpu, shown: [.cpu, .gpu]))
        #expect(!CardMenu.canHide(.cpu, shown: [.cpu]))
        #expect(!CardMenu.canHide(.battery, shown: [.cpu]))
    }

    @Test func sensorsAreSortedHottestFirstAndTheHottestIsNamed() {
        let items = [
            SensorStats.Item(group: .cpu, celsius: 70), SensorStats.Item(group: .gpu, celsius: 80),
            SensorStats.Item(group: .ssd, celsius: 70), SensorStats.Item(group: .battery, celsius: 30),
        ]
        #expect(SensorSummary.hottestFirst(items).map(\.group) == [.gpu, .cpu, .ssd, .battery])  // ties keep their order
        #expect(SensorSummary.hottestLabel(Sensor(id: "x", name: "CPU 25", group: .cpuPerformance, celsius: 81, isKnown: true)) == "CPU 25 · performance core")
        #expect(SensorSummary.hottestLabel(Sensor(id: "y", name: "SSD 2", group: .ssd, celsius: 50, isKnown: true)) == "SSD 2")
    }

    @Test func historyStatsAndThePointerIndex() {
        let stats = HistoryView.stats([4, 1, 7, 0])
        #expect(stats?.low == 0 && stats?.high == 7 && stats?.average == 3)
        #expect(HistoryView.stats([]) == nil)
        // Full coverage: the left edge is the first value, the right edge the last.
        #expect(HistoryView.index(at: 0, count: 11, coverage: 1) == 0)
        #expect(HistoryView.index(at: 1, count: 11, coverage: 1) == 10)
        #expect(HistoryView.index(at: 0.52, count: 11, coverage: 1) == 5)
        // Data over the right half only: left of it there is nothing to read.
        #expect(HistoryView.index(at: 0.25, count: 11, coverage: 0.5) == nil)
        #expect(HistoryView.index(at: 0.5, count: 11, coverage: 0.5) == 0)
        #expect(HistoryView.index(at: 0.75, count: 11, coverage: 0.5) == 5)
        #expect(HistoryView.index(at: 0.5, count: 0, coverage: 1) == nil)
        #expect(HistoryView.secondsAgo(index: 5, count: 11, span: 600) == 300)
        #expect(HistoryView.agoText(240) == "4 min ago" && HistoryView.agoText(24) == "24 s ago" && HistoryView.agoText(7200) == "2 h ago")
    }

    @Test func theTopProcessesSwitchSplitsIntoOnePerPanel() {
        let off = scratchDefaults("split-off")
        off.set(false, forKey: "showTopProcesses")
        let a = AppSettings(defaults: off)
        #expect(!a.showCPUProcesses && !a.showMemoryProcesses)
        #expect(off.object(forKey: "showTopProcesses") == nil)  // retired
        let again = AppSettings(defaults: off)  // the migration was saved
        #expect(!again.showCPUProcesses && !again.showMemoryProcesses)
        again.showCPUProcesses = true
        #expect(AppSettings(defaults: off).showCPUProcesses && !AppSettings(defaults: off).showMemoryProcesses)
        let fresh = AppSettings(defaults: scratchDefaults("split-none"))
        #expect(fresh.showCPUProcesses && fresh.showMemoryProcesses)
    }

    @Test func clocksShareOneRowAndNumbersSplitFromTheirUnits() {
        #expect(PanelRows.clocks(efficiencyMHz: 2049, performanceMHz: 3311) == "E 2.0 · P 3.3 GHz")
        #expect(PanelRows.clocks(efficiencyMHz: nil, performanceMHz: 3311) == "P 3.3 GHz")
        #expect(PanelRows.clocks(efficiencyMHz: nil, performanceMHz: nil) == nil)
        #expect(NumberParts.split("31 KB/s") == ("31", "KB/s"))
        #expect(NumberParts.split("34%") == ("34%", ""))
        #expect(OverviewSection.usedOf(644_000_000_000, 995_000_000_000) == ("644", "of 995 GB"))
        #expect(OverviewSection.usedOf(900_000_000_000, 2_000_000_000_000) == ("900 GB", "of 2.0 TB"))
    }
}
