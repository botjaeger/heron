import Foundation

// Plain value types ("structs") that describe one reading of the system.
// Samplers produce them; the UI only reads them. Keeping them dumb makes them easy to test.

public struct CPUReading: Sendable, Equatable {
    public var user: Double  // 0...1 share of all cores
    public var system: Double
    public var idle: Double
    public var cores: [CoreLoad]  // one per logical core
    public var loadAverage: [Double]  // 1, 5, 15 minutes
    public var total: Double { user + system }

    public init(user: Double, system: Double, idle: Double, cores: [CoreLoad], loadAverage: [Double]) {
        self.user = user; self.system = system; self.idle = idle; self.cores = cores; self.loadAverage = loadAverage
    }
}

public struct CoreLoad: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case performance, efficiency, unknown }
    public var id: Int
    public var kind: Kind
    public var load: Double  // 0...1
    public init(id: Int, kind: Kind, load: Double) { self.id = id; self.kind = kind; self.load = load }
}

extension Array where Element == CoreLoad {
    /// Average load (0...1) of the cores of one kind, or nil when the chip has none of that kind.
    public func averageLoad(of kind: CoreLoad.Kind) -> Double? {
        let loads = filter { $0.kind == kind }.map(\.load)
        return loads.isEmpty ? nil : loads.reduce(0, +) / Double(loads.count)
    }
}

public struct MemoryReading: Sendable, Equatable {
    public enum Pressure: String, Sendable { case normal, warning, critical }
    public var total: UInt64  // bytes
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var pressure: Pressure
    /// Memory pressure, 0...1: 1 − the kernel's free-memory level (`kern.memorystatus_level`),
    /// the number Activity Monitor's pressure graph follows. Nil when the kernel does not report it.
    public var pressurePercent: Double?
    /// What Activity Monitor calls "Memory Used".
    public var used: UInt64 { app + wired + compressed }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public struct VolumeReading: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var total: UInt64
    public var available: UInt64
    public var isInternal: Bool
    public var format: String
    public var used: UInt64 { total > available ? total - available : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    /// The startup disk, mounted at "/". The one place that path is compared (`RootVolumeTests`).
    public var isRoot: Bool { path == "/" }
}

public struct DiskReading: Sendable, Equatable {
    /// The startup disk among `volumes`, if it was read.
    public var root: VolumeReading? { volumes.first(where: \.isRoot) }
    public var volumes: [VolumeReading]
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    /// Bytes read and written since boot, every block device together; nil when none reports them.
    public var bytesReadSinceBoot: UInt64?
    public var bytesWrittenSinceBoot: UInt64?
}

public struct NetworkReading: Sendable, Equatable {
    public var interface: String?  // e.g. "en0"
    public var interfaceKind: String  // "Wi-Fi", "Ethernet", ...
    public var localIP: String?
    public var downBytesPerSecond: Double
    public var upBytesPerSecond: Double
    public var sessionDown: UInt64  // bytes since Heron started
    public var sessionUp: UInt64
}

public struct BatteryReading: Sendable, Equatable {
    public var present: Bool
    public var percent: Double  // 0...1
    public var isCharging: Bool
    public var onAC: Bool
    public var minutesRemaining: Int?  // to empty, or to full when charging
    public var cycleCount: Int?
    public var maxCapacityFraction: Double?  // health, 0...1
    public var condition: String?
    public var temperatureC: Double?
    public var watts: Double?  // positive = drawing from battery
    public var chargeLimit: Double?  // 0...1, the macOS charge limit; nil when off or unknown
    /// Whether Heron could read the charge-limit setting at all (false: `chargeLimit` nil means unknown, not off).
    public var chargeLimitKnown = false
}

public struct GPUReading: Sendable, Equatable {
    public var device: Double  // 0...1
    public var renderer: Double?
    public var tiler: Double?
    public var name: String?
}

public struct Sensor: Sendable, Equatable, Identifiable {
    public enum Group: String, Sendable, CaseIterable {
        case cpuPerformance = "CPU performance cores"
        case cpuEfficiency = "CPU efficiency cores"
        case cpu = "CPU"
        case gpu = "GPU"
        case memory = "Memory"
        case ssd = "SSD"
        case battery = "Battery"
        case surface = "Enclosure"
        case wireless = "Wireless"
        case other = "Other"
    }
    public var id: String  // stable key, e.g. "smc:Tp01" or "hid:PMU tdie1"
    public var name: String
    public var group: Group
    public var celsius: Double
    public var isKnown: Bool  // false = we could not identify it
}

public struct Fan: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double?
}

