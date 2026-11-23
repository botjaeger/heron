import Foundation
import Testing

@testable import HeronCore

/// macOS's charge limit, from powerd's charge policies.
@Suite struct ChargeLimitTests {
    /// /Library/Preferences/com.apple.powerd.charging.plist on an M3 Max (macOS 27, 20 Nov 2026),
    /// with System Settings › Battery › Charge limit at 80%.
    static let captured = Data(
        base64Encoded:
            "YnBsaXN0MDDSAQIDBF8QD2Jvb3RTZXNzaW9uVVVJRFhwb2xpY2llc18QJEM4NURDQTVELTZDOEUtNDdDRC1BMTFELTg5RTVGODQ1RTcyRE8RAi5icGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVHJvb3SAAagLDBIkJSkvM1UkbnVsbNINDg8RWk5TLm9iamVjdHNWJGNsYXNzoRCAAoAH2RMUFQ4WFxgZGhscHR4fICAfI1ZyZWFzb25Vb3duZXJYc29jbGltaXRVZHJhaW5adGVybWluYXRlZF5ub0NoYXJnZVRvRnVsbF1pc0VuZE9mQ2hhcmdlVXRva2VugAMRYWAQUIAGCQgICYAEXxARbWFudWFsQ2hhcmdlTGltaXTSJg4nKFxOUy51dWlkYnl0ZXNPEBBx2l3pSKRFc50doFhZOYL3gAXSKissLVokY2xhc3NuYW1lWCRjbGFzc2VzVk5TVVVJRKIsLlhOU09iamVjdNIqKzAxXxAQQ2hhcmdlQ3RybFBvbGljeaIyLl8QEENoYXJnZUN0cmxQb2xpY3nSKis0NV5OU011dGFibGVBcnJheaM0Ni5XTlNBcnJheQAIABEAGgAkACkAMgA3AEkATABRAFMAXABiAGcAcgB5AHsAfQB/AJIAmQCfAKgArgC5AMgA1gDcAN4A4QDjAOUA5gDnAOgA6QDrAP8BBAERASQBJgErATYBPwFGAUkBUgFXAWoBbQGAAYUBlAGYAAAAAAAAAgEAAAAAAAAANwAAAAAAAAAAAAAAAAAAAaAACAANAB8AKABPAAAAAAAAAgEAAAAAAAAABQAAAAAAAAAAAAAAAAAAAoE="
    )!
    static let boot = "C85DCA5D-6C8E-47CD-A11D-89E5F845E72D"

    /// A file like powerd's, holding `policies`.
    static func file(_ policies: [ChargePolicyRecord], boot: String = boot) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("ChargeCtrlPolicy", for: ChargePolicyRecord.self)
        archiver.encode(NSMutableArray(array: policies), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let top: [String: Any] = ["bootSessionUUID": boot, "policies": archiver.encodedData]
        return try PropertyListSerialization.data(fromPropertyList: top, format: .binary, options: 0)
    }

    @Test func theCapturedFileSays80Percent() {
        #expect(ChargeLimitSource.parse(Self.captured, bootSession: Self.boot) == .limit(0.8))
    }

    @Test func aFileFromAnotherBootIsNotTrusted() {
        #expect(ChargeLimitSource.parse(Self.captured, bootSession: "00000000-0000-0000-0000-000000000000") == .unknown)
    }

    @Test func noManualPolicyMeansOff() throws {
        #expect(ChargeLimitSource.parse(try Self.file([]), bootSession: Self.boot) == .off)
        let ended = ChargePolicyRecord(reason: "manualChargeLimit", socLimit: 85, terminated: true)
        #expect(ChargeLimitSource.parse(try Self.file([ended]), bootSession: Self.boot) == .off)
        let other = ChargePolicyRecord(reason: "somethingElse", socLimit: 80, terminated: false)
        #expect(ChargeLimitSource.parse(try Self.file([other]), bootSession: Self.boot) == .off)
        let full = ChargePolicyRecord(reason: "manualChargeLimit", socLimit: 100, terminated: false)
        #expect(ChargeLimitSource.parse(try Self.file([full]), bootSession: Self.boot) == .off)
    }

    @Test func aWrittenPolicyReadsBack() throws {
        let p = ChargePolicyRecord(reason: "manualChargeLimit", socLimit: 90, terminated: false)
        #expect(ChargeLimitSource.parse(try Self.file([p]), bootSession: Self.boot) == .limit(0.9))
    }

