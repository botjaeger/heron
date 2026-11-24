import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

/// The hover panels open, switch and close on the design's timing (120 ms / 250 ms / 300 ms).
@Suite struct HoverIntentTests {
    typealias Intent = HoverIntent<String>

    @Test func aCardOpensAfterThePointerRestsOnIt() {
        var h = Intent()
        h.pointer(inPopover: true, now: 0)
        h.pointer(onCard: "cpu", now: 0)
        let early = h.advance(to: 0.119)
        #expect(!early && h.open == nil)
        let due = h.advance(to: 0.12)
        #expect(due && h.open == "cpu")
    }

    @Test func crossingACardOnTheWayOpensNothing() {
        var h = Intent()
        h.pointer(inPopover: true, now: 0)
        h.pointer(onCard: "gpu", now: 0)
        h.pointer(onCard: nil, now: 0.05)  // left it before 120 ms
        h.advance(to: 1)
        #expect(h.open == nil)
    }

    @Test func switchingWaitsLongerThanOpening() {
        var h = Intent()
        h.pointer(inPopover: true, now: 0)
        h.open("cpu")
        h.pointer(onCard: "memory", now: 2)
        h.advance(to: 2.2)
        #expect(h.open == "cpu")  // 200 ms: still the first panel
        h.advance(to: 2.25)
        #expect(h.open == "memory")
        h.pointer(onCard: "memory", now: 3)  // resting on the open card schedules nothing
        #expect(h.pending == nil)
    }

    @Test func leavingClosesAfterTheGraceUnlessThePointerReachesThePanel() {
        var h = Intent()
        h.pointer(inPopover: true, now: 0)
        h.open("cpu")
        h.pointer(onCard: nil, now: 1)
        h.pointer(inPopover: false, now: 1)  // off the popover, towards the panel
        h.advance(to: 1.29)
        #expect(h.open == "cpu")
        h.pointer(inPanel: true, now: 1.2)  // reached the panel inside 300 ms
        h.advance(to: 5)
        #expect(h.open == "cpu")  // the panel keeps itself open
        h.pointer(inPanel: false, now: 6)
        #expect(abs((h.deadline ?? 0) - 6.3) < 1e-9)
        h.advance(to: 6.31)
        #expect(h.open == nil)
    }

    @Test func movingBetweenCardsAndTheGapsKeepsThePanel() {
        var h = Intent()
        h.pointer(inPopover: true, now: 0)
        h.pointer(onCard: "cpu", now: 0)
        h.advance(to: 0.12)
        h.pointer(onCard: nil, now: 1)  // off the card: the gap between two cards, or the header
        h.advance(to: 10)
        #expect(h.open == "cpu")
        h.pointer(onCard: "cpu", now: 11)  // back on the open card: nothing to do
        #expect(h.pending == nil && h.closeAt == nil)
    }

    @Test func closingThePopoverClosesEverything() {
        var h = Intent()
        h.pointer(inPopover: true, now: 0)
        h.pointer(onCard: "cpu", now: 0)
        h.advance(to: 0.2)
        h.pointer(onCard: "gpu", now: 0.3)  // a switch is pending
        h.close()
        #expect(h.open == nil && h.pending == nil && h.deadline == nil)
        h.advance(to: 5)
        #expect(h.open == nil)
    }
}

/// The panel goes left of the popover when there is room, otherwise right, and stays on screen.
@Suite struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)  // visibleFrame: menu bar excluded
    let size = CGSize(width: 360, height: 500)

    @Test func leftOfThePopoverLinedUpWithTheCard() {
        let popover = CGRect(x: 900, y: 175, width: 360, height: 700)
        let card = CGRect(x: 914, y: 600, width: 332, height: 90)
        let placed = PanelPlacement.frame(size: size, popover: popover, card: card, visible: screen)
        #expect(placed.side == .left)
        #expect(placed.frame.maxX == popover.minX - PanelPlacement.gap)
        #expect(placed.frame.maxY == card.maxY + PanelPlacement.headerOffset)
    }

    @Test func flipsRightWhenTheLeftHasNoRoom() {
        let popover = CGRect(x: 100, y: 175, width: 360, height: 700)
        let placed = PanelPlacement.frame(size: size, popover: popover, card: nil, visible: screen)
        #expect(placed.side == .right)
        #expect(placed.frame.minX == popover.maxX + PanelPlacement.gap)
    }

    @Test func neitherSideFitsTakesTheRoomierOneAndClamps() {
        let narrow = CGRect(x: 0, y: 0, width: 900, height: 875)
        let popover = CGRect(x: 300, y: 175, width: 360, height: 700)  // 292 left, 232 right
        let placed = PanelPlacement.frame(size: size, popover: popover, card: nil, visible: narrow)
        #expect(placed.side == .left)
        #expect(placed.frame.minX == 0)
    }

    @Test func staysInsideTheVisibleFrameVertically() {
        let popover = CGRect(x: 900, y: 175, width: 360, height: 700)
        // A card at the very top: the panel would poke above the menu bar.
        let high = PanelPlacement.frame(size: size, popover: popover, card: CGRect(x: 914, y: 800, width: 332, height: 60), visible: screen)
        #expect(high.frame.maxY == screen.maxY)
        // A card near the bottom: the panel would drop below the Dock.
        let low = PanelPlacement.frame(size: size, popover: popover, card: CGRect(x: 914, y: 10, width: 332, height: 60), visible: screen)
        #expect(low.frame.minY == screen.minY)
        // Taller than the screen: the top stays visible.
        let tall = PanelPlacement.frame(size: CGSize(width: 360, height: 1000), popover: popover, card: nil, visible: screen)
        #expect(tall.frame.maxY == screen.maxY)
    }
}

