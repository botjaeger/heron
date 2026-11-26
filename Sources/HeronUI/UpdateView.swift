import SwiftUI

/// The update window: the waiting version, its notes in What's New's cards, the switch to install
/// automatically from now on, and what to do with it. Opened by a check you asked for, or from the
/// icon dot, the popover strip or the menu item (`UpdateState`).
public struct UpdateView: View {
    @Environment(AppServices.self) private var services

    public init() {}

    /// The window's size, What's New's.
    public static let size = CGSize(width: 640, height: 480)

    /// The heading for each state of the waiting update.
    static func heading(_ state: UpdateState) -> String {
        guard let offer = state.offer else { return "Checking for updates…" }
        switch state {
        case .downloading: return "Downloading Heron \(offer.version)"
        case .preparing: return "Preparing Heron \(offer.version)"
        case .ready: return "Heron \(offer.version) is ready"
        case .installing: return "Installing Heron \(offer.version)"
        default: return "Heron \(offer.version) is available"
        }
    }

    /// "You have 1.0.0 · 4.5 MB · Released 3 December 2026", in the user's own date format.
    static func facts(_ offer: UpdateOffer, current: String) -> String {
        var parts = ["You have \(current)"]
        if let size = offer.size { parts.append(UpdateState.megabytes(size)) }
        if let date = offer.date { parts.append("Released \(date.formatted(date: .long, time: .omitted))") }
        return parts.joined(separator: " · ")
    }

    /// The main button's title, and whether it does anything in this state.
    static func primary(_ state: UpdateState) -> (title: String, enabled: Bool) {
        switch state {
        case .available: ("Install Update", true)
        case .downloading: ("Downloading…", false)
        case .preparing: ("Preparing…", false)
        case .ready: ("Restart Heron Now", true)
        case .installing: ("Installing…", false)
        case .idle, .checking, .failed: ("Install Update", false)
        }
    }

    public var body: some View {
        let state = services.update
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        HeronMark(size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.heading(state)).font(.system(size: 20, weight: .bold)).tracking(-0.2)
                            if let offer = state.offer {
                                Text(Self.facts(offer, current: services.appVersion)).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                            }
                        }
                    }
                    if let offer = state.offer {
                        ForEach(offer.notes, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(group.title).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Changelog.color(group.title))
                                    Rectangle().fill(Theme.settingsLine).frame(height: 1)
                                }
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], spacing: 10) {
                                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                        ChangeCard(icon: item.icon, color: Changelog.color(group.title), title: item.title, text: item.body)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
            if let progress = state.progress {
                ProgressView(value: progress).padding(.horizontal, 32).padding(.bottom, 10)
                    .accessibilityLabel(state.statusLine ?? "Downloading")
            }
            Toggle(
                "Install updates automatically from now on",
                isOn: Binding(
                    get: { services.automaticallyChecksForUpdates && services.automaticallyDownloadsUpdates },
                    set: { on in
                        if on && !services.automaticallyChecksForUpdates { services.setAutomaticChecks(true) }
                        services.setAutomaticDownloads(on)
                    })
            )
            .toggleStyle(.checkbox).font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.bottom, 14)
            footer(state)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.settingsWindow)
    }

    private func footer(_ state: UpdateState) -> some View {
        let primary = Self.primary(state)
        return HStack(spacing: 8) {
            if case .available = state {
                Button("Skip This Version") { services.skipUpdate() }.buttonStyle(.link).font(.system(size: 13, weight: .medium))
            }
            Spacer()
            Button(laterTitle(state)) { services.laterUpdate() }.controlSize(.large)
            Button(primary.title) {
                if case .ready = state { services.restartToUpdate() } else { services.installUpdate() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .disabled(!primary.enabled)
        }
        .padding(.leading, 32).padding(.trailing, 20)
        .frame(height: 56)
        .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
    }

    /// "Later" while you decide; once downloaded, the same button lets it install when Heron quits.
    private func laterTitle(_ state: UpdateState) -> String {
        if case .ready = state { return "When I Quit" }
        return "Later"
    }
}

/// Above the overview's footer while an update waits: the version, and Update… to open its window.
struct UpdateStrip: View {
    var offer: UpdateOffer
    var state: UpdateState
    var open: () -> Void

    /// The strip's line under the version.
    static func detail(_ state: UpdateState, current: String) -> String {
        switch state {
        case .downloading, .preparing: state.statusLine ?? "Downloading…"
        case .ready: "Installs when you quit Heron"
        default: "You have \(current)"
        }
    }

    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 10) {
            HeronMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.isReady ? "Heron \(offer.version) is ready" : "Heron \(offer.version) is available").font(.system(size: 13, weight: .semibold))
                Text(Self.detail(state, current: services.appVersion)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(state.isReady ? "Restart…" : "Update…", action: open)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.vertical, 9).padding(.leading, 12).padding(.trailing, 10)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

extension UpdateState {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// One change in a card: its glyph on a tinted tile, a title and a line. What's New and the update
/// window both draw their changes with it.
struct ChangeCard: View {
    var icon: HeronIcon?
    var color: Color
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15))
                if let icon { HeronIconView(icon, size: 15) }
            }
            .foregroundStyle(color)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).lineSpacing(2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
    }
}
