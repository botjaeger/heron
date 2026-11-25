import AppKit
import HeronCore
import HeronUI
import ServiceManagement
import SwiftUI

/// Wires everything together: samplers, the menu bar item, windows, alerts, updates.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let settings = AppSettings()
    let services: AppServices
    /// AI plan usage (Settings › AI Usage); refreshed every 5 minutes.
    let ai = AIUsageService()
    lazy var statusBar = StatusBarController(monitor: monitor, settings: settings, services: services, ai: ai)
    lazy var windows = WindowManager(monitor: monitor, settings: settings, services: services, ai: ai)
    let alerts = AlertCenter()
    let updater = Updater()
    let hotKey = GlobalHotKey()
    /// Reloads into a newer copy when `packaging/install.sh` replaces the installed app.
    let bundleWatcher = BundleWatcher()

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        services = AppServices(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "1.0.0",
            buildNumber: info["CFBundleVersion"] as? String ?? "1")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        connectServices()
        bundleWatcher.start()
        applySettings()
        monitor.onSample = { [weak self] snapshot in self?.didSample(snapshot) }
        monitor.start()
        statusBar.rebuild()
        ai.onUpdate = { [weak self] in self?.didRefreshAI() }
        ai.start()
        hotKey.action = { [weak self] in self?.statusBar.showAIPanel(toggle: true) }
        alerts.onOpenAI = { [weak self] in self?.statusBar.showAIPanel(toggle: false) }
        applySettings()
        // The first run asks on its alerts step ("Allow Notifications…"); until then only read it.
        if settings.onboardingDone {
            alerts.requestPermission { [weak self] permission in self?.services.notificationPermission = permission }
        } else {
            alerts.permission { [weak self] permission in self?.services.notificationPermission = permission }
        }
        updater.start(settings: settings)
        syncUpdaterState()

        if !settings.onboardingDone {
            windows.showOnboarding()
        } else if settings.lastSeenVersion != services.appVersion {
            // First launch after an update: show what changed.
            if !settings.lastSeenVersion.isEmpty { windows.showChangelog() }
        }
        settings.lastSeenVersion = services.appVersion
        runSmokeTestIfRequested()
    }

    /// `HERON_SMOKE_SECONDS=8 swift run Heron` opens every window, logs what is on screen,
    /// then quits. Used to check a build end to end without clicking.
    private func runSmokeTestIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["HERON_SMOKE_SECONDS"], let seconds = Double(value) else { return }
        // Settings opens on AI Usage with the Add account sheet: its sheet must attach with content
        // (an empty one once locked the window). It opens with Privacy Mode on, so the sheet begins
        // on a private window and must follow it (the next sample puts the user's setting back).
        windows.privacy = true
        windows.showSettings(.aiUsageAdd)
        smokeCheckSheetFollowsSettings(tries: 100)
        windows.showChangelog()
        windows.showAbout()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds / 2) { [self] in statusBar.debugOpenFirstPopover() }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 3 / 4) { [self] in statusBar.debugOpenPanel(.memory) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            print("SMOKE status items:", statusBar.debugDescription)
            print("SMOKE popover:", statusBar.debugPopoverState)
            print("SMOKE panel:", statusBar.debugPanelState)
            for window in NSApp.windows where window.isVisible {
                print("SMOKE window:", window.title.isEmpty ? "(popover/status)" : window.title, Int(window.frame.width), "x", Int(window.frame.height))
                if let sheet = window.attachedSheet, sheet.frame.height < 20 { print("SMOKE FAIL: empty sheet on", window.title) }
                if window.styleMask.contains(.resizable), window.title == "Heron Settings" { print("SMOKE FAIL: Settings resizes (its columns are fixed)") }
                if let sheet = window.attachedSheet {
                    print(
                        "SMOKE sheet on", window.title + ":", Int(sheet.frame.width), "x", Int(sheet.frame.height), "content",
                        sheet.contentView.map { "\(Int($0.fittingSize.width)) x \(Int($0.fittingSize.height))" } ?? "none")
                }
            }
            // Privacy Mode keeps every open window out of recordings, Settings and its sheet
            // included; the next sample puts the user's own setting back (`applySettings`). The
            // status item's windows ignore `sharingType` (`StatusBarController.applyPrivacy`).
            windows.privacy = true
            statusBar.privacy = true
            var covered = 0
            for window in NSApp.windows where window.isVisible && !window.className.contains("StatusBarWindow") {
                if window.sharingType == .none {
                    covered += 1
                } else {
                    print("SMOKE FAIL: Privacy Mode leaves a window shareable:", window.title.isEmpty ? "(popover)" : window.title, window.className)
                }
            }
            print("SMOKE privacy:", covered, "windows hidden from recordings with Privacy Mode on")
            windows.privacy = settings.aiUsage.privacyMode
            statusBar.privacy = settings.aiUsage.privacyMode
            let s = monitor.snapshot
            if s.awaitingReadings { print("SMOKE FAIL: still waiting for the first readings after \(seconds) s") }
            print(
                "SMOKE snapshot cpu:", s.cpu.map { Format.percent($0.total) } ?? "nil", "mem:", s.memory.map { Format.percent($0.usedFraction) } ?? "nil",
                "sensors:", s.sensors.count, "fans:", s.fans.count, "power:", s.power?.package.map(Format.watts) ?? "nil",
                "history cpu samples:", monitor.history[.cpu].count, "updater:", updater.isAvailable)
            // Then the popover's clicks and keys, with posted events.
            statusBar.debugInteract(outside: NSApp.windows.first { $0.title == "About Heron" }) { exit(0) }
        }
    }

    /// Smoke: once the Add account sheet is on Settings, it has Settings' sharing type.
    private func smokeCheckSheetFollowsSettings(tries: Int) {
        let parent = NSApp.windows.first { $0.title == "Heron Settings" }
        guard let parent, let sheet = parent.attachedSheet else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [self] in smokeCheckSheetFollowsSettings(tries: tries - 1) }
            } else {
                print("SMOKE FAIL: no sheet on Settings to check Privacy Mode on")
            }
            return
        }
        // The sheet takes its parent's setting right after it attaches.
        DispatchQueue.main.async {
            if parent.sharingType != .none {
                print("SMOKE privacy sheet: not exercised, a sample put the setting back first")
            } else if sheet.sharingType != .none {
                print("SMOKE FAIL: the Add account sheet shows in recordings while Settings is hidden")
            } else {
                print("SMOKE privacy sheet: the Add account sheet follows Settings")
            }
        }
    }

    /// Runs on the main thread after every sample.
    private func didSample(_ snapshot: Snapshot) {
        applySettings()
        statusBar.update()
        alerts.evaluate(rules: settings.alertRules, snapshot: snapshot, cooldown: settings.alertCooldown, unit: settings.temperatureUnit)
    }

    /// Runs on the main thread after every AI refresh pass.
    private func didRefreshAI() {
        statusBar.update()
        alerts.evaluateAI(ai.lines, settings: settings.aiUsage)
    }

    /// Pushes settings into the parts that do not read them directly. Cheap; runs every sample.
    private func applySettings() {
        if monitor.interval != settings.interval { monitor.interval = settings.interval }
        if monitor.slowOnLowBattery != settings.slowOnLowBattery { monitor.slowOnLowBattery = settings.slowOnLowBattery }
        if monitor.includeUnnamedSensors != !settings.hideUnknownSensors { monitor.includeUnnamedSensors = !settings.hideUnknownSensors }
        if monitor.hideDiskImages != settings.hideDiskImages { monitor.hideDiskImages = settings.hideDiskImages }
        let appearance: NSAppearance? =
            switch settings.appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        // Compared by name: this runs every sample and setting it redraws every window, and AppKit
        // does not promise one instance per named appearance.
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
        statusBar.privacy = settings.aiUsage.privacyMode
        windows.privacy = settings.aiUsage.privacyMode
        hotKey.set(settings.aiUsage.shortcut)
    }

    private func syncUpdaterState() {
        services.updaterAvailable = updater.isAvailable
        services.automaticallyChecksForUpdates = updater.automaticallyChecks
        services.automaticallyDownloadsUpdates = updater.automaticallyDownloads
        services.lastUpdateCheck = updater.lastCheck
    }

    private func connectServices() {
        services.launchAtLogin = SMAppService.mainApp.status == .enabled
        services.setLaunchAtLogin = { [weak self] on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Heron: launch at login failed: \(error.localizedDescription)")
            }
            self?.services.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        services.checkForUpdates = { [weak self] in
            guard let self else { return }
            // Until this check reports, Settings › Updates says when Heron last looked, not "up to date".
            services.lastCheckFoundNothing = false
            services.checkingForUpdates = updater.isAvailable
            updater.checkNow()
            syncUpdaterState()
        }
        updater.onResult = { [weak self] nothingNew in self?.services.lastCheckFoundNothing = nothingNew }
        updater.onFinish = { [weak self] in
            self?.services.checkingForUpdates = false
            self?.syncUpdaterState()
        }
        services.refreshNotificationPermission = { [weak self] in
            self?.alerts.permission { self?.services.notificationPermission = $0 }
        }
        services.requestNotifications = { [weak self] in
            self?.alerts.requestPermission { self?.services.notificationPermission = $0 }
        }
        services.setAutomaticChecks = { [weak self] on in
            self?.updater.automaticallyChecks = on; self?.syncUpdaterState()
        }
        services.setAutomaticDownloads = { [weak self] on in
            self?.updater.automaticallyDownloads = on; self?.syncUpdaterState()
        }
        services.fetchPublicIP = { [weak self] in
            PublicIP.fetch { ip in self?.services.publicIP = ip ?? "Unavailable" }
        }
        services.openSettings = { [weak self] route in
            self?.statusBar.closePopovers(); self?.windows.showSettings(route)
        }
        services.openActivityMonitor = { [weak self] in
            self?.statusBar.closePopovers()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"), configuration: .init())
        }
        services.showChangelog = { [weak self] in self?.windows.showChangelog() }
        services.showAbout = { [weak self] in self?.windows.showAbout() }
        services.openURL = { NSWorkspace.shared.open($0) }
        services.quit = { NSApp.terminate(nil) }
        services.resetSettings = { [weak self] in
            guard let self else { return }
            settings.reset()
            statusBar.rebuild()
        }
        services.finishOnboarding = { [weak self] in
            self?.settings.onboardingDone = true
            self?.windows.closeOnboarding()
            self?.statusBar.rebuild()
        }
    }

}