/// The keyboard: ↑/↓ move the focus, the arrow towards the panel (or Return) opens it, the other
/// arrow or Esc goes back one step; Esc with nothing open is left to the popover.
@Suite struct PanelKeyboardTests {
    @Test func arrowsWalkOpenAndClose() {
        let p = DetailPanels()
        p.visibleParts = { [.cpu, .gpu, .memory] }
        p.side = .left
        #expect(p.handle(.down) && p.focused == .cpu)
        #expect(p.handle(.down) && p.focused == .gpu)
        #expect(p.handle(.left) && p.open == .gpu)
        #expect(p.handle(.down) && p.open == .memory)  // an open panel follows the focus
        p.showHistory(HistoryItem(part: .memory, metric: .memoryApp, title: "App", unit: .bytes, color: Theme.memory))
        #expect(p.handle(.escape) && p.history == nil && p.open == .memory)
        #expect(p.handle(.right) && p.open == nil)
        #expect(!p.handle(.escape))
        p.side = .right
        #expect(p.handle(.enter) && p.open == .memory)
        #expect(p.handle(.left) && p.open == nil)
    }

    @Test func aDifferentPanelForgetsTheHistory() {
        let p = DetailPanels()
        p.openNow(.cpu)
        p.showHistory(HistoryItem(part: .cpu, metric: .cpuPower, title: "CPU power", unit: .watts, color: Theme.cpu))
        #expect(p.history?.title == "CPU power")
        p.openNow(.gpu)
        #expect(p.history == nil)
        p.closeAll()
        #expect(p.open == nil && p.focused == nil)
    }
}

/// A row's history opens beside its panel like a submenu: on a rest of the pointer, never in
/// place of the details (which moved the panel out from under the pointer and closed it).
@Suite struct HistorySubmenuTests {
    let power = HistoryItem(part: .cpu, metric: .cpuPower, title: "CPU power", unit: .watts, color: Theme.cpu)
    let temperature = HistoryItem(part: .cpu, metric: .cpuTemperature, title: "CPU temperature", unit: .temperature, color: Theme.warning)

    /// The CPU panel open, the pointer on it.
    func cpuPanel(_ now: @escaping () -> Double) -> DetailPanels {
        let p = DetailPanels()
        p.clock = now
        p.openNow(.cpu)
        p.pointerInPopover(nil)
        p.pointerInPanel(true)
        return p
    }

    @Test func restingOnARowOpensItsHistory() {
        var now = 0.0
        let p = cpuPanel { now }
        p.pointerOnHistoryRow(power, inside: true)
        now = 0.11
        p.pointerInPanel(true)  // any call runs what is due
        #expect(p.history == nil)
        now = 0.12
        p.pointerInPanel(true)
        #expect(p.history == power && p.open == .cpu)
    }

