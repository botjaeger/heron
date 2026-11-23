import Foundation
import Testing
import UserNotifications

@testable import HeronCore
@testable import HeronUI

/// Settings › Overview, Alerts and Updates: the pure rules behind what the panes show.
@Suite struct SettingsPanesTests {
    /// The position line follows the order and the eye; a hidden section, and Battery on a Mac
    /// without one, say why the popover leaves them out.
    @Test func reorderingAndHidingMoveTheSectionsPosition() {
        let s = AppSettings(defaults: scratchDefaults("overview-position"))
        var snapshot = Snapshot()
        snapshot.battery = BatteryReading(present: true, percent: 0.5, isCharging: false, onAC: false)
        func line(_ part: OverviewPart) -> String {
            OverviewPane.position(of: part, order: s.overviewOrder, hidden: s.hiddenSections, snapshot: snapshot)
        }
        #expect(line(.cpu) == "1st of 7 in the popover")
        s.setOverviewOrder(OverviewArrange.step(s.overviewOrder, .cpu, by: 1))  // ⌥⌘↓
        #expect(line(.cpu) == "2nd of 7 in the popover")
        #expect(line(.gpu) == "1st of 7 in the popover")
        s.setOverviewOrder(OverviewArrange.move(s.overviewOrder, .battery, onto: .gpu))  // dragged to the top
        #expect(line(.battery) == "1st of 7 in the popover" && line(.cpu) == "3rd of 7 in the popover")
        s.setHidden(.gpu, true)
        #expect(line(.gpu) == "Hidden. The menu bar and alerts still read it.")
        #expect(line(.cpu) == "2nd of 6 in the popover")
        #expect(line(.disk) == "5th of 6 in the popover")
        #expect(OverviewPane.hint(.gpu, settings: s) == "Hidden")
        #expect(OverviewPane.hint(.cpu, settings: s) == "Bars")
        #expect(OverviewPane.hint(.sensors, settings: s) == "3 temperatures")
        snapshot.battery = nil
        #expect(line(.battery) == "This Mac has no battery, so the popover leaves it out.")
        #expect(line(.cpu) == "1st of 5 in the popover")
    }

