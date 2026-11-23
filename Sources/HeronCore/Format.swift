import Foundation

/// Every number Heron shows goes through here, so units look the same everywhere.
public enum Format {
    public enum TemperatureUnit: String, CaseIterable, Sendable { case celsius, fahrenheit }

    /// 0.234 -> "23%"
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction.unitClamped * 100).rounded()))%"
    }

    /// 19_537_000_000 -> "18.2 GB" (binary units, like Activity Monitor).
    public static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1024) }
        if gb >= 1 { return String(format: gb >= 100 ? "%.0f GB" : "%.1f GB", gb) }
        let mb = Double(value) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(value) / 1024)
    }

    /// Disk sizes use decimal units, like Finder ("994 GB").
    public static func diskBytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1000) }
        return String(format: "%.0f GB", gb)
    }

    /// Throughput: "8.4 MB/s", "312 KB/s". With `bits`, "67 Mb/s".
    public static func rate(_ bytesPerSecond: Double, bits: Bool = false) -> String {
        let value = bits ? bytesPerSecond * 8 : bytesPerSecond
        let unit = bits ? "b/s" : "B/s"
        switch value {
        case ..<1_000: return String(format: "%.0f \(unit)", value)
        case ..<1_000_000: return String(format: "%.0f K\(unit)", value / 1_000)
        case ..<10_000_000: return String(format: "%.1f M\(unit)", value / 1_000_000)
        case ..<1_000_000_000: return String(format: "%.0f M\(unit)", value / 1_000_000)
        default: return String(format: "%.1f G\(unit)", value / 1_000_000_000)
        }
    }

    public static func temperature(_ celsius: Double, unit: TemperatureUnit = .celsius) -> String {
        "\(Int(converted(celsius, to: unit).rounded()))°"
    }

    /// °C → the display unit. Every stored temperature (sensors, limits, curves) is in °C.
    public static func converted(_ celsius: Double, to unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// The display unit → °C, for values the user types.
    public static func celsius(_ value: Double, from unit: TemperatureUnit) -> Double {
        unit == .celsius ? value : (value - 32) * 5 / 9
    }

    public static func watts(_ value: Double) -> String {
        String(format: abs(value) >= 10 ? "%.0f W" : "%.1f W", value)
    }

    /// 2400 -> "2,400 rpm". A comma, not a space: "Fans 4 351 rpm" read as four fans.
    public static func rpm(_ value: Double) -> String {
        let s = String(max(0, Int(value.rounded())))
        guard s.count > 3 else { return "\(s) rpm" }
        return "\(s.dropLast(3)),\(s.suffix(3)) rpm"
    }

    /// 310 -> "5h 10m"
    public static func minutes(_ value: Int) -> String {
        value >= 60 ? "\(value / 60)h \(value % 60)m" : "\(value)m"
    }

    public static func uptime(since boot: Date, now: Date = Date()) -> String {
        let total = Int(now.timeIntervalSince(boot) / 60)
        let days = total / 1440, hours = (total % 1440) / 60, mins = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    public static func gigahertz(_ mhz: Double) -> String { String(format: "%.1f GHz", mhz / 1000) }
}
