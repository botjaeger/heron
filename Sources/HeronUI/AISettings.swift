import Foundation
import HeronCore

/// Every AI usage setting, stored together under "aiUsage". Defaults follow OpenUsage.
public struct AIUsageSettings: Codable, Equatable, Sendable {
    public enum Display: String, Codable, CaseIterable, Sendable { case left, used }
    public enum ResetFormat: String, Codable, CaseIterable, Sendable { case countdown, clock }
    public enum ProvidersAs: String, Codable, CaseIterable, Sendable { case logo, name }
    public enum MenuMode: String, Codable, CaseIterable, Sendable { case mostUrgent, chosen }
    public enum CardShows: String, Codable, CaseIterable, Sendable { case mostUrgent, pinned, chosen }
    public enum Alert: String, Codable, CaseIterable, Sendable { case warning, critical, burningFast, useItOrLoseIt }

    // Display (Settings › AI Usage)
    public var display: Display = .left
    public var resetFormat: ResetFormat = .countdown
    public var paceMarks = false
    public var providersAs: ProvidersAs = .logo
    public var thresholds: AIThresholds = .standard
    /// Sends a notification (off by default; the first one asks macOS).
    public var notify: Set<Alert> = []
    public var privacyMode = false
    /// The global shortcut that opens the AI usage panel ("⌥⌘U"), or nil.
    public var shortcut: String?

    // Menu bar item (Settings › Menu Bar › AI usage)
    public var menuMode: MenuMode = .mostUrgent
    /// How many limits "most urgent" shows: 0 = the Heron icon only, up to 5.
    public var menuCount = 3
    public var alwaysShow = false
    /// The limits "chosen" shows, in order (`AILimitLine.id`: "accountID/metricKey").
    public var menuChosen: [String] = []
    public var showLimitName = true

    // Overview card (Settings › Overview › AI usage)
    public var cardShows: CardShows = .mostUrgent
    public var cardRows = 3
    public var cardPill = true
    public var cardChosen: [String] = []

    public init() {}

    public var boardOptions: AIPriorityBoard.Options {
        AIPriorityBoard.Options(thresholds: thresholds, burningFast: true, useItOrLoseIt: true)
    }

    // Older stored values may lack newer keys: decode each with its default. Keys no longer
    // read ("priority", "panelOpensOn") are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AIUsageSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        display = v(.display, d.display); resetFormat = v(.resetFormat, d.resetFormat); paceMarks = v(.paceMarks, d.paceMarks)
        providersAs = v(.providersAs, d.providersAs)
        thresholds = v(.thresholds, d.thresholds); notify = v(.notify, d.notify)
        privacyMode = v(.privacyMode, d.privacyMode); shortcut = v(.shortcut, d.shortcut)
        menuMode = v(.menuMode, d.menuMode); menuCount = min(5, max(0, v(.menuCount, d.menuCount))); alwaysShow = v(.alwaysShow, d.alwaysShow)
        menuChosen = v(.menuChosen, d.menuChosen); showLimitName = v(.showLimitName, d.showLimitName)
        cardShows = v(.cardShows, d.cardShows); cardRows = min(5, max(1, v(.cardRows, d.cardRows))); cardPill = v(.cardPill, d.cardPill)
        cardChosen = v(.cardChosen, d.cardChosen)
    }
}
