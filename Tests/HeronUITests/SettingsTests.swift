import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

@Suite struct SettingsTests {
    /// A private UserDefaults domain per test, removed afterwards.
    func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "app.heron.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        defaults.removePersistentDomain(forName: name)
    }

    @Test func valuesSurviveARelaunch() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            s.interval = 2
            s.temperatureUnit = .fahrenheit
            s.setShown(.gpu, true)
            s.alertRules.append(AlertRule(subject: .gpuLoad, comparison: .above, threshold: 95, seconds: 10))
            let again = AppSettings(defaults: d)
            #expect(again.interval == 2)
            #expect(again.temperatureUnit == .fahrenheit)
            #expect(again.isShown(.gpu))
            #expect(again.alertRules.count == AlertRule.defaults.count + 1)
        }
    }

    @Test func resetRestoresDefaultsButKeepsFirstRunState() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            s.onboardingDone = true
            s.lastSeenVersion = "1.0.0"
            s.interval = 5
            s.temperatureUnit = .fahrenheit
            s.setShown(.cpu, true)
            s.reset()
            #expect(s.interval == 1 && s.temperatureUnit == .celsius && s.shownItems.isEmpty)
            #expect(s.onboardingDone && s.lastSeenVersion == "1.0.0")
            let again = AppSettings(defaults: d)
            #expect(again.interval == 1 && again.temperatureUnit == .celsius)
        }
    }

    @Test func retiredFanSettingsAreForgottenAtLaunch() {
        withDefaults { d in
            for key in ["fanMode", "fanCurve", "fanRiskAccepted", "combineItems"] { d.set("x", forKey: key) }
            d.set(2.0, forKey: "interval")
            _ = AppSettings(defaults: d)
            for key in ["fanMode", "fanCurve", "fanRiskAccepted", "combineItems"] { #expect(d.object(forKey: key) == nil) }
            #expect(d.double(forKey: "interval") == 2)
        }
    }

    @Test func savedMenuOrderIsKeptAndNewItemsAreAdded() {
        let saved = [MenuItemConfig(kind: .battery, enabled: true, style: .text), MenuItemConfig(kind: .cpu, enabled: false, style: .gauge)]
        let merged = MenuItemConfig.merged(saved)
        #expect(merged.prefix(2).map(\.kind) == [.battery, .cpu])
        #expect(merged.count == MenuItemKind.allCases.count)
        #expect(merged[1].style == .gauge)
    }

    @Test func menuBarTemperatureFollowsTheChosenSensor() {
        var s = Snapshot()
        s.sensors = [
            Sensor(id: "a", name: "CPU 1", group: .cpu, celsius: 70, isKnown: true),
            Sensor(id: "b", name: "GPU 1", group: .gpu, celsius: 55, isKnown: true),
            Sensor(id: "c", name: "SSD 1", group: .ssd, celsius: 40, isKnown: true),
            Sensor(id: "d", name: "TCMz", group: .other, celsius: 99, isKnown: false),  // unknown: ignored
        ]
        #expect(SensorSummary.value(.hottest, in: s) == 70)
        #expect(SensorSummary.value(.gpu, in: s) == 55)
        #expect(SensorSummary.value(.ssd, in: s) == 40)
    }
}

