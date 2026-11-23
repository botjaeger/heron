import CoreGraphics
import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// The first run, What's New and About: the rules behind what they show and do.
@Suite struct FirstRunTests {
    @Test func theStepsGoForwardAndBack() {
        typealias Flow = OnboardingFlow
        #expect(Flow.next(.welcome) == .items)
        #expect(Flow.next(.items) == .alerts)
        #expect(Flow.next(.alerts) == nil)  // after the alerts the first run is done
        #expect(Flow.back(.alerts) == .items && Flow.back(.items) == .welcome && Flow.back(.welcome) == .welcome)
        #expect(Flow.caption(.items) == "Step 2 of 3")
        #expect(Flow.primaryTitle(.welcome, anyAlertOn: true) == "Continue" && Flow.primaryTitle(.items, anyAlertOn: false) == "Continue")
    }

    @Test func everyAlertOffFinishesWithoutAsking() {
        typealias Flow = OnboardingFlow
        #expect(Flow.primaryTitle(.alerts, anyAlertOn: true) == "Allow Notifications…")
        #expect(Flow.asksPermission(anyAlertOn: true) && Flow.offersNotNow(anyAlertOn: true))
        // Nothing to allow: "Finish", no prompt, no "Not now".
        #expect(Flow.primaryTitle(.alerts, anyAlertOn: false) == "Finish")
        #expect(!Flow.asksPermission(anyAlertOn: false) && !Flow.offersNotNow(anyAlertOn: false))
    }

    @Test func theFirstRunRulesAreTheRealDefaultsInPlainWords() {
        let rules = FirstRunAlerts.rows.compactMap { row in AlertRule.defaults.first { $0.subject == row.subject } }
        #expect(rules.count == 3)  // each row has its real rule
        #expect(rules.map { FirstRunAlerts.hint($0, unit: .celsius) } == ["Above 95° for 30 seconds", "Memory pressure reaches Critical for 10 seconds", "Below 10%"])
        #expect(FirstRunAlerts.hint(rules[0], unit: .fahrenheit) == "Above 203° for 30 seconds")
    }

    @Test func theWidthHintWarnsPastTheNotch() {
        #expect(MenuBarWidthHint.text(points: 228, items: 5) == "Takes about 230 pt of your menu bar")
        #expect(!MenuBarWidthHint.isWide(344))  // rounds to 340: not past it
        #expect(MenuBarWidthHint.isWide(346))  // rounds to 350
        #expect(MenuBarWidthHint.text(points: 382, items: 8) == "About 380 pt wide. On a MacBook with a notch some items may hide; untick a few to fit.")
        #expect(MenuBarWidthHint.text(points: 16, items: 0) == "Only the Heron icon will show · about 20 pt of your menu bar")
    }

    @Test func whatsNewListsReleasesOnlyWhenThereAreSeveral() {
        #expect(!ChangelogView.showsSidebar(Changelog.entries) || Changelog.entries.count > 1)
        let one = ChangelogEntry(version: "1.0.0", date: "2026", groups: [])
        #expect(!ChangelogView.showsSidebar([one]))
        #expect(ChangelogView.showsSidebar([one, ChangelogEntry(version: "1.1.0", date: "2027", groups: [])]))
        // No release-notes page is known for any release yet: no link to a page that may not exist.
        #expect(Changelog.entries.allSatisfy { $0.notesURL == nil })
    }

    @Test func aboutSaysWhatTheLastCheckFound() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let off = AboutView.updateLine(available: false, checking: false, lastCheck: now, foundNothing: true, now: now)
        #expect(off.text == "Updates are off in this build" && !off.upToDate)
        let fresh = AboutView.updateLine(available: true, checking: false, lastCheck: now, foundNothing: true, now: now)
        #expect(fresh.text == "Heron is up to date · checked just now" && fresh.upToDate)
        #expect(!AboutView.updateLine(available: true, checking: true, lastCheck: now, foundNothing: true, now: now).upToDate)
        #expect(!AboutView.updateLine(available: true, checking: false, lastCheck: nil, foundNothing: true, now: now).upToDate)
    }

    @Test func sparklesLicenceIsShownVerbatim() throws {
        // The package checkout's LICENSE, when this tree has one (it does after any `swift build`).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent(".build/checkouts/Sparkle/LICENSE")
        try #require(FileManager.default.fileExists(atPath: file.path), "no Sparkle checkout at \(file.path)")
        #expect(Acknowledgements.sparkle == (try String(contentsOf: file, encoding: .utf8)))
    }

    @Test func theNewRowsOpenTheirHistories() {
        var s = Snapshot()
        s.gpu = GPUReading(device: 0.3, renderer: 0.25, tiler: 0.1, name: nil)
        let rows = PanelRows.gpuDetails(s, unit: .celsius)
        #expect(rows.first { $0.key == "Renderer" }?.history?.source == .metric(.gpuRenderer))
        #expect(rows.first { $0.key == "Tiler" }?.history?.source == .metric(.gpuTiler))
        let m = MemoryReading(total: 100, app: 10, wired: 5, compressed: 0, cached: 0, free: 0, swapUsed: 3_200, pressure: .normal)
        #expect(PanelRows.swap(m).history?.source == .metric(.swapUsed))
        #expect(PanelRows.pressureHistory.source == .metric(.memoryPressure))
    }
}