    @Test func movingOntoTheHistoryKeepsBothAndLeavingClosesBoth() {
        var now = 0.0
        let p = cpuPanel { now }
        p.pointerOnHistoryRow(power, inside: true)
        now = 0.12
        p.pointerInPanel(true)  // the timer firing
        #expect(p.history == power)
        now = 0.2
        p.pointerOnHistoryRow(power, inside: false)  // off the row, out of the panel...
        p.pointerInPanel(false)
        now = 0.3
        p.pointerInHistory(true)  // ...and onto the history
        now = 5
        p.pointerInHistory(true)
        #expect(p.open == .cpu && p.history == power)
        p.pointerInHistory(false)  // back across the panel's other rows
        p.pointerInPanel(true)
        p.pointerOnHistoryRow(temperature, inside: true)
        now = 5.1
        p.pointerOnHistoryRow(temperature, inside: false)
        now = 6
        p.pointerInPanel(true)
        #expect(p.history == power)  // crossed in 100 ms: no switch
        p.pointerInPanel(false)  // off everything
        now = 6.29
        p.pointerInPanel(false)
        #expect(p.history == power)
        now = 6.31
        p.pointerInPanel(false)
        #expect(p.open == nil && p.history == nil)
    }

    @Test func restingOnAnotherRowSwitches() {
        var now = 0.0
        let p = cpuPanel { now }
        p.showHistory(power)  // a click: no delay
        #expect(p.history == power)
        p.pointerOnHistoryRow(temperature, inside: true)
        p.pointerOnHistoryRow(power, inside: false)  // the old row's "left" arrives late
        now = 0.25
        p.pointerInPanel(true)
        #expect(p.history == temperature)
    }

    @Test func theHistoryWaitsWhileThePointerIsOnTheOverview() {
        var now = 0.0
        let p = cpuPanel { now }
        p.showHistory(power)
        p.pointerInPanel(false)
        p.pointerInPopover(CGPoint(x: -100, y: -100))  // the overview, on no card
        now = 10
        p.pointerInPopover(CGPoint(x: -100, y: -100))
        #expect(p.open == .cpu && p.history == power)
    }
}

/// A history goes beside the panel, away from the popover, its top just above its row's.
@Suite struct HistoryPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 320, height: 400)
    let popover = CGRect(x: 1000, y: 175, width: 360, height: 700)
    let row = CGRect(x: 650, y: 500, width: 330, height: 30)

    @Test func outwardOfThePanelLevelWithItsRow() {
        let panel = CGRect(x: 632, y: 300, width: 360, height: 560)
        let f = PanelPlacement.historyFrame(size: size, panel: panel, popover: popover, row: row, side: .left, visible: screen)
        #expect(f.maxX == panel.minX - PanelPlacement.gap)
        #expect(f.maxY == row.maxY + PanelPlacement.historyOffset)
        let right = PanelPlacement.historyFrame(
            size: size, panel: CGRect(x: 368, y: 300, width: 360, height: 560),
            popover: CGRect(x: 0, y: 175, width: 360, height: 700), row: nil, side: .right, visible: screen)
        #expect(right.minX == 368 + 360 + PanelPlacement.gap)
    }

    @Test func noRoomOutwardGoesToThePopoversOtherSide() {
        let pop = CGRect(x: 380, y: 175, width: 360, height: 700)
        let panel = CGRect(x: 12, y: 300, width: 360, height: 560)
        let f = PanelPlacement.historyFrame(size: size, panel: panel, popover: pop, row: row, side: .left, visible: screen)
        #expect(f.minX == pop.maxX + PanelPlacement.gap)
        #expect(!f.intersects(panel) && !f.intersects(pop))
    }
}

/// Class: the card frames and the pointer must share one space. The popover's hosting view sits
/// 13 pt inside its window, so frames read in SwiftUI's `.global` (window) space were 13 pt off
/// the pointer and the panel (found on the live smoke run).
@Suite struct CardFrameSpaceTests {
    @MainActor @Test func cardFramesAreInTheHostingViewsOwnSpace() {
        let panels = DetailPanels()
        let settings = AppSettings(defaults: scratchDefaults("frames"))
        let root = PopoverRoot().environment(Monitor()).environment(settings).environment(AppServices()).environment(panels)
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let inset: CGFloat = 13
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width + 2 * inset, height: size.height + 2 * inset),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 2 * inset, height: size.height + 2 * inset))
        window.contentView = container
        host.frame = NSRect(x: inset, y: inset, width: size.width, height: size.height)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let cpu = panels.cardFrames[.cpu]
        #expect(cpu != nil)
        // The overview's cards sit its padding in from the hosting view's left edge, not 13 + that.
        #expect(cpu.map { abs($0.minX - PopoverView.overviewPadding) < 0.5 } == true)
        // And inside the hosting view's bounds.
        #expect(cpu.map { NSRect(origin: .zero, size: size).contains($0) } == true)
    }
}

