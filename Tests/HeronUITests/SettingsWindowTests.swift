import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// The Settings window: every setting has a control, the sidebar search, arranging the overview.
@Suite struct SettingsWindowTests {
    func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "app.heron.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        defaults.removePersistentDomain(forName: name)
    }

    /// `AppSettings.keys` names every stored setting, so the registry check below can't be skipped
    /// by leaving a new setting out of `keys`.
    @Test func keysListEveryStoredSetting() {
        withDefaults { d in
            let stored = Mirror(reflecting: AppSettings(defaults: d)).children.compactMap(\.label)
                .map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
                .filter { $0 != "defaults" && $0 != "$observationRegistrar" }
            #expect(Set(stored) == Set(AppSettings.keys))
        }
    }

    /// No setting may disappear from Settings: every stored key is on some pane's list, or on the
    /// short list of keys Heron keeps for itself; and no pane lists a key that does not exist.
    @Test func everySettingBelongsToAPane() {
        let registered = Set(SettingsPane.allCases.flatMap(\.keys))
        let all = Set(AppSettings.keys)
        let internalKeys = Set(SettingsPane.internalKeys)
        #expect(
            registered.union(internalKeys) == all,
            "no pane: \(all.subtracting(registered).subtracting(internalKeys).sorted()); unknown: \(registered.subtracting(all).sorted())")
        #expect(registered.isDisjoint(with: internalKeys))
    }

    /// Each pane's keys are written by a control in the Settings source: a `$settings.key` binding,
    /// or the setter that writes it. A read alone (`settings.key ? …`) does not count.
    @Test func everyRegisteredKeyIsBoundInTheSettingsSource() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HeronUI")
        // Every Settings source: SettingsView, SettingsParts and the panes in files of their own (SettingsAIUsage…).
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("Settings") && $0.hasSuffix(".swift") }.sorted()
        #expect(files.contains("SettingsView.swift") && files.contains("SettingsParts.swift") && files.contains("SettingsAIUsage.swift"))
        let source =
            try files
            .map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        let writer = [
            "menuItems": "settings.setShown(", "cardStyles": "settings.setCardStyle(",
            "overviewOrder": "settings.setOverviewOrder(", "hiddenSections": "settings.setHidden(",
            "showIcon": "settings.showIcon = ", "alertRules": "settings.alertRules[", "sensorCard": "settings.sensorCard = ",
        ]
        for pane in SettingsPane.allCases {
            for key in pane.keys {
                let token = writer[key] ?? "$settings.\(key)"
                #expect(source.contains(token), "\(pane.title): no control writes \(key) (looked for \(token))")
            }
        }
    }

    /// The sidebar lists every pane, six; the metric panes and About are gone (their settings live in
    /// Overview and Alerts; About is the window the footer opens), so a search for them finds where
    /// their settings went.
    @Test func searchFiltersTheSidebarByTitleAndOption() {
        #expect(SettingsPane.sidebar == [.general, .menuBar, .overview, .aiUsage, .alerts, .updates])
        #expect(SettingsPane.allCases == SettingsPane.sidebar)
        #expect(SettingsPane.matching("") == SettingsPane.sidebar)
        #expect(SettingsPane.matching("   ") == SettingsPane.sidebar)
        #expect(SettingsPane.matching("about").isEmpty)
        #expect(SettingsPane.matching("Licence").isEmpty)
        #expect(SettingsPane.matching("fans") == [.overview])  // the fans list in Overview › Sensors
        #expect(SettingsPane.matching("Spacing") == [.menuBar])  // an option, not a title
        #expect(SettingsPane.matching("FAHRENHEIT") == [.general])  // case does not matter
        #expect(SettingsPane.matching(" public ip ") == [.overview])  // trimmed
        #expect(SettingsPane.matching("battery health") == [.alerts])  // the rule that replaced Battery's switch
        #expect(SettingsPane.matching("spac") == [.menuBar])  // "Spacing"
        #expect(SettingsPane.matching("zzz").isEmpty)
        for pane in SettingsPane.allCases { #expect(SettingsPane.matching(pane.title).contains(pane), "\(pane)") }
    }

    @Test func draggingASectionPutsItInTheTargetsPlace() {
        let order: [OverviewPart] = [.cpu, .gpu, .memory, .network, .disk, .sensors, .battery]
        #expect(OverviewArrange.move(order, .cpu, onto: .memory) == [.gpu, .memory, .cpu, .network, .disk, .sensors, .battery])  // down
        #expect(OverviewArrange.move(order, .disk, onto: .gpu) == [.cpu, .disk, .gpu, .memory, .network, .sensors, .battery])  // up
        #expect(OverviewArrange.move(order, .cpu, onto: .gpu) == [.gpu, .cpu, .memory, .network, .disk, .sensors, .battery])  // neighbours swap
        #expect(OverviewArrange.move(order, .battery, onto: .cpu).first == .battery)
        #expect(OverviewArrange.move(order, .cpu, onto: .battery).last == .cpu)
        #expect(OverviewArrange.move(order, .disk, onto: .disk) == order)
    }

    @Test func steppingASectionStopsAtTheEnds() {
        let order: [OverviewPart] = [.cpu, .gpu, .memory, .network, .disk, .sensors, .battery]
        #expect(OverviewArrange.step(order, .gpu, by: -1) == [.gpu, .cpu, .memory, .network, .disk, .sensors, .battery])
        #expect(OverviewArrange.step(order, .gpu, by: 1) == [.cpu, .memory, .gpu, .network, .disk, .sensors, .battery])
        #expect(OverviewArrange.step(order, .cpu, by: -1) == order)
        #expect(OverviewArrange.step(order, .battery, by: 1) == order)
    }

    /// The arranged order is what the popover then draws, and it survives a relaunch.
    @Test func anArrangedOrderIsSavedAndDrawn() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            s.setOverviewOrder(OverviewArrange.move(s.overviewOrder, .battery, onto: .cpu))
            s.setHidden(.gpu, true)
            #expect(AppSettings(defaults: d).overviewOrder.first == .battery)
            var snapshot = Snapshot()
            snapshot.battery = BatteryReading(present: true, percent: 0.5, isCharging: false, onAC: false)
            #expect(
                OverviewSection.parts(order: s.overviewOrder, hidden: s.hiddenSections, snapshot: snapshot)
                    == [.battery, .cpu, .memory, .network, .disk, .sensors])
        }
    }
}
