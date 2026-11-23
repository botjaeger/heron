import Foundation
import IOKit
import IOKit.ps

/// Battery state. Charge and time come from the public IOPowerSources API; health,
/// cycles, temperature and power draw come from the AppleSmartBattery registry entry.
public final class BatterySampler {
    private var chargeLimit = ChargeLimitFile()

    public init() {}

    public func sample() -> BatteryReading {
        var reading = BatteryReading(present: false, percent: 0, isCharging: false, onAC: true)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return reading }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            reading.present = true
            reading.percent = max > 0 ? (Double(current) / Double(max)).unitClamped : 0
            reading.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            reading.onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            // -1 means "still calculating"; 0 is valid only when full.
            let minutes = reading.isCharging ? desc[kIOPSTimeToFullChargeKey] as? Int : desc[kIOPSTimeToEmptyKey] as? Int
            reading.minutesRemaining = (minutes ?? -1) > 0 ? minutes : nil
            reading.condition = desc["BatteryHealth"] as? String
        }
        guard reading.present else { return reading }

        switch chargeLimit.read() {
        case .unknown: break
        case .off: reading.chargeLimitKnown = true
        case .limit(let fraction): reading.chargeLimitKnown = true; reading.chargeLimit = fraction
        }

        Registry.forEachService("AppleSmartBattery") { service in
            // Only the keys used, one by one: copying the whole entry each tick built a large dictionary.
            let p = { (key: String) in Registry.property(service, key) }
            reading.cycleCount = p("CycleCount") as? Int
            // Since macOS 13 the capacities moved into the "BatteryData" sub-dictionary (read only when needed).
            var batteryData: [String: Any]?
            let data = { (key: String) -> Any? in
                if batteryData == nil { batteryData = p("BatteryData") as? [String: Any] ?? [:] }
                return batteryData?[key]
            }
            let raw = p("AppleRawMaxCapacity") as? Int ?? data("AppleRawMaxCapacity") as? Int
            let design = p("DesignCapacity") as? Int ?? data("DesignCapacity") as? Int
            if let raw, let design, design > 0 { reading.maxCapacityFraction = Double(raw) / Double(design) }
            // Older Macs publish "Temperature" here (in 0.01 °C); newer ones only via the SMC (TB0T).
            if let t = p("Temperature") as? Int { reading.temperatureC = Double(t) / 100 }
            if let mV = p("Voltage") as? Int, let amperage = p("InstantAmperage") as? NSNumber ?? p("Amperage") as? NSNumber {
                // The registry stores a signed value in an unsigned field; reinterpret the bits.
                let mA = Int64(truncatingIfNeeded: amperage.uint64Value)
                reading.watts = -Double(mA) * Double(mV) / 1_000_000  // positive while discharging
            }
        }
        return reading
    }
}

/// macOS's charge limit (System Settings › Battery › Charging, macOS 26+). powerd keeps its charge
/// policies in a root-owned, world-readable file: `policies` is a keyed archive of
/// `ChargeCtrlPolicy` objects, and the charge limit is the one whose reason is
/// "manualChargeLimit", with `soclimit` in percent. Undocumented; read only, never written.
public enum ChargeLimitState: Equatable, Sendable {
    case unknown  // no file, an old boot's file, or a format Heron does not know: the row hides
    case off
    case limit(Double)  // 0...1
}

public enum ChargeLimitSource {
    public static let path = "/Library/Preferences/com.apple.powerd.charging.plist"

    /// `file` is the plist's bytes; `bootSession` the running boot's `kern.bootsessionuuid`. A file
    /// written in another boot is not trusted (powerd rewrites it each boot).
    public static func parse(_ file: Data, bootSession: String?) -> ChargeLimitState {
        guard let top = try? PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any],
            let policies = top["policies"] as? Data
        else { return .unknown }
        if let session = top["bootSessionUUID"] as? String, let bootSession, session != bootSession { return .unknown }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: policies) else { return .unknown }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ChargePolicyRecord.self, forClassName: "ChargeCtrlPolicy")
        defer { unarchiver.finishDecoding() }
        guard let list = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [Any] else { return .unknown }
        let manual = list.compactMap { $0 as? ChargePolicyRecord }.first { $0.reason == "manualChargeLimit" && !$0.terminated }
        guard let manual, manual.socLimit > 0, manual.socLimit < 100 else { return .off }
        return .limit(Double(manual.socLimit) / 100)
    }
}

/// The fields Heron reads from one of powerd's `ChargeCtrlPolicy` objects.
final class ChargePolicyRecord: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let reason: String?
    let socLimit: Int
    let terminated: Bool

    init(reason: String?, socLimit: Int, terminated: Bool) { self.reason = reason; self.socLimit = socLimit; self.terminated = terminated }

    required init?(coder: NSCoder) {
        reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String?
        socLimit = coder.decodeInteger(forKey: "soclimit")
        terminated = coder.decodeBool(forKey: "terminated")
    }

    func encode(with coder: NSCoder) {
        coder.encode(reason as NSString?, forKey: "reason")
        coder.encode(socLimit, forKey: "soclimit")
        coder.encode(terminated, forKey: "terminated")
    }
}

/// Reads `ChargeLimitSource.path` again only when the file changes.
struct ChargeLimitFile {
    var path = ChargeLimitSource.path
    private var cached: (modified: Date, state: ChargeLimitState)?

    mutating func read() -> ChargeLimitState {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            cached = nil
            return .unknown
        }
        if let cached, cached.modified == modified { return cached.state }
        let state =
            (try? Data(contentsOf: URL(fileURLWithPath: path))).map {
                ChargeLimitSource.parse($0, bootSession: Sysctl.string("kern.bootsessionuuid"))
            } ?? .unknown
        cached = (modified, state)
        return state
    }
}