    @Test func unreadableFilesAreUnknown() throws {
        #expect(ChargeLimitSource.parse(Data("not a plist".utf8), bootSession: Self.boot) == .unknown)
        let noPolicies = try PropertyListSerialization.data(fromPropertyList: ["bootSessionUUID": Self.boot], format: .binary, options: 0)
        #expect(ChargeLimitSource.parse(noPolicies, bootSession: Self.boot) == .unknown)
        let badArchive = try PropertyListSerialization.data(fromPropertyList: ["policies": Data([1, 2, 3])], format: .binary, options: 0)
        #expect(ChargeLimitSource.parse(badArchive, bootSession: Self.boot) == .unknown)
    }
}

/// CPU cluster clocks from IOReport residencies and the pmgr frequency tables.
@Suite struct ClockMathTests {
    static func table(_ pairs: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (hz, mv) in pairs { for word in [hz, mv] { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } } }
        return data
    }

    /// pmgr's voltage-states1-sram on an M3 Max: the efficiency cluster's six steps.
    static let efficiency = table([
        (1_020_000_000, 790), (1_320_000_000, 800), (1_704_000_000, 840),
        (2_088_000_000, 895), (2_484_000_000, 990), (2_568_000_000, 990),
    ])

    @Test func tablesAreHertzAndMillivoltPairs() {
        #expect(ClockMath.frequencies(Self.efficiency) == [1020, 1320, 1704, 2088, 2484, 2568])
        #expect(ClockMath.frequencies(Self.table([(1, 640), (1, 705)])) == nil)  // voltage-states0: not clocks
        #expect(ClockMath.frequencies(Data([1, 2, 3])) == nil)
        #expect(ClockMath.frequencies(Data()) == nil)
    }

    /// The ECPU channel of one real 1-second IOReport delta on the same Mac.
    @Test func theActiveClockIsTheResidencyWeightedAverage() throws {
        let states: [(name: String, residency: Int64)] = [
            ("DOWN", 0), ("IDLE", 6_757_100), ("V0P5", 1_807_997), ("V1P4", 552_774), ("V2P3", 1_175_996),
            ("V3P2", 1_774_798), ("V4P1", 7_216_641), ("V5P0", 4_920_788),
        ]
        let table = try #require(ClockMath.frequencies(Self.efficiency))
        let mhz = try #require(ClockMath.activeMHz(states, table: table))
        #expect(abs(mhz - 2226.27) < 0.01)  // idle time does not count
    }

    @Test func stepsThatDoNotMatchTheTableGiveNothing() {
        let table: [Double] = [1000, 2000]
        #expect(ClockMath.activeMHz([("IDLE", 5), ("V0P2", 1), ("V1P1", 1), ("V2P0", 1)], table: table) == nil)  // 3 steps, 2 clocks
        #expect(ClockMath.activeMHz([("IDLE", 5), ("V0P0", 4)], table: table) == nil)  // 1 step, 2 clocks
        #expect(ClockMath.activeMHz([("IDLE", 5), ("V0P1", 0), ("V1P0", 0)], table: table) == nil)  // idle throughout
        #expect(ClockMath.activeMHz([("V0P1", 1), ("V1P0", 3)], table: table) == 1750)
    }

    @Test func performanceClustersMergeAndOtherBlocksAreSkipped() {
        let table: [Double] = [1000, 3000]
        let channels = [
            ClockMath.Channel(name: "ECPM", states: [("V0P1", 0), ("V1P0", 100)]),
            ClockMath.Channel(name: "PCPU", states: [("IDLE", 50), ("V0P1", 3), ("V1P0", 1)]),
            ClockMath.Channel(name: "PCPM", states: [("V0P1", 100), ("V1P0", 0)]),
            ClockMath.Channel(name: "PCPU1", states: [("DOWN", 90), ("V0P1", 1), ("V1P0", 3)]),
            ClockMath.Channel(name: "PCPM1_IDLE", states: [("V0P1", 100), ("V1P0", 0)]),
        ]
        let r = ClockMath.reading(channels: channels, efficiencyTable: table, performanceTable: table)
        #expect(r.performanceMHz == 2000)  // 4 ticks at 1 GHz, 4 at 3 GHz
        #expect(r.efficiencyMHz == nil)  // no ECPU channel (ECPM is not it)
        #expect(ClockMath.reading(channels: channels, efficiencyTable: nil, performanceTable: nil) == ClockReading(efficiencyMHz: nil, performanceMHz: nil))
    }
}

