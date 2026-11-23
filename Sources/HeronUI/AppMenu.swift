import AppKit

/// The app's main menu. A menu bar app never shows it, but AppKit routes key equivalents through
/// it: without an Edit menu, ⌘C / ⌘V / ⌘A did nothing in the alert limit field, and without a
/// Window menu ⌘W did not close Settings.
@MainActor
public enum AppMenu {
    public static func make() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            return entry
        }
        submenu(
            "Heron",
            [
                item("Hide Heron", #selector(NSApplication.hide(_:)), "h"),
                .separator(),
                item("Quit Heron", #selector(NSApplication.terminate(_:)), "q"),
            ])
        submenu(
            "Edit",
            [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
            ])
        submenu(
            "Window",
            [
                item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                item("Close", #selector(NSWindow.performClose(_:)), "w"),
            ])
        return main
    }
}

/// The menu a right-click on Heron's menu bar item opens, ordered by use: Settings first, Quit last.
@MainActor
public enum StatusMenu {
    public enum Entry: CaseIterable, Sendable {
        case settings, activityMonitor, checkForUpdates, whatsNew, about, quit

        public var title: String {
            switch self {
            case .settings: return "Settings…"
            case .activityMonitor: return "Open Activity Monitor"
            case .checkForUpdates: return "Check for Updates…"
            case .whatsNew: return "What’s New"
            case .about: return "About Heron"
            case .quit: return "Quit Heron"
            }
        }

        /// The ⌘ shortcut shown beside it.
        public var key: String {
            switch self {
            case .settings: return ","
            case .quit: return "q"
            default: return ""
            }
        }
    }

    /// The entries in order; nil is a separator.
    public static let layout: [Entry?] = [.settings, .activityMonitor, nil, .checkForUpdates, .whatsNew, .about, nil, .quit]

    /// The menu, each entry sending its `action` to `target`. An entry whose action is nil is greyed
    /// out (Check for Updates… in a build without updates).
    public static func make(target: AnyObject, action: (Entry) -> Selector?) -> NSMenu {
        let menu = NSMenu()
        for entry in layout {
            guard let entry else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: action(entry), keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = .command
            item.target = target
            menu.addItem(item)
        }
        return menu
    }
}
