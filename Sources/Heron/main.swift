import AppKit
import HeronCore
import HeronUI

// `Heron usage --json` prints the last AI usage readings and exits before any UI starts: no
// refresh, no token read (exit 4 when nothing has been fetched yet).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "usage" {
    guard CommandLine.arguments.dropFirst(2).contains("--json") else {
        FileHandle.standardError.write(Data("usage: Heron usage --json\n".utf8))
        exit(2)
    }
    let (json, status) = AIUsageExport.run(defaults: .standard)
    print(json)
    if status != 0 { FileHandle.standardError.write(Data("Heron has no AI usage readings yet.\n".utf8)) }
    exit(status)
}

// `Heron changelog --notes <version>` prints that release's notes as the update feed carries them
// (`ReleaseNotes`), for scripts/release.sh; exit 1 when Changelog.entries has no such release.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "changelog" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count == 2, args[0] == "--notes" else {
        FileHandle.standardError.write(Data("usage: Heron changelog --notes <version>\n".utf8))
        exit(2)
    }
    guard let html = ReleaseNotes.html(for: args[1]) else {
        FileHandle.standardError.write(Data("Changelog.entries has no entry for \(args[1]).\n".utf8))
        exit(1)
    }
    print(html)
    exit(0)
}

// Entry point. Heron is a plain AppKit app (no Dock icon) whose windows are SwiftUI views.
// An AppKit entry point gives full control over the status bar items: their order,
// their images and their popovers.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only; Info.plist also sets LSUIElement
    app.mainMenu = AppMenu.make()  // never shown, but carries ⌘C/⌘V/⌘W/⌘Q for the windows
    // `delegate` stays alive because app.run() never returns while the app runs.
    withExtendedLifetime(delegate) { app.run() }
}
