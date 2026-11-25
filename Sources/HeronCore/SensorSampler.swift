import CSystem
import Foundation

/// Temperatures and fans.
/// Temperatures: SMC "T…" keys first (they carry the component in the name), HID sensors as a fallback.
/// Fans: SMC keys F<n>Ac (actual), F<n>Mn/Mx (limits), F<n>Tg (target).
public final class SensorSampler {
    private let smc: SMC?
    /// The keys found by the scan, with the name and group each keeps for the whole run
    /// (so "CPU 12" is always the same key, even while others drop out).
    private var scanned: [Sensor] = []

    public init() {
        smc = SMC()
        if let smc {
            // One-time scan: float "T…" keys that report a plausible temperature.
            let candidates: [(String, Double)] = smc.allKeys().compactMap { key in
                guard key.hasPrefix("T"), let value = smc.read(key), value.type == "flt " || value.type == "sp78",
                    let c = value.number
                else { return nil }
                return (key, c)
            }
            scanned = SensorNaming.smcSensors(SensorNaming.plausible(candidates))
        }
    }

    public var hasSMC: Bool { smc != nil }

    /// How many sensors have no known name (counted at the scan, whether or not they are read).
    public var unnamedCount: Int { scanned.filter { !$0.isKnown }.count }

    /// Names of the named sensors, whether or not each reported this read: the scan's keys (fixed
    /// for the run), or every HID name seen so far. Settings › Overview › Sensors offers a card temperature for
    /// every group named here, also one that skipped this read.
    public var knownNames: [String] { scanned.isEmpty ? hidNames.sorted() : scanned.filter(\.isKnown).map(\.name) }
    private var hidNames = Set<String>()

    /// `includeUnnamed: false` skips the keys without a known name: on an M3 Max that is 160 of
    /// 274 keys, most of the per-second SMC cost, for sensors the UI hides by default.
    public func temperatures(includeUnnamed: Bool = true) -> [Sensor] {
        if let smc, !scanned.isEmpty {
            // Filtered on every read, not only at the scan: idle CPU clusters' slots switch between
            // real values and -4.0 °C (measured on an M3 Max: 48 of 106 CPU keys at -4.0), which
            // dragged the CPU average from ~82 °C to 45 °C.
            let wanted = includeUnnamed ? scanned : scanned.filter(\.isKnown)
            let raw = wanted.compactMap { s in smc.number(String(s.id.dropFirst(4))).map { (s, $0) } }
            let keep = Set(SensorNaming.plausible(raw.map { ($0.0.id, $0.1) }).map(\.0))
            return raw.filter { keep.contains($0.0.id) }.map { s, c in
                var r = s; r.celsius = c; return r
            }
        }
        let hid = hidTemperatures()
        hidNames.formUnion(hid.filter(\.isKnown).map(\.name))
        return hid
    }

    public func hidTemperatures() -> [Sensor] {
        var buffer = [heron_hid_temp](repeating: heron_hid_temp(), count: 128)
        let count = Int(heron_hid_temperatures(&buffer, 128))
        let raw: [(String, Double)] = buffer.prefix(count).map { item in
            var temp = item
            let name = withUnsafeBytes(of: &temp.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return (name, item.celsius)
        }
        return SensorNaming.hidSensors(raw)
    }

    public func fans() -> [Fan] {
        guard let smc else { return [] }
        let total = SensorNaming.fanCount(smc.number("FNum"))
        return (0..<total).compactMap { i in
            guard let rpm = smc.number("F\(i)Ac") else { return nil }
            let name = total == 2 ? (i == 0 ? "Left" : "Right") : (total == 1 ? "Fan" : "Fan \(i + 1)")
            return Fan(
                id: i, name: name, rpm: max(0, rpm), minRPM: smc.number("F\(i)Mn") ?? 0,
                maxRPM: smc.number("F\(i)Mx") ?? 0, targetRPM: smc.number("F\(i)Tg"))
        }
    }
}

/// Turns raw sensor keys/names into readable, grouped sensors. Pure, unit tested.
public enum SensorNaming {
    /// The fan count from the SMC's "FNum", 0 to 16 (as many as keep a history): a garbage value
    /// (an infinity trapped `Int(...)`, a billion read the SMC a billion times a sample) reads as none.
    public static func fanCount(_ v: Double?) -> Int {
        guard let v, v.isFinite, v >= 1, v <= Double(MetricHistory.maxItems) else { return 0 }
        return Int(v)
    }

