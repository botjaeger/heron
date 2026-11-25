import AppKit
import Foundation
import HeronCore
import HeronUI
import Sparkle
import UserNotifications

/// Turns fired alert rules and AI usage states into macOS notifications.
@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private var engine = AlertEngine()
    private var aiEngine = AIAlertEngine()
    /// Notifications need a real app bundle; under `swift run` there is none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    /// A clicked AI usage notification: open its panel.
    var onOpenAI: () -> Void = {}
    nonisolated static let aiKey = "heron.ai"

    override init() {
        super.init()
        if canNotify { UNUserNotificationCenter.current().delegate = self }
    }

    /// After every AI refresh: a notification for each limit that just entered a state the user
    /// asked to hear about (Settings › AI Usage › Alerts › Notify).
    func evaluateAI(_ lines: [AILimitLine], settings: AIUsageSettings) {
        let enabled = Set(settings.notify.compactMap { AIAlertKind(rawValue: $0.rawValue) })
        for alert in aiEngine.evaluate(lines, thresholds: settings.thresholds, enabled: enabled, hideLabels: settings.privacyMode) {
            // Kind and line id only: the title and body carry the account's label, often an email.
            NSLog("Heron AI alert: \(alert.kind.rawValue) \(alert.lineID)")
            guard canNotify else { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.userInfo = [Self.aiKey: alert.lineID]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ai/\(alert.lineID)/\(alert.kind.rawValue)", content: content, trigger: nil))
        }
    }

    /// While Heron is the active app (Settings or the popover in front), macOS drops a notification
    /// unless its delegate asks for it to be shown: an alert fired then was never seen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let isAI = response.notification.request.content.userInfo[Self.aiKey] != nil
        DispatchQueue.main.async { [weak self] in
            if isAI { self?.onOpenAI() }
            completionHandler()
        }
    }

    /// Asks macOS once (it shows its prompt only while the user has not answered), then reports
    /// the permission as it now stands.
    func requestPermission(_ done: @escaping @MainActor (NotificationPermission) -> Void) {
        guard canNotify else { done(.unavailable); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.permission(done) }
        }
    }

    /// The permission as System Settings › Notifications has it now.
    func permission(_ done: @escaping @MainActor (NotificationPermission) -> Void) {
        guard canNotify else { done(.unavailable); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let permission = NotificationPermission(settings.authorizationStatus)
            DispatchQueue.main.async { done(permission) }
        }
    }

    func evaluate(rules: [AlertRule], snapshot: Snapshot, cooldown: Bool, unit: Format.TemperatureUnit) {
        engine.cooldown = cooldown ? 600 : 0
        for alert in engine.evaluate(rules, snapshot: snapshot, now: Date(), unit: unit) {
            NSLog("Heron alert: \(alert.title) — \(alert.body)")
            guard canNotify else { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            if alert.rule.playSound { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.rule.id.uuidString, content: content, trigger: nil))
        }
    }
}

/// Sparkle auto-updates. Sparkle refuses to run without an EdDSA public key (SUPublicEDKey in
/// Info.plist), so until one is configured the updater stays off and "Check for Updates" is disabled.
final class Updater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private weak var settings: AppSettings?
    /// A check's outcome: true when it found no newer version.
    var onResult: (Bool) -> Void = { _ in }
    /// A check ended (with or without an update, or an error).
    var onFinish: () -> Void = {}

    var isAvailable: Bool { controller != nil }

    func start(settings: AppSettings) {
        self.settings = settings
        let info = Bundle.main.infoDictionary ?? [:]
        guard let key = info["SUPublicEDKey"] as? String, !key.isEmpty, info["SUFeedURL"] != nil else {
            NSLog("Heron: updates off (no SUPublicEDKey / SUFeedURL in Info.plist)")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func checkNow() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// Beta channel: the appcast marks beta builds with <sparkle:channel>beta</sparkle:channel>.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        settings?.betaUpdates == true ? ["beta"] : []
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { onResult(true) }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { onResult(false) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) { onFinish() }
}

/// Looks up the public IP address, only when the user asks for it.
enum PublicIP {
    static func fetch(_ done: @escaping @MainActor (String?) -> Void) {
        let url = URL(string: "https://api.ipify.org")!
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let ip = ok ? data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            DispatchQueue.main.async { done(ip) }
        }.resume()
    }
}