/// A page taller than the screen had its top cut off by macOS (2026-11-23, the overview on a 14"
/// display): with a cap the page stops at it and the sections scroll; without one it is full height.
@Suite struct PageMaxHeightTests {
    @MainActor func host(_ kind: PopoverKind, cap: CGFloat?, tag: String) -> (NSHostingView<AnyView>, DetailPanels) {
        let panels = DetailPanels()
        panels.popoverMaxHeight = cap
        panels.panelMaxHeight = cap
        let settings = AppSettings(defaults: scratchDefaults(tag))
        let view: AnyView =
            kind == .overview
            ? AnyView(PopoverRoot().environment(Monitor()).environment(settings).environment(AppServices()).environment(panels))
            : AnyView(PopoverView(kind: kind).environment(Monitor()).environment(settings).environment(AppServices()).environment(panels))
        return (NSHostingView(rootView: view), panels)
    }

    @MainActor @Test func theOverviewStopsAtTheCapAndScrolls() {
        let full = host(.overview, cap: nil, tag: "cap-full").0.fittingSize.height
        #expect(full > 300)
        let (capped, panels) = host(.overview, cap: 300, tag: "cap-300")
        #expect(abs(capped.fittingSize.height - 300) < 1)
        // A cap above the page's height changes nothing.
        #expect(abs(host(.overview, cap: full + 200, tag: "cap-big").0.fittingSize.height - full) < 1)
        // The scrolling cards' area sits between header and footer, inside the page.
        capped.frame = NSRect(origin: .zero, size: capped.fittingSize)
        capped.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let viewport = panels.viewport
        #expect(viewport.map { $0.minY > 30 && $0.maxY < 300 - 30 } == true)
    }

    @MainActor @Test func aPanelStopsAtTheCapToo() {
        let full = host(.cpu, cap: nil, tag: "cap-panel-full").0.fittingSize.height
        #expect(full > 250)
        #expect(abs(host(.cpu, cap: 250, tag: "cap-panel").0.fittingSize.height - 250) < 1)
    }

    /// A card scrolled under the header is not under the pointer there.
    @MainActor @Test func aCardOutsideTheViewportIsNotHovered() {
        let panels = DetailPanels()
        panels.reportFrame(.cpu, CGRect(x: 12, y: 0, width: 336, height: 120))
        panels.reportViewport(CGRect(x: 12, y: 60, width: 336, height: 400))
        panels.clock = { 0 }
        panels.pointerInPopover(CGPoint(x: 100, y: 30))  // on the header, over the scrolled-away card
        panels.clock = { 1 }
        panels.pointerInPopover(CGPoint(x: 100, y: 30))
        #expect(panels.open == nil)
        panels.pointerInPopover(CGPoint(x: 100, y: 90))  // on the card's visible part
        panels.clock = { 2 }
        panels.pointerInPopover(CGPoint(x: 100, y: 90))
        #expect(panels.open == .cpu)
    }
}

/// "Copy picture" on every panel: the header button follows Settings › General › Copy picture, and
/// the picture is the whole panel at full height, even when the panel on screen scrolls.
@Suite struct CopyPictureTests {
    @Test func theButtonIsOnEveryPanelWhileTheSettingIsOn() {
        for kind in PopoverKind.allCases where kind != .overview {
            #expect(PopoverView.showsCopyButton(kind, on: true, picture: false), "\(kind)")
            #expect(!PopoverView.showsCopyButton(kind, on: false, picture: false), "\(kind)")
            #expect(!PopoverView.showsCopyButton(kind, on: true, picture: true), "\(kind)")
        }
        // The overview has no header button.
        #expect(!PopoverView.showsCopyButton(.overview, on: true, picture: false))
    }

    @Test func theSettingIsOnByDefaultAndReset() {
        let defaults = scratchDefaults("copy-picture")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.copyPicture)
        settings.copyPicture = false
        #expect(!AppSettings(defaults: defaults).copyPicture)
        settings.reset()
        #expect(settings.copyPicture)
    }

    @MainActor @Test func thePictureIsTheWholePanel() throws {
        let monitor = Monitor()
        let settings = AppSettings(defaults: scratchDefaults("copy-picture-image"))
        for kind in PopoverKind.allCases where kind != .overview && kind != .ai {
            let view = PopoverView.picture(kind, snapshot: monitor.snapshot, monitor: monitor, settings: settings, services: AppServices(), ai: nil)
            let full = NSHostingView(rootView: view).fittingSize
            let image = try #require(PanelPicture.image(view, scheme: .dark, scale: 1), "\(kind)")
            #expect(abs(image.size.width - PopoverView.width) < 1, "\(kind)")
            #expect(abs(image.size.height - full.height) < 1 && image.size.height > 60, "\(kind) \(image.size) vs \(full)")
        }
    }
}
