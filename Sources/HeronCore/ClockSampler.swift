import CSystem
import Foundation
import IOKit

/// The CPU clusters' clock speed, readable without root: IOReport says how long each cluster spent
/// at each step of its frequency table ("V3P2" is step 3), and the power manager's registry entry
/// (`pmgr`) lists the table itself. The average over the active time is what `powermetrics` calls
/// the cluster's active frequency.
///
/// The GPU is left out: on an M3 Max its table (voltage-states9-sram) has 13 frequencies, not in
/// order, against 15 IOReport steps, so the steps cannot be mapped to frequencies with confidence.
public final class ClockSampler {
    /// The registry keys of the efficiency and performance clusters' tables (M1 to M3).
    static let efficiencyTableKey = "voltage-states1-sram"
    static let performanceTableKey = "voltage-states5-sram"

    private let report: OpaquePointer?
    private let efficiencyTable: [Double]?
    private let performanceTable: [Double]?

    public init() {
        report = heron_ioreport_create_cpu_states()
        let tables = Self.tables()
        efficiencyTable = tables[Self.efficiencyTableKey].flatMap(ClockMath.frequencies)
        performanceTable = tables[Self.performanceTableKey].flatMap(ClockMath.frequencies)
        _ = readDelta()  // prime: the first delta is "since forever"
    }

    deinit { heron_ioreport_destroy(report) }

    public var isAvailable: Bool { report != nil && (efficiencyTable != nil || performanceTable != nil) }

    /// Call once per tick: the clocks since the previous call.
    public func sample() -> ClockReading? {
        guard isAvailable else { return nil }
        let channels = readDelta()
        guard !channels.isEmpty else { return nil }
        return ClockMath.reading(channels: channels, efficiencyTable: efficiencyTable, performanceTable: performanceTable)
    }

    private func readDelta() -> [ClockMath.Channel] {
        guard let report else { return [] }
        var raw = [heron_state_channel](repeating: heron_state_channel(), count: 64)
        let count = Int(heron_ioreport_sample_states(report, &raw, 64))
        return raw.prefix(count).map { c in
            var copy = c
            let name = withUnsafeBytes(of: &copy.channel) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let states = Int(max(0, min(c.count, HERON_MAX_STATES)))
            let names: [String] = withUnsafeBytes(of: &copy.names) { bytes in
                (0..<states).map { i in String(decoding: bytes[(i * 16)..<(i * 16 + 16)].prefix { $0 != 0 }, as: UTF8.self) }
            }
            let residency: [Int64] = withUnsafeBytes(of: &copy.residency) { Array($0.bindMemory(to: Int64.self).prefix(states)) }
            return ClockMath.Channel(name: name, states: Array(zip(names, residency)))
        }
    }

    /// The `voltage-states*` properties of the `pmgr` registry entry.
    static func tables() -> [String: Data] {
        var result: [String: Data] = [:]
        Registry.forEachService("AppleARMIODevice") { service in
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS, String(cBuffer: name) == "pmgr" else { return }
            for key in [efficiencyTableKey, performanceTableKey] {
                if let data = Registry.property(service, key) as? Data { result[key] = data }
            }
        }
        return result
    }
}

/// Pure parts of `ClockSampler`, unit tested.
public enum ClockMath {
    public struct Channel: Equatable, Sendable {
        public var name: String
        public var states: [(name: String, residency: Int64)]
        public init(name: String, states: [(name: String, residency: Int64)]) { self.name = name; self.states = states }
        public static func == (a: Channel, b: Channel) -> Bool {
            a.name == b.name && a.states.map(\.name) == b.states.map(\.name) && a.states.map(\.residency) == b.states.map(\.residency)
        }
    }

    /// A `voltage-states*-sram` table: pairs of little-endian UInt32 (frequency in Hz, millivolts)
    /// → the frequencies in MHz. Nil unless every one is a plausible CPU clock (100–6,000 MHz).
    public static func frequencies(_ table: Data) -> [Double]? {
        guard table.count >= 8, table.count.isMultiple(of: 8) else { return nil }
        let words: [UInt32] = table.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)) }
        }
        let mhz = stride(from: 0, to: words.count, by: 2).map { Double(words[$0]) / 1_000_000 }
        return mhz.allSatisfy { (100...6_000).contains($0) } ? mhz : nil
    }

    /// The step a state stands for: "V3P2" → 3. IDLE, DOWN and OFF are not steps.
    static func step(_ state: String) -> Int? {
        guard state.hasPrefix("V"), let p = state.firstIndex(of: "P") else { return nil }
        return Int(state[state.index(after: state.startIndex)..<p])
    }

    /// The residency-weighted average frequency of the active steps, in MHz. Nil when the steps do
    /// not match the table one for one, or the cluster never left idle.
    public static func activeMHz(_ states: [(name: String, residency: Int64)], table: [Double]) -> Double? {
        let steps = states.compactMap { s in step(s.name).map { ($0, max(0, s.residency)) } }
        guard steps.count == table.count, steps.allSatisfy({ $0.0 < table.count }) else { return nil }
        let total = steps.reduce(0) { $0 + Double($1.1) }
        guard total > 0 else { return nil }
        return steps.reduce(0) { $0 + table[$1.0] * Double($1.1) } / total
    }

    /// "ECPU" is the efficiency cluster; "PCPU", "PCPU1"… the performance clusters (merged:
    /// their residencies are added step by step). ECPM/PCPM are other blocks and are skipped.
    public static func reading(channels: [Channel], efficiencyTable: [Double]?, performanceTable: [Double]?) -> ClockReading {
        func merged(_ prefix: String) -> [(name: String, residency: Int64)]? {
            let clusters = channels.filter { $0.name.hasPrefix(prefix) && $0.name.dropFirst(prefix.count).allSatisfy(\.isNumber) }
            guard let first = clusters.first else { return nil }
            return first.states.indices.map { i in
                (first.states[i].name, clusters.reduce(0) { $0 + (i < $1.states.count && $1.states[i].name == first.states[i].name ? $1.states[i].residency : 0) })
            }
        }
        let e = efficiencyTable.flatMap { table in merged("ECPU").flatMap { activeMHz($0, table: table) } }
        let p = performanceTable.flatMap { table in merged("PCPU").flatMap { activeMHz($0, table: table) } }
        return ClockReading(efficiencyMHz: e, performanceMHz: p)
    }
}