@Suite struct DisplayPowerTests {
    @Test func displayEnginesAddUpAndStayOutOfThePackage() {
        let r = PowerMath.reading(channels: [("CPU Energy", "mJ", 2000), ("DISP0", "mJ", 1149), ("DISPEXT0", "mJ", 65)], seconds: 1)
        #expect(abs((r?.display ?? 0) - 1.214) < 1e-9)
        #expect(r?.package == 2)
        #expect(PowerMath.reading(channels: [("CPU Energy", "mJ", 2000)], seconds: 1)?.display == nil)
    }

    @Test func theWindowAveragesTheDisplayToo() {
        var w = PowerWindow(span: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = w.add(PowerReading(cpu: 6, gpu: nil, ane: nil, dram: nil, display: 2), at: t0)
        #expect(w.add(PowerReading(cpu: 6, gpu: nil, ane: nil, dram: nil, display: 2), at: t0 + 2)?.display == 1)
    }
}

/// Histories for the rows Batch 5 left without one: per fan (keyed), load, display, battery.
@Suite struct ItemHistoryTests {
    static func fan(_ id: Int, _ rpm: Double) -> Fan { Fan(id: id, name: "Fan \(id)", rpm: rpm, minRPM: 0, maxRPM: 6000) }

    @Test func eachFanKeepsItsOwnHistory() {
        var h = MetricHistory()
        for t in 0..<3 {
            var s = Snapshot()
            s.date = Date(timeIntervalSince1970: 1_000 + Double(t))
            s.fans = [Self.fan(0, 2000 + Double(t)), Self.fan(1, 4000)]
            h.record(s)
        }
        #expect(h.series(.item(ItemKey(.fanRPM, id: 0)), seconds: 60, points: 60) == [2000, 2001, 2002])
        #expect(h.series(.item(ItemKey(.fanRPM, id: 1)), seconds: 60, points: 60) == [4000, 4000, 4000])
        #expect(h.latest(.item(ItemKey(.fanRPM, id: 0))) == 2002)
        #expect(h.series(.item(ItemKey(.fanRPM, id: 7)), seconds: 60, points: 60).isEmpty)  // never seen
        #expect(h.latest(.item(ItemKey(.fanRPM, id: 7))) == nil)
    }

    @Test func listItemsAreCappedAndCounted() {
        var h = MetricHistory()
        let before = h.storedValues
        var s = Snapshot()
        s.fans = (0..<20).map { Self.fan($0, 1000) }
        h.record(s)
        #expect(h.storedValues == before + MetricHistory.maxItems * 1_680)
        #expect(h.latest(.item(ItemKey(.fanRPM, id: MetricHistory.maxItems - 1))) == 1000)
        #expect(h.latest(.item(ItemKey(.fanRPM, id: MetricHistory.maxItems))) == nil)
    }

    @Test func loadDisplayAndBatteryRowsAreRecorded() {
        var h = MetricHistory()
        var s = Snapshot()
        s.cpu = CPUReading(user: 0, system: 0, idle: 1, cores: [], loadAverage: [3.5, 4, 8])
        s.power = PowerReading(cpu: 1, gpu: nil, ane: nil, dram: nil, display: 0.5)
        var b = BatteryReading(present: true, percent: 0.5, isCharging: true, onAC: true)
        b.cycleCount = 239; b.maxCapacityFraction = 0.846; b.watts = -31
        s.battery = b
        h.record(s)
        #expect(h.latest(.metric(.loadAverage)) == 3.5)
        #expect(h.latest(.metric(.displayPower)) == 0.5)
        #expect(h.latest(.metric(.batteryCycles)) == 239)
        #expect(h.latest(.metric(.batteryHealth)) == 0.846)
        #expect(h.latest(.metric(.batteryPower)) == 31)  // charging: the size of the flow
    }

    @Test func noBatteryRecordsNoBatteryRows() {
        var h = MetricHistory()
        var s = Snapshot()
        var b = BatteryReading(present: false, percent: 0, isCharging: false, onAC: true)
        b.cycleCount = 5
        s.battery = b
        h.record(s)
        #expect(h.series(.metric(.batteryCycles), seconds: 60).isEmpty)
        #expect(h.series(.metric(.batteryPower), seconds: 60).isEmpty)
    }
}
