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

/// Sparkle auto-updates, shown by Heron itself (`HeronUserDriver`). Sparkle refuses to run without
/// an EdDSA public key (SUPublicEDKey in Info.plist): builds made without the update feed and key
/// (`swift run`, `install.sh`) keep updates off and "Check for Updates" disabled. Releases carry
/// both (scripts/release.sh).
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private(set) var driver: HeronUserDriver?
    private weak var settings: AppSettings?
    /// A check's outcome: true when it found no newer version.
    var onResult: (Bool) -> Void = { _ in }
    /// A check ended (with or without an update, or an error).
    var onFinish: () -> Void = {}

    var isAvailable: Bool { updater != nil }

    func start(settings: AppSettings, services: AppServices) {
        self.settings = settings
        let info = Bundle.main.infoDictionary ?? [:]
        guard let key = info["SUPublicEDKey"] as? String, !key.isEmpty, let feed = info["SUFeedURL"] as? String, !feed.isEmpty else {
            NSLog("Heron: updates off (no SUPublicEDKey / SUFeedURL in Info.plist)")
            return
        }
        let driver = HeronUserDriver(services: services)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("Heron: updates off (Sparkle did not start: \(error.localizedDescription))")
            return
        }
        driver.check = { [weak updater] in updater?.checkForUpdates() }
        self.driver = driver
        self.updater = updater
        if Self.installsAtOnce {
            NSLog("Heron update test: checking \(feed)")
            updater.automaticallyDownloadsUpdates = true
            updater.checkForUpdatesInBackground()
        }
    }

    /// `HERON_UPDATE_TEST=1`: check at launch, download in the background and install at once, with
    /// no window or click. Proves the whole update chain end to end on a test copy (docs.md ›
    /// Updates); never set for a copy someone uses.
    static var installsAtOnce: Bool { ProcessInfo.processInfo.environment["HERON_UPDATE_TEST"] == "1" }
    /// `HERON_UPDATE_TEST=buttons`: the path a person takes, with Heron's own buttons pressed in
    /// code: Check Now, then Install Update in the window it opens, then Restart Heron Now.
    static var pressesButtons: Bool { ProcessInfo.processInfo.environment["HERON_UPDATE_TEST"] == "buttons" }
    /// `HERON_UPDATE_TEST=scheduled`: the daily check's path: a background check that should only
    /// mark the update as waiting (dot, strip, menu item) and open nothing. Logs the states.
    static var checksQuietly: Bool { ProcessInfo.processInfo.environment["HERON_UPDATE_TEST"] == "scheduled" }

    /// Drives `pressesButtons` or `checksQuietly`, logging every state it passes through.
    func pressButtons(_ services: AppServices) {
        if Self.checksQuietly {
            updater?.automaticallyDownloadsUpdates = false
            updater?.checkForUpdatesInBackground()
            pressed = ["install", "restart"]  // watch only
        } else {
            services.checkForUpdates()
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressNext(services) }
        }
    }

    private var lastLogged = ""
    private var pressed: Set<String> = []

    private func pressNext(_ services: AppServices) {
        let state = "\(services.update)"
        if state != lastLogged {
            let windows = NSApp.windows.filter(\.isVisible).map(\.title).filter { !$0.isEmpty }
            NSLog("Heron update test: \(state.prefix(60)) · waiting \(services.update.waiting?.version ?? "none") · windows \(windows)")
            lastLogged = state
        }
        switch services.update {
        case .available where !pressed.contains("install"): pressed.insert("install"); services.installUpdate()
        case .ready where !pressed.contains("restart"): pressed.insert("restart"); services.restartToUpdate()
        default: break
        }
    }

    /// A downloaded update waits for Heron to quit; Restart Heron Now runs this block early. With
    /// "Install updates automatically" it was found and downloaded without you, so nothing marks it.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        if Self.installsAtOnce {
            NSLog("Heron update test: installing \(item.displayVersionString) now")
            immediateInstallHandler()
            return true
        }
        guard let driver else { return false }
        driver.installNow = immediateInstallHandler
        if case .ready = driver.services.update {
        } else {
            driver.services.update = .ready(HeronUserDriver.offer(item, automatic: updater.automaticallyDownloadsUpdates))
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        NSLog("Heron update: aborted: \(error.localizedDescription) \((error as NSError).userInfo)")
    }

    func checkNow() { updater?.checkForUpdates() }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }

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
