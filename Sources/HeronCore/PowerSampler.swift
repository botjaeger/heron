import CSystem
import Foundation

/// Power draw per component, from IOReport's "Energy Model" counters (no root needed).
///
/// The kernel publishes energy in lumps about every 2 seconds, not continuously (measured on
/// an M3 Max: 8 empty samples at 250 ms, then one lump). Dividing one sample by the tick
/// interval would swing between double and zero, so `PowerWindow` averages the lumps of the
/// last 10 seconds over the time between their arrivals.
public final class PowerSampler {
    private let report: OpaquePointer?
    private var window = PowerWindow()
    /// Raw channels from the last sample (name, unit, energy). Useful for debugging new chips.
    public private(set) var lastChannels: [(name: String, unit: String, value: Int64)] = []

    public init() {
        report = heron_ioreport_create()
        _ = readDelta()  // prime: the first delta is "since forever"
    }

    deinit { heron_ioreport_destroy(report) }

    public var isAvailable: Bool { report != nil }

    /// Call once per tick; returns the current estimate (nil until two lumps arrived).
    public func sample(now: Date = Date()) -> PowerReading? {
        guard report != nil else { return nil }
        let energy = PowerMath.reading(channels: readDelta(), seconds: 1)  // seconds: 1 → joules
        return window.add(energy, at: now)
    }

    /// One IOReport delta with no windowing (debugging only; fills `lastChannels`).
    public func debugRawSample() -> Int { readDelta().count }

    private func readDelta() -> [(name: String, unit: String, value: Int64)] {
        guard let report else { return [] }
        let count = Int(heron_ioreport_sample(report, &channels, Int32(channels.count)))
        var out: [(name: String, unit: String, value: Int64)] = []
        out.reserveCapacity(count)
        for i in 0..<min(count, channels.count) {
            let c = channels[i]
            // Names and units repeat tick after tick: reuse last tick's strings when the bytes match.
            let name = Self.text(c.channel, reusing: i < lastChannels.count ? lastChannels[i].name : nil)
            let unit = Self.text(c.unit, reusing: i < lastChannels.count ? lastChannels[i].unit : nil)
            out.append((name, unit, c.value))
        }
        lastChannels = out
        return lastChannels
    }

    /// One buffer for every tick (2048 channels, ~311 KB): the C side clears each entry it writes.
    private var channels = [heron_energy_channel](repeating: heron_energy_channel(), count: 2048)

    /// A NUL-terminated C char array as a String, or `previous` when it holds the same bytes.
    static func text<T>(_ tuple: T, reusing previous: String?) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            if let previous, previous.utf8.elementsEqual(bytes) { return previous }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Averages energy lumps into watts. Pure, unit tested.
public struct PowerWindow: Sendable {
    public var span: TimeInterval = 10
    private var lumps: [(date: Date, joules: PowerReading)] = []
    private var current: PowerReading?

    public init(span: TimeInterval = 10) { self.span = span }

    /// `energy` is joules since the previous call (as a PowerReading whose fields are joules).
    public mutating func add(_ energy: PowerReading?, at now: Date) -> PowerReading? {
        guard let energy, (energy.package ?? 0) > 0 else { return current }  // no lump this tick
        // The wall clock went back (set by hand, NTP): the lumps before it would measure a negative
        // period and freeze the estimate until the clock caught up. Start again from this one.
        if let last = lumps.last, now < last.date { lumps.removeAll() }
        lumps.append((now, energy))
        // Keep lumps inside the span, but always at least two to measure a period.
        while lumps.count > 2, let first = lumps.first, now.timeIntervalSince(first.date) > span { lumps.removeFirst() }
        guard lumps.count >= 2, let first = lumps.first else { return current }
        let seconds = now.timeIntervalSince(first.date)
        guard seconds > 0 else { return current }
        // The first lump only marks the start time; its energy belongs to the time before it.
        let counted = lumps.dropFirst().map(\.joules)
        func total(_ part: KeyPath<PowerReading, Double?>) -> Double? {
            let values = counted.compactMap { $0[keyPath: part] }
            return values.isEmpty ? nil : values.reduce(0, +) / seconds
        }
        current = PowerReading(cpu: total(\.cpu), gpu: total(\.gpu), ane: total(\.ane), dram: total(\.dram), display: total(\.display))
        return current
    }
}

public enum PowerMath {
    /// Joules per unit label IOReport uses.
    static func joules(_ value: Int64, unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return Double(value) / 1e3
        case "uJ", "µJ": return Double(value) / 1e6
        case "nJ": return Double(value) / 1e9
        default: return Double(value) / 1e3
        }
    }

    public static func reading(channels: [(name: String, unit: String, value: Int64)], seconds: Double) -> PowerReading? {
        guard seconds > 0, !channels.isEmpty else { return nil }
        var cpu = 0.0, gpu = 0.0, ane = 0.0, dram = 0.0, display = 0.0
        var sawCPU = false, sawGPU = false, sawANE = false, sawDRAM = false, sawDisplay = false
        for c in channels {
            let watts = joules(c.value, unit: c.unit) / seconds
            // "CPU Energy" is the total; EACC_CPU / PACC0_CPU are parts of it and must not be added.
            if c.name.hasSuffix("CPU Energy") {
                cpu += watts; sawCPU = true
            } else if c.name == "GPU Energy" || c.name.hasPrefix("GPU") && c.name.hasSuffix("Energy") {
                gpu += watts; sawGPU = true
            } else if c.name.hasPrefix("ANE") {
                ane += watts; sawANE = true
            } else if c.name.hasPrefix("DRAM") {
                dram += watts; sawDRAM = true
            }
            // DISP0 (built-in display) and DISPEXT0 (external displays): the display engines.
            else if c.name.hasPrefix("DISP") {
                display += watts; sawDisplay = true
            }
        }
        return PowerReading(
            cpu: sawCPU ? cpu : nil, gpu: sawGPU ? gpu : nil, ane: sawANE ? ane : nil, dram: sawDRAM ? dram : nil,
            display: sawDisplay ? display : nil)
    }
}