    /// Unused sensor slots report a fixed whole number (40.0 °C on an M3 Max, dozens of keys at once).
    /// A whole-number value shared by 4 or more keys is treated as a placeholder and dropped.
    /// Readings that can be real temperatures: inside 5…130 °C and not a shared placeholder.
    public static func plausible(_ raw: [(String, Double)]) -> [(String, Double)] {
        droppingPlaceholders(raw.filter { $0.1 > 5 && $0.1 < 130 })
    }

    public static func droppingPlaceholders(_ raw: [(String, Double)]) -> [(String, Double)] {
        var counts: [Double: Int] = [:]
        for (_, c) in raw where c == c.rounded() { counts[c, default: 0] += 1 }
        return raw.filter { _, c in !(c == c.rounded() && counts[c, default: 0] >= 4) }
    }

    public static func group(forSMCKey key: String) -> Sensor.Group? {
        guard key.count == 4 else { return nil }
        let prefix = String(key.prefix(2))
        switch prefix {
        // Which "Tp"/"Te" keys belong to which core type changes with every chip generation,
        // so both are reported simply as CPU.
        case "Tp", "Te": return .cpu
        case "Tg": return .gpu
        case "Tm": return .memory
        case "TH", "TN": return .ssd
        case "TB": return .battery
        case "Ts", "TA": return .surface
        case "TW": return .wireless
        default: return nil
        }
    }

    public static func smcSensors(_ raw: [(String, Double)]) -> [Sensor] {
        var counters: [Sensor.Group: Int] = [:]
        var seen = Set<String>()
        // A key is one sensor: never list it twice (ids key SwiftUI lists).
        return raw.filter { seen.insert($0.0).inserted }.sorted { $0.0 < $1.0 }.map { key, celsius in
            let group = group(forSMCKey: key)
            let resolved = group ?? .other
            counters[resolved, default: 0] += 1
            let name = group == nil ? key : "\(resolved.shortName) \(counters[resolved]!)"
            return Sensor(id: "smc:\(key)", name: name, group: resolved, celsius: celsius, isKnown: group != nil)
        }
    }

    public static func hidGroup(forName name: String) -> Sensor.Group? {
        let n = name.lowercased()
        if n.contains("tdie") || n.contains("tdev") || n.contains("cpu") { return .cpu }
        if n.contains("gpu") { return .gpu }
        if n.contains("nand") || n.contains("ssd") { return .ssd }
        if n.contains("battery") || n.contains("gas gauge") { return .battery }
        return nil
    }

    /// The HID layer lists most PMU sensors twice under the same name (measured on an M3 Max), and
    /// some report nonsense such as -1.6 °C. Ids must be unique (SwiftUI lists are keyed by them),
    /// and the same plausibility range as the SMC scan applies.
    public static func hidSensors(_ raw: [(String, Double)]) -> [Sensor] {
        var counters: [Sensor.Group: Int] = [:]
        var seen: [String: Int] = [:]
        return raw.filter { $0.1 > 5 && $0.1 < 130 }.sorted { $0.0 < $1.0 }.map { name, celsius in
            let group = hidGroup(forName: name)
            let resolved = group ?? .other
            counters[resolved, default: 0] += 1
            seen[name, default: 0] += 1
            let display = group == nil ? name : "\(resolved.shortName) \(counters[resolved]!)"
            let id = seen[name]! == 1 ? "hid:\(name)" : "hid:\(name)#\(seen[name]!)"
            return Sensor(id: id, name: display, group: resolved, celsius: celsius, isKnown: group != nil)
        }
    }
}

extension Sensor.Group {
    public var shortName: String {
        switch self {
        case .cpuPerformance: return "CPU P-core"
        case .cpuEfficiency: return "CPU E-core"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .ssd: return "SSD"
        case .battery: return "Battery"
        case .surface: return "Enclosure"
        case .wireless: return "Wireless"
        case .other: return "Sensor"
        }
    }
}
