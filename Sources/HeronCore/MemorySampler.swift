import Foundation

/// Reads memory the way Activity Monitor reports it.
public final class MemorySampler {
    public init() {}

    public func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            // host_statistics64 wants an array of integers, so the struct is reinterpreted as one.
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self)
        let pressureLevel = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        return MemoryMath.reading(
            stats: stats, pageSize: SystemInfo.pageSize, total: SystemInfo.physicalMemory,
            swapUsed: swap.map { UInt64($0.xsu_used) } ?? 0, pressureLevel: pressureLevel,
            freeLevel: Sysctl.int("kern.memorystatus_level"))
    }
}

public enum MemoryMath {
    /// `freeLevel`: `kern.memorystatus_level`, the percentage of memory still free for apps (0...100).
    public static func reading(stats: vm_statistics64, pageSize: UInt64, total: UInt64, swapUsed: UInt64, pressureLevel: Int, freeLevel: Int? = nil) -> MemoryReading {
        func bytes(_ pages: UInt32) -> UInt64 { UInt64(pages) * pageSize }
        let internalBytes = bytes(stats.internal_page_count)
        let purgeable = bytes(stats.purgeable_count)
        let app = internalBytes > purgeable ? internalBytes - purgeable : 0
        let wired = bytes(stats.wire_count)
        let compressed = bytes(stats.compressor_page_count)
        let cached = bytes(stats.external_page_count) + purgeable
        let used = app + wired + compressed
        let free = total > used + cached ? total - used - cached : 0
        let pressure: MemoryReading.Pressure = pressureLevel >= 4 ? .critical : (pressureLevel >= 2 ? .warning : .normal)
        // A level outside 0...100 is not a percentage: report nothing rather than a wrong number.
        let pressurePercent = freeLevel.flatMap { (0...100).contains($0) ? Double(100 - $0) / 100 : nil }
        return MemoryReading(
            total: total, app: app, wired: wired, compressed: compressed, cached: cached,
            free: free, swapUsed: swapUsed, pressure: pressure, pressurePercent: pressurePercent)
    }
}
