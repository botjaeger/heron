import AppKit
import HeronCore
import HeronUI
import SwiftUI

/// Owns Heron's ONE status item (the icon in the menu bar) and its popover.
/// The item shows the Heron mark, followed by whichever metrics the user enabled in
/// Settings › Menu Bar; clicking it opens the overview popover (every section, Settings › Overview order).
/// AppKit is used directly instead of SwiftUI's MenuBarExtra for control over the image,
/// the right-click menu and the popover.
///
/// Resting the pointer on an overview card opens that section's panel beside the popover
/// (`DetailPanels` decides when, `DetailPanelWindow` shows it). The popover closes itself on a
/// click outside the popover, its panel and the item (not `.transient`, which would close it on a
/// click in the panel).
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let monitor: Monitor
    private let settings: AppSettings
    private let services: AppServices
    let ai: AIUsageService
    private(set) var item: NSStatusItem?
    private(set) var popover: NSPopover?
    let panels = DetailPanels()
    private(set) lazy var panel = DetailPanelWindow(monitor: monitor, settings: settings, services: services, ai: ai, panels: panels) { $0.pointerInPanel($1) }
    /// A row's history, beside the panel like a submenu.
    private(set) lazy var historyPanel = DetailPanelWindow(monitor: monitor, settings: settings, services: services, ai: ai, panels: panels) { $0.pointerInHistory($1) }
    private lazy var popoverTracker = PointerTracker { [weak self] _, point in self?.panels.pointerInPopover(point) }
    private var monitors: [Any] = []
    /// While the popover is open: display changes (`screensChanged`).
    private var screenObserver: (any NSObjectProtocol)?
    /// What the item's image was last drawn from (`MenuBarLabel.renderKey`); nil while it shows the bare mark.
    private var renderedKey: MenuBarLabel.RenderKey?
    /// Privacy Mode (Settings › AI Usage): the item, the popover and its panels stay out of screen
    /// recordings and shared screens.
    var privacy = false {
        didSet { if privacy != oldValue { applyPrivacy() } }
    }

    init(monitor: Monitor, settings: AppSettings, services: AppServices, ai: AIUsageService) {
        self.monitor = monitor
        self.settings = settings
        self.services = services
        self.ai = ai
        super.init()
        panels.visibleParts = { [weak settings, weak monitor, weak ai] in
            guard let settings, let monitor else { return [] }
            return DetailPanels.visibleParts(
                order: settings.overviewOrder, hidden: settings.hiddenSections, snapshot: monitor.snapshot,
                ai: !(ai?.accounts.isEmpty ?? true))
        }
        panels.onChange = { [weak self] in self?.placePanel() }
    }

    /// Creates the status item and its popover (once), then draws it.
    func rebuild() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageOnly
            item.button?.setAccessibilityLabel("Heron")
            self.item = item

            let popover = NSPopover()
            popover.behavior = .applicationDefined  // closed by `watchOutsideClicks`, see the type's comment
            popover.animates = false
            popover.delegate = self
            // Empty until shown: the overview is set in `showPopover` and dropped in `popoverDidClose`.
            let controller = NSHostingController(rootView: AnyView(EmptyView()))
            controller.sizingOptions = .preferredContentSize  // popover follows the SwiftUI size
            popover.contentViewController = controller
            popoverTracker.attach(to: controller.view)
            self.popover = popover
            applyPrivacy()
        }
        update()
    }

    /// `sharingType` .none keeps a window out of screenshots, recordings and screen sharing. The
    /// status item's own window ignores it (macOS 27.2 reads back `.readOnly` right after the set,
    /// measured 2026-11-26), so the menu bar item stays visible; it shows no account names.
    private func applyPrivacy() {
        for window in [popover?.contentViewController?.view.window, panel, historyPanel, item?.button?.window] {
            window?.setPrivate(privacy)
        }
    }

    /// The global shortcut and a clicked AI notification: opens the popover with the AI usage panel.
    /// `toggle`: a second press closes it.
    /// With no account yet there is no panel, so Settings › AI Usage opens instead.
    func showAIPanel(toggle: Bool) {
        guard let popover, let button = item?.button else { return }
        if toggle, popover.isShown { closePopovers(); return }
        guard !ai.accounts.isEmpty else { services.openSettings(.aiUsage()); return }
        if !popover.isShown {
            showPopover(popover, from: button)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
        panels.openNow(.ai)
    }

    // MARK: Hover panel

    /// Shows, moves or hides the panel to match `panels`. Called when it opens, switches or shows a
    /// history, and after every sample (its height follows the readings).
    private func placePanel() {
        guard let popover, popover.isShown, let part = panels.open,
            let view = popover.contentViewController?.view, let window = view.window
        else {
            historyPanel.hide()
            panel.hide()
            return
        }
        let size = panel.show(PopoverKind(part)) { PopoverView(kind: PopoverKind(part)) }
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        // The card's frame: `PopoverRoot.space` (the hosting view, y down) to screen.
        let card = panels.cardFrames[part].map { view.screenRect($0, in: window) }
        let placed = PanelPlacement.frame(size: size, popover: window.frame, card: card, visible: visible)
        panels.side = placed.side
        panel.present(at: placed.frame)
        placeHistory(popover: window.frame, visible: visible)
    }

    /// Shows, moves or hides the history beside the panel, its title level with its row.
    private func placeHistory(popover: NSRect, visible: NSRect) {
        guard let item = panels.history, panel.isVisible, let content = panel.contentView else {
            historyPanel.hide()
            return
        }
        let size = historyPanel.show(item) { HistoryPage(item: item) }
        // The row's frame: `DetailPanels.space` (the panel's hosting view, which fills its content
        // view; y down) to screen.
        let row = panels.historyFrames[item].map { content.screenRect($0, in: panel) }
        historyPanel.present(
            at: PanelPlacement.historyFrame(
                size: size, panel: panel.frame, popover: popover, row: row,
                side: panels.side, visible: visible))
    }

    func popoverDidClose(_ notification: Notification) {
        stopWatching()
        panels.closeAll()
        historyPanel.hide()
        panel.hide()
        // A closed popover's window stays alive, ordered out, and its SwiftUI view kept updating:
        // every card on each sample and the spinning fan at 30 fps, ~24% CPU with the popover
        // closed (measured 2026-11-23). Drop the view; `showPopover` builds it again.
        hostingController?.rootView = AnyView(EmptyView())
    }

    var hostingController: NSHostingController<AnyView>? { popover?.contentViewController as? NSHostingController<AnyView> }

    /// The overview the popover shows while open.
    private var overview: AnyView {
        AnyView(PopoverRoot().environment(monitor).environment(settings).environment(services).environment(ai).environment(panels))
    }

    /// While the popover is shown: a click anywhere but the popover, its panel or the item closes
    /// it; the arrow keys, Return and Esc drive the overview (see `DetailPanels.handle`).
    private func watchOutsideClicks() {
        stopWatching()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: clicks,
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let popover = self.popover else { return }
                    let ours = [popover.contentViewController?.view.window, self.panel, self.historyPanel, self.item?.button?.window]
                    if !ours.contains(where: { $0 != nil && $0 === event.window }) { self.closePopovers() }
                }
                return event
            })
        {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: clicks,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.closePopovers() }
            })
        {
            monitors.append(global)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) ?? false } ? nil : event
            })
        {
            monitors.append(keys)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func stopWatching() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Returns true when the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let popover, popover.isShown, event.window === popover.contentViewController?.view.window,
            event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        else { return false }
        let key: PanelKey? =
            switch event.keyCode {
            case 126: .up
            case 125: .down
            case 123: .left
            case 124: .right
            case 36, 76: .enter
            case 53: .escape
            default: nil
            }
        guard let key else { return false }
        if panels.handle(key) { return true }
        if key == .escape { closePopovers(); return true }  // no panel open: Esc closes the popover
        return false
    }

    /// Redraws the item. Called after each sample.
    func update() {
        if panels.open != nil { placePanel() }  // its height follows the readings
        guard let button = item?.button else { return }
        if settings.shownItems.isEmpty {  // nothing shown: the icon is drawn whatever "Show icon" says
            // Icon only: a fixed template image, nothing to re-render every second.
            if button.image !== Self.markImage { button.image = Self.markImage }
            renderedKey = nil
            if button.accessibilityValue() != nil { button.setAccessibilityValue(nil) }
            if button.toolTip != nil { button.toolTip = nil }
            return
        }
        // A template image cannot hold the warning red or metric colours, so a coloured image is
        // drawn in the menu bar's own ink (and the colours' half for that menu bar) instead of
        // being re-tinted by macOS.
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var label = MenuBarLabel(snapshot: monitor.snapshot, history: monitor.history, settings: settings, ai: ai)
        if label.isColoured { label.ink = dark ? .white : .black; label.dark = dark }
        // The menu bar's own screen: a Retina laptop beside a 1x display draws each at its scale.
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Most samples change nothing the item draws ("CPU 16%" stays 16%): skip the render.
        let key = label.renderKey(scale: scale)
        if key != renderedKey {
            button.image = MenuBarRenderer.image(for: label, scale: scale)
            renderedKey = key
        }
        let spoken = label.spokenValue
        if button.accessibilityValue() as? String != spoken { button.setAccessibilityValue(spoken) }
        // The hottest sensor's full name: the bar shows only its group ("CPU ▲81°").
        let tip = label.toolTip
        if button.toolTip != tip { button.toolTip = tip }
    }

    /// Opens the popover with the panel machinery running.
    func showPopover(_ popover: NSPopover, from button: NSStatusBarButton) {
        capHeights(for: button)
        hostingController?.rootView = overview
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let window = popover.contentViewController?.view.window else { return }
        applyPrivacy()  // the popover's window exists only once it is shown
        window.acceptsMouseMovedEvents = true
        panels.side = PanelPlacement.side(width: PopoverView.width, popover: window.frame, visible: (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame)
        watchOutsideClicks()
    }

    /// Taller than the screen, macOS cut the popover's top off: cap it (and the panels beside it)
    /// so the cards scroll. 30 pt: the popover's arrow and a margin under the menu bar.
    private func capHeights(for button: NSStatusBarButton) {
        guard let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame else { return }
        panels.popoverMaxHeight = visible.height - 30
        panels.panelMaxHeight = visible.height - 16
    }

    /// A display added, removed or rearranged while the popover is open: the menu bar may now be on
    /// a smaller screen, so the caps and the panels' places are worked out again.
    private func screensChanged() {
        guard let popover, popover.isShown, let button = item?.button else { return }
        capHeights(for: button)
        placePanel()
    }

    nonisolated override var debugDescription: String { MainActor.assumeIsolated { statusDescription } }
    private var statusDescription: String {
        guard let image = item?.button?.image else { return "heron[none]" }
        return "heron[\(Int(image.size.width))x\(Int(image.size.height))\(image.isTemplate ? " template" : "")]"
    }

    func closePopovers() {
        if popover?.isShown == true { popover?.performClose(nil) }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let item, let popover else { return }
        // Right-click (or control-click): the classic app menu.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            closePopovers()
            showMenu(for: item)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(popover, from: sender)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu(for item: NSStatusItem) {
        let updates = services.updaterAvailable
        let menu = StatusMenu.make(target: self) { entry in
            switch entry {
            case .settings: return #selector(menuSettings)
            case .activityMonitor: return #selector(menuActivityMonitor)
            case .checkForUpdates: return updates ? #selector(menuUpdates) : nil
            case .whatsNew: return #selector(menuChangelog)
            case .about: return #selector(menuAbout)
            case .quit: return #selector(menuQuit)
            }
        }
        // Attaching a menu and clicking shows it under the item; detach so left-click opens the popover again.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func menuAbout() { services.showAbout() }
    @objc private func menuChangelog() { services.showChangelog() }
    @objc private func menuUpdates() { services.checkForUpdates() }
    @objc private func menuSettings() { services.openSettings(SettingsRoute(.menuBar)) }
    @objc private func menuActivityMonitor() { services.openActivityMonitor() }
    @objc private func menuQuit() { services.quit() }

    /// Template version of the mark for the menu bar (same drawing as `HeronGlyph`).
    static let markImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 100, y: rect.height / 100)
            context.setFillColor(NSColor.black.withAlphaComponent(HeronShape.glyphTrackOpacity).cgColor)
            context.addPath(HeronShape.parts(glyph: true).track)
            context.fillPath()
            context.setFillColor(NSColor.black.cgColor)
            for part in HeronShape.glyphSolid { context.addPath(part) }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

extension NSView {
    /// A frame read in this view's SwiftUI space (a named coordinate space; y down from the top)
    /// as screen points: a card for its panel, a row for its history, the smoke test's report.
    func screenRect(_ rect: NSRect, in window: NSWindow) -> NSRect {
        let local = isFlipped ? rect : NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(convert(local, to: nil))
    }
}