/// Settings › Menu Bar (variants and appearance) and Settings › Overview (order, hidden sections).
@Suite struct MenuBarAndOverviewSettingsTests {
    func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "app.heron.tests.menubar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        defaults.removePersistentDomain(forName: name)
    }

    /// Stores menu items the way an earlier version did.
    func storeItems(_ items: [MenuItemConfig], in d: UserDefaults) {
        // A fixed value type always encodes; a failure would be a broken test, so record it.
        guard let data = try? JSONEncoder().encode(items) else { Issue.record("could not encode menu items"); return }
        d.set(data, forKey: "menuItems")
    }

    @Test func defaultsMatchTheDesign() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            #expect(s.showIcon && s.colourMode == .monochrome && s.spacing == .regular && s.warnRed)
            #expect(MenuItemKind.allCases.allSatisfy(s.showsLabel))
            #expect(s.overviewOrder == [.cpu, .gpu, .memory, .network, .disk, .ai, .sensors, .battery] && s.hiddenSections.isEmpty)
            #expect(s.cardStyle(.memory) == .rings)
            let defaults: [MenuItemKind: MenuItemStyle] = [
                .cpu: .bar, .gpu: .bar, .memory: .bar, .temperature: .hottest,
                .network: .both, .disk: .free, .fans: .rpm, .battery: .both, .ai: .text,
            ]
            for kind in MenuItemKind.allCases {
                #expect(s.style(of: kind) == defaults[kind] && kind.styles.first == defaults[kind], "\(kind)")
                #expect(Set(kind.styles).count == kind.styles.count, "\(kind) lists a variant twice")
            }
            #expect(MenuItemKind.memory.styles == [.bar, .text, .usedGB, .freeGB, .pressure, .graph, .gauge])
            #expect(MenuItemKind.memory.title(of: .freeGB) == "Available")
        }
    }

    @Test func everyNewSettingSurvivesARelaunchAndResets() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            s.showIcon = false; s.colourMode = .metric; s.setLabel(.cpu, false); s.spacing = .wide; s.warnRed = false; s.setLabel(.temperature, false)
            s.setOverviewOrder([.battery, .cpu]); s.setHidden(.disk, true)
            s.setStyle(.memory, .pressure); s.setStyle(.temperature, .ssd); s.setStyle(.fans, .percent)
            let again = AppSettings(defaults: d)
            #expect(
                !again.showIcon && again.colourMode == .metric && !again.showsLabel(.cpu) && again.spacing == .wide && !again.warnRed && !again.showsLabel(.temperature)
                    && again.showsLabel(.gpu))
            #expect(again.overviewOrder.prefix(2) == [.battery, .cpu] && again.hiddenSections == [.disk])
            #expect(again.style(of: .memory) == .pressure && again.style(of: .temperature) == .ssd && again.style(of: .fans) == .percent)
            #expect(again.menuBarSensor == .ssd)
            s.reset()
            for fresh in [s, AppSettings(defaults: d)] {
                #expect(fresh.showIcon && fresh.colourMode == .monochrome && fresh.showsLabel(.cpu) && fresh.spacing == .regular && fresh.warnRed && fresh.showsLabel(.temperature))
                #expect(fresh.overviewOrder == OverviewPart.allCases && fresh.hiddenSections.isEmpty)
                #expect(fresh.style(of: .memory) == .bar && fresh.style(of: .temperature) == .hottest)
            }
        }
    }

    @Test func invalidStoredValuesFallBack() {
        withDefaults { d in
            d.set("neon", forKey: "colourMode")
            d.set("huge", forKey: "spacing")
            d.set("yes", forKey: "showIcon")  // wrong type
            d.set(["disk", "nonsense", "disk", "cpu"], forKey: "overviewOrder")
            d.set(OverviewPart.allCases.map(\.rawValue), forKey: "hiddenSections")  // every section hidden
            // A style this version does not know, and one the kind does not offer.
            d.set(Data(#"[{"kind":"memory","enabled":true,"style":"sparkle"},{"kind":"cpu","enabled":true,"style":"rpm"}]"#.utf8), forKey: "menuItems")
            let s = AppSettings(defaults: d)
            #expect(s.colourMode == .monochrome && s.spacing == .regular && s.showIcon)
            #expect(s.overviewOrder == [.disk, .cpu, .gpu, .memory, .network, .ai, .sensors, .battery])
            #expect(s.hiddenSections.isEmpty)
            #expect(s.menuItems.prefix(2).map(\.kind) == [.memory, .cpu] && s.isShown(.memory) && s.isShown(.cpu))
            #expect(s.style(of: .memory) == .bar && s.style(of: .cpu) == .bar)
        }
    }

    @Test func stylesOfEarlierVersionsAreMigrated() {
        withDefaults { d in
            storeItems(
                [
                    .init(kind: .battery, enabled: true, style: .bar), .init(kind: .temperature, enabled: true, style: .text),
                    .init(kind: .disk, enabled: true, style: .text), .init(kind: .network, enabled: false, style: .text),
                    .init(kind: .fans, enabled: true, style: .text), .init(kind: .cpu, enabled: true, style: .text),
                    .init(kind: .memory, enabled: true, style: .gauge), .init(kind: .gpu, enabled: false, style: .graph),
                ], in: d)
            let s = AppSettings(defaults: d)
            let expected: [MenuItemKind: MenuItemStyle] = [
                .battery: .icon, .temperature: .cpu, .disk: .free, .network: .both,
                .fans: .rpm, .cpu: .text, .memory: .gauge, .gpu: .graph,
            ]
            for (kind, style) in expected { #expect(s.style(of: kind) == style, "\(kind)") }
            #expect(s.menuItems.map(\.kind) == [.battery, .temperature, .disk, .network, .fans, .cpu, .memory, .gpu, .ai])  // order kept, new kinds after
            #expect(s.isShown(.battery) && !s.isShown(.network))  // switches kept
        }
        withDefaults { d in
            storeItems([.init(kind: .battery, enabled: true, style: .text)], in: d)
            #expect(AppSettings(defaults: d).style(of: .battery) == .both)
        }
    }

    /// The separate "menuBarSensor" setting becomes the temperature item's variant, then is gone.
    @Test func theMenuBarSensorBecomesTheTemperatureVariant() {
        withDefaults { d in
            storeItems([.init(kind: .temperature, enabled: true, style: .text)], in: d)
            d.set("ssd", forKey: "menuBarSensor")
            let s = AppSettings(defaults: d)
            #expect(s.style(of: .temperature) == .ssd && s.menuBarSensor == .ssd)
            #expect(d.object(forKey: "menuBarSensor") == nil)
            #expect(AppSettings(defaults: d).style(of: .temperature) == .ssd)  // the migration was saved
        }
        withDefaults { d in
            d.set("gpu", forKey: "menuBarSensor")  // no menu items stored yet
            #expect(AppSettings(defaults: d).style(of: .temperature) == .gpu)
            #expect(AppSettings(defaults: d).style(of: .temperature) == .gpu)
        }
        withDefaults { d in
            d.set("bogus", forKey: "menuBarSensor")
            #expect(AppSettings(defaults: d).style(of: .temperature) == .hottest)
            #expect(d.object(forKey: "menuBarSensor") == nil)
        }
    }

    @Test func theLastVisibleOverviewSectionCannotBeHidden() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            let parts = OverviewPart.allCases
            for part in parts.dropLast() { #expect(s.setHidden(part, true)) }
            #expect(!s.setHidden(parts.last!, true))
            #expect(s.hiddenSections.count == parts.count - 1 && !s.isHidden(parts.last!))
            #expect(s.setHidden(parts[0], true))  // already hidden: fine
            #expect(s.setHidden(parts[0], false) && !s.isHidden(parts[0]))
            #expect(AppSettings(defaults: d).hiddenSections.count == parts.count - 2)
        }
    }

    @Test func theOverviewOrderHasEverySectionOnce() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            s.setOverviewOrder([.disk, .disk, .cpu, .disk])
            #expect(s.overviewOrder == [.disk, .cpu, .gpu, .memory, .network, .ai, .sensors, .battery])
            #expect(AppSettings(defaults: d).overviewOrder == s.overviewOrder)
        }
    }

    /// With nothing shown, the Heron icon is the whole item, so "Show icon" off cannot hide it.
    @Test func theIconStaysWhenNothingElseIsShown() {
        withDefaults { d in
            let s = AppSettings(defaults: d)
            s.showIcon = false
            #expect(s.showsIcon)
            s.setShown(.cpu, true)
            #expect(!s.showsIcon)
        }
    }
}

/// Onboarding opens its item list with every item ticked, once: picks made there survive Back.
@Suite struct OnboardingTests {
    @Test func everyItemIsTickedTheFirstTimeOnly() {
        let s = AppSettings(defaults: scratchDefaults("onboarding"))
        var prefilled = false
        OnboardingView.tickEverything(s, prefilled: &prefilled)
        #expect(MenuItemKind.allCases.allSatisfy { s.isShown($0) })
        s.setShown(.fans, false)  // the user unticks one, goes Back, Continues
        OnboardingView.tickEverything(s, prefilled: &prefilled)
        #expect(!s.isShown(.fans))
    }
}
