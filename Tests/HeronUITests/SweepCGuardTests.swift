import AppKit
import Foundation
import Testing

// Guards for the classes found by sweep C (the app target, recovery, long runs and the docs), listed
// in docs/workstreams/heron-redesign-defect-classes.md. The app target (`Heron`) is an executable
// the tests cannot import, so these read its source.

/// A file of the package, read from its root (`docs.md`, `scripts/check.sh`, …).
private func packageFile(_ path: String) throws -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path), dir.path != "/" { dir.deleteLastPathComponent() }
    return try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
}

/// The text of `func name(` in `text`, from its line to its closing brace; nil when there is none.
private func body(of name: String, in text: String) -> String? {
    guard let start = text.range(of: "func \(name)(") else { return nil }
    var depth = 0
    var opened = false
    var index = start.lowerBound
    while index < text.endIndex {
        let c = text[index]
        if c == "{" { depth += 1; opened = true }
        if c == "}" { depth -= 1 }
        index = text.index(after: index)
        if opened && depth == 0 { return String(text[start.lowerBound..<index]) }
    }
    return nil
}

private func appSource(_ file: String) -> String? { sourceFiles("Heron").first { $0.name == file }?.text }

@Suite struct SweepCGuardTests {
    /// Class: work retried every sample after it failed. `applySettings` runs after every sample,
    /// so each step it drives must compare with what was last asked for, not with what last
    /// worked: a global shortcut another app holds was registered again (and logged) every second,
    /// and an appearance is compared by name (AppKit hands back one cached instance per name
    /// today, measured 2026-11-25, but does not promise it; a miss would redraw every window).
    @Test func perSampleStepsCompareWithWhatWasAsked() throws {
        let hotKey = try #require(appSource("HotKey.swift"))
        let set = try #require(body(of: "set", in: hotKey))
        let firstGuard = try #require(set.split(separator: "\n").first { $0.contains("guard ") })
        #expect(firstGuard.contains("requested"), "GlobalHotKey.set must skip a shortcut already asked for, registered or not")
        #expect(!firstGuard.contains("registered"), "GlobalHotKey.set compares with the last registered shortcut: a taken one is retried every sample")

        let delegate = try #require(appSource("AppDelegate.swift"))
        let apply = try #require(body(of: "applySettings", in: delegate))
        for line in apply.split(separator: "\n") where line.contains("NSApp.appearance") && line.contains("!=") {
            #expect(line.contains(".name"), "the appearance is compared by instance every sample: \(line)")
        }
        // Every assignment there is guarded by a comparison, or goes through a setter that compares.
        for line in apply.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard line.contains(" = "), !line.hasPrefix("let "), !line.hasPrefix("//"), !line.hasPrefix("case ") else { continue }
            let compared = line.hasPrefix("if ") && line.contains("!=")
            #expect(compared || line.hasPrefix("statusBar.privacy =") || line.hasPrefix("windows.privacy ="), "unguarded per-sample assignment: \(line)")
        }
        let status = try #require(appSource("StatusBarController.swift"))
        #expect(status.contains("didSet { if privacy != oldValue"), "StatusBarController.privacy must ignore an unchanged value")
        let windows = try #require(appSource("WindowManager.swift"))
        #expect(windows.contains("didSet { if privacy != oldValue"), "WindowManager.privacy must ignore an unchanged value")
    }

    /// Class: a second copy of a window. Every window `WindowManager` keeps is open (closing
    /// removes it), so it is reused whether or not it is visible: after Hide Heron (⌘H) a
    /// visibility check made a second About or What's New that stacked on the first when shown.
    @Test func anOpenWindowIsReusedWhenHidden() throws {
        let manager = try #require(appSource("WindowManager.swift"))
        let show = try #require(body(of: "show<V: View>", in: manager) ?? body(of: "show", in: manager))
        let reuse = try #require(show.split(separator: "\n").first { $0.contains("windows[id]") && $0.contains("if let") })
        #expect(!reuse.contains("isVisible"), "a hidden window is not reused: \(reuse)")
        #expect(show.contains("unhide"), "reusing a window of a hidden app must unhide it")
    }

    /// Class: a notification dropped while Heron is the active app. Without `willPresent`, macOS
    /// shows nothing for an app in front (Settings open, the popover key).
    @Test func notificationsShowWhileHeronIsActive() {
        for (name, text) in sourceFiles("Heron") where text.contains("UNUserNotificationCenterDelegate") {
            #expect(text.contains("willPresent notification: UNNotification"), "\(name) is a notification delegate without willPresent")
        }
    }

    /// Class: a failure swallowed where the next step depends on it. `try? relaunch.run()` then
    /// quit: a reload that could not start the new copy left no Heron running. In the app target a
    /// `try?` only ever produces a value that is checked, never a discarded statement.
    @Test func noDiscardedTryInTheApp() {
        for (name, text) in sourceFiles("Heron") {
            for line in text.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("try? ") {
                Issue.record("\(name): a discarded try? hides a failure: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// Class: a size taken from a screen once. The popover's and panels' height caps come from the
    /// menu bar's screen; a display removed or changed while the popover is open sizes them again.
    /// Every app file that reads `visibleFrame` follows display changes.
    @Test func screenSizesFollowDisplayChanges() throws {
        for (name, text) in sourceFiles("Heron") where text.contains(".visibleFrame") {
            #expect(text.contains("didChangeScreenParametersNotification"), "\(name) sizes from a screen but never hears it change")
        }
        let status = try #require(appSource("StatusBarController.swift"))
        let stop = try #require(body(of: "stopWatching", in: status))
        #expect(stop.contains("removeObserver"), "the display observer outlives the popover")
    }

    /// Class: orphaned code (the HeronUI half is `NoOrphanedTypesTests`). Every function the app
    /// target declares is called, selected or overridden somewhere: `AlertCenter.notify` was never
    /// called. Delegate and override methods are called by AppKit.
    @Test func everyAppFunctionIsUsed() throws {
        let files = sourceFiles("Heron")
        let all = files.map(\.text).joined(separator: "\n")
        let declaration = try Regex(#"func ([A-Za-z_][A-Za-z0-9_]*)"#)
        let calledByTheSystem: Set<String> = [
            "applicationDidFinishLaunching", "userNotificationCenter", "windowWillClose", "popoverDidClose", "allowedChannels",
            "updaterDidNotFindUpdate", "updater",
            // SPUUserDriver: Sparkle calls every one (HeronUserDriver).
            "show", "showUserInitiatedUpdateCheck", "showUpdateFound", "showUpdateReleaseNotes", "showUpdateReleaseNotesFailedToDownloadWithError",
            "showUpdateNotFoundWithError", "showUpdaterError", "showDownloadInitiated", "showDownloadDidReceiveExpectedContentLength",
            "showDownloadDidReceiveData", "showDownloadDidStartExtractingUpdate", "showExtractionReceivedProgress", "showReady",
            "showInstallingUpdate", "showUpdateInstalledAndRelaunched", "showUpdateInFocus", "dismissUpdateInstallation",
        ]
        for (name, text) in files {
            for line in text.split(separator: "\n") where !line.contains("override ") && !line.contains("@objc") {
                guard let match = try declaration.firstMatch(in: String(line)), let found = match.output[1].substring else { continue }
                let fn = String(found)
                if calledByTheSystem.contains(fn) { continue }
                // A call (`name(`, a trailing closure `name {`) or a selector; the declaration counts once.
                // Simple word boundaries: Unicode's keep "panel.hide" one word.
                let uses = try Regex("\\b\(fn)\\s*[({]|#selector\\(\(fn)\\b").wordBoundaryKind(.simple)
                let count = all.matches(of: uses).count
                #expect(count >= 2, "\(name): \(fn) is declared but never used")
            }
        }
    }

    /// Class: docs that drift from the tree. AGENTS.md's layout names every AI file and every app
    /// file; docs.md's Checks lists every step `scripts/check.sh` runs.
    @Test func docsNameWhatTheTreeHas() throws {
        let agents = try packageFile("AGENTS.md")
        for target in ["HeronCore", "HeronUI"] {
            for (name, _) in sourceFiles(target) where name.hasPrefix("AI") {
                #expect(agents.contains("`\(name.dropLast(6))`"), "AGENTS.md's layout table does not name \(target)/\(name)")
            }
        }
        for (name, _) in sourceFiles("Heron") where name != "main.swift" {
            #expect(agents.contains("`\(name.dropLast(6))"), "AGENTS.md's layout table does not name Heron/\(name)")
        }

        let check = try packageFile("scripts/check.sh")
        let docs = try packageFile("docs.md")
        // What docs.md's Checks table says for each function check.sh runs as a gate step.
        let documented = [
            "format_lint": "swift format lint --strict", "swiftlint_lint": "swiftlint lint --strict", "site_links": "Site links",
            "build_debug": "`swift build`", "build_release": "swift build -c release", "run_tests": "`swift test`",
            "run_snap": "swift run heron-snap", "fix_format": "`--fix`", "fix_lint": "`--fix`",
        ]
        let step = try Regex(#"^\s*step "[^"]+" ([a-z_]+)"#).anchorsMatchLineEndings()
        let steps = check.matches(of: step).compactMap { $0.output[1].substring.map(String.init) }
        #expect(steps.count >= 7, "found \(steps.count) gate steps in check.sh")
        for fn in steps {
            let phrase = try #require(documented[fn], "check.sh runs \(fn), which this guard does not know: add it to docs.md's Checks and here")
            #expect(docs.contains(phrase), "docs.md's Checks does not list check.sh's \(fn) (\(phrase))")
        }
    }
}
