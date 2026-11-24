import HeronCore
import SwiftUI

/// What clicking the Heron menu bar item opens: the overview, every section in Settings › Overview
/// order. Each metric's detail page (`PopoverView(kind:)`) becomes its hover panel.
public struct PopoverRoot: View {
    public init() {}

    /// The hosting view's own space (y down from its top), shared by the card frames and the pointer.
    static let space = "heron.popover"

    public var body: some View {
        PopoverView(kind: .overview).coordinateSpace(.named(Self.space))
    }
}

/// One popover page. One view, eight variants: the overview, and each section's hover panel
/// (no footer; a row's history opens in its own panel beside it, `HistoryPage`).
public struct PopoverView: View {
    public var kind: PopoverKind
    /// Readings to draw instead of the monitor's latest (heron-snap's edge cases).
    var snapshot: Snapshot?
    /// heron-snap: this card drawn as under the pointer, its "…" menu drawn open (a real menu
    /// cannot be rendered off screen).
    var debugMenu: OverviewPart?
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(DetailPanels.self) private var panels: DetailPanels?
    /// Optional: views without AI accounts (tests, older hosts) draw without it.
    @Environment(AIUsageService.self) private var ai: AIUsageService?

    /// heron-snap: the AI panel on a given view, its first resets list open (and confirming).
    var aiDebug: AIPanelDebug?
    /// Drawn for "Copy picture": the panel without its Copy picture button.
    var picture = false
    @Environment(\.colorScheme) private var scheme

    public init(kind: PopoverKind, snapshot: Snapshot? = nil, debugMenu: OverviewPart? = nil, aiDebug: AIPanelDebug? = nil) {
        self.kind = kind; self.snapshot = snapshot; self.debugMenu = debugMenu; self.aiDebug = aiDebug
    }

    private var s: Snapshot { snapshot ?? monitor.snapshot }

    /// The width of the popover and of every panel.
    public static let width: CGFloat = 360
    /// The overview's padding and the gap between its cards (a panel's: 14 and 10).
    static let overviewPadding: CGFloat = 12

    /// The tallest the page may be (the screen's visible height less the popover's arrow and a
    /// margin, `StatusBarController`): past it the sections scroll under a fixed header and footer.
    /// nil (heron-snap, Settings previews, tests) draws the page at its full height.
    private var maxHeight: CGFloat? { kind == .overview ? panels?.popoverMaxHeight : panels?.panelMaxHeight }

    public var body: some View {
        page
            .frame(width: Self.width)
            .coordinateSpace(.named(DetailPanels.space))  // history rows report their frames in it
            .accessibilityElement(children: .contain)
            .accessibilityLabel(kind == .overview ? "Heron overview" : "\(title) details")
    }

