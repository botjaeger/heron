import HeronCore
import SwiftUI

// MARK: - About

/// The About window: the mark, name and version (once), Check for Updates with its result in
/// place, the website and the third-party notices, three facts, and the legal lines.
public struct AboutView: View {
    @Environment(AppServices.self) private var services
    @State private var showsNotices = false
    /// heron-snap: the notices drawn in place of the window (a sheet cannot be rendered off screen).
    var noticesOnly = false
    public init() {}
    public init(noticesOnly: Bool) { self.noticesOnly = noticesOnly }

    /// The window's size, as in the design.
    public static let size = CGSize(width: 440, height: 560)

    /// The line under the buttons: Settings › Updates' status ("Heron is up to date · checked just
    /// now", "Last checked today at 09:12"), or that this build cannot update. `upToDate` draws it
    /// green with a tick: only when the last check really found nothing.
    static func updateLine(available: Bool, checking: Bool, lastCheck: Date?, foundNothing: Bool, now: Date = Date()) -> (text: String, upToDate: Bool) {
        guard available else { return ("Updates are off in this build", false) }
        return (
            UpdatesPane.status(checking: checking, lastCheck: lastCheck, foundNothing: foundNothing, now: now),
            !checking && foundNothing && lastCheck != nil
        )
    }

    public var body: some View {
        if noticesOnly { AcknowledgementsView(onDone: {}) } else { window }
    }

    private var window: some View {
        let available = services.updaterAvailable
        let update = services.update
        let checked = Self.updateLine(
            available: available, checking: services.checkingForUpdates,
            lastCheck: services.lastUpdateCheck, foundNothing: services.lastCheckFoundNothing)
        // An update under way says so here too, in Settings › Updates' words.
        let line = available ? (update.statusLine.map { (text: $0, upToDate: false) } ?? checked) : checked
        return VStack(spacing: 0) {
            HeronMark(size: 88)
            Text("Heron").font(.system(size: 24, weight: .bold)).tracking(-0.3).padding(.top, 12)
            Text("Version \(services.appVersion) (\(services.buildNumber))").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                .padding(.top, 2)
            Text("Everything your Mac is doing, one glance away.").font(.system(size: 13)).multilineTextAlignment(.center)
                .padding(.top, 8)
            HStack(spacing: 8) {
                if update.waiting != nil {
                    Button(update.menuTitle) { services.showUpdate() }
                } else {
                    Button(services.checkingForUpdates ? "Checking…" : "Check for Updates") {
                        services.checkingForUpdates = true
                        services.checkForUpdates()
                    }
                    .disabled(!available || services.checkingForUpdates)
                }
                Button("Website") { services.openURL(AppServices.website) }
                Button("Acknowledgements") { showsNotices = true }
            }
            .controlSize(.large)
            .padding(.top, 16)
            HStack(spacing: 5) {
                if line.upToDate { HeronIconView(.check, size: 12, weight: 2.2).accessibilityHidden(true) }
                Text(line.text).monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(line.upToDate ? Theme.memory : Theme.muted)
            .frame(height: 16)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            SettingsCard {
                FactRow(title: "This Mac", value: SystemInfo.friendlyName, first: true)
                FactRow(title: "Requires", value: "macOS 14 or later · Apple silicon")
                FactRow(title: "Licence", value: "MIT · © 2026 botjaeger")
            }
            .padding(.top, 14)
            Spacer(minLength: 12)
            Text(AppServices.legal)
                .font(.system(size: 11)).lineSpacing(2).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        // Room for the traffic lights over the content (the window has no title bar of its own).
        .padding(.top, 40).padding(.horizontal, 28).padding(.bottom, 22)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.settingsWindow)
        .sheet(isPresented: $showsNotices) { AcknowledgementsView { showsNotices = false } }
    }
}

/// About › Acknowledgements: the projects Heron's research builds on, and every third-party
/// licence Heron ships (Sparkle's, verbatim).
struct AcknowledgementsView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Acknowledgements").font(.system(size: 15, weight: .bold))
            Text(Acknowledgements.thanks).font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            SettingsCaption("Sparkle · software updates").padding(.top, 14)
            // The licence's own line breaks, never re-wrapped (a re-wrap leaves "do so," alone on a line).
            ScrollView([.vertical, .horizontal]) {
                Text(Acknowledgements.sparkle).font(.system(size: 11)).textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
            .padding(.top, 6)
            HStack {
                Spacer()
                Button("Done", action: onDone).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 540, height: 460)
        .background(Theme.settingsWindow)
    }
}
