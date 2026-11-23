import AppKit
import HeronCore
import HeronUI
import SwiftUI

/// A hover panel: a borderless panel that never becomes key (the popover keeps the keyboard),
/// with the popover's material, rounded corners and shadow. One hosts the open section's page
/// (`PopoverView(kind:)`) beside the popover, another a row's history (`HistoryPage`) beside that;
/// each reports the pointer entering and leaving it through `report`.
@MainActor
final class DetailPanelWindow: NSPanel {
    private let monitor: Monitor
    private let settings: AppSettings
    private let services: AppServices
    private let ai: AIUsageService
    private let panels: DetailPanels
    private let report: (DetailPanels, Bool) -> Void
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var shown: AnyHashable?
    private lazy var tracker = PointerTracker { [weak self] inside, _ in
        guard let self else { return }
        self.report(self.panels, inside)
    }

    init(
        monitor: Monitor, settings: AppSettings, services: AppServices, ai: AIUsageService, panels: DetailPanels,
        report: @escaping (DetailPanels, Bool) -> Void
    ) {
        self.monitor = monitor
        self.settings = settings
        self.services = services
        self.ai = ai
        self.panels = panels
        self.report = report
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PopoverView.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        tracker.attach(to: effect)
    }

    /// Smoke test: whether the panel still hosts a page (an emptied host measures 0 tall).
    var debugHoldsPage: Bool { host.fittingSize.height > 10 }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `content` (rebuilt only when `id` changes) and returns its size.
    func show<Content: View>(_ id: AnyHashable, _ content: () -> Content) -> NSSize {
        if shown != id {
            shown = id
            host.rootView = AnyView(content().environment(monitor).environment(settings).environment(services).environment(ai).environment(panels))
        }
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// Places the panel; one not on screen yet fades in from 40% (still with Reduce Motion), like
    /// the design's 120 ms ease-out.
    func present(at frame: NSRect) {
        let fresh = !isVisible
        // Called on every sample: an unchanged frame needs no resize and no forced redraw.
        if frame != self.frame { setFrame(frame, display: true) }
        guard fresh else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = still ? 1 : 0.4
        orderFrontRegardless()
        if !still {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    func hide() {
        orderOut(nil)
        // An ordered-out panel's SwiftUI page kept updating on every sample (0.1–0.6% CPU per panel
        // ever opened, measured 2026-11-23): drop it; `show` builds it again.
        if shown != nil {
            shown = nil
            host.rootView = AnyView(EmptyView())
        }
        // A panel hidden under the pointer sends no "exited": say so, or the hover logic would think
        // the pointer is still on it and never close the next panel when the pointer wanders off.
        let wasInside = tracker.inside
        tracker.reset()
        if wasInside { report(panels, false) }
    }
}

/// Reports the pointer entering, moving in and leaving a view, whether or not the app is active
/// (`.activeAlways`: the popover's app is usually not the active one).
@MainActor
final class PointerTracker: NSResponder {
    private let report: (Bool, NSPoint?) -> Void
    private weak var view: NSView?
    private var area: NSTrackingArea?
    private(set) var inside = false

    init(report: @escaping (Bool, NSPoint?) -> Void) {
        self.report = report
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(to view: NSView) {
        if let area, let old = self.view { old.removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        view.addTrackingArea(area)
        self.view = view
        self.area = area
    }

    func reset() { inside = false }

    override func mouseEntered(with event: NSEvent) { inside = true; report(true, location(event)) }
    override func mouseMoved(with event: NSEvent) { if inside { report(true, location(event)) } }
    override func mouseExited(with event: NSEvent) { inside = false; report(false, nil) }

    /// The pointer in the view's own coordinates, y down from its top (`PopoverRoot.space`).
    private func location(_ event: NSEvent) -> NSPoint? {
        guard let view else { return nil }
        let p = view.convert(event.locationInWindow, from: nil)
        return view.isFlipped ? p : NSPoint(x: p.x, y: view.bounds.height - p.y)
    }
}
