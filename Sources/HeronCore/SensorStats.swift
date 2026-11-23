import Foundation

/// One temperature per component, used by the menu bar, the popovers and alerts.
///
/// A component's temperature is the AVERAGE of its identified sensors, not the hottest one.
/// An M3 Max reports 58 CPU hotspots; under ordinary load single hotspots touch 99 °C while the
/// average sits near 85 °C. Showing the maximum painted the menu bar red and fired the default
/// "CPU above 95° for 30 s" alert on a Mac that was working normally. The hottest single sensor
/// is still available as "Hottest" (`Snapshot.hottest`).
public enum SensorStats {
    public struct Item: Sendable, Equatable {
        public var group: Sensor.Group
        public var celsius: Double
    }

    /// Display order of the groups.
    public static let order: [Sensor.Group] = [.cpu, .cpuPerformance, .cpuEfficiency, .gpu, .ssd, .memory, .battery, .wireless, .surface, .other]
    public static let cpuGroups: Set<Sensor.Group> = [.cpu, .cpuPerformance, .cpuEfficiency]

    /// The average temperature of `sensors` in `groups`, nil when none reports.
    public static func average(_ sensors: [Sensor], in groups: Set<Sensor.Group>) -> Double? {
        let values = sensors.filter { groups.contains($0.group) }.map(\.celsius)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// One averaged reading per group that has sensors, in `order`.
    public static func groups(_ sensors: [Sensor]) -> [Item] {
        order.compactMap { g in average(sensors, in: [g]).map { Item(group: g, celsius: $0) } }
    }
}
