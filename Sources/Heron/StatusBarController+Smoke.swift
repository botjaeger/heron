import AppKit
import HeronCore
import HeronUI
import SwiftUI

/// The smoke run's hooks (`HERON_SMOKE_SECONDS`): open, drive and measure the popover and panels.
extension StatusBarController {
    /// Smoke test: open the popover as if clicked.
    func debugOpenFirstPopover() {
        guard let popover, let button = item?.button else { return }
        showPopover(popover, from: button)
    }

    var debugPopoverState: String {
        guard let popover, popover.isShown else { return "" }
        return "heron shown \(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))"
    }

    /// Smoke test: open a section's panel as a click would.
    func debugOpenPanel(_ part: OverviewPart) { panels.openNow(part) }

    /// Smoke test: drives the open popover with posted events (the real cursor never moves) and
    /// logs what each step did: a click on the panel's first button, Esc three times, then a
    /// click in another window. Calls `done` when finished.
    func debugInteract(outside: NSWindow?, done: @escaping () -> Void) {
        func post(_ event: NSEvent?) { if let event { NSApp.postEvent(event, atStart: false) } }
        func key(_ code: UInt16) {
            guard let window = popover?.contentViewController?.view.window else { return }
            post(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: code))
        }
        func click(_ window: NSWindow, at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                post(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
        }
        /// The first button SwiftUI exposes in the panel, as a point in the panel's window.
        func firstButton() -> (String, NSPoint)? {
            func walk(_ element: Any, depth: Int) -> (String, NSRect)? {
                guard depth < 30, let e = element as? NSAccessibilityProtocol else { return nil }
                if e.accessibilityRole() == .button, e.accessibilityFrame().width > 0 {
                    return ((e.accessibilityLabel() ?? "?"), e.accessibilityFrame())
                }
                for child in e.accessibilityChildren() ?? [] { if let hit = walk(child, depth: depth + 1) { return hit } }
                return nil
            }
            guard let content = panel.contentView, let (label, frame) = walk(content, depth: 0) else { return nil }
            return (label, panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)))
        }
        var steps: [() -> Void] = []
        steps.append { [self] in
            if let (label, point) = firstButton() {
                print("SMOKE step: click panel button '\(label)'")
                click(panel, at: point)
            } else {
                // SwiftUI builds its accessibility tree only for a real client, so fall back to
                // the memory panel's "App memory" row: 145 pt below the panel's top, under the
                // Used split bar (heron-snap's panel-memory render shows where).
                let point = NSPoint(x: 100, y: panel.frame.height - 145)
                print("SMOKE step: click panel at \(Int(point.x)),\(Int(point.y)) (memory › App row)")
                click(panel, at: point)
            }
        }
        steps.append { [self] in
            print(
                "SMOKE after panel click: history \(panels.history?.title ?? "nil") beside the panel \(historyPanel.isVisible && !historyPanel.frame.intersects(panel.frame)) panel shown \(panel.isVisible) popover shown \(popover?.isShown == true)"
            )
            key(53)
        }
        steps.append { [self] in
            print("SMOKE after Esc 1: history \(panels.history?.title ?? "nil") visible \(historyPanel.isVisible) panel \(panels.open?.rawValue ?? "nil")")
            key(53)
        }
        steps.append { [self] in
            print("SMOKE after Esc 2: panel \(panels.open?.rawValue ?? "nil") visible \(panel.isVisible) popover shown \(popover?.isShown == true)")
            if panel.debugHoldsPage || historyPanel.debugHoldsPage { print("SMOKE FAIL: a hidden panel still holds its page") }
            key(53)
        }
        steps.append { [self] in
            print("SMOKE after Esc 3: popover shown \(popover?.isShown == true)")
            debugOpenFirstPopover()
        }
        steps.append { [self] in
            print("SMOKE reopened: popover shown \(popover?.isShown == true)")
            if let outside { click(outside, at: NSPoint(x: outside.frame.width / 2, y: outside.frame.height / 2)) }
        }
        steps.append { [self] in
            print("SMOKE after outside click: popover shown \(popover?.isShown == true)")
            // Idle with everything closed: the closed popover once kept redrawing (~24% CPU).
            for window in NSApp.windows where window.isVisible && window !== item?.button?.window { window.close() }
            // An emptied host measures 0 tall; the overview measures hundreds of points.
            let held = (hostingController?.view.fittingSize.height ?? 0) > 10
            print("SMOKE closed popover holds the overview: \(held)")
            if held { print("SMOKE FAIL: the closed popover still holds its view") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let start = Self.cpuSeconds(), clock = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    let share = (Self.cpuSeconds() - start) / Date().timeIntervalSince(clock)
                    print("SMOKE idle cpu, everything closed: \(String(format: "%.1f", share * 100))%")
                    // A debug build samples every second; the release build idles near 1.5%.
                    if share > 0.06 { print("SMOKE FAIL: idle CPU above 6%") }
                    done()
                }
            }
        }
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(i + 1)) { step() }
        }
    }

    /// This process's CPU time so far (user + system), in seconds.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    /// Smoke test: where the open panel sits against its card (both in screen points), so the
    /// card-frame → screen conversion that the pointer matching shares can be checked live.
    var debugPanelState: String {
        guard let popover, popover.isShown, let part = panels.open,
            let view = popover.contentViewController?.view, let window = view.window,
            let rect = panels.cardFrames[part]
        else { return "no panel" }
        let card = view.screenRect(rect, in: window)
        func r(_ f: NSRect) -> String { "x \(Int(f.minX))…\(Int(f.maxX)) y \(Int(f.minY))…\(Int(f.maxY))" }
        return
            "\(part.rawValue) visible \(panel.isVisible) side \(panels.side) panel[\(r(panel.frame))] card[\(r(card))] popover[\(r(window.frame))] hostInWindow[\(r(view.convert(view.bounds, to: nil)))] cardLocal[\(r(rect))]"
    }
}
