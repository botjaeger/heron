import AppKit
import HeronCore
import SwiftUI

// Settings › AI Usage (design: SettingsAIUsage, AIAccounts): the accounts and their sheets, how
// usage shows, the thresholds, which states notify, Privacy Mode, the global shortcut and the
// command line.

// MARK: - Environment

private struct SettingsAIAccountKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct AICLIPresenceKey: EnvironmentKey { static let defaultValue: AICLIPresence = .live }

/// Whether Claude Code and the Codex CLI have a sign-in on this Mac (the "Use … sign-in" buttons).
public struct AICLIPresence: Equatable, Sendable {
    public var claudeCode: Bool
    public var codex: Bool
    public init(claudeCode: Bool, codex: Bool) { self.claudeCode = claudeCode; self.codex = codex }
    public static var live: AICLIPresence { AICLIPresence(claudeCode: BorrowedSignIn.hasClaudeCode, codex: BorrowedSignIn.hasCodex) }
}

extension EnvironmentValues {
    /// The AI account whose sheet Settings › AI Usage opens with (`SettingsRoute.aiUsage(account:)`).
    var settingsAIAccount: String? {
        get { self[SettingsAIAccountKey.self] }
        set { self[SettingsAIAccountKey.self] = newValue }
    }
    /// Injected by heron-snap and the tests; the app reads the files.
    public var aiCLIPresence: AICLIPresence {
        get { self[AICLIPresenceKey.self] }
        set { self[AICLIPresenceKey.self] = newValue }
    }
}

// MARK: - Shortcut

/// The global shortcut, stored as its symbols ("⌥⌘U") in `AIUsageSettings.shortcut`. Key codes are
/// the ANSI layout's (Carbon `kVK_ANSI_*`), which `RegisterEventHotKey` takes.
public struct AIShortcut: Equatable, Sendable {
    public var keyCode: UInt16
    /// ⌃ ⌥ ⇧ ⌘ only.
    public var control = false, option = false, shift = false, command = false

    static let keys: [(UInt16, String)] = [
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"),
        (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"),
        (16, "Y"), (6, "Z"), (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        (27, "-"), (24, "="), (33, "["), (30, "]"), (41, ";"), (39, "'"), (43, ","), (47, "."), (44, "/"), (42, "\\"), (50, "`"),
        (49, "Space"), (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
        (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
    ]

    public init(keyCode: UInt16, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.keyCode = keyCode; self.control = control; self.option = option; self.shift = shift; self.command = command
    }

    /// "⌥⌘U" back to a shortcut; nil for anything Heron cannot register.
    public init?(string: String) {
        var rest = Substring(string)
        var c = false, o = false, s = false, m = false
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            switch first {
            case "⌃": c = true
            case "⌥": o = true
            case "⇧": s = true
            default: m = true
            }
            rest = rest.dropFirst()
        }
        guard let code = Self.keys.first(where: { $0.1 == String(rest) })?.0 else { return nil }
        self.init(keyCode: code, control: c, option: o, shift: s, command: m)
        guard isValid else { return nil }
    }

    /// A key typed in the recorder; nil without ⌘, ⌃ or ⌥ (a bare key would steal typing everywhere).
    public init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard Self.keys.contains(where: { $0.0 == keyCode }) else { return nil }
        self.init(
            keyCode: keyCode, control: flags.contains(.control), option: flags.contains(.option),
            shift: flags.contains(.shift), command: flags.contains(.command))
        guard isValid else { return nil }
    }

    public var isValid: Bool { command || control || option }

    public var string: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + (Self.keys.first { $0.0 == keyCode }?.1 ?? "?")
    }

    /// Carbon's modifier bits: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public var carbonModifiers: UInt32 {
        (command ? 0x100 : 0) | (shift ? 0x200 : 0) | (option ? 0x800 : 0) | (control ? 0x1000 : 0)
    }
}

// MARK: - Pane

