import Foundation

/// A fixed-size ring buffer of numbers: once full, the oldest value is overwritten.
/// One per graph. 86,400 slots = 24 hours at one sample per second, about 0.7 MB.
public struct RingBuffer: Sendable, Equatable {
    private var storage: [Double]
    private var start = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Double](repeating: 0, count: self.capacity)
    }

    public mutating func append(_ value: Double) {
        let index = (start + count) % capacity
        storage[index] = value
        if count < capacity { count += 1 } else { start = (start + 1) % capacity }
    }

    /// The newest `n` values, oldest first.
    public func last(_ n: Int) -> [Double] {
        let take = min(n, count)
        return (0..<take).map { storage[(start + count - take + $0) % capacity] }
    }

    // swiftlint:disable:next empty_count - `count` is the ring's fill level, not a collection's
    public var latest: Double? { count == 0 ? nil : storage[(start + count - 1) % capacity] }

    /// The newest `n` values squeezed into at most `points` buckets (averaged), for drawing.
    public func downsampled(last n: Int, points: Int) -> [Double] {
        Self.downsample(last(n), points: points)
    }

    /// `values` squeezed into at most `points` buckets (averaged).
    public static func downsample(_ values: [Double], points: Int) -> [Double] {
        guard values.count > points, points > 0 else { return values }
        let size = Double(values.count) / Double(points)
        return (0..<points).map { i in
            let lower = Int(Double(i) * size), upper = max(lower + 1, Int(Double(i + 1) * size))
            let slice = values[lower..<min(upper, values.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

/// The graphs Heron keeps.
public enum Metric: String, CaseIterable, Codable, Sendable {
    // cpuSystem: the system share of `cpu`; the user share is cpu − cpuSystem (one buffer, not two).
    case cpu, cpuSystem, gpu, memory, networkDown, networkUp, diskRead, diskWrite, battery, temperature, power
    // The detail panels' rows (kept as a `TieredHistory`, see `keepsEverySecond`).
    // Core kinds: average load 0...1. Power rails: watts. Memory parts: bytes.
    case cpuEfficiency, cpuPerformance
    case cpuPower, gpuPower, anePower, dramPower
    case memoryApp, memoryWired, memoryCompressed, memoryCached, memoryFree
    // °C: the CPU average (all CPU groups, identified sensors, as the alerts read it), the battery (`Snapshot.batteryCelsius`)
    // (its own reading, else its sensors' average), and one average per sensor group (the Sensors panel's rows).
    case cpuTemperature, batteryTemperature
    case sensorCPU, sensorCPUPerformance, sensorCPUEfficiency, sensorGPU, sensorSSD, sensorMemory,
        sensorBattery, sensorWireless, sensorEnclosure, sensorOther
    // The 1-minute load average; the display engines' watts; the battery's cycle count, maximum
    // capacity (0...1) and watts in or out (the size, whichever way they flow).
    case loadAverage, displayPower, batteryCycles, batteryHealth, batteryPower
    // The GPU's renderer and tiler utilisation (0...1), memory pressure (0...1, the kernel's
    // percentage) and swap used (bytes).
    case gpuRenderer, gpuTiler, memoryPressure, swapUsed

    /// The first ten graphs keep every second for 24 hours (0.7 MB each); the rest keep a
    /// `TieredHistory` (13 KB each). The battery's charge is tiered too: it moves slowly, and a
    /// tier's resolution (every second for 10 minutes, then 10 s and 2 min) is finer than any of
    /// its graphs draws, so it keeps the whole history under 8 MB.
    public var keepsEverySecond: Bool {
        switch self {
        case .cpu, .cpuSystem, .gpu, .memory, .networkDown, .networkUp, .diskRead, .diskWrite, .temperature, .power: return true
        default: return false
        }
    }

    /// The history of one sensor group's average temperature.
    public static func sensor(_ group: Sensor.Group) -> Metric {
        switch group {
        case .cpu: return .sensorCPU
        case .cpuPerformance: return .sensorCPUPerformance
        case .cpuEfficiency: return .sensorCPUEfficiency
        case .gpu: return .sensorGPU
        case .ssd: return .sensorSSD
        case .memory: return .sensorMemory
        case .battery: return .sensorBattery
        case .wireless: return .sensorWireless
        case .surface: return .sensorEnclosure
        case .other: return .sensorOther
        }
    }
}

/// A history kept per item of a list whose length depends on the Mac (its fans), one
/// `TieredHistory` each, made when the item is first seen.
public struct ItemKey: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case fanRPM }
    public var kind: Kind
    public var id: Int
    public init(_ kind: Kind, id: Int) { self.kind = kind; self.id = id }
}

/// What a panel row's history reads: one of the fixed graphs, or one item of a list.
public enum HistorySource: Hashable, Sendable {
    case metric(Metric)
    case item(ItemKey)
    /// An AI account's limit resets: opens beside the panel like a history, drawn from the
    /// account's reading (`AIResetPlan`), so it has no recorded values.
    case aiResets(account: String)
}

/// One number's history at falling resolution: every second for 10 minutes, then 10-second
/// averages for an hour, then 2-minute averages for 24 hours. 1,680 values (13 KB) instead of
/// 86,400 (0.7 MB). Each coarser tier averages the seconds it covers; the bucket still filling
/// counts as its newest value, so a graph moves before a whole bucket is in.
public struct TieredHistory: Sendable, Equatable {
    public struct Tier: Sendable, Equatable {
        public let seconds: Int  // seconds per value
        public private(set) var ring: RingBuffer
        var sum = 0.0
        var filled = 0  // seconds in the bucket still filling
        public var span: Int { seconds * ring.capacity }

        init(seconds: Int, capacity: Int) { self.seconds = max(1, seconds); ring = RingBuffer(capacity: capacity) }

        mutating func append(_ value: Double) {
            sum += value; filled += 1
            if filled >= seconds { ring.append(sum / Double(filled)); sum = 0; filled = 0 }
        }

        /// The newest values covering `seconds`, the filling bucket last.
        func values(covering seconds: Int) -> [Double] {
            var result = ring.last(max(1, seconds / self.seconds))
            if filled > 0 {
                result.append(sum / Double(filled))
                if result.count > max(1, seconds / self.seconds) { result.removeFirst() }
            }
            return result
        }
    }

    public static let layout: [(seconds: Int, capacity: Int)] = [(1, 600), (10, 360), (120, 720)]
    public private(set) var tiers: [Tier]

    public init(layout: [(seconds: Int, capacity: Int)] = TieredHistory.layout) {
        tiers = layout.map { Tier(seconds: $0.seconds, capacity: $0.capacity) }
    }

    /// One value per second.
    public mutating func append(_ value: Double) {
        for i in tiers.indices { tiers[i].append(value) }
    }

    /// Values for a graph covering the last `seconds`, at most `points` wide: from the finest tier
    /// that spans them (the coarsest when none does).
    public func series(seconds: Int, points: Int) -> [Double] {
        guard let tier = tiers.first(where: { $0.span >= seconds }) ?? tiers.last else { return [] }
        return RingBuffer.downsample(tier.values(covering: seconds), points: points)
    }

    /// Values held, all tiers together.
    public var capacity: Int { tiers.map(\.ring.capacity).reduce(0, +) }

    /// Seconds of history held (every tier sees every second; the coarsest reaches back furthest).
    public var seconds: Int { tiers.map { $0.ring.count * $0.seconds + $0.filled }.max() ?? 0 }
}

/// One slot per second, whatever the sampling interval, so "10 min" always means ten minutes:
/// sampling at 0.5 s keeps one value per second, sampling at 5 s (low battery) repeats each value
/// for the seconds it stood for. Gaps longer than `maxFill` seconds (sleep) are not filled.
public struct MetricHistory: Sendable, Equatable {
    public static let capacity = 86_400
    public static let maxFill = 10
    /// A sample this many seconds before the next slot is a clock set back, not a fast sample
    /// (at 0.5 s sampling a sample lands at most 1 s early).
    static let clockStep: TimeInterval = 3
    /// At most this many list items keep a history (13 KB each); later ones get none.
    public static let maxItems = 16
    private var items: [ItemKey: TieredHistory] = [:]
    private var buffers: [Metric: RingBuffer] = Dictionary(
        uniqueKeysWithValues: Metric.allCases.filter(\.keepsEverySecond).map { ($0, RingBuffer(capacity: MetricHistory.capacity)) })
    private var tiered: [Metric: TieredHistory] = Dictionary(uniqueKeysWithValues: Metric.allCases.filter { !$0.keepsEverySecond }.map { ($0, TieredHistory()) })
    private var nextSlot: Date?
    public init() {}

    public mutating func record(_ snapshot: Snapshot) {
        let date = snapshot.date
        var slots = 1
        if let next = nextSlot, date < next.addingTimeInterval(-Self.clockStep) {
            // The wall clock went back (set by hand, NTP): start the slots again from now, or
            // nothing would be recorded until the clock caught up with the old slot.
            nextSlot = date.addingTimeInterval(1)
        } else if let next = nextSlot {
            guard date >= next else { return }  // faster than once a second: this second already has a value
            let behind = Int(date.timeIntervalSince(next)) + 1
            if behind > Self.maxFill {
                nextSlot = date.addingTimeInterval(1)
            } else {
                slots = behind
                nextSlot = next.addingTimeInterval(Double(behind))
            }
        } else {
            nextSlot = date.addingTimeInterval(1)
        }
        func add(_ m: Metric, _ v: Double?) {
            guard let v else { return }
            for _ in 0..<slots { if m.keepsEverySecond { buffers[m]?.append(v) } else { tiered[m]?.append(v) } }
        }
        add(.cpu, snapshot.cpu?.total)
        add(.cpuSystem, snapshot.cpu?.system)
        add(.gpu, snapshot.gpu?.device)
        add(.memory, snapshot.memory?.usedFraction)
        add(.networkDown, snapshot.network?.downBytesPerSecond)
        add(.networkUp, snapshot.network?.upBytesPerSecond)
        add(.diskRead, snapshot.disk?.readBytesPerSecond)
        add(.diskWrite, snapshot.disk?.writeBytesPerSecond)
        add(.battery, snapshot.battery.flatMap { $0.present ? $0.percent : nil })
        add(.temperature, snapshot.hottest?.celsius)
        add(.power, snapshot.power?.package)
        add(.cpuEfficiency, snapshot.cpu?.cores.averageLoad(of: .efficiency))
        add(.cpuPerformance, snapshot.cpu?.cores.averageLoad(of: .performance))
        add(.cpuPower, snapshot.power?.cpu)
        add(.gpuPower, snapshot.power?.gpu)
        add(.anePower, snapshot.power?.ane)
        add(.dramPower, snapshot.power?.dram)
        add(.memoryApp, snapshot.memory.map { Double($0.app) })
        add(.memoryWired, snapshot.memory.map { Double($0.wired) })
        add(.memoryCompressed, snapshot.memory.map { Double($0.compressed) })
        add(.memoryCached, snapshot.memory.map { Double($0.cached) })
        add(.memoryFree, snapshot.memory.map { Double($0.free) })
        add(.cpuTemperature, SensorStats.average(snapshot.sensors.filter(\.isKnown), in: SensorStats.cpuGroups))
        add(.batteryTemperature, snapshot.batteryCelsius)
        for group in Sensor.Group.allCases { add(.sensor(group), SensorStats.average(snapshot.sensors, in: [group])) }
        add(.loadAverage, snapshot.cpu?.loadAverage.first)
        add(.displayPower, snapshot.power?.display)
        let battery = snapshot.battery.flatMap { $0.present ? $0 : nil }
        add(.batteryCycles, battery?.cycleCount.map(Double.init))
        add(.batteryHealth, battery?.maxCapacityFraction)
        add(.batteryPower, battery?.watts.map(abs))
        add(.gpuRenderer, snapshot.gpu?.renderer)
        add(.gpuTiler, snapshot.gpu?.tiler)
        add(.memoryPressure, snapshot.memory?.pressurePercent)
        add(.swapUsed, snapshot.memory.map { Double($0.swapUsed) })
        for fan in snapshot.fans {
            let key = ItemKey(.fanRPM, id: fan.id)
            if items[key] == nil {
                guard items.count < Self.maxItems else { continue }
                items[key] = TieredHistory()
            }
            for _ in 0..<slots { items[key]?.append(fan.rpm) }
        }
    }

    /// The every-second buffer of a metric; for a tiered metric, its finest tier.
    public subscript(metric: Metric) -> RingBuffer { buffers[metric] ?? tiered[metric]?.tiers.first?.ring ?? RingBuffer(capacity: 1) }

    /// Values for a graph covering the last `seconds`, at most `points` wide.
    public func series(_ metric: Metric, seconds: Int, points: Int = 120) -> [Double] {
        if let t = tiered[metric] { return t.series(seconds: max(1, seconds), points: points) }
        return self[metric].downsampled(last: max(1, seconds), points: points)
    }

    /// Values for a row's graph, a fixed metric or a list item (empty for an item never seen).
    public func series(_ source: HistorySource, seconds: Int, points: Int = 120) -> [Double] {
        switch source {
        case .metric(let m): return series(m, seconds: seconds, points: points)
        case .item(let key): return items[key]?.series(seconds: max(1, seconds), points: points) ?? []
        case .aiResets: return []
        }
    }

    /// Seconds of history held for a graph, so it can be drawn over the part of its time axis it
    /// covers (two minutes of data are not "24 hours ago … now").
    public func seconds(_ source: HistorySource) -> Int {
        switch source {
        case .metric(let m): return tiered[m]?.seconds ?? self[m].count
        case .item(let key): return items[key]?.seconds ?? 0
        case .aiResets: return 0
        }
    }

    /// The newest value of a row's history.
    public func latest(_ source: HistorySource) -> Double? {
        switch source {
        case .metric(let m): return self[m].latest
        case .item(let key): return items[key]?.tiers.first?.ring.latest
        case .aiResets: return nil
        }
    }

    /// Numbers held in memory, every graph together (8 bytes each).
    public var storedValues: Int {
        buffers.values.map(\.capacity).reduce(0, +) + tiered.values.map(\.capacity).reduce(0, +) + items.values.map(\.capacity).reduce(0, +)
    }
}
