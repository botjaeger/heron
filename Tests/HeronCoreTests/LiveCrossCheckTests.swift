import Foundation
import IOKit.ps
import Testing

@testable import HeronCore

// Live checks on this Mac: each sampler is compared against a SECOND, independent macOS API,
// so a parsing mistake shows up as a mismatch rather than a plausible-looking wrong number.

@Suite struct LiveCrossCheckTests {
    @Test func memoryTotalMatchesSysctl() throws {
        let r = try #require(MemorySampler().sample())
        let memsize = try #require(Sysctl.value("hw.memsize", as: UInt64.self))
        #expect(r.total == memsize)
        #expect(r.used > 0 && r.used < r.total)
        // The parts can never add up to more than the machine has.
        #expect(r.app + r.wired + r.compressed + r.cached <= r.total)
    }

    @Test func coreCountAndKindsMatchPerfLevels() throws {
        let ticks = try #require(CPUSampler.readTicks())
        #expect(ticks.count == SystemInfo.logicalCores)
        let kinds = SystemInfo.coreKinds()
        #expect(kinds.count == ticks.count)
        if let p = SystemInfo.performanceCores, let e = SystemInfo.efficiencyCores {
            #expect(kinds.filter { $0 == .performance }.count == p)
            #expect(kinds.filter { $0 == .efficiency }.count == e)
        }
    }

    @Test func cpuLoadAgreesWithHostStatistics() throws {
        // host_statistics(HOST_CPU_LOAD_INFO) sums all cores in the kernel; ours sums per core.
        func hostTicks() -> (busy: Double, all: Double) {
            var info = host_cpu_load_info()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
            }
            let t = info.cpu_ticks
            let busy = Double(t.0) + Double(t.1) + Double(t.3)  // user, system, nice
            return (busy, busy + Double(t.2))
        }
        let sampler = CPUSampler()
        _ = sampler.sample()
        let h0 = hostTicks()
        Thread.sleep(forTimeInterval: 1)
        let ours = try #require(sampler.sample())
        let h1 = hostTicks()
        let theirs = (h1.busy - h0.busy) / max(1, h1.all - h0.all)
        #expect(abs(ours.total - theirs) < 0.15, "ours \(ours.total) vs host_statistics \(theirs)")
    }

    @Test func network64BitCountersAgreeWithGetifaddrs() throws {
        // getifaddrs reports the same counters truncated to 32 bits.
        let ours = NetworkSampler.readCounters()
        var list: UnsafeMutablePointer<ifaddrs>?
        #expect(getifaddrs(&list) == 0)
        defer { freeifaddrs(list) }
        var compared = 0
        for entry in sequence(first: list!, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = item.ifa_data else { continue }
            let name = String(cString: item.ifa_name)
            guard let mine = ours[name] else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            let low = UInt32(truncatingIfNeeded: mine.received)
            // Traffic between the two reads can add a little; allow 50 MB of drift.
            #expect(stats.ifi_ibytes &- low < 50_000_000, "\(name): \(stats.ifi_ibytes) vs \(low)")
            compared += 1
        }
        #expect(compared > 0)
    }

    @Test func rootVolumeMatchesStatfs() throws {
        let volumes = DiskSampler().volumes()
        let root = try #require(volumes.first { $0.isRoot })
        var fs = statfs()
        #expect(statfs("/", &fs) == 0)
        let total = UInt64(fs.f_blocks) * UInt64(fs.f_bsize)
        #expect(root.total == total)
    }

    @Test func batteryPercentMatchesRegistry() throws {
        let b = BatterySampler().sample()
        guard b.present else { return }  // desktop Mac: nothing to compare
        var registry: Int?
        Registry.forEachService("AppleSmartBattery") { registry = Registry.property($0, "CurrentCapacity") as? Int }
        let percent = try #require(registry)
        #expect(abs(b.percent * 100 - Double(percent)) <= 1)
        if let health = b.maxCapacityFraction { #expect(health > 0.3 && health <= 1.1) }
    }

    @Test func processSamplerSeesThisTestProcess() {
        let sampler = ProcessSampler()
        _ = sampler.sample(limit: 10_000)
        Thread.sleep(forTimeInterval: 0.3)
        let all = sampler.sample(limit: 10_000)
        // Rows are grouped by app name and keep the first pid seen: while `swift test` runs a
        // second copy of this test binary, the row holding this process may carry the other pid.
        let name = sampler.appName(of: getpid())
        let me = all.memory.first { $0.pid == getpid() || ($0.name == name && $0.count > 1) }
        #expect(me != nil)
        #expect((me?.memory ?? 0) > 1_000_000)
    }

    @Test func fanReadingsAreWithinTheirLimits() {
        let sensors = SensorSampler()
        guard sensors.hasSMC else { return }
        for fan in sensors.fans() {
            #expect(fan.maxRPM > fan.minRPM)
            #expect(fan.rpm >= 0 && fan.rpm <= fan.maxRPM * 1.1)
        }
        let temps = sensors.temperatures()
        #expect(temps.allSatisfy { $0.celsius > 5 && $0.celsius < 130 })
    }

    @Test func diskTotalsSinceBootOnlyGrowAndAgreeWithTheRate() throws {
        let disk = DiskSampler()
        let first = disk.sample()
        let read0 = try #require(first.bytesReadSinceBoot), written0 = try #require(first.bytesWrittenSinceBoot)
        Thread.sleep(forTimeInterval: 0.5)
        let second = disk.sample()
        let read1 = try #require(second.bytesReadSinceBoot), written1 = try #require(second.bytesWrittenSinceBoot)
        #expect(read1 >= read0 && written1 >= written0)
        // The rate is the same counters' delta: over ~0.5 s it cannot exceed the totals' growth by much.
        #expect(second.readBytesPerSecond * 0.4 <= Double(read1 - read0) + 1)
    }

    @Test func clocksStayInsideTheirTables() throws {
        let clocks = ClockSampler()
        guard clocks.isAvailable else { return }
        Thread.sleep(forTimeInterval: 0.5)
        let r = try #require(clocks.sample())
        // M-series clusters run between ~600 MHz and ~4.5 GHz.
        for mhz in [r.efficiencyMHz, r.performanceMHz].compactMap({ $0 }) { #expect(mhz > 500 && mhz < 5_000) }
        #expect(r.efficiencyMHz != nil || r.performanceMHz != nil)
    }
}