/// Settings › AI Usage.
struct AIUsagePane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(AIUsageService.self) private var ai
    @Environment(\.settingsAIAccount) private var routedAccount
    @Environment(\.aiCLIPresence) private var cli
    /// Made on first use (a reference, so the sheets never see it missing: an empty sheet locked the window).
    @State private var flows = FlowHolder()
    @State private var adding = false
    @State private var sheetAccount: AccountID?
    @State private var dragging: String?
    /// The CLI whose sign-in the add sheet is borrowing (its "Try again" borrows again).
    @State private var borrowing: AIProvider?

    struct AccountID: Identifiable, Hashable { var id: String }

    /// Holds the sign-in flow, created the first time anything needs it. A class in `@State`, so
    /// creating it inside `body` or a sheet changes no state and never re-renders.
    @MainActor final class FlowHolder {
        private var made: AISignInFlow?
        func flow(_ ai: AIUsageService, _ services: AppServices) -> AISignInFlow {
            if let made { return made }
            let f = AISignInFlow(service: ai, openURL: { [services] in services.openURL($0) })
            made = f
            return f
        }
        var existing: AISignInFlow? { made }
    }

    private var flow: AISignInFlow { flows.flow(ai, services) }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(pane: .aiUsage)
            accounts
            SettingsGroup("Usage display") {
                SettingsRow(title: "Show usage as", subtitle: "Click any amount to flip it", first: true) {
                    CompactSegments(title: "Show usage as", selection: $settings.aiUsage.display, options: [(.left, "48% left"), (.used, "52% used")])
                }
                SettingsRow(title: "Reset times", subtitle: "Click any reset to flip it") {
                    CompactSegments(
                        title: "Reset times", selection: $settings.aiUsage.resetFormat,
                        options: [(.countdown, "Resets 3h 25m"), (.clock, "Resets Wed 4:00 PM")])
                }
                SettingsRow(title: "Pace marks", subtitle: "Where an even pace would be by now") {
                    SettingsSwitch(title: "Pace marks", isOn: $settings.aiUsage.paceMarks)
                }
                SettingsRow(title: "Providers as", subtitle: "Here, the card and the panel") {
                    CompactSegments(title: "Providers as", selection: $settings.aiUsage.providersAs, options: [(.logo, "Logo"), (.name, "Name")])
                }
            }
            thresholds
            alerts
            tools
        }
        .onAppear {
            if routedAccount == SettingsRoute.addAccount { flow.cancel(); borrowing = nil; adding = true }
            if let id = routedAccount, ai.accounts.contains(where: { $0.id == id }) { sheetAccount = AccountID(id: id) }
        }
        .sheet(
            isPresented: $adding, onDismiss: { flows.existing?.cancel() },
            content: {
                AIAddAccountSheet(flow: flow, borrowed: borrowing) { adding = false }
            }
        )
        .sheet(
            item: $sheetAccount, onDismiss: { flows.existing?.cancel() },
            content: { item in
                AIAccountSheet(accountID: item.id, flow: flow) { sheetAccount = nil }
            }
        )
    }

    // MARK: Accounts

    /// The borrow buttons to offer: only for a CLI signed in on this Mac, and not once its sign-in is added.
    static func borrowable(_ cli: AICLIPresence, accounts: [AIAccount]) -> [AIProvider] {
        var out: [AIProvider] = []
        if cli.claudeCode, !accounts.contains(where: { $0.extras["identity"] == "borrowed:claude" }) { out.append(.claude) }
        if cli.codex, !accounts.contains(where: { $0.extras["identity"] == "borrowed:codex" }) { out.append(.codex) }
        return out
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption("Accounts")
            SettingsCard {
                if ai.accounts.isEmpty {
                    Text("No accounts yet. Add one to see your plan’s limits here, in the menu bar and in the popover.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
                ForEach(Array(ai.accounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(account, first: index == 0)
                }
                HStack(spacing: 8) {
                    Button("Add account…") {
                        flow.cancel(); borrowing = nil; adding = true
                    }
                    ForEach(Self.borrowable(cli, accounts: ai.accounts), id: \.self) { provider in
                        Button(provider == .claude ? "Use Claude Code’s sign-in" : "Use Codex’s sign-in") {
                            borrowing = provider; flow.borrow(provider); adding = true
                        }
                    }
                    Spacer(minLength: 8)
                    if ai.accounts.count > 1 { Text("Drag to reorder").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
            }
        }
        .padding(.top, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accounts")
    }

    private func accountRow(_ account: AIAccount, first: Bool) -> some View {
        let status = Self.status(ai.readings[account.id], refreshing: ai.refreshing.contains(account.id))
        return Button {
            sheetAccount = AccountID(id: account.id)
        } label: {
            HStack(spacing: 10) {
                HeronIconView(.grip, size: 12, weight: 2.4).foregroundStyle(Theme.muted)
                AIAccountMark(account: account, initials: ai.initials(account), size: 18, asName: settings.aiUsage.providersAs == .name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(Self.subtitle(account, plan: ai.readings[account.id]?.plan)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(status.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.problem ? Theme.warning : Theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.settingsPreview, in: RoundedRectangle(cornerRadius: 5))
                HeronIconView(.chevronRight, size: 12, weight: 2).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
        .opacity(dragging == account.id ? 0.5 : 1)
        .help("Click to manage; drag to reorder")
        .onDrag {
            dragging = account.id
            return NSItemProvider(object: account.id as NSString)
        }
        .onDrop(of: [.text], delegate: AccountDropDelegate(target: account.id, dragging: $dragging, ai: ai))
        .accessibilityLabel("\(account.provider.name), \(account.label), \(status.text)")
    }

    /// "Browser sign-in · Max", "Claude Code’s sign-in (borrowed, read-only) · Pro".
    static func subtitle(_ a: AIAccount, plan: String?) -> String {
        let how: String
        switch (a.signIn, a.provider) {
        case (.borrowed, .claude): how = "Claude Code’s sign-in (borrowed, read-only)"
        case (.borrowed, _): how = "Codex CLI’s sign-in (borrowed, read-only)"
        case (.oauth, .opencode): how = "Device code sign-in"
        case (.oauth, _): how = "Browser sign-in"
        }
        return [how, plan].compactMap { $0 }.joined(separator: " · ")
    }

    /// The row's chip: the problem, "Checking…" before a first answer, otherwise OK.
    static func status(_ r: AIReading?, refreshing: Bool) -> (text: String, problem: Bool) {
        if let p = r?.problem { return (p.message, true) }
        if r == nil { return (refreshing ? "Checking…" : "Not read yet", false) }
        return ("OK", false)
    }

    // MARK: Thresholds

    static func settingWarning(_ t: AIThresholds, to w: Int) -> AIThresholds { AIThresholds(warning: w, critical: t.critical) }
    static func settingCritical(_ t: AIThresholds, to c: Int) -> AIThresholds { AIThresholds(warning: t.warning, critical: c) }

    private var thresholds: some View {
        let t = settings.aiUsage.thresholds
        return SettingsGroup("Thresholds") {
            SettingsRow(title: "Warning", subtitle: "20% to 70% left", first: true, indent: 12) {
                stepper("Warning", value: t.warning, range: AIThresholds.warningRange) { settings.aiUsage.thresholds = Self.settingWarning(t, to: $0) }
            }
            .overlay(alignment: .leading) { dot(Theme.caution) }
            SettingsRow(title: "Critical", subtitle: "5% to 25% left; stays under Warning", indent: 12) {
                stepper("Critical", value: t.critical, range: AIThresholds.criticalRange.lowerBound...min(AIThresholds.criticalRange.upperBound, t.warning - 5)) {
                    settings.aiUsage.thresholds = Self.settingCritical(t, to: $0)
                }
            }
            .overlay(alignment: .leading) { dot(Theme.warning) }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6).padding(.leading, 14).accessibilityHidden(true)
    }

    private func stepper(_ title: String, value: Int, range: ClosedRange<Int>, set: @escaping @MainActor (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text("\(value)% left").font(.system(size: 13, weight: .medium)).monospacedDigit()
            Stepper(title, value: Binding(get: { value }, set: { v in MainActor.assumeIsolated { set(v) } }), in: range, step: 5).labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)% left")
    }

    // MARK: Alerts

    private var alerts: some View {
        let t = settings.aiUsage.thresholds
        let rows: [(AIUsageSettings.Alert, String, String)] = [
            (.warning, "Warning", "\(t.warning)% left or less"),
            (.critical, "Critical", "\(t.critical)% left or less"),
            (.burningFast, "Burning fast", "Would run out before it resets at this pace"),
            (.useItOrLoseIt, "Use it or lose it", "Resets within 24 h with over half left"),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                SettingsCaption("Alerts")
                Spacer()
                SettingsCaption("Notify").fixedSize().frame(width: 64)
            }
            .padding(.trailing, 14)
            SettingsCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    SettingsRow(title: row.1, subtitle: row.2, first: index == 0) {
                        SettingsSwitch(
                            title: "Notify for \(row.1)",
                            isOn: Binding(
                                get: { settings.aiUsage.notify.contains(row.0) },
                                set: { on in
                                    if on {
                                        settings.aiUsage.notify.insert(row.0)
                                        if services.notificationPermission == .notAsked { services.requestNotifications() }
                                    } else {
                                        settings.aiUsage.notify.remove(row.0)
                                    }
                                })
                        )
                        .frame(width: 64)
                    }
                }
                if !settings.aiUsage.notify.isEmpty, !services.notificationPermission.delivers {
                    SettingsRow(title: services.notificationPermission.title, subtitle: services.notificationPermission.hint) {
                        if let title = services.notificationPermission.actionTitle {
                            Button(title) {
                                if services.notificationPermission.action == .ask { services.requestNotifications() } else { services.openURL(AppServices.notificationSettings) }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Alerts")
        .onAppear { services.refreshNotificationPermission() }
    }

    // MARK: Privacy and tools

    /// The command that prints the readings: the installed app's own binary, quoted when its path has spaces.
    static func command(executable: String) -> String {
        (executable.contains(" ") ? "'\(executable)'" : executable) + " usage --json"
    }

    static var executable: String {
        Bundle.main.bundleURL.pathExtension == "app"
            ? (Bundle.main.executablePath ?? "/Applications/Heron.app/Contents/MacOS/Heron")
            : "/Applications/Heron.app/Contents/MacOS/Heron"
    }

    private var tools: some View {
        @Bindable var settings = settings
        let command = Self.command(executable: Self.executable)
        return SettingsGroup("Privacy and tools") {
            SettingsRow(title: "Privacy Mode", subtitle: "Keeps the menu bar item, the popover and its panels out of screen recordings and shared screens", first: true) {
                SettingsSwitch(title: "Privacy Mode", isOn: $settings.aiUsage.privacyMode)
            }
            SettingsRow(title: "Global shortcut", subtitle: "Opens the AI usage panel from any app") {
                AIShortcutRecorder(shortcut: $settings.aiUsage.shortcut)
            }
            SettingsRow(title: "Command line", subtitle: "Prints the last readings as JSON; never signs in or refreshes", stacked: true) {
                HStack(spacing: 8) {
                    Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.settingsPreview, in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
            }
        }
    }
}

/// Drag one account onto another to move it there (`AIUsageService.move`).
private struct AccountDropDelegate: DropDelegate {
    var target: String
    @Binding var dragging: String?
    var ai: AIUsageService

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target,
            let i = ai.accounts.firstIndex(where: { $0.id == from }), let j = ai.accounts.firstIndex(where: { $0.id == target })
        else { return }
        withAnimation(.easeOut(duration: 0.15)) { ai.move(from: IndexSet(integer: i), to: j > i ? j + 1 : j) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// A provider's mark (or name) with the account's initials when its provider has several.
struct AIAccountMark: View {
    var account: AIAccount
    var initials: String?
    var size: CGFloat
    var asName = false

    var body: some View {
        HStack(spacing: 4) {
            if asName {
                Text(account.provider.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    .frame(width: 66, alignment: .leading)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    ProviderMarkView(account.provider, size: size)
                    if let initials {
                        Text(initials).font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Theme.settingsCard)
                            .padding(.horizontal, 2)
                            .background(Color.primary, in: RoundedRectangle(cornerRadius: 3))
                            .offset(x: 5, y: 4)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

// MARK: - Shortcut recorder

/// "Record shortcut", then the next key combination typed; Esc cancels, Delete clears.
struct AIShortcutRecorder: View {
    @Binding var shortcut: String?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refused = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? (refused ? "Add ⌘, ⌃ or ⌥" : "Type a shortcut…") : (shortcut ?? "Record shortcut"))
                    .font(.system(size: 12, weight: shortcut == nil || recording ? .regular : .semibold)).monospacedDigit()
                    .frame(minWidth: 110)
            }
            .accessibilityLabel(shortcut.map { "Shortcut \($0). Record another" } ?? "Record shortcut")
            if shortcut != nil, !recording {
                Button("Clear") { shortcut = nil }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        refused = false
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: stop()  // Esc
            case 51, 117: shortcut = nil; stop()  // Delete, Forward Delete
            default:
                if let s = AIShortcut(keyCode: event.keyCode, flags: event.modifierFlags) { shortcut = s.string; stop() } else { refused = true }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Account sheet

/// One account: rename, its limits (show, pin), Refresh, Sign in again…, Remove account….
public struct AIAccountSheet: View {
    var accountID: String
    var flow: AISignInFlow
    var close: () -> Void
    @Environment(AIUsageService.self) private var ai
    @State private var name = ""
    @State private var confirmRemove = false
    @State private var signingIn = false

    public init(accountID: String, flow: AISignInFlow, close: @escaping () -> Void) {
        self.accountID = accountID; self.flow = flow; self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let account = ai.accounts.first(where: { $0.id == accountID }) {
                if signingIn, flow.step != .idle {
                    AISignInStepView(
                        step: flow.step, flow: flow, retry: { signInAgain(account) },
                        done: {
                            signingIn = false; flow.cancel()
                        })
                } else {
                    content(account)
                }
            } else {
                Text("This account was removed.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                HStack {
                    Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction)
                }.padding(.top, 12)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { name = ai.accounts.first { $0.id == accountID }?.label ?? "" }
    }

    @ViewBuilder private func content(_ account: AIAccount) -> some View {
        let reading = ai.readings[account.id]
        Text("Account").font(.system(size: 13, weight: .bold)).padding(.bottom, 10)
        HStack(spacing: 10) {
            AIAccountMark(account: account, initials: ai.initials(account), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .bold))
                        .onSubmit { rename(account) }
                        .accessibilityLabel("Account name")
                    Text("✎").font(.system(size: 11)).foregroundStyle(Theme.muted).accessibilityHidden(true)
                }
                Text(([account.provider.name] + [reading?.plan].compactMap { $0 } + [AIUsagePane.signInWord(account)]).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        if let problem = reading?.problem {
            Text(problem.message).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warning).padding(.top, 8)
        }
        SettingsCaption("Limits · show, pin, drag").padding(.top, 14).padding(.bottom, 4)
        let metrics = reading?.metrics ?? []
        if metrics.isEmpty {
            Text("Its limits show here after the first reading.").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 6)
        }
        ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(Theme.muted).accessibilityHidden(true)
                Text(metric.title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                let pinned = account.pinned.contains(metric.key)
                // Only a limit with a bar can be pinned (counts, tokens and uncapped money never rank).
                if case .limit = metric.value {
                    Button {
                        ai.togglePin(account.id, metric.key)
                    } label: {
                        HeronIconView(.pin, size: 12, weight: 2).foregroundStyle(pinned ? Theme.ai : Theme.muted)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pinned ? "Unpin \(metric.title)" : "Pin \(metric.title)")
                    .help(pinned ? "Pinned first on the AI usage card and in the menu bar" : "Pin first on the AI usage card and in the menu bar")
                } else {
                    Color.clear.frame(width: 20, height: 20).accessibilityHidden(true)
                }
                SettingsSwitch(
                    title: "Show \(metric.title)",
                    isOn: Binding(
                        get: { !(ai.accounts.first { $0.id == account.id }?.hidden.contains(metric.key) ?? false) },
                        set: { _ in ai.toggleHidden(account.id, metric.key) }))
            }
            .padding(.vertical, 5)
            .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
            .contentShape(Rectangle())
            // Drag a limit onto another to put it there; every surface follows (`AIUsageService.moveMetric`).
            .onDrag { NSItemProvider(object: metric.key as NSString) }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                _ = providers.first?.loadObject(ofClass: NSString.self) { key, _ in
                    guard let key = key as? String, key != metric.key else { return }
                    Task { @MainActor in ai.moveMetric(account.id, key, before: metric.key) }
                }
                return true
            }
            .accessibilityAction(named: "Move up") {
                if index > 0 { ai.moveMetric(account.id, metric.key, before: metrics[index - 1].key) }
            }
            .accessibilityAction(named: "Move down") {
                if index + 2 < metrics.count {
                    ai.moveMetric(account.id, metric.key, before: metrics[index + 2].key)
                } else if index + 1 < metrics.count {
                    ai.moveMetric(account.id, metric.key, before: nil)
                }
            }
        }
        HStack(spacing: 6) {
            Button(ai.refreshing.contains(account.id) ? "Refreshing…" : "Refresh") { Task { await ai.refresh(account, force: true) } }
                .disabled(ai.refreshing.contains(account.id))
            Button("Sign in again…") { signInAgain(account) }
            Button("Remove account…", role: .destructive) { confirmRemove = true }.foregroundStyle(Theme.warning)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        HStack {
            Spacer()
            Button("Done") {
                rename(account); close()
            }.keyboardShortcut(.defaultAction)
        }.padding(.top, 14)
            .confirmationDialog("Remove \(account.label)?", isPresented: $confirmRemove) {
                Button("Remove Account", role: .destructive) {
                    ai.remove(account.id); close()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(account.signIn == .borrowed ? "Heron stops reading it. The CLI stays signed in." : "Heron forgets this sign-in and its settings.")
            }
    }

    /// The same login lands on this account again (`AIUsageService.add` matches its identity), so
    /// it keeps its name, place and settings.
    private func signInAgain(_ account: AIAccount) {
        signingIn = true
        if account.signIn == .borrowed { flow.borrow(account.provider) } else { flow.start(account.provider) }
    }

    private func rename(_ account: AIAccount) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != account.label else { name = account.label; return }
        var a = account; a.label = trimmed; ai.update(a)
    }
}

extension AIUsagePane {
    /// "browser sign-in", "device code", "Claude Code’s sign-in".
    static func signInWord(_ a: AIAccount) -> String {
        switch (a.signIn, a.provider) {
        case (.borrowed, .claude): return "Claude Code’s sign-in"
        case (.borrowed, _): return "Codex’s sign-in"
        case (.oauth, .opencode): return "device code"
        case (.oauth, _): return "browser sign-in"
        }
    }
}

// MARK: - Add account sheet

/// Pick a provider, then follow its sign-in (`AISignInFlow.step`).
public struct AIAddAccountSheet: View {
    var flow: AISignInFlow
    /// Set when the sheet shows a borrowed sign-in's outcome.
    var borrowed: AIProvider?
    var close: () -> Void
    @State private var provider: AIProvider = .claude

    public init(flow: AISignInFlow, borrowed: AIProvider? = nil, close: @escaping () -> Void) {
        self.flow = flow; self.borrowed = borrowed; self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if flow.step == .idle {
                AIProviderPicker { p in
                    provider = p; flow.start(p)
                }
                HStack {
                    Spacer(); Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                }.padding(.top, 14)
            } else {
                AISignInStepView(
                    step: flow.step, flow: flow,
                    retry: {
                        if let borrowed { flow.borrow(borrowed) } else { flow.start(provider) }
                    },
                    done: {
                        flow.cancel(); close()
                    })
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

/// "Add account": one row per provider and how it signs in.
struct AIProviderPicker: View {
    var pick: (AIProvider) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add account").font(.system(size: 13, weight: .bold)).padding(.bottom, 8)
            ForEach(AIProvider.allCases) { p in
                Button {
                    pick(p)
                } label: {
                    HStack(spacing: 10) {
                        ProviderMarkView(p, size: 18)
                        Text(p.name).font(.system(size: 13))
                        Spacer()
                        Text(p.signInKind).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        HeronIconView(.chevronRight, size: 12, weight: 2).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
                .accessibilityLabel("\(p.name), \(p.signInKind)")
            }
        }
    }
}

/// One sign-in step: the browser with a paste field, OpenCode's device code, a failure, done.
/// Takes the step as a value so heron-snap can draw each one.
public struct AISignInStepView: View {
    var step: AISignInFlow.Step
    var flow: AISignInFlow?
    /// "Try again" after a failure: the same sign-in from the start.
    var retry: () -> Void
    var done: () -> Void
    @Environment(AppServices.self) private var services
    @State private var code = ""

    public init(step: AISignInFlow.Step, flow: AISignInFlow?, retry: @escaping () -> Void, done: @escaping () -> Void) {
        self.step = step; self.flow = flow; self.retry = retry; self.done = done
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .idle:
                EmptyView()
            case .browser(let p, _):
                Text("\(p.name) · browser sign-in").font(.system(size: 13, weight: .bold)).padding(.bottom, 8)
                note("Finish signing in in your browser. If it does not come back, paste the code here.")
                TextField("Code", text: $code)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .onSubmit { submit() }
                    .padding(.vertical, 10)
                HStack(spacing: 6) {
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Try again") {
                        code = ""; flow?.start(p)
                    }
                    Button("Continue") { submit() }.keyboardShortcut(.defaultAction).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .device(let dc):
                Text("OpenCode · device code").font(.system(size: 13, weight: .bold)).padding(.bottom, 8)
                note("Enter this code in the OpenCode Console")
                Text(dc.userCode).font(.system(size: 26, weight: .bold, design: .monospaced)).tracking(3).textSelection(.enabled)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Code \(dc.userCode.map(String.init).joined(separator: " "))")
                HStack(spacing: 6) {
                    Button("Copy code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(dc.userCode, forType: .string)
                    }
                    Button("Open browser") { services.openURL(dc.verificationURL) }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    note("Waiting for OpenCode… then pick a workspace")
                }
                .padding(.top, 10)
            case .failed(let message):
                Text("Couldn’t sign in").font(.system(size: 13, weight: .bold)).padding(.bottom, 8)
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Spacer()
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                    Button("Try again", action: retry).keyboardShortcut(.defaultAction)
                }
                .padding(.top, 14)
            case .done(let label):
                Text("Added \(label)").font(.system(size: 13, weight: .bold)).padding(.bottom, 8)
                note("Its limits show after the first reading, in a few seconds.")
                HStack {
                    Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction)
                }.padding(.top, 14)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        flow?.submitPasted(c)
    }
}
