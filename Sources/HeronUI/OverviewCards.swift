import HeronCore
import SwiftUI

// MARK: - Sections

/// The overview: one full-width card per section, each with its icon tile, title, value and a ›
/// that opens its panel. Each card draws its value in the style picked in Settings
/// (`AppSettings.cardStyle`).
struct OverviewSection: View {
    var snapshot: Snapshot
    /// One card alone, as Settings previews it: no frame reporting, no hover, nothing opens.
    var only: OverviewPart?
    /// The style `only` is drawn in instead of the chosen one: Settings › Overview's style tiles.
    var style: CardStyle?
    /// heron-snap: the card drawn hovered with its "…" menu open.
    var debugMenu: OverviewPart?
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(DetailPanels.self) private var panels: DetailPanels?
    @Environment(AIUsageService.self) private var ai: AIUsageService?

    /// The sections drawn, top to bottom: Settings › Overview order without the hidden ones,
    /// Battery only on a Mac that has one, AI usage only once an AI account exists (`ai`).
    static func parts(order: [OverviewPart], hidden: Set<OverviewPart>, snapshot: Snapshot, ai: Bool = false) -> [OverviewPart] {
        order.filter { !hidden.contains($0) && ($0 != .battery || snapshot.battery?.present == true) && ($0 != .ai || ai) }
    }

    private var hasAI: Bool { !(ai?.accounts.isEmpty ?? true) }

    /// A card that needs attention (red border and ›): a hot CPU, GPU or sensor, critical memory
    /// pressure, a nearly full startup disk, a low battery. Thresholds from `Warnings` only.
    static func isHot(_ part: OverviewPart, in s: Snapshot) -> Bool {
        switch part {
        case .cpu: return SensorSummary.value(.cpu, in: s).map(Warnings.isHot) ?? false
        case .gpu: return SensorSummary.value(.gpu, in: s).map(Warnings.isHot) ?? false
        case .memory: return s.memory?.pressure == .critical
        case .disk: return s.rootVolume.map(Warnings.isNearlyFull) ?? false
        case .sensors: return SensorSummary.value(.hottest, in: s).map(Warnings.isHot) ?? false
        case .battery: return s.battery.map(Warnings.isLow) ?? false
        case .network, .ai: return false
        }
    }

    /// The line a hot card adds, the user's next question: what is causing it. CPU: the app using
    /// the most CPU while the CPU is hot, as its share of the whole Mac ("74% of CPU": the card has
    /// no "100% = one core" caption, so "1038%" would read as nonsense); Memory: the app using the
    /// most memory at critical pressure.
    static func cause(_ part: OverviewPart, in s: Snapshot) -> (name: String, value: String)? {
        guard isHot(part, in: s) else { return nil }
        switch part {
        case .cpu:
            let cores = s.cpu?.cores.count ?? 0
            guard cores > 0 else { return nil }
            return s.topCPU.first.map { ($0.title, "\(Format.percent(ProcessUsage.cpuShare($0.cpu, cores: cores))) of CPU") }
        case .memory: return s.topMemory.first.map { ($0.title, Format.bytes($0.memory)) }
        default: return nil
        }
    }

    private var s: Snapshot { snapshot }

