import HeronCore
import SwiftUI

/// When a value turns red. One home, so the menu bar, the overview, the panels and Settings agree:
/// a reading red in one place is red in every other (a guard test keeps the thresholds out of
/// every other file).
enum Warnings {
    /// Too hot, in °C (shown in the user's unit).
    static let hotCelsius = 90.0
    /// Under this much free space the startup disk is nearly full (the default "almost full" alert).
    static let nearlyFullBytes: UInt64 = 10_000_000_000

    static func isHot(_ celsius: Double) -> Bool { celsius >= hotCelsius }

    /// Over 95% used, or under 10 GB free, whichever comes first.
    static func isNearlyFull(_ volume: VolumeReading) -> Bool {
        volume.usedFraction > 0.95 || volume.available < nearlyFullBytes
    }

    /// Below 20% and running on the battery (macOS's own low-battery level).
    static func isLow(_ battery: BatteryReading) -> Bool { battery.present && !battery.onAC && battery.percent < 0.2 }

    /// A temperature's text colour: red when hot.
    static func color(celsius: Double) -> Color { isHot(celsius) ? Theme.warning : .primary }

    /// A volume's meter colour: the text colour, red when nearly full.
    static func color(volume: VolumeReading) -> Color { isNearlyFull(volume) ? Theme.warning : .primary }

    /// The full scale of a temperature's mini bar in the Sensors panel (a scale, not a warning).
    static let barScaleCelsius = 110.0
}
