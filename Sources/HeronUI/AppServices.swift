import Foundation
import Observation
import UserNotifications

/// Things the views can ask the app to do, and the state those services report back.
/// The app target fills in the closures (updater, login item); previews and the
/// snapshot tool use the harmless defaults.
@MainActor
@Observable
public final class AppServices {
    public var appVersion: String
    public var buildNumber: String
    public var launchAtLogin = false
    public var automaticallyChecksForUpdates = true
    public var automaticallyDownloadsUpdates = false
    public var lastUpdateCheck: Date?
    /// The last check of this session finished and found no newer version. Only then does
    /// Settings › Updates say Heron is up to date.
    public var lastCheckFoundNothing = false
    /// A check started from Settings › Updates is running.
    public var checkingForUpdates = false
    public var updaterAvailable = false
    public var publicIP: String?
    /// Whether macOS lets Heron show notifications (`UNUserNotificationCenter`'s authorization).
    public var notificationPermission: NotificationPermission = .allowed

    @ObservationIgnored public var setLaunchAtLogin: (Bool) -> Void = { _ in }
    @ObservationIgnored public var checkForUpdates: () -> Void = {}
    @ObservationIgnored public var setAutomaticChecks: (Bool) -> Void = { _ in }
    @ObservationIgnored public var setAutomaticDownloads: (Bool) -> Void = { _ in }
    @ObservationIgnored public var fetchPublicIP: () -> Void = {}
    @ObservationIgnored public var openSettings: (SettingsRoute) -> Void = { _ in }
    @ObservationIgnored public var openActivityMonitor: () -> Void = {}
    @ObservationIgnored public var showChangelog: () -> Void = {}
    @ObservationIgnored public var showAbout: () -> Void = {}
    @ObservationIgnored public var openURL: (URL) -> Void = { _ in }
    @ObservationIgnored public var quit: () -> Void = {}
    @ObservationIgnored public var resetSettings: () -> Void = {}
    @ObservationIgnored public var finishOnboarding: () -> Void = {}
    /// Reads the notification authorization again (Settings › Alerts on appear).
    @ObservationIgnored public var refreshNotificationPermission: () -> Void = {}
    /// Asks macOS for permission to notify (the system prompt; only while it has not been asked).
    @ObservationIgnored public var requestNotifications: () -> Void = {}

    public init(appVersion: String = "1.0.0", buildNumber: String = "1") {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    public static let website = URL(string: "https://github.com/botjaeger/heron")!
    /// System Settings › Notifications, and › Battery.
    public static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    public static let batterySettings = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    /// Disclaimer shown in About, in three lines.
    public static let legal =
        "Provided as is, without warranty. Heron only reads your Mac’s sensors — it never changes fan speeds or other hardware settings. Not made or endorsed by Apple."
}

/// Whether Heron may show notifications, as Settings › Alerts reports it.
public enum NotificationPermission: Equatable, Sendable {
    /// Allowed (also provisional: delivered quietly to Notification Centre).
    case allowed
    /// Turned off for Heron in System Settings.
    case denied
    /// macOS has not asked yet.
    case notAsked
    /// No app bundle (`swift run`): macOS cannot show Heron's notifications at all.
    case unavailable

    public init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional: self = .allowed
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        @unknown default: self = .denied
        }
    }

    /// What the button on the permission row does.
    public enum Action: Equatable, Sendable { case openSettings, ask }

    public var title: String {
        switch self {
        case .allowed: return "Notifications are allowed"
        case .denied: return "Notifications are off for Heron"
        case .notAsked: return "Heron has not asked to notify you yet"
        case .unavailable: return "Notifications need the installed app"
        }
    }

    public var hint: String {
        switch self {
        case .allowed: return "Banners and sounds follow your choices in System Settings."
        case .denied: return "Turn them on in System Settings › Notifications to get these alerts."
        case .notAsked: return "macOS asks once; until then the rules below send nothing."
        case .unavailable: return "This copy of Heron runs without its app bundle, so macOS shows nothing."
        }
    }

    public var action: Action? {
        switch self {
        case .allowed, .denied: return .openSettings
        case .notAsked: return .ask
        case .unavailable: return nil
        }
    }

    public var actionTitle: String? {
        switch action {
        case .openSettings?: return "Open System Settings…"
        case .ask?: return "Allow Notifications…"
        case nil: return nil
        }
    }

    /// The rules can reach the user.
    public var delivers: Bool { self == .allowed }
}
