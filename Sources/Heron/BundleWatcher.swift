import AppKit

/// Reloads Heron when its installed copy is replaced (`packaging/install.sh` swaps in a new build):
/// every 2 s it compares its executable on disk with the one it launched from, and when that file
/// changes it starts the new copy once this one has quit, then quits. Only for an .app bundle
/// (`swift run` and the tests have none). Sparkle's own updates relaunch through Sparkle.
@MainActor
final class BundleWatcher {
    private let bundle = Bundle.main.bundleURL
    private let executable = Bundle.main.executableURL
    private var launched: (inode: UInt64, modified: Date)?
    private var timer: Timer?
    private var relaunching = false

    func start() {
        guard bundle.pathExtension == "app", let executable, let id = Self.identity(executable) else { return }
        launched = id
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // A reload a second late is fine; the slack lets macOS batch this wake with others.
        timer?.tolerance = 1
    }

    static func identity(_ url: URL) -> (inode: UInt64, modified: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
            let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value, let modified = a[.modificationDate] as? Date
        else { return nil }
        return (inode, modified)
    }

    private func check() {
        guard !relaunching, let executable, let launched else { return }
        // Mid-copy the executable can be missing: wait for the next tick.
        guard let now = Self.identity(executable), now.inode != launched.inode || now.modified != launched.modified else { return }
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then open the new copy.
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundle.path]
        do {
            try relaunch.run()
        } catch {
            // Nothing would start the new copy: quitting now would leave no Heron at all. Keep
            // running this one, and stop watching this build (the next install is a new one).
            NSLog("Heron: could not start the new copy (\(error.localizedDescription)); keeping this one")
            self.launched = now
            return
        }
        relaunching = true
        // AppKit declines `terminate` while a sheet is attached (seen 2026-11-22 with Settings'
        // "Couldn't sign in" sheet up): close sheets first, and exit outright if it still declines.
        // Settings are already saved (UserDefaults writes as they change).
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UserDefaults.standard.synchronize()
            exit(0)
        }
    }
}
