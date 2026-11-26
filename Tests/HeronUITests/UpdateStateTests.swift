import AppKit
import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// One update state (`UpdateState`) drives the icon dot, the popover strip, the menu item, the
/// update window, About and Settings › Updates.
@MainActor
@Suite struct UpdateStateTests {
    let offer = UpdateOffer(version: "1.1.0", size: 4_485_730)
    var automatic: UpdateOffer { UpdateOffer(version: "1.1.0", size: 4_485_730, automatic: true) }

    /// What waits for you: a found, downloading or downloaded update; never one that installs
    /// itself, one already installing, or none.
    @Test func whatCountsAsWaiting() {
        #expect(UpdateState.available(offer).waiting == offer)
        #expect(UpdateState.downloading(offer, received: 1, expected: 2).waiting == offer)
        #expect(UpdateState.preparing(offer).waiting == offer)
        #expect(UpdateState.ready(offer).waiting == offer)
        #expect(UpdateState.ready(automatic).waiting == nil, "Install automatically: nothing marks it")
        #expect(UpdateState.available(automatic).waiting == nil)
        #expect(UpdateState.installing(offer).waiting == nil)
        for state in [UpdateState.idle, .checking, .failed("x")] { #expect(state.waiting == nil, "\(state)") }
    }

    @Test func theMenuItemNamesTheWaitingVersion() {
        #expect(UpdateState.idle.menuTitle == "Check for Updates…")
        #expect(UpdateState.available(offer).menuTitle == "Update to Heron 1.1.0…")
        #expect(UpdateState.ready(automatic).menuTitle == "Check for Updates…")
        let menu = StatusMenu.make(target: NSObject(), update: .available(offer)) { _ in nil }
        let item = menu.items.first { $0.title.hasPrefix("Update to") }
        #expect(item?.image != nil, "the item carries the icon's dot")
        let idle = StatusMenu.make(target: NSObject()) { _ in nil }
        #expect(idle.items.contains { $0.title == "Check for Updates…" && $0.image == nil })
    }

    @Test func downloadProgressAndItsLine() {
        let state = UpdateState.downloading(offer, received: 2_900_000, expected: 4_485_730)
        #expect(state.progress.map { abs($0 - 0.6465) < 0.001 } == true)
        #expect(state.statusLine == "Downloading Heron 1.1.0 · 2.9 of 4.5 MB")
        #expect(UpdateState.downloading(offer, received: 9, expected: nil).progress == nil, "no total yet: no bar")
        #expect(UpdateState.downloading(offer, received: 9, expected: 0).progress == nil)
        #expect(UpdateState.downloading(offer, received: 10, expected: 5).progress == 1, "never past full")
        #expect(UpdateState.available(offer).statusLine == "Heron 1.1.0 is available · 4.5 MB")
        #expect(UpdateState.ready(offer).statusLine == "Heron 1.1.0 is ready · installs when you quit Heron")
        #expect(UpdateState.idle.statusLine == nil, "the check status shows instead")
    }

    /// Settings' main button and the update window's do the same thing in each state.
    @Test func theMainButtonFollowsTheState() {
        typealias Row = (UpdateState, String, UpdatesPane.Does, Bool)
        let rows: [Row] = [
            (.idle, "Check Now", .check, false),
            (.available(offer), "Install Update", .install, true),
            (.downloading(offer, received: 1, expected: 2), "Downloading…", .none, false),
            (.preparing(offer), "Preparing…", .none, false),
            (.ready(offer), "Restart Heron Now", .restart, true),
            (.installing(offer), "Installing…", .none, false),
        ]
        for (state, title, does, windowEnabled) in rows {
            let settings = UpdatesPane.action(state, checking: false)
            #expect(settings.title == title, "\(state)")
            #expect(settings.does == does, "\(state)")
            if state.offer != nil {
                #expect(UpdateView.primary(state).title == title, "\(state)")
                #expect(UpdateView.primary(state).enabled == windowEnabled, "\(state)")
            }
        }
        #expect(UpdatesPane.action(.idle, checking: true).does == .none)
    }

    @Test func theWindowSaysWhatItIs() {
        #expect(UpdateView.heading(.available(offer)) == "Heron 1.1.0 is available")
        #expect(UpdateView.heading(.ready(offer)) == "Heron 1.1.0 is ready")
        #expect(UpdateView.heading(.checking) == "Checking for updates…")
        #expect(UpdateView.facts(offer, current: "1.0.0") == "You have 1.0.0 · 4.5 MB")
        #expect(UpdateStrip.detail(.available(offer), current: "1.0.0") == "You have 1.0.0")
        #expect(UpdateStrip.detail(.ready(offer), current: "1.0.0") == "Installs when you quit Heron")
    }

    /// The dot sits on the glyph, so the glyph shows while an update waits even with "Show icon"
    /// off, the image keeps its colour, and VoiceOver hears it.
    @Test func theMenuBarItemCarriesTheDot() {
        let settings = AppSettings(defaults: scratchDefaults("update-dot"))
        settings.showIcon = false
        var label = MenuBarLabel(snapshot: Snapshot(), history: MetricHistory(), settings: settings)
        let before = label.renderKey(scale: 2)
        #expect(!label.spokenValue.contains("update"))
        label.updateWaiting = true
        #expect(label.showsIcon)
        #expect(label.isColoured)
        #expect(label.spokenValue.hasSuffix("update available"))
        #expect(label.renderKey(scale: 2) != before, "the dot redraws the item")
    }

    /// Every surface reads the one state: a new one that kept its own copy would drift.
    @Test func everyUpdateSurfaceReadsTheOneState() throws {
        let ui = sourceFiles("HeronUI"), app = sourceFiles("Heron")
        func text(_ files: [(name: String, text: String)], _ name: String) throws -> String { try #require(files.first { $0.name == name }?.text, "\(name)") }
        #expect(try text(ui, "PopoverView.swift").contains("services.update.waiting"))
        #expect(try text(ui, "AboutView.swift").contains("services.update"))
        #expect(try text(ui, "SettingsUpdates.swift").contains("services.update"))
        #expect(try text(ui, "UpdateView.swift").contains("services.update"))
        let bar = try text(app, "StatusBarController.swift")
        #expect(bar.contains("services.update.waiting"))
        #expect(bar.contains("label.updateWaiting = updateWaiting"))
        #expect(bar.contains("StatusMenu.make(target: self, update: services.update)"))
        // Only the driver moves it.
        for file in app + ui where file.name != "UpdateDriver.swift" && file.name != "Services.swift" {
            #expect(!file.text.contains("services.update = ") && !file.text.contains(".update = ."), "\(file.name) sets the update state")
        }
    }
}