    /// Restore defaults puts back every setting the Overview pane holds, and only those.
    @Test func restoreDefaultsResetsTheOverviewPaneOnly() {
        let d = scratchDefaults("overview-restore")
        let s = AppSettings(defaults: d)
        let fresh = AppSettings(defaults: scratchDefaults("overview-restore-fresh"))
        s.setOverviewOrder([.battery, .sensors, .disk, .network, .memory, .gpu, .cpu])
        s.setHidden(.gpu, true)
        s.setCardStyle(.cpu, .ring)
        s.showCores = false; s.showCPUProcesses = false; s.showMemoryProcesses = false; s.networkInBits = true; s.showPublicIP = true
        s.hideDiskImages = false; s.sensorCard = [.ssd]; s.sensorCardFans = false; s.nameHottest = true; s.hideUnknownSensors = false
        s.interval = 5; s.alertCooldown = false; s.setShown(.cpu, true)
        s.restoreOverviewDefaults()
        #expect(s.overviewOrder == fresh.overviewOrder && s.hiddenSections == fresh.hiddenSections && s.cardStyles == fresh.cardStyles)
        #expect(
            s.showCores == fresh.showCores && s.showCPUProcesses == fresh.showCPUProcesses && s.showMemoryProcesses == fresh.showMemoryProcesses
                && s.networkInBits == fresh.networkInBits)
        #expect(s.showPublicIP == fresh.showPublicIP && s.hideDiskImages == fresh.hideDiskImages && s.sensorCard == fresh.sensorCard)
        #expect(s.sensorCardFans == fresh.sensorCardFans && s.nameHottest == fresh.nameHottest && s.hideUnknownSensors == fresh.hideUnknownSensors)
        // Other panes' settings stay, and the restore is saved.
        #expect(s.interval == 5 && !s.alertCooldown && s.isShown(.cpu))
        #expect(AppSettings(defaults: d).overviewOrder == OverviewPart.allCases)
    }

    /// Card | Panel is one choice for every section: picking another section keeps it.
    @Test func thePreviewChoiceStaysAcrossSections() {
        var editor = OverviewEditorState(selected: .cpu)
        #expect(!editor.showsPanel)
        editor.showsPanel = true
        editor.select(.sensors)
        #expect(editor.selected == .sensors && editor.showsPanel)
        editor.showsPanel = false
        editor.select(.battery)
        #expect(editor.selected == .battery && !editor.showsPanel)
    }

    /// A rule read into the editor's sentence and saved back is the same rule, in °C and °F;
    /// memory pressure reads as a level.
    @Test func aRuleSurvivesTheSentenceRoundTrip() {
        let rules =
            AlertRule.defaults + [
                AlertRule(subject: .cpuLoad, comparison: .above, threshold: 85, seconds: 300, playSound: true),
                AlertRule(subject: .memoryPressure, comparison: .above, threshold: 0.5, seconds: 60),
            ]
        for unit in [Format.TemperatureUnit.celsius, .fahrenheit] {
            for rule in rules {
                let back = AlertSentence(rule, unit: unit).rule(from: rule, unit: unit)
                #expect(back.subject == rule.subject && back.comparison == rule.comparison && back.seconds == rule.seconds, "\(rule.summary()) \(unit)")
                #expect(abs(back.threshold - rule.threshold) < 1e-9, "\(rule.summary()) \(unit): \(back.threshold)")
                #expect(back.id == rule.id && back.enabled == rule.enabled && back.playSound == rule.playSound)
            }
        }
        let hot = AlertSentence(AlertRule.defaults[0], unit: .fahrenheit)
        #expect(hot.limit == 203)
        #expect(hot.text(unit: .fahrenheit) == "Notify me when CPU temperature is above 203 °F for 30 s")
        let pressure = AlertSentence(AlertRule.defaults[1], unit: .celsius)
        #expect(pressure.level == .critical)
        #expect(pressure.text(unit: .celsius) == "Notify me when Memory pressure reaches Critical for 10 s")
        var warning = pressure
        warning.level = .warning
        #expect(warning.rule(from: AlertRule.defaults[1], unit: .celsius).threshold == 0.5)
        // Picking another reading starts from its own limit, not the old number.
        var sentence = hot
        sentence.choose(.diskFreeGB, unit: .fahrenheit)
        #expect(sentence.comparison == .below && sentence.limit == 10 && sentence.seconds == 30)
        #expect(sentence.text(unit: .fahrenheit) == "Notify me when Free space on the startup disk is below 10 GB for 30 s")
        #expect(
            AlertSentence(AlertRule(subject: .batteryPercent, comparison: .below, threshold: 10, seconds: 0), unit: .celsius).text(unit: .celsius)
                == "Notify me when Battery charge is below 10%")
    }

    /// "Would send" only when the reading is past the limit; the wait is named.
    @Test func theRightNowLineSaysWhetherTheRuleWouldSend() {
        var s = Snapshot()
        s.battery = BatteryReading(present: true, percent: 0.79, isCharging: false, onAC: true)
        let low = AlertRule(subject: .batteryPercent, comparison: .below, threshold: 10, seconds: 0)
        #expect(AlertPreview.reading(.batteryPercent, in: s, unit: .celsius) == "79% · on power adapter")
        #expect(AlertPreview.nowLine(low, value: 79, unit: .celsius, snapshot: s) == "Battery charge 79% · on power adapter, above 10%. Would not send.")
        #expect(AlertPreview.nowLine(low, value: 5, unit: .celsius, snapshot: s).hasSuffix("Would send now."))
        let hot = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 95, seconds: 30)
        #expect(AlertPreview.nowLine(hot, value: 97, unit: .celsius, snapshot: Snapshot()) == "CPU temperature 97°, above 95°. Would send if it stays there for 30 s.")
        #expect(AlertPreview.nowLine(hot, value: nil, unit: .celsius, snapshot: Snapshot()) == "This Mac gives no reading for CPU temperature, so the rule never sends.")
    }

    /// Installing needs checking: turning checks off turns installing off; turning them on leaves it.
    @Test func turningChecksOffTurnsInstallingOff() {
        #expect(UpdatesPane.switches(settingChecks: false, installs: true) == (false, false))
        #expect(UpdatesPane.switches(settingChecks: true, installs: true) == (true, true))
        #expect(UpdatesPane.switches(settingChecks: true, installs: false) == (true, false))
        #expect(UpdatesPane.flowHint(checks: false, installs: false).hasPrefix("Heron will not look for updates"))
        #expect(UpdatesPane.flowHint(checks: true, installs: true).contains("installs it the next time you quit"))
        #expect(UpdatesPane.flowHint(checks: true, installs: false).contains("asks before installing"))
    }

    /// "Up to date" only after a check that found nothing; otherwise when Heron last looked.
    @Test func theStatusLineClaimsUpToDateOnlyWhenACheckFoundNothing() {
        let now = Date()
        #expect(UpdatesPane.status(checking: true, lastCheck: now, foundNothing: true, now: now) == "Checking for updates…")
        #expect(UpdatesPane.status(checking: false, lastCheck: nil, foundNothing: false, now: now) == "Not checked yet")
        #expect(UpdatesPane.status(checking: false, lastCheck: now.addingTimeInterval(-5), foundNothing: true, now: now) == "Heron is up to date · checked just now")
        #expect(UpdatesPane.status(checking: false, lastCheck: now.addingTimeInterval(-5), foundNothing: false, now: now) == "Last checked just now")
        let morning = Calendar.current.startOfDay(for: now).addingTimeInterval(8 * 3600 + 45 * 60)
        let later = morning.addingTimeInterval(3600)
        #expect(
            UpdatesPane.status(checking: false, lastCheck: morning, foundNothing: true, now: later)
                == "Heron is up to date · checked today at \(morning.formatted(date: .omitted, time: .shortened))")
        #expect(UpdatesPane.status(checking: false, lastCheck: morning.addingTimeInterval(-86_400), foundNothing: false, now: later).hasPrefix("Last checked yesterday at "))
    }

    /// The permission row follows macOS's authorization: allowed and denied open System Settings,
    /// not asked yet asks, and a copy without its app bundle offers nothing it cannot do.
    @Test func thePermissionRowFollowsTheAuthorization() {
        #expect(NotificationPermission(.authorized) == .allowed)
        #expect(NotificationPermission(.provisional) == .allowed)
        #expect(NotificationPermission(.denied) == .denied)
        #expect(NotificationPermission(.notDetermined) == .notAsked)
        #expect(NotificationPermission.allowed.title == "Notifications are allowed" && NotificationPermission.allowed.action == .openSettings)
        #expect(NotificationPermission.denied.action == .openSettings && !NotificationPermission.denied.delivers)
        #expect(NotificationPermission.notAsked.action == .ask && NotificationPermission.notAsked.actionTitle == "Allow Notifications…")
        #expect(NotificationPermission.unavailable.action == nil && NotificationPermission.unavailable.actionTitle == nil)
        #expect(NotificationPermission.allowed.delivers)
    }
}
