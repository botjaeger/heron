import Foundation
import Testing

@testable import HeronCore

// Guards for defect classes found in the Nov 2026 sweep (docs/workstreams/heron-defect-classes.md).

@Suite struct ComponentTemperatureTests {
    func snapshot(_ cpu: [Double], gpu: [Double] = [], unknown: Double? = nil) -> Snapshot {
        var s = Snapshot()
        s.sensors =
            cpu.enumerated().map { Sensor(id: "smc:Tp\($0.offset)", name: "CPU \($0.offset + 1)", group: .cpu, celsius: $0.element, isKnown: true) }
            + gpu.enumerated().map { Sensor(id: "smc:Tg\($0.offset)", name: "GPU \($0.offset + 1)", group: .gpu, celsius: $0.element, isKnown: true) }
        if let unknown { s.sensors.append(Sensor(id: "smc:TCMz", name: "TCMz", group: .other, celsius: unknown, isKnown: false)) }
        return s
    }

    @Test func aComponentIsTheAverageOfItsSensorsNotItsHottestSpot() {
        // Measured on an M3 Max at 24% load: 58 CPU hotspots from 74 to 99 °C.
        let s = snapshot([74, 84, 99, 99], gpu: [70, 80], unknown: 120)
        #expect(AlertRule.Subject.cpuTemperature.value(in: s) == 89)
        #expect(AlertRule.Subject.gpuTemperature.value(in: s) == 75)
        #expect(AlertRule.Subject.hottestTemperature.value(in: s) == 99)  // unknown sensors never count
        #expect(SensorStats.groups(s.sensors).first { $0.group == .cpu }?.celsius == 89)
    }

    @Test func theDefaultHeatAlertStaysQuietOnANormallyBusyMac() {
        var engine = AlertEngine(cooldown: 600)
        let s = snapshot([74, 80, 84, 99, 99, 85, 82])  // hotspots at 99, average 86
        let t0 = Date(timeIntervalSince1970: 0)
        let heat = AlertRule.defaults.filter { $0.subject == .cpuTemperature }
        #expect(!heat.isEmpty)
        #expect(engine.evaluate(heat, snapshot: s, now: t0).isEmpty)
        #expect(engine.evaluate(heat, snapshot: s, now: t0 + 60).isEmpty)
    }

    /// Heron only reads: no SMC write path may come back without the signed helper it needs.
    @Test func heronHasNoWayToWriteTheSMC() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { ["swift", "c", "h"].contains($0.pathExtension) }
        #expect(files.count > 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["SMC_CMD_WRITE", "smc_write", "Ftst", "SMAppService.daemon"] {
                #expect(!text.contains(banned), "\(file.lastPathComponent) contains \(banned)")
            }
        }
    }
}

@Suite struct SensorIdentityTests {
    /// Class: every sensor list is keyed by id in SwiftUI, so ids must be unique for any input.
    @Test func idsAreUniqueEvenWhenTheSystemRepeatsANameOrKey() {
        let hid = SensorNaming.hidSensors([("PMU tdie1", 61.6), ("PMU tdie1", 62.1), ("PMU tcal", 51.9), ("PMU tcal", 51.9), ("gas gauge battery", 34)])
        #expect(Set(hid.map(\.id)).count == hid.count)
        let smc = SensorNaming.smcSensors([("Tp01", 60), ("Tp01", 61), ("TCMz", 70)])
        #expect(Set(smc.map(\.id)).count == smc.count)
    }

    @Test func slotsThatGoIdleAfterTheScanDoNotCount() {
        // Captured on an M3 Max: the same Tp keys read 75–99 °C at the scan and -4.0 later.
        let later = [
            ("Tp04", 75.6), ("Tp05", 80.7), ("Tp1g", -4.0), ("Tp1o", -4.0), ("Tp1x", -4.0), ("Tp25", -4.0), ("Tp3a", 40.0), ("Tp3b", 40.0), ("Tp3e", 40.0), ("Tp3f", 40.0),
        ]
        let kept = SensorNaming.plausible(later)
        #expect(kept.map(\.0) == ["Tp04", "Tp05"])
        var s = Snapshot()
        s.sensors = SensorNaming.smcSensors(kept)
        #expect(abs((AlertRule.Subject.cpuTemperature.value(in: s) ?? 0) - 78.15) < 1e-9)
    }

