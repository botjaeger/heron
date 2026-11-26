import AppKit
import HeronCore
import HeronUI
import SwiftUI

/// Opens and reuses the app's windows (Settings, Welcome, What's new, About).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let monitor: Monitor
    private let settings: AppSettings
    private let services: AppServices
    private let ai: AIUsageService
    private var windows: [String: NSWindow] = [:]
    /// Privacy Mode: Settings lists account e-mail addresses, so every window Heron opens stays out
    /// of screenshots, recordings and shared screens, as the popover and its panels do
    /// (`StatusBarController.privacy`).
    var privacy = false {
        didSet { if privacy != oldValue { for window in windows.values { window.setPrivate(privacy) } } }
    }

    init(monitor: Monitor, settings: AppSettings, services: AppServices, ai: AIUsageService) {
        self.monitor = monitor
        self.settings = settings
        self.services = services
        self.ai = ai
        super.init()
        // A sheet is a window of its own and does not take its parent's sharing type: the Add
        // account sheet on Settings showed in recordings with Privacy Mode on (smoke, 2026-11-26).
        // Every Heron window's sheet follows its parent, the popover's panels' too.
        NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) { note in
            let parent = note.object as? NSWindow
            MainActor.assumeIsolated {
                // The sheet is attached right after this notification.
                DispatchQueue.main.async { if let parent { parent.setPrivate(parent.sharingType == .none) } }
            }
        }
    }

    func showSettings(_ route: SettingsRoute = SettingsRoute(.general)) {
        // A new hosting view each time so the requested pane (and Overview section) is selected.
        windows["settings"]?.close()
        // A fixed size, like macOS's own Settings windows: the panes are laid out in fixed columns
        // for 900 × 700, so a larger (or zoomed) window only left empty space (2026-11-23).
        // Long panes scroll.
        show("settings", title: "Heron Settings", sidebar: true) { SettingsView(route: route) }
    }

    func showOnboarding() { show("onboarding", title: "Welcome to Heron", untitled: true) { OnboardingView() } }
    func closeOnboarding() { windows["onboarding"]?.close() }
    func showChangelog() {
        show("changelog", title: "What’s New in Heron") { ChangelogView { [weak self] in self?.windows["changelog"]?.close() } }
    }
    func showAbout() { show("about", title: "About Heron", untitled: true) { AboutView() } }
    func showUpdate() { show("update", title: "Update Heron") { UpdateView() } }
    func closeUpdate() { windows["update"]?.close() }

    /// `sidebar`: the content runs up under a transparent title bar (Settings, as in the design:
    /// the sidebar starts at the window's top edge, the traffic lights over it).
    /// `untitled`: the same title bar without the window's title (the first run and About draw
    /// their own heading under the traffic lights).
    private func show<V: View>(
        _ id: String, title: String, sidebar: Bool = false, untitled: Bool = false,
        @ViewBuilder content: () -> V
    ) {
        // Any window still in `windows` is open (closing removes it), even one not visible: Hide
        // Heron (⌘H) orders windows out, and a second copy made then stacked on the first.
        if let existing = windows[id] {
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let root = content().environment(monitor).environment(settings).environment(services).environment(ai)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        // Every window is a fixed size (no resize, no zoom); their content scrolls where it runs long.
        window.styleMask = [.titled, .closable]
        if sidebar || untitled {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        if sidebar {
            window.contentMinSize = SettingsView.size
            window.setContentSize(SettingsView.size)
        }
        window.isReleasedWhenClosed = false
        window.setPrivate(privacy)
        window.delegate = self
        window.center()
        windows[id] = window
        // Menu bar apps are not active by default; activate so the window comes to the front.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windows.first(where: { $0.value === window })?.key
        else { return }
        if id == "onboarding" && !settings.onboardingDone { settings.onboardingDone = true }
        // Closing the update window is "Later" (its own button closes it the same way).
        if id == "update" {
            windows[id] = nil
            services.laterUpdate()
        }
        // A closed window kept its SwiftUI view alive, and a hidden Settings on Menu Bar re-rendered
        // its previews on every sample. Every open builds a fresh window, so let this one go.
        windows[id] = nil
        DispatchQueue.main.async { window.contentViewController = nil }
    }
}

extension NSWindow {
    /// Privacy Mode for this window and the sheet on it (a sheet is a window of its own):
    /// `sharingType` .none keeps them out of screenshots, recordings and shared screens.
    func setPrivate(_ on: Bool) {
        let type: NSWindow.SharingType = on ? .none : .readOnly
        for window in [self, attachedSheet].compactMap({ $0 }) where window.sharingType != type { window.sharingType = type }
    }
}