public struct PowerReading: Sendable, Equatable {
    public var cpu: Double?  // watts
    public var gpu: Double?
    public var ane: Double?
    public var dram: Double?
    /// The chip's display engines (IOReport DISP*: internal and external), not the panel's
    /// backlight. Not part of `package`.
    public var display: Double?
    public var package: Double? {
        let parts = [cpu, gpu, ane, dram].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// The CPU clusters' average clock while active (MHz), from how long each spent at each step of
/// its frequency table. Nil for a cluster Heron cannot read or that was idle the whole interval.
public struct ClockReading: Sendable, Equatable {
    public var efficiencyMHz: Double?
    public var performanceMHz: Double?
    public init(efficiencyMHz: Double?, performanceMHz: Double?) { self.efficiencyMHz = efficiencyMHz; self.performanceMHz = performanceMHz }
}

public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var cpu: Double  // 1.0 = one full core
    public var memory: UInt64  // bytes (physical footprint)
    /// Processes summed into this row: an app's helpers count with it ("Microsoft Edge (6)").
    public var count: Int = 1

    public init(pid: Int32, name: String, cpu: Double, memory: UInt64, count: Int = 1) {
        self.pid = pid; self.name = name; self.cpu = cpu; self.memory = memory; self.count = count
    }

    /// "Microsoft Edge (6)": the name, and how many processes it sums when more than one.
    public var title: String { count > 1 ? "\(name) (\(count))" : name }

    /// A process's CPU as a share of the whole Mac, 0...1: `cpu` counts one core as 1.0 (Activity
    /// Monitor's "1038%"), which reads as nonsense where no "100% = one core" caption explains it.
    public static func cpuShare(_ cpu: Double, cores: Int) -> Double {
        cores > 0 ? min(1, max(0, cpu / Double(cores))) : 0
    }
}

/// Everything Heron knows at one moment.
public struct Snapshot: Sendable, Equatable {
    public var date = Date()
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var disk: DiskReading?
    public var network: NetworkReading?
    public var battery: BatteryReading?
    public var gpu: GPUReading?
    public var sensors: [Sensor] = []
    /// Every named sensor's name, also those that did not report this read (`SensorSampler.knownNames`).
    public var sensorNames: [String] = []
    public var fans: [Fan] = []
    public var power: PowerReading?
    public var clocks: ClockReading?
    public var topCPU: [ProcessUsage] = []
    public var topMemory: [ProcessUsage] = []
    /// True until Heron has its first full set of readings: CPU, GPU and the rates need two
    /// samples, so a reading missing now is one still on its way, not one this Mac lacks. Every
    /// surface keeps its place and draws no number meanwhile, never an invented "0" or "–".
    public var awaitingReadings = false
    public init() {}

    /// The hottest identified sensor, used for the menu bar temperature item.
    public var hottest: Sensor? { sensors.filter(\.isKnown).max { $0.celsius < $1.celsius } }

    /// The startup disk ("/"): the disk card, menu bar item, alert and Settings previews all read it here.
    public var rootVolume: VolumeReading? { disk?.root }

    /// The battery's temperature, the one number every place shows (overview card, panel row,
    /// history): the battery's own reading, else the average of its identified sensors.
    public var batteryCelsius: Double? {
        guard battery?.present == true else { return nil }
        return battery?.temperatureC ?? SensorStats.average(sensors.filter(\.isKnown), in: [.battery])
    }
}