    @Test func liveCPUTemperatureHasNoImplausibleSensors() {
        let sensors = SensorSampler().temperatures()
        #expect(sensors.allSatisfy { $0.celsius > 5 && $0.celsius < 130 })
    }

    @Test func implausibleHIDReadingsAreDropped() {
        let hid = SensorNaming.hidSensors([("PMU tdev2", -1.6), ("PMU tdie1", 61.6), ("PMU tdev9", 150)])
        #expect(hid.map(\.celsius) == [61.6])
    }
}

@Suite struct HistoryTimeAxisTests {
    func snap(_ t: Double, cpu: Double = 0.5) -> Snapshot {
        var s = Snapshot()
        s.date = Date(timeIntervalSince1970: 1_000 + t)
        s.cpu = CPUReading(user: cpu, system: 0, idle: 1 - cpu, cores: [], loadAverage: [])
        return s
    }

    @Test func halfSecondSamplingKeepsOneValuePerSecond() {
        var h = MetricHistory()
        for i in 0..<20 { h.record(snap(Double(i) * 0.5)) }  // 10 seconds
        #expect(h[.cpu].count == 10)
    }

    @Test func fiveSecondSamplingFillsTheSecondsItStoodFor() {
        var h = MetricHistory()
        for i in 0..<4 { h.record(snap(Double(i) * 5, cpu: Double(i) / 10)) }  // 0, 5, 10, 15 s
        #expect(h[.cpu].count == 16)
        #expect(h.series(.cpu, seconds: 5) == [0.3, 0.3, 0.3, 0.3, 0.3])
    }

    @Test func aLongSleepIsNotPaintedAsAFlatLine() {
        var h = MetricHistory()
        h.record(snap(0)); h.record(snap(1)); h.record(snap(3_600))
        #expect(h[.cpu].count == 3)
    }

    @Test func oneSecondSamplingWithTimerJitterStaysOnePerSecond() {
        var h = MetricHistory()
        for t in [0, 1.04, 2.01, 3.09, 4.0, 5.08] { h.record(snap(t)) }
        #expect(h[.cpu].count == 6)
    }

    @Test func systemLoadIsKeptBesideTotalLoadSecondForSecond() {
        var h = MetricHistory()
        for i in 0..<5 {
            var s = snap(Double(i))
            s.cpu = CPUReading(user: 0.4, system: 0.1 * Double(i), idle: 0.6 - 0.1 * Double(i), cores: [], loadAverage: [])
            h.record(s)
        }
        #expect(h[.cpuSystem].count == h[.cpu].count)
        let system = h.series(.cpuSystem, seconds: 5), total = h.series(.cpu, seconds: 5)
        for (s, t) in zip(system, total) { #expect(abs((t - s) - 0.4) < 1e-9) }  // user = total − system
    }
}

@Suite struct ProcessNamingTests {
    @Test func appBundlesAndPlainBinaries() {
        #expect(ProcessNaming.display(path: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari")
        #expect(ProcessNaming.display(path: "/opt/homebrew/bin/node") == "node")
    }

    @Test func versionNamedBinariesFallBackToArgv0() {
        #expect(ProcessNaming.looksLikeVersion("2.1.328"))
        #expect(!ProcessNaming.looksLikeVersion("node"))
        #expect(!ProcessNaming.looksLikeVersion("1password"))
        // KERN_PROCARGS2: argc (Int32), exec path, NUL padding, argv[0], …
        var buffer: [UInt8] = [1, 0, 0, 0]
        buffer += Array("/Users/x/.local/versions/2.1.328".utf8) + [0, 0, 0]
        buffer += Array("claude".utf8) + [0] + Array("--resume".utf8) + [0]
        #expect(ProcessNaming.argv0(procargs: buffer) == "claude")
        #expect(ProcessNaming.argv0(procargs: [1, 0, 0]) == nil)
    }

    @Test func liveNamesAreNeverBareVersionNumbers() {
        let top = ProcessSampler().sample(limit: 50)
        for row in top.memory { #expect(!ProcessNaming.looksLikeVersion(row.name) || ProcessSampler.argv0(of: row.pid) == nil, "\(row.name)") }
        #expect(top.memory.allSatisfy { !$0.name.isEmpty })
    }
}