    /// Header, sections, footer. With a `maxHeight` the sections sit in a scroll view: a page taller
    /// than the screen had its top cut off by macOS (2026-11-23, the overview on a 14" display).
    @ViewBuilder private var page: some View {
        if let maxHeight {
            CappedHeight(maxHeight: maxHeight) {
                VStack(alignment: .leading, spacing: kind == .overview ? 8 : 10) {
                    header.layoutPriority(1)
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) { sections }
                            .scrollBounceBehavior(.basedOnSize)
                            .background {
                                GeometryReader { geo in
                                    let frame = geo.frame(in: .named(PopoverRoot.space))
                                    Color.clear
                                        .onAppear { if kind == .overview { panels?.reportViewport(frame) } }
                                        .onChange(of: frame) { _, new in if kind == .overview { panels?.reportViewport(new) } }
                                }
                            }
                            // ↑ ↓ walk the cards: the one the keyboard is on scrolls into view.
                            .onChange(of: panels?.focused) { _, part in
                                if kind == .overview, let part { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(part) } }
                            }
                    }
                    if kind == .overview { footer.layoutPriority(1) }
                }
                .padding(kind == .overview ? Self.overviewPadding : 14)
            }
        } else {
            VStack(alignment: .leading, spacing: kind == .overview ? 8 : 10) {
                header
                sections
                if kind == .overview { footer }
            }
            .padding(kind == .overview ? Self.overviewPadding : 14)
        }
    }

    @ViewBuilder private var sections: some View {
        switch kind {
        case .overview: OverviewSection(snapshot: s, debugMenu: debugMenu)
        case .cpu: CPUSection(snapshot: s)
        case .gpu: GPUSection(snapshot: s)
        case .memory: MemorySection(snapshot: s)
        case .disk: DiskSection(snapshot: s)
        case .network: NetworkSection(snapshot: s)
        case .sensors: SensorsSection(snapshot: s)
        case .battery: BatterySection(snapshot: s)
        case .ai: AIPanelView(openResets: aiDebug?.openResets ?? false, confirmReset: aiDebug?.confirmReset ?? false)
        }
    }

    @ViewBuilder private var header: some View {
        if kind == .overview {
            // The mark, "Heron" over the Mac's name and uptime, and the status pill beside them;
            // when a long pill leaves the name no room, the pill moves up beside "Heron" and the
            // name gets the full width under it.
            let name = Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                HeronMark(size: 30)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.system(size: 15, weight: .bold))
                            name.fixedSize()
                        }
                        Spacer(minLength: 8)
                        StatusPill(snapshot: s)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(title).font(.system(size: 15, weight: .bold))
                            Spacer(minLength: 8)
                            StatusPill(snapshot: s)
                        }
                        name.lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 4)
        } else {
            // A panel: the section's icon tile, its title and a line of facts under it.
            HStack(spacing: 10) {
                if let part = kind.part { IconTile(part: part, battery: s.battery, size: 30) }
                VStack(alignment: .leading, spacing: 1) {
                    // "Copy picture" sits on the title's line, over it rather than beside the
                    // header: the subtitle keeps the full width (the CPU line needs all of it) and
                    // the header is as tall with the button as without.
                    Text(title).font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) {
                            if Self.showsCopyButton(kind, on: settings.copyPicture, picture: picture) {
                                CopyPictureButton { copyPicture() }
                            }
                        }
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2).padding(.bottom, 2)
        }
    }

    /// A panel's header button: on with Settings › General › Copy picture, never on the overview,
    /// never in the picture itself. The same button on every panel, the AI usage panel's too.
    static func showsCopyButton(_ kind: PopoverKind, on: Bool, picture: Bool) -> Bool {
        on && !picture && kind != .overview
    }

    /// This panel at its full height, header and every section, as "Copy picture" draws it. The AI
    /// usage panel: its header and account cards without the footer, account names hidden in
    /// Privacy Mode.
    static func picture(_ kind: PopoverKind, snapshot: Snapshot, monitor: Monitor, settings: AppSettings, services: AppServices, ai: AIUsageService?) -> AnyView {
        if kind == .ai, let ai {
            return AnyView(
                AIPanelPicture()
                    .padding(14)
                    .frame(width: Self.width)
                    .environment(monitor).environment(settings).environment(ai).environment(services)
                    .environment(\.aiHidesEmails, settings.aiUsage.privacyMode))
        }
        var page = PopoverView(kind: kind, snapshot: snapshot)
        page.picture = true
        let content = page.environment(monitor).environment(settings).environment(services)
        return ai.map { AnyView(content.environment($0)) } ?? AnyView(content)
    }

    private func copyPicture() {
        PanelPicture.copy(Self.picture(kind, snapshot: s, monitor: monitor, settings: settings, services: services, ai: ai), scheme: scheme)
    }

    private var title: String { kind.title }

    /// "up 1d 4h"; nothing when the boot time cannot be read.
    private var upTime: String { SystemInfo.bootDate.map { "up \(Format.uptime(since: $0))" } ?? "" }

    private var subtitle: String {
        switch kind {
        case .overview: return [SystemInfo.friendlyName, upTime].filter { !$0.isEmpty }.joined(separator: " · ")
        case .cpu:
            let kinds = [SystemInfo.efficiencyCores.map { "\($0) efficiency" }, SystemInfo.performanceCores.map { "\($0) performance" }].compactMap { $0 }
            // "M3 Max", not "Apple M3 Max": with the brand the line ran past the panel's width.
            return "\(SystemInfo.shortChip(SystemInfo.chipName)) · \(SystemInfo.logicalCores) cores" + (kinds.count == 2 ? " (\(kinds.joined(separator: ", ")))" : "")
        case .gpu: return s.gpu?.name ?? "GPU"
        case .memory: return "\(Format.bytes(SystemInfo.physicalMemory)) unified memory"
        case .disk: return "\(s.disk?.volumes.count ?? 0) volume\(s.disk?.volumes.count == 1 ? "" : "s")"
        case .network: return [s.network?.interfaceKind, s.network?.interface].compactMap { $0 }.joined(separator: " · ")
        case .sensors: return "\(s.sensors.filter { $0.isKnown || !settings.hideUnknownSensors }.count) sensors · \(s.fans.count) fan\(s.fans.count == 1 ? "" : "s")"
        case .battery:
            guard let b = s.battery else { return "" }
            return [b.maxCapacityFraction.map { "Health \(Format.percent($0))" }, b.cycleCount.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: " · ")
        case .ai: return AIText.accountsLine(ai?.accounts ?? [])
        }
    }

    /// heron-snap: the picture "Copy picture" puts on the pasteboard for `kind`'s panel.
    public static func pictureImage(_ kind: PopoverKind, monitor: Monitor, settings: AppSettings, services: AppServices, ai: AIUsageService?, dark: Bool) -> NSImage? {
        PanelPicture.image(picture(kind, snapshot: monitor.snapshot, monitor: monitor, settings: settings, services: services, ai: ai), scheme: dark ? .dark : .light, scale: 2)
    }

    /// "Settings…" opens what this popover shows: General for the overview, Settings › Overview
    /// on its section for a panel.
    var settingsRoute: SettingsRoute {
        guard let part = kind.part else { return SettingsRoute(.general) }
        return .overview(part)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                services.openActivityMonitor()
            } label: {
                HStack(spacing: 6) {
                    HeronIconView(.activity, size: 13).foregroundStyle(Theme.muted); Text("Activity Monitor")
                }
            }
            Spacer()
            Button("Settings…") { services.openSettings(settingsRoute) }
            Button("Quit") { services.quit() }
        }
        .buttonStyle(FooterButtonStyle())
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1) }
        .padding(.top, 2)
    }
}

/// Proposes its content its own height, but no more than `maxHeight`: below the cap the page is as
/// tall as it needs; above it a flexible child (the sections' scroll view) gets what is left.
struct CappedHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sub = subviews.first else { return .zero }
        let ideal = sub.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// The overview footer's small bordered buttons.
struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
    }
}
