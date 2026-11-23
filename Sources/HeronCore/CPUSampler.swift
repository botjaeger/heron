import Foundation
import IOKit

/// Measures CPU load. The kernel only gives running totals of "ticks" per core, so a
/// reading is always the difference between two samples (the first call returns nil).
public final class CPUSampler {
    private var previous: [CoreTicks]?
    private let kinds: [CoreLoad.Kind]

    public init() {
        kinds = SystemInfo.coreKinds()
    }

    public func sample() -> CPUReading? {
        guard let current = Self.readTicks() else { return nil }
        defer { previous = current }
        guard let previous, previous.count == current.count else { return nil }
        var reading = CPUMath.reading(previous: previous, current: current, kinds: kinds)
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { reading.loadAverage = load }
        return reading
    }

    static func readTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        // The kernel allocated this array for us; we must hand the memory back.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }
}

public struct CoreTicks: Sendable, Equatable {
    public var user, system, idle, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

/// Pure math, kept apart from the kernel calls so it can be unit tested.
public enum CPUMath {
    public static func reading(previous: [CoreTicks], current: [CoreTicks], kinds: [CoreLoad.Kind]) -> CPUReading {
        var sumUser = 0.0, sumSystem = 0.0, sumIdle = 0.0
        var cores: [CoreLoad] = []
        for (index, (old, new)) in zip(previous, current).enumerated() {
            // `&-` subtracts with wrap-around: the counters are 32-bit and can roll over.
            let user = Double((new.user &- old.user) &+ (new.nice &- old.nice))
            let system = Double(new.system &- old.system)
            let idle = Double(new.idle &- old.idle)
            let total = user + system + idle
            sumUser += user; sumSystem += system; sumIdle += idle
            let kind = index < kinds.count ? kinds[index] : .unknown
            cores.append(CoreLoad(id: index, kind: kind, load: total > 0 ? ((user + system) / total).unitClamped : 0))
        }
        let all = sumUser + sumSystem + sumIdle
        guard all > 0 else { return CPUReading(user: 0, system: 0, idle: 1, cores: cores, loadAverage: []) }
        return CPUReading(user: sumUser / all, system: sumSystem / all, idle: sumIdle / all, cores: cores, loadAverage: [])
    }
}

/// Static facts about this Mac.
public enum SystemInfo {
    public static var chipName: String { Sysctl.string("machdep.cpu.brand_string") ?? "Apple silicon" }
    public static var modelIdentifier: String { Sysctl.string("hw.model") ?? "Mac" }

    /// The Mac's marketing name as the system stores it ("MacBook Pro (16-inch, Nov 2023)"):
    /// `IODeviceTree:/product`'s "product-name". Nil when the device tree has none (never guessed
    /// from the model identifier).
    public static var productName: String? {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return nil }
        defer { IOObjectRelease(product) }
        guard let data = Registry.property(product, "product-name") as? Data else { return nil }
        return productName(from: data)
    }

    /// The device tree's NUL-terminated UTF-8 bytes as a name; nil when empty.
    public static func productName(from data: Data) -> String? {
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "MacBook Pro (16-inch, Nov 2023) · M3 Max": the marketing name and the chip, or the chip
    /// alone when the system gives no marketing name.
    public static func friendlyName(product: String?, chip: String) -> String {
        guard let product else { return chip }
        return "\(shortProduct(product)) · \(shortChip(chip))"
    }

    /// "Apple M3 Max" → "M3 Max", where the Mac's name or "Apple silicon" already says whose chip it is.
    public static func shortChip(_ chip: String) -> String {
        chip.hasPrefix("Apple ") ? String(chip.dropFirst("Apple ".count)) : chip
    }

    /// "MacBook Pro (14-inch, Nov 2023)" → "MacBook Pro 14″": the screen size kept, the year
    /// dropped. Any other shape is kept as the system wrote it.
    public static func shortProduct(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return name }
        let inside = name[open.upperBound..<name.index(before: name.endIndex)]
        let first = (inside.split(separator: ",").first ?? "").trimmingCharacters(in: .whitespaces)
        guard first.hasSuffix("-inch"), Double(first.dropLast("-inch".count)) != nil else { return name }
        return "\(name[..<open.lowerBound]) \(first.dropLast("-inch".count))″"
    }

    public static var friendlyName: String { friendlyName(product: productName, chip: chipName) }

    public static var logicalCores: Int { Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount }
    public static var performanceCores: Int? { Sysctl.int("hw.perflevel0.logicalcpu") }
    public static var efficiencyCores: Int? { Sysctl.int("hw.perflevel1.logicalcpu") }
    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    /// The kernel's page size, the unit of `host_statistics64` page counts (16 KB on Apple silicon).
    public static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        return host_page_size(mach_host_self(), &size) == KERN_SUCCESS ? UInt64(size) : 16_384
    }()

    public static var bootDate: Date? {
        guard let tv = Sysctl.value("kern.boottime", as: timeval.self) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// Whether each logical core is a performance or efficiency core, in kernel order.
    /// Read from the device tree (`IODeviceTree:/cpus/cpuN`, property "cluster-type": "E" or "P").
    /// Binned chips skip numbers (an M3 Max has no cpu9), so cores are sorted by "cpu-id" and
    /// then numbered 0, 1, 2… which is the order host_processor_info uses.
    public static func coreKinds() -> [CoreLoad.Kind] {
        var found: [(cpuID: Int, kind: CoreLoad.Kind)] = []
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            defer { IOObjectRelease(cpus) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                while case let entry = IOIteratorNext(iterator), entry != 0 {
                    defer { IOObjectRelease(entry) }
                    let props = Registry.properties(entry)
                    guard let idData = props["cpu-id"] as? Data, idData.count >= 4,
                        let typeData = props["cluster-type"] as? Data, let first = typeData.first
                    else { continue }
                    let id = Int(idData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                    switch Character(UnicodeScalar(first)) {
                    case "P": found.append((id, .performance))
                    case "E": found.append((id, .efficiency))
                    default: found.append((id, .unknown))
                    }
                }
            }
        }
        let count = logicalCores
        let ordered = found.sorted { $0.cpuID < $1.cpuID }.map(\.kind)
        if ordered.count == count { return ordered }
        // Fallback: Apple silicon numbers efficiency cores first.
        if let e = efficiencyCores, let p = performanceCores, e + p == count {
            return Array(repeating: .efficiency, count: e) + Array(repeating: .performance, count: p)
        }
        return Array(repeating: .unknown, count: count)
    }
}
