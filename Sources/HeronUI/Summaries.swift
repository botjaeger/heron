import HeronCore
import SwiftUI

extension PopoverKind {
    /// The overview section this page is the panel of (nil for the overview itself).
    public var part: OverviewPart? { OverviewPart(rawValue: rawValue) }
    public init(_ part: OverviewPart) { self = PopoverKind(rawValue: part.rawValue) ?? .overview }
}

/// Memory pressure's colour: green, amber at Warning, red at Critical.
func pressureColor(_ p: MemoryReading.Pressure?) -> Color {
    switch p {
    case .critical: return Theme.warning
    case .warning: return Theme.caution
    default: return Theme.memory
    }
}

/// The fans as one number, the same in the menu bar, the overview and VoiceOver: the average of
/// every fan (a Mac with two fans shows neither the left nor the right one alone).
public enum FanSummary {
    /// Average speed in rpm; nil without fans.
    public static func rpm(_ fans: [Fan]) -> Double? {
        fans.isEmpty ? nil : fans.map(\.rpm).reduce(0, +) / Double(fans.count)
    }

    /// Average share of each fan's maximum (0...1); nil when no fan reports a maximum.
    public static func fraction(_ fans: [Fan]) -> Double? {
        let rated = fans.filter { $0.maxRPM > 0 }
        return rated.isEmpty ? nil : rated.map { $0.rpm / $0.maxRPM }.reduce(0, +) / Double(rated.count)
    }

    /// Each fan's speed without the unit, for the overview card: "2,567 · 2,779".
    public static func speeds(_ fans: [Fan]) -> String {
        fans.map { NumberParts.split(Format.rpm($0.rpm)).number }.joined(separator: " · ")
    }
}

/// One temperature per component group (the average, see `SensorStats`), in a fixed order.
public enum SensorSummary {
    public static func groups(_ sensors: [Sensor]) -> [SensorStats.Item] { SensorStats.groups(sensors) }

    /// The Sensors panel's order: hottest first (ties keep the fixed group order).
    public static func hottestFirst(_ items: [SensorStats.Item]) -> [SensorStats.Item] {
        items.enumerated().sorted { $0.element.celsius != $1.element.celsius ? $0.element.celsius > $1.element.celsius : $0.offset < $1.offset }.map(\.element)
    }

    /// The Sensors panel's highlight: "CPU 25 · performance core" (the core kind when the sensor
    /// sits on one), else the sensor's name.
    public static func hottestLabel(_ sensor: Sensor) -> String {
        switch sensor.group {
        case .cpuPerformance: return "\(sensor.name) · performance core"
        case .cpuEfficiency: return "\(sensor.name) · efficiency core"
        default: return sensor.name
        }
    }

    /// The battery's temperature, the same number in the card, the panel and its history.
    public static func batteryCelsius(in s: Snapshot) -> Double? { s.batteryCelsius }

    /// The temperature the menu bar shows for a setting. Same numbers as the alert subjects.
    public static func value(_ choice: AppSettings.SensorChoice, in s: Snapshot) -> Double? {
        switch choice {
        case .hottest: return AlertRule.Subject.hottestTemperature.value(in: s)
        case .cpu: return AlertRule.Subject.cpuTemperature.value(in: s)
        case .gpu: return AlertRule.Subject.gpuTemperature.value(in: s)
        case .ssd: return AlertRule.Subject.ssdTemperature.value(in: s)
        }
    }

    /// A temperature of the Sensors card: Hottest, CPU, GPU and SSD as the menu bar shows them,
    /// the battery as its card and panel do, the others the average of their named sensors.
    public static func cardValue(_ item: SensorCardItem, in s: Snapshot) -> Double? {
        let known = s.sensors.filter(\.isKnown)
        switch item {
        case .hottest: return value(.hottest, in: s)
        case .cpu: return value(.cpu, in: s)
        case .gpu: return value(.gpu, in: s)
        case .ssd: return value(.ssd, in: s)
        case .battery: return batteryCelsius(in: s)
        case .wireless: return SensorStats.average(known, in: [.wireless])
        case .enclosure: return SensorStats.average(known, in: [.surface])
        }
    }

    /// The Sensors card's temperatures: the picked ones this Mac has a reading for, in order.
    /// "Hottest" reads "Hottest · CPU 6" when the hottest sensor is named. When none of the picked
    /// ones has a reading but a named sensor does, the card shows Hottest (it keeps one).
    public static func cardTemperatures(_ items: [SensorCardItem], nameHottest: Bool, in s: Snapshot) -> [(item: SensorCardItem, label: String, celsius: Double)] {
        func entry(_ item: SensorCardItem) -> (item: SensorCardItem, label: String, celsius: Double)? {
            guard let celsius = cardValue(item, in: s) else { return nil }
            if item == .hottest, nameHottest, let name = hottestName(in: s) { return (item, "Hottest · \(name)", celsius) }
            return (item, item.title, celsius)
        }
        let picked = items.prefix(SensorCardItem.limit).compactMap(entry)
        return picked.isEmpty ? [entry(.hottest)].compactMap { $0 } : picked
    }

    /// The hottest named sensor's name ("CPU 6"): the sensor behind `value(.hottest)`, named in the
    /// menu bar item's tooltip and on the Sensors card.
    public static func hottestName(in s: Snapshot) -> String? { s.hottest?.name }

    /// The temperatures this Mac can put on the Sensors card: groups it has a named sensor for
    /// (also one that skipped this read), a battery with a temperature, and Hottest.
    public static func cardItems(in s: Snapshot) -> [SensorCardItem] {
        let groups = Set(s.sensors.filter(\.isKnown).map(\.group))
        // A named sensor is called after its group ("CPU P-core 3", "Enclosure 2"): the group's
        // name, a space, then more.
        func has(_ group: Sensor.Group) -> Bool {
            groups.contains(group) || s.sensorNames.contains { $0.hasPrefix(group.rawValue + " ") }
        }
        return SensorCardItem.allCases.filter { item in
            switch item {
            case .hottest: return s.hottest != nil || !s.sensorNames.isEmpty
            case .cpu: return has(.cpu) || groups.contains(.cpuPerformance) || groups.contains(.cpuEfficiency)
            case .gpu: return has(.gpu)
            case .ssd: return has(.ssd)
            case .battery: return batteryCelsius(in: s) != nil
            case .wireless: return has(.wireless)
            case .enclosure: return has(.surface)
            }
        }
    }
}
