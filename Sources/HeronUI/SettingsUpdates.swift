import HeronCore
import SwiftUI

// MARK: - Updates

/// Settings › Updates: this version and whether it is the newest, Check Now, then the automatic
/// update switches (installing needs checking) and the channel, with one line on what happens.
struct UpdatesPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services

    /// The status line under the version. "Up to date" only when the last check really found
    /// nothing; otherwise it says when Heron last looked.
    static func status(checking: Bool, lastCheck: Date?, foundNothing: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        if checking { return "Checking for updates…" }
        guard let lastCheck else { return "Not checked yet" }
        let when: String
        if now.timeIntervalSince(lastCheck) < 60 {
            when = "just now"
        } else if calendar.isDate(lastCheck, inSameDayAs: now) {
            when = "today at \(lastCheck.formatted(date: .omitted, time: .shortened))"
        } else if calendar.isDateInYesterday(lastCheck) {
            when = "yesterday at \(lastCheck.formatted(date: .omitted, time: .shortened))"
        } else {
            when = "on \(lastCheck.formatted(date: .abbreviated, time: .shortened))"
        }
        return foundNothing ? "Heron is up to date · checked \(when)" : "Last checked \(when)"
    }

    enum Does { case check, install, restart, none }

    /// The main button: Check Now with nothing waiting, Install Update for a waiting version,
    /// Restart Heron Now once it is downloaded, and a busy title while it works.
    static func action(_ update: UpdateState, checking: Bool) -> (title: String, does: Does) {
        switch update {
        case .available: ("Install Update", .install)
        case .downloading: ("Downloading…", .none)
        case .preparing: ("Preparing…", .none)
        case .ready: ("Restart Heron Now", .restart)
        case .installing: ("Installing…", .none)
        case .checking: ("Checking…", .none)
        case .idle, .failed: checking ? ("Checking…", .none) : ("Check Now", .check)
        }
    }

    /// The two switches after "Check for updates automatically" is set: installing needs checking,
    /// so turning checks off turns installing off too.
    static func switches(settingChecks checks: Bool, installs: Bool) -> (checks: Bool, installs: Bool) { (checks, checks && installs) }

    /// The one line under the switches: what happens when an update comes out.
    static func flowHint(checks: Bool, installs: Bool) -> String {
        if !checks { return "Heron will not look for updates. Use Check Now when you want one." }
        return installs
            ? "When an update comes out, Heron installs it the next time you quit. What’s New shows what changed."
            : "When an update comes out, Heron marks its menu bar icon and asks before installing."
    }

    var body: some View {
        @Bindable var settings = settings
        let available = services.updaterAvailable
        let checks = services.automaticallyChecksForUpdates
        let installs = checks && services.automaticallyDownloadsUpdates
        let update = services.update
        let upToDate = update.offer == nil && !services.checkingForUpdates && services.lastCheckFoundNothing && services.lastUpdateCheck != nil
        let action = Self.action(update, checking: services.checkingForUpdates)
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(pane: .updates)
            if !available {
                // Without a signing key Sparkle never starts; switches that cannot change anything stay off.
                Text("Updates are off in this build. It was made without an update feed and signing key.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            SettingsGroup("This Mac") {
                HStack(spacing: 12) {
                    HeronMark(size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Heron \(services.appVersion) (\(services.buildNumber))").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        HStack(spacing: 6) {
                            Circle().fill(update.offer != nil ? Theme.accent : (upToDate ? Theme.memory : Theme.muted)).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(
                                update.statusLine
                                    ?? Self.status(checking: services.checkingForUpdates, lastCheck: services.lastUpdateCheck, foundNothing: services.lastCheckFoundNothing)
                            )
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer(minLength: 8)
                    if let offer = update.offer {
                        Button("What’s New in \(offer.version)…") { services.showUpdate() }
                    } else {
                        Button("What’s New…") { services.showChangelog() }
                    }
                    Button(action.title) {
                        switch action.does {
                        case .check:
                            services.checkingForUpdates = true
                            services.checkForUpdates()
                        case .install: services.installUpdate()
                        case .restart: services.restartToUpdate()
                        case .none: break
                        }
                    }
                    .frame(minWidth: 96)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!available || action.does == .none)
                }
                .padding(14)
                if let progress = update.progress {
                    ProgressView(value: progress).padding(.leading, 66).padding(.trailing, 14).padding(.bottom, 14)
                        .accessibilityLabel(update.statusLine ?? "Downloading")
                }
            }
            SettingsGroup("Automatic updates") {
                SettingsRow(
                    title: "Check for updates automatically",
                    subtitle: "Once a day, in the background. Updates are signed, so only real ones install.", first: true, minHeight: 52
                ) {
                    SettingsSwitch(
                        title: "Check for updates automatically",
                        isOn: Binding(
                            get: { checks },
                            set: { on in
                                let next = Self.switches(settingChecks: on, installs: services.automaticallyDownloadsUpdates)
                                services.setAutomaticChecks(next.checks)
                                if next.installs != services.automaticallyDownloadsUpdates { services.setAutomaticDownloads(next.installs) }
                            }))
                }
                SettingsRow(
                    title: "Install updates automatically",
                    subtitle: checks ? "Downloads in the background and installs the next time you quit Heron" : "Needs “Check for updates automatically”",
                    minHeight: 52, indent: 16
                ) {
                    SettingsSwitch(title: "Install updates automatically", isOn: Binding(get: { installs }, set: { services.setAutomaticDownloads($0) }))
                        .disabled(!checks)
                }
                .foregroundStyle(checks ? Color.primary : Theme.muted)
                SettingsRow(title: "Channel", subtitle: settings.betaUpdates ? "New features earlier; may have rough edges" : "Tested releases only", minHeight: 52) {
                    SettingsSegments(title: "Channel", selection: $settings.betaUpdates, options: [(false, "Stable"), (true, "Beta")])
                }
            }
            .disabled(!available)
            Text(Self.flowHint(checks: checks, installs: installs))
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8).padding(.horizontal, 2)
        }
    }
}

/// "Chip ........ Apple M3 Max" rows in their own card.
struct FactRow: View {
    var title: String
    var value: String
    var first = false
    var body: some View {
        SettingsRow(title: title, first: first, minHeight: 44) {
            Text(value).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
    }
}
