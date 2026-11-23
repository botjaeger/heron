import Foundation
import Testing

@testable import HeronCore

// Pure logic: these run anywhere and pin the maths the UI relies on.

@Suite struct CPUMathTests {
    @Test func loadIsTheShareOfBusyTicks() {
        let old = [CoreTicks(user: 100, system: 50, idle: 850, nice: 0), CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let new = [CoreTicks(user: 160, system: 70, idle: 870, nice: 0), CoreTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let r = CPUMath.reading(previous: old, current: new, kinds: [.efficiency, .performance])
        #expect(abs(r.cores[0].load - 0.8) < 1e-9)  // 80 busy of 100
        #expect(r.cores[1].load == 0)
        #expect(abs(r.user - 60.0 / 200) < 1e-9)
        #expect(abs(r.system - 20.0 / 200) < 1e-9)
        #expect(r.cores[0].kind == .efficiency)
    }

    @Test func countersThatWrapAroundStillGiveTheRightDelta() {
        let old = [CoreTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let new = [CoreTicks(user: 10, system: 0, idle: 20, nice: 0)]  // user advanced by 20 across the wrap
        let r = CPUMath.reading(previous: old, current: new, kinds: [])
        #expect(abs(r.cores[0].load - 0.5) < 1e-9)
        #expect(r.cores[0].kind == .unknown)
    }

    @Test func noTicksMeansIdle() {
        let t = [CoreTicks(user: 5, system: 5, idle: 5, nice: 0)]
        let r = CPUMath.reading(previous: t, current: t, kinds: [])
        #expect(r.total == 0 && r.idle == 1)
    }
}

@Suite struct MemoryMathTests {
    @Test func usedMatchesActivityMonitorFormula() {
        var s = vm_statistics64()
        s.internal_page_count = 1000; s.purgeable_count = 100; s.wire_count = 200
        s.compressor_page_count = 50; s.external_page_count = 300
        let r = MemoryMath.reading(stats: s, pageSize: 16384, total: 16384 * 4000, swapUsed: 0, pressureLevel: 1)
        #expect(r.app == 900 * 16384)
        #expect(r.used == (900 + 200 + 50) * 16384)
        #expect(r.cached == 400 * 16384)
        #expect(r.free == (4000 - 1150 - 400) * 16384)
        #expect(r.pressure == .normal)
    }

    @Test func pressureLevels() {
        let s = vm_statistics64()
        #expect(MemoryMath.reading(stats: s, pageSize: 1, total: 1, swapUsed: 0, pressureLevel: 2).pressure == .warning)
        #expect(MemoryMath.reading(stats: s, pageSize: 1, total: 1, swapUsed: 0, pressureLevel: 4).pressure == .critical)
    }

    /// Pressure % = 100 − kern.memorystatus_level (the share of memory still free for apps).
    @Test func pressurePercentIsTheInverseOfTheFreeLevel() {
        let s = vm_statistics64()
        func percent(_ level: Int?) -> Double? { MemoryMath.reading(stats: s, pageSize: 1, total: 1, swapUsed: 0, pressureLevel: 1, freeLevel: level).pressurePercent }
        #expect(percent(42) == 0.58)
        #expect(percent(100) == 0 && percent(0) == 1)
        #expect(percent(nil) == nil)
        #expect(percent(-1) == nil && percent(101) == nil)  // not a percentage: no number rather than a wrong one
    }
}

@Suite struct SMCDecodeTests {
    @Test func littleEndianFloat() {
        #expect(SMCDecode.number(type: "flt ", bytes: [0x00, 0xD0, 0x10, 0x45]) == 2317)  // 0x4510D000
        #expect(SMCDecode.number(type: "flt ", bytes: [0x00, 0x00, 0x20, 0x42]) == 40)  // 40.0 as LE float
    }
    @Test func fixedPointTypes() {
        #expect(SMCDecode.number(type: "fpe2", bytes: [0x24, 0x40]) == 2320)  // 0x2440 / 4
        #expect(SMCDecode.number(type: "sp78", bytes: [0x3E, 0x80]) == 62.5)
        #expect(SMCDecode.number(type: "sp78", bytes: [0xFF, 0x00]) == -1)
        #expect(SMCDecode.number(type: "ui8 ", bytes: [2]) == 2)
        #expect(SMCDecode.number(type: "ui16", bytes: [0x01, 0x00]) == 256)
    }
    @Test func unknownOrShortValuesAreNil() {
        #expect(SMCDecode.number(type: "flag", bytes: [1]) == nil)
        #expect(SMCDecode.number(type: "flt ", bytes: [1, 2]) == nil)
    }
}

@Suite struct SensorNamingTests {
    @Test func groupsFromKeyPrefixes() {
        #expect(SensorNaming.group(forSMCKey: "Tp01") == .cpu)
        #expect(SensorNaming.group(forSMCKey: "Te05") == .cpu)
        #expect(SensorNaming.group(forSMCKey: "Tg0f") == .gpu)
        #expect(SensorNaming.group(forSMCKey: "TH0x") == .ssd)
        #expect(SensorNaming.group(forSMCKey: "TB0T") == .battery)
        #expect(SensorNaming.group(forSMCKey: "TCMz") == nil)
        #expect(SensorNaming.group(forSMCKey: "Tp0") == nil)
    }

    @Test func unknownKeysKeepTheirNameAndAreMarked() {
        let s = SensorNaming.smcSensors([("TCMz", 70), ("Tp01", 60), ("Tp05", 61)])
        #expect(s.map(\.name) == ["TCMz", "CPU 1", "CPU 2"])
        #expect(s.map(\.isKnown) == [false, true, true])
    }

    @Test func placeholderValuesAreDropped() {
        // 40.0 repeated by many keys (unused slots on an M3 Max) must go; 40.0 on its own stays.
        let raw = [("Tp3a", 40.0), ("Tp3b", 40.0), ("Tp3e", 40.0), ("Tp3f", 40.0), ("Tp01", 61.3), ("TB0T", 31.0)]
        #expect(SensorNaming.droppingPlaceholders(raw).map(\.0) == ["Tp01", "TB0T"])
        let few = [("Tp3a", 40.0), ("Tp3b", 40.0), ("Tp01", 61.3)]
        #expect(SensorNaming.droppingPlaceholders(few).count == 3)
    }

    @Test func hidNames() {
        #expect(SensorNaming.hidGroup(forName: "PMU tdie3") == .cpu)
        #expect(SensorNaming.hidGroup(forName: "NAND CH0 temp") == .ssd)
        #expect(SensorNaming.hidGroup(forName: "gas gauge battery") == .battery)
        #expect(SensorNaming.hidGroup(forName: "PMU tcal") == nil)
    }
}

@Suite struct PowerMathTests {
    @Test func energyOverTimeIsWatts() {
        let r = PowerMath.reading(
            channels: [
                ("CPU Energy", "mJ", 6844), ("GPU Energy", "nJ", 2_000_000_000), ("ANE", "mJ", 0), ("DRAM", "mJ", 4000),
                ("EACC_CPU", "mJ", 1977),
            ], seconds: 2)
        #expect(r?.cpu == 3.422)  // EACC_CPU is a sub-channel and must not be added again
        #expect(r?.gpu == 1)
        #expect(r?.ane == 0)
        #expect(r?.dram == 2)
        #expect(abs((r?.package ?? 0) - 6.422) < 1e-9)
    }
    @Test func windowAveragesLumpsOverTheirArrivalTimes() {
        // Lumps of 6 J arrive every 2 s (3 W), sampled once a second: zero, lump, zero, lump…
        var w = PowerWindow(span: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        let lump = PowerReading(cpu: 6, gpu: nil, ane: nil, dram: nil)
        let empty = PowerReading(cpu: 0, gpu: nil, ane: nil, dram: nil)
        #expect(w.add(lump, at: t0) == nil)  // one lump: no period yet
        #expect(w.add(empty, at: t0 + 1) == nil)
        #expect(w.add(lump, at: t0 + 2)?.cpu == 3)
        #expect(w.add(empty, at: t0 + 3)?.cpu == 3)  // empty tick keeps the estimate
        #expect(w.add(lump, at: t0 + 4)?.cpu == 3)
        #expect(w.add(nil, at: t0 + 5)?.cpu == 3)
    }

    @Test func windowForgetsOldLumps() {
        var w = PowerWindow(span: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<5 { _ = w.add(PowerReading(cpu: 20, gpu: nil, ane: nil, dram: nil), at: t0 + Double(i * 2)) }  // 10 W
        var last: PowerReading?
        for i in 5..<10 { last = w.add(PowerReading(cpu: 4, gpu: nil, ane: nil, dram: nil), at: t0 + Double(i * 2)) }  // 2 W
        #expect(last?.cpu == 2)
    }

    @Test func missingChannelsStayNil() {
        let r = PowerMath.reading(channels: [("CPU Energy", "mJ", 1000)], seconds: 1)
        #expect(r?.gpu == nil && r?.cpu == 1)
        #expect(PowerMath.reading(channels: [], seconds: 0) == nil)
    }
}

@Suite struct RingBufferTests {
    @Test func keepsTheNewestValues() {
        var b = RingBuffer(capacity: 3)
        for v in 1...5 { b.append(Double(v)) }
        #expect(b.count == 3)
        #expect(b.last(3) == [3, 4, 5])
        #expect(b.last(10) == [3, 4, 5])
        #expect(b.latest == 5)
    }
    @Test func downsamplingAverages() {
        var b = RingBuffer(capacity: 10)
        for v in [0.0, 2, 4, 6] { b.append(v) }
        #expect(b.downsampled(last: 4, points: 2) == [1, 5])
        #expect(b.downsampled(last: 4, points: 10) == [0, 2, 4, 6])
    }
}

@Suite struct AlertEngineTests {
    func snapshot(cpuTemp: Double) -> Snapshot {
        var s = Snapshot()
        s.sensors = [Sensor(id: "smc:Tp01", name: "CPU 1", group: .cpu, celsius: cpuTemp, isKnown: true)]
        return s
    }
    let rule = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 90, seconds: 30)
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firesOnlyAfterTheDuration() {
        var e = AlertEngine(cooldown: 600)
        #expect(e.evaluate([rule], snapshot: snapshot(cpuTemp: 95), now: t0).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(cpuTemp: 95), now: t0 + 29).isEmpty)
        let fired = e.evaluate([rule], snapshot: snapshot(cpuTemp: 95), now: t0 + 30)
        #expect(fired.count == 1)
        #expect(fired.first?.title == "CPU running hot · 95°")
        #expect(fired.first?.body.contains("Above 90° for 30 seconds") == true)
    }

    @Test func aDipResetsTheTimer() {
        var e = AlertEngine(cooldown: 0)
        _ = e.evaluate([rule], snapshot: snapshot(cpuTemp: 95), now: t0)
        _ = e.evaluate([rule], snapshot: snapshot(cpuTemp: 85), now: t0 + 20)
        #expect(e.evaluate([rule], snapshot: snapshot(cpuTemp: 95), now: t0 + 31).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(cpuTemp: 95), now: t0 + 61).count == 1)
    }

    @Test func doesNotRepeatWhileStillHotOrWithinCooldown() {
        var e = AlertEngine(cooldown: 600)
        let instant = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 90, seconds: 0)
        #expect(e.evaluate([instant], snapshot: snapshot(cpuTemp: 95), now: t0).count == 1)
        #expect(e.evaluate([instant], snapshot: snapshot(cpuTemp: 95), now: t0 + 700).isEmpty)  // never cleared
        _ = e.evaluate([instant], snapshot: snapshot(cpuTemp: 80), now: t0 + 701)
        #expect(e.evaluate([instant], snapshot: snapshot(cpuTemp: 95), now: t0 + 702).count == 1)  // cleared, past cooldown
        _ = e.evaluate([instant], snapshot: snapshot(cpuTemp: 80), now: t0 + 703)
        #expect(e.evaluate([instant], snapshot: snapshot(cpuTemp: 95), now: t0 + 800).isEmpty)  // within cooldown
    }

    @Test func disabledRulesAndMissingReadingsNeverFire() {
        var e = AlertEngine(cooldown: 0)
        var off = rule; off.enabled = false; off.seconds = 0
        #expect(e.evaluate([off], snapshot: snapshot(cpuTemp: 99), now: t0).isEmpty)
        var empty = rule; empty.seconds = 0
        #expect(e.evaluate([empty], snapshot: Snapshot(), now: t0).isEmpty)
    }

    @Test func summaries() {
        #expect(rule.summary() == "CPU temperature above 90° for 30 s")
        #expect(AlertRule(subject: .diskFreeGB, comparison: .below, threshold: 10, seconds: 0).summary() == "Startup disk below 10 GB free")
        #expect(AlertRule(subject: .memoryPressure, comparison: .above, threshold: 1.5, seconds: 10).summary() == "Memory pressure critical for 10 s")
        #expect(AlertRule(subject: .cpuLoad, comparison: .above, threshold: 80, seconds: 0).summary() == "CPU load above 80%")
        #expect(AlertRule(subject: .batteryPercent, comparison: .below, threshold: 10, seconds: 60).summary() == "Battery below 10% for 1 min")
        #expect(AlertRule(subject: .memoryPressure, comparison: .above, threshold: 0.5, seconds: 300).summary() == "Memory pressure high for 5 min")
    }

    @Test func temperatureLimitsFollowTheDisplayUnit() {
        // Stored in °C, shown in °F: a Fahrenheit user must not read "95°" as 95 °F.
        let hot = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 95, seconds: 0)
        #expect(hot.summary(unit: .fahrenheit) == "CPU temperature above 203°")
        #expect(hot.subject.unit(.fahrenheit) == "°F")
        #expect(AlertRule.Subject.cpuLoad.unit(.fahrenheit) == "%")
        #expect(abs(Format.celsius(Format.converted(95, to: .fahrenheit), from: .fahrenheit) - 95) < 1e-9)
        #expect(Format.celsius(212, from: .fahrenheit) == 100)
    }

    @Test func everySubjectSuggestsALimitInItsOwnRange() {
        for subject in AlertRule.Subject.allCases {
            let s = subject.suggestedRule
            switch subject {
            case .memoryPressure: #expect(s.threshold > 0 && s.threshold <= 2)
            case .diskFreeGB: #expect(s.comparison == .below)
            default: #expect(s.threshold > 0 && s.threshold <= 100, "\(subject)")
            }
        }
    }
}

@Suite struct FormatTests {
    @Test func units() {
        #expect(Format.percent(0.234) == "23%")
        #expect(Format.percent(1.7) == "100%")
        #expect(Format.bytes(19_540_000_000) == "18.2 GB")
        #expect(Format.diskBytes(994_000_000_000) == "994 GB")
        #expect(Format.rate(8_400_000) == "8.4 MB/s")
        #expect(Format.rate(312_000) == "312 KB/s")
        #expect(Format.rate(1_000_000, bits: true) == "8.0 Mb/s")
        #expect(Format.temperature(62.4) == "62°")
        #expect(Format.temperature(100, unit: .fahrenheit) == "212°")
        #expect(Format.rpm(2400) == "2,400 rpm")
        #expect(Format.rpm(980) == "980 rpm")
        #expect(Format.minutes(310) == "5h 10m")
        #expect(Format.watts(4.44) == "4.4 W")
        #expect(Format.watts(14.2) == "14 W")
    }
}

@Suite struct CoreAverageTests {
    @Test func averagesAreTakenPerKind() {
        let cores = [
            CoreLoad(id: 0, kind: .efficiency, load: 0.4), CoreLoad(id: 1, kind: .efficiency, load: 0.6),
            CoreLoad(id: 2, kind: .performance, load: 0.9), CoreLoad(id: 3, kind: .performance, load: 0.7),
            CoreLoad(id: 4, kind: .performance, load: 0.8),
        ]
        #expect(abs(cores.averageLoad(of: .efficiency)! - 0.5) < 1e-9)
        #expect(abs(cores.averageLoad(of: .performance)! - 0.8) < 1e-9)
        #expect(cores.averageLoad(of: .unknown) == nil)  // no such cores: no legend row, not "0%"
    }
}