    var body: some View {
        let shown = only.map { [$0] } ?? Self.parts(order: settings.overviewOrder, hidden: settings.hiddenSections, snapshot: s, ai: hasAI)
        // Built once: the AI card and what VoiceOver reads for it share the model.
        let aiModel = shown.contains(.ai) ? ai.map { AICardModel(ai: $0, settings: settings.aiUsage) } : nil
        VStack(spacing: 8) {
            if let only {
                Card(trailingInset: 15, spacing: 10) { card(only, ai: aiModel) }
                    .overlay(alignment: .trailing) { Chevron(color: only.color, hot: Self.isHot(only, in: s)).padding(.trailing, 7) }
                    .overlay { if Self.isHot(only, in: s) { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1) } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(only.title), \(spokenValue(only, ai: aiModel))")
            } else {
                ForEach(shown) { part in
                    OverviewCardFrame(
                        part: part, open: panels?.open == part, focused: panels?.focused == part,
                        hot: Self.isHot(part, in: s), canHide: CardMenu.canHide(part, shown: shown),
                        spokenValue: spokenValue(part, ai: aiModel), panels: panels, debugMenu: debugMenu == part
                    ) {
                        card(part, ai: aiModel)
                    }
                    .zIndex(debugMenu == part ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder private func card(_ part: OverviewPart, ai model: AICardModel?) -> some View {
        switch part {
        case .cpu: cpuCard
        case .gpu: gpuCard
        case .memory: memoryCard
        case .network: networkCard
        case .disk: diskCard
        case .sensors: sensorsCard
        case .battery: batteryCard
        case .ai: aiCard(model)
        }
        if let cause = Self.cause(part, in: s) { causeLine(cause) }
    }

    private var range: Int { settings.graphRange.rawValue }

    /// The style a card draws in: the chosen one, or `style` for a Settings tile.
    private func cardStyle(_ card: OverviewCard) -> CardStyle {
        if let style, card.styles.contains(style) { return style }
        return settings.cardStyle(card)
    }

    /// What VoiceOver reads for a card: "CPU, 34%, shows details".
    private func spokenValue(_ part: OverviewPart, ai model: AICardModel?) -> String {
        switch part {
        case .cpu: return Format.percent(s.cpu?.total ?? 0)
        case .gpu: return Format.percent(s.gpu?.device ?? 0)
        case .memory: return Format.percent(s.memory?.usedFraction ?? 0)
        case .network:
            return
                "down \(Format.rate(s.network?.downBytesPerSecond ?? 0, bits: settings.networkInBits)), up \(Format.rate(s.network?.upBytesPerSecond ?? 0, bits: settings.networkInBits))"
        case .disk:
            guard let root = s.rootVolume else { return "–" }
            return "\(Format.diskBytes(root.used)) used of \(Format.diskBytes(root.total))"
        case .sensors:
            if let t = SensorSummary.cardTemperatures(settings.sensorCard, nameHottest: settings.nameHottest, in: s).first {
                return "\(t.label) \(Format.temperature(t.celsius, unit: settings.temperatureUnit))"
            }
            return FanSummary.rpm(s.fans).map { "fans \(Format.rpm($0))" } ?? "no readings"
        case .battery: return s.battery.map { "\(Format.percent($0.percent)), \(BatteryStatus.text($0))" } ?? "–"
        case .ai: return model?.spoken ?? "no accounts"
        }
    }

    // MARK: Pieces

    /// The tile, the title, an optional chip, and the "…" menu while the pointer is on the card.
    private func title(_ part: OverviewPart, chip: (text: String, color: Color)? = nil) -> some View {
        HStack(spacing: 8) {
            IconTile(part: part, battery: s.battery)
            Text(part.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(part.titleColor).lineLimit(1)
            if let chip {
                Text(chip.text).font(.system(size: 11, weight: .semibold)).foregroundStyle(chip.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(chip.color.opacity(0.16), in: Capsule())
                    .fixedSize()
            }
            CardMenuButton(part: part)
        }
        .frame(minHeight: 26)
    }

    private func header(_ part: OverviewPart, _ number: String, unit: String = "", chip: (text: String, color: Color)? = nil) -> some View {
        HStack {
            title(part, chip: chip)
            Spacer(minLength: 8)
            BigNumber(number: number, unit: unit)
        }
    }

    /// A temperature as every card writes it (`temperatureText`), nil without a reading.
    private func temperature(_ celsius: Double?) -> Text? { celsius.map { temperatureText($0, settings) } }

    /// "79° · 14 W": the parts that have a value, joined by a dot.
    private func joined(_ parts: [Text?]) -> Text? {
        let present = parts.compactMap { $0 }
        guard var result = present.first else { return nil }
        for part in present.dropFirst() { result = result + Text(" · ") + part }
        return result
    }

    private func sub(_ left: Text?, _ right: Text? = nil) -> some View {
        HStack {
            if let left { left.lineLimit(1) }
            Spacer(minLength: 8)
            if let right { right.lineLimit(1) }
        }
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    /// "Top: Xcode · 74% of CPU" under a hot card, over a hairline.
    private func causeLine(_ cause: (name: String, value: String)) -> some View {
        HStack(spacing: 4) {  // a word space, so "Top: node · 16% of CPU" reads as one line
            Text("Top:")
            Text(cause.name).fontWeight(.semibold).foregroundStyle(Color.primary).lineLimit(1).truncationMode(.middle)
            Text("· \(cause.value)").monospacedDigit().fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.track).frame(height: 1) }
    }

    /// A value in the text colour, for the parts of a note that are numbers.
    private func strong(_ text: String) -> Text { Text(text).font(Theme.number(12, weight: .medium)).foregroundStyle(Color.primary) }

    /// Title (and notes under it) on the left, a ring on the right.
    private func ringRow(_ part: OverviewPart, notes: [Text?], parts: [(fraction: Double, color: Color)], value: String, size: CGFloat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                title(part)
                ForEach(Array(notes.compactMap { $0 }.enumerated()), id: \.offset) { _, note in
                    note.font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            BigRing(parts: parts, size: size, value: value)
        }
    }

    /// GPU and the memory graph: a percentage drawn as a bar, a ring or a graph, a note under it.
    @ViewBuilder private func percentCard(
        _ part: OverviewPart, style: CardStyle, fraction: Double, metric: Metric, color: Color, note: Text?,
        chip: (text: String, color: Color)? = nil
    ) -> some View {
        switch style {
        case .ring:
            ringRow(part, notes: [note], parts: [(fraction, color)], value: wholePercent(fraction), size: 56)
        case .graph:
            header(part, wholePercent(fraction), unit: "%", chip: chip)
            Sparkline(values: monitor.history.series(metric, seconds: range, points: 60), color: color, fill: true).frame(height: 26)
            sub(note)
        default:
            header(part, wholePercent(fraction), unit: "%", chip: chip)
            Meter(fraction: fraction, color: color)
            sub(note)
        }
    }

    // MARK: Cards

    @ViewBuilder private var cpuCard: some View {
        let user = s.cpu?.user ?? 0, system = s.cpu?.system ?? 0, total = s.cpu?.total ?? 0
        let trail = joined([temperature(SensorSummary.value(.cpu, in: s)), s.power?.cpu.map { Text(Format.watts($0)) }])
        switch cardStyle(.cpu) {
        case .ring:
            HStack {
                title(.cpu)
                Spacer(minLength: 8)
                BigRing(parts: [(user, Theme.cpu), (system, UserSystemBars.systemColor)], size: 76, value: wholePercent(total), caption: "TOTAL")
            }
            UserSystemLegend(user: user, system: system, trailing: trail)
        case .graph:
            header(.cpu, wholePercent(total), unit: "%")
            UserSystemArea(
                total: monitor.history.series(.cpu, seconds: range, points: 60),
                system: monitor.history.series(.cpuSystem, seconds: range, points: 60), height: 40
            )
            .background(ChartGuides())
            UserSystemLegend(user: user, system: system, trailing: trail)
        default:
            header(.cpu, wholePercent(total), unit: "%")
            UserSystemBars(
                total: monitor.history.series(.cpu, seconds: range, points: 60),
                system: monitor.history.series(.cpuSystem, seconds: range, points: 60),
                user: user, systemNow: system, height: 40, trailing: trail, slots: 60)
        }
    }

    @ViewBuilder private var gpuCard: some View {
        let note = joined([temperature(SensorSummary.value(.gpu, in: s)), s.power?.gpu.map { Text(Format.watts($0)) }])
        percentCard(.gpu, style: cardStyle(.gpu), fraction: s.gpu?.device ?? 0, metric: .gpu, color: Theme.gpu, note: note)
    }

    /// Memory's chip after the title: the pressure level when it is not normal.
    private var pressureChip: (text: String, color: Color)? {
        switch s.memory?.pressure {
        case .warning: return ("Warning", Theme.caution)
        case .critical: return ("Critical", Theme.warning)
        default: return nil
        }
    }

    @ViewBuilder private var memoryCard: some View {
        let m = s.memory
        let total = Double(max(1, m?.total ?? 1))
        let parts: [(fraction: Double, color: Color)] = [
            (Double(m?.app ?? 0) / total, Theme.memory), (Double(m?.wired ?? 0) / total, Theme.cpu),
            (Double(m?.compressed ?? 0) / total, Theme.gpu),
        ]
        let used = m?.usedFraction ?? 0
        let level = m?.pressure.rawValue.capitalized ?? "–"
        let swap = "Swap \(Format.bytes(m?.swapUsed ?? 0))"
        let note = Text("Pressure: \(level) · \(swap)")
        switch cardStyle(.memory) {
        case .rings:
            header(.memory, String(format: "%.1f", Double(m?.used ?? 0) / 1_073_741_824), unit: "/ \(Format.bytes(m?.total ?? 0))", chip: pressureChip)
            MemoryRings(memory: m)
        case .ring:
            ringRow(.memory, notes: [note], parts: parts, value: wholePercent(used), size: 60)
        case .graph:
            percentCard(.memory, style: .graph, fraction: used, metric: .memory, color: Theme.memory, note: note, chip: pressureChip)
        default:
            header(.memory, wholePercent(used), unit: "%", chip: pressureChip)
            SplitMeter(parts: parts)
            sub(note)
        }
    }

    /// "↓ 31 KB/s  ↑ 8 KB/s" with arrow glyphs: download in the network colour, upload in the
    /// second rate colour.
    private func rate(_ icon: HeronIcon, _ text: String, _ color: Color) -> some View {
        let parts = NumberParts.split(text)
        return HStack(spacing: 3) {
            HeronIconView(icon, size: 13, weight: 2.2)
            BigNumber(number: parts.number, unit: parts.unit, size: 15, color: color, unitColor: color)
        }
        .foregroundStyle(color)
    }

    @ViewBuilder private var networkCard: some View {
        let down = s.network?.downBytesPerSecond ?? 0, up = s.network?.upBytesPerSecond ?? 0
        HStack {
            title(.network)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                rate(.arrowDown, Format.rate(down, bits: settings.networkInBits), Theme.network)
                rate(.arrowUp, Format.rate(up, bits: settings.networkInBits), Theme.upload)
            }
            .layoutPriority(1)
        }
        switch cardStyle(.network) {
        case .graph:
            let d = monitor.history.series(.networkDown, seconds: range, points: 60), u = monitor.history.series(.networkUp, seconds: range, points: 60)
            let top = max(d.max() ?? 0, u.max() ?? 0, 1) * 1.15  // one scale for both
            ZStack {  // download's area, upload's line, download's line on top
                Sparkline(values: d, color: Theme.network, fixedMax: top, fill: true)
                Sparkline(values: u, color: Theme.upload, fixedMax: top)
                Sparkline(values: d, color: Theme.network, fixedMax: top)
            }.frame(height: 30)
        case .mirrored:
            MirroredBars(
                up: monitor.history[.networkDown].last(MirroredBars.slots), down: monitor.history[.networkUp].last(MirroredBars.slots),
                upColor: Theme.network, downColor: Theme.upload
            )
            .frame(height: 34)
        default:
            EmptyView()
        }
    }

    /// "644 of 995 GB": the used number alone when both share a unit, else both in full.
    static func usedOf(_ used: UInt64, _ total: UInt64) -> (number: String, unit: String) {
        let u = NumberParts.split(Format.diskBytes(used)), t = NumberParts.split(Format.diskBytes(total))
        return u.unit == t.unit ? (u.number, "of \(Format.diskBytes(total))") : (Format.diskBytes(used), "of \(Format.diskBytes(total))")
    }

    @ViewBuilder private var diskCard: some View {
        let root = s.rootVolume
        // "Read 388 MB/s · Write 2.2 MB/s": labels muted, numbers in the text colour.
        let activity = Text("Read ") + strong(Format.rate(s.disk?.readBytesPerSecond ?? 0)) + Text(" · Write ") + strong(Format.rate(s.disk?.writeBytesPerSecond ?? 0))
        let free = root.map { strong(Format.diskBytes($0.available)) + Text(" free") }
        if cardStyle(.disk) == .ring, let root {
            ringRow(
                .disk, notes: [Text("\(Format.diskBytes(root.available)) free of \(Format.diskBytes(root.total))"), activity],
                parts: [(root.usedFraction, Warnings.color(volume: root))], value: wholePercent(root.usedFraction), size: 56)
        } else {
            HStack {
                title(.disk)
                Spacer(minLength: 8)
                if let root {
                    let v = Self.usedOf(root.used, root.total)
                    BigNumber(number: v.number, unit: v.unit)
                }
            }
            if cardStyle(.disk) == .mirrored {
                // Activity instead of space: read up in the text colour, write down in grey.
                MirroredBars(
                    up: monitor.history[.diskRead].last(MirroredBars.slots), down: monitor.history[.diskWrite].last(MirroredBars.slots),
                    upColor: .primary, downColor: Theme.muted
                )
                .frame(height: 34)
            } else if let root {
                Meter(fraction: root.usedFraction, color: Warnings.color(volume: root))
            }
            sub(activity, free)
        }
    }

    @ViewBuilder private var sensorsCard: some View {
        let fans = s.fans
        HStack {
            title(.sensors)
            Spacer(minLength: 8)
            // Settings › Overview › Sensors › "Fan speed": each fan in the title row, or not at all.
            if settings.sensorCardFans, let rpm = FanSummary.rpm(fans) {
                HStack(spacing: 4) {
                    SpinningFan(rpm: rpm).foregroundStyle(Theme.fan)
                    (Text(FanSummary.speeds(fans)).font(Theme.number(13, weight: .semibold)).foregroundStyle(Color.primary)
                        + Text(" rpm").font(.system(size: 11)).foregroundStyle(Theme.muted))
                        .lineLimit(1)
                }
            }
        }
        // Settings › Overview › Sensors › "On the card": up to five, in the order picked.
        let temps = SensorSummary.cardTemperatures(settings.sensorCard, nameHottest: settings.nameHottest, in: s)
        if temps.isEmpty {
            Text("This Mac does not report any temperature sensors to Heron.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        } else {
            HStack(alignment: .bottom, spacing: temps.count > 3 ? 14 : 22) {
                ForEach(temps, id: \.item) { t in
                    VStack(alignment: .leading, spacing: 3) {
                        // A named hottest sensor ("Hottest · CPU P-core 12") gives way first.
                        Text(t.label).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        Text(Format.temperature(t.celsius, unit: settings.temperatureUnit)).font(Theme.number(20))
                            .foregroundStyle(Warnings.color(celsius: t.celsius)).fixedSize()
                    }
                    .layoutPriority(t.item == .hottest && settings.nameHottest ? 0 : 1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var batteryCard: some View {
        if let b = s.battery, b.present {
            header(.battery, wholePercent(b.percent), unit: "%")
            ChargeMeter(battery: b)
            sub(Text(BatteryStatus.text(b)), b.maxCapacityFraction.map { Text("Health ") + strong(Format.percent($0)) })
        }
    }

    /// The tile, "AI usage" and the summary pill; the rows and footer from `AICardBody`.
    @ViewBuilder private func aiCard(_ model: AICardModel?) -> some View {
        HStack {
            title(.ai)
            Spacer(minLength: 8)
            if settings.aiUsage.cardPill, let pill = model?.pill { AIPill(text: pill.text, color: pill.color) }
        }
        if let model { AICardBody(model: model) }
    }
}

/// What the overview card's "…" menu does, as pure rules.
enum CardMenu {
    /// "Customize this card…": Settings › Overview with the card's section selected.
    static func route(_ part: OverviewPart) -> SettingsRoute { .overview(part) }
    /// "Hide from overview": never the last card the popover shows.
    static func canHide(_ part: OverviewPart, shown: [OverviewPart]) -> Bool { shown.contains(part) && shown.count > 1 }
}

/// The card's state its "…" button reads: shown while the pointer (or keyboard) is on the card.
struct CardMenuState: Equatable {
    var shown = false
    var canHide = true
}

private struct CardMenuKey: EnvironmentKey { static let defaultValue: CardMenuState? = nil }
extension EnvironmentValues {
    var cardMenu: CardMenuState? {
        get { self[CardMenuKey.self] }
        set { self[CardMenuKey.self] = newValue }
    }
}

/// The "…" after a card's title: "Customize this card…" and "Hide from overview".
struct CardMenuButton: View {
    var part: OverviewPart
    @Environment(\.cardMenu) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services

    var body: some View {
        if let state, state.shown {
            // The label is an image: AppKit draws a menu's label from its text and images only,
            // so a SwiftUI-drawn glyph there never showed. The square behind it is SwiftUI's.
            Menu {
                CardMenuItems(part: part, canHide: state.canHide)
            } label: {
                Image(nsImage: HeronIcon.more.templateImage(size: 16, weight: 2.8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(Color.primary)
            .accessibilityLabel("\(part.title) card options")
        }
    }
}

/// The card menu's items drawn as an open macOS menu, for heron-snap's render of it.
struct DrawnCardMenu: View {
    var part: OverviewPart
    var canHide: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardMenuItems(part: part, canHide: canHide)
        }
        .buttonStyle(DrawnMenuItemStyle())
        .font(.system(size: 13))
        .padding(5)
        .frame(width: 200, alignment: .leading)
        .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .fixedSize()
    }
}

/// A drawn menu item: its title, greyed when it is disabled.
private struct DrawnMenuItemStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.primary : Theme.muted)
            .padding(.horizontal, 9).frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The card menu's items (the "…" menu and the card's right-click menu).
struct CardMenuItems: View {
    var part: OverviewPart
    var canHide: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services

    var body: some View {
        Button("Customize this card…") { services.openSettings(CardMenu.route(part)) }
        Divider()
        Button("Hide from overview") { settings.setHidden(part, true) }.disabled(!canHide)
    }
}

/// An overview card: full width, with room on the right for the › that opens the section's panel.
/// Under the pointer it lifts and shows its "…" menu; while its panel is open it has a border in
/// its colour and a lit ›; a hot card has a red border and ›. The keyboard's card has a focus ring.
/// It reports its frame so the pointer can be matched to it and its panel lined up with it; a
/// click opens its panel at once. VoiceOver: a button, "CPU, 34%, shows details".
struct OverviewCardFrame<Content: View>: View {
    var part: OverviewPart
    var open = false
    var focused = false
    var hot = false
    var canHide = true
    var spokenValue = ""
    var panels: DetailPanels?
    /// heron-snap: drawn as under the pointer, with its "…" menu open.
    var debugMenu = false
    @ViewBuilder var content: Content
    @State private var pointerOn = false

    private var hovered: Bool { pointerOn || debugMenu }

    var body: some View {
        Card(trailingInset: 15, spacing: 10, highlight: open ? 0.05 : (hovered ? 0.03 : 0)) { content }
            .overlay(alignment: .trailing) { Chevron(hovered: hovered, open: open, color: part.color, hot: hot).padding(.trailing, 7) }
            .overlay {
                if hot {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1)
                } else if open {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(part.color.opacity(0.55), lineWidth: 1)
                }
                if focused && !open {
                    RoundedRectangle(cornerRadius: 11).stroke(Theme.cpu, lineWidth: 2).padding(-1)
                }
            }
            // heron-snap's open menu (a real menu cannot be rendered off screen) is drawn over the
            // whole card: drawn inside the title row, the card's later rows painted over it.
            .overlay(alignment: .topLeading) {
                if debugMenu { DrawnCardMenu(part: part, canHide: canHide).padding(.leading, 60).padding(.top, 46) }
            }
            .environment(\.cardMenu, CardMenuState(shown: hovered || focused, canHide: canHide))
            .contentShape(Rectangle())
            .onHover { pointerOn = $0 }
            .onTapGesture { panels?.openNow(part) }
            .contextMenu { CardMenuItems(part: part, canHide: canHide) }
            .background {
                GeometryReader { geo in
                    // In the popover root's space, not `.global`: global is the popover WINDOW's
                    // space, which starts 13 pt outside the hosting view the pointer is read in.
                    let frame = geo.frame(in: .named(PopoverRoot.space))
                    Color.clear
                        .onAppear { panels?.reportFrame(part, frame) }
                        .onChange(of: frame) { _, new in panels?.reportFrame(part, new) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(part.title), \(spokenValue), shows details")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { panels?.openNow(part) }
    }
}
