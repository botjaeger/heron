import AppKit
import HeronCore
import SwiftUI

/// Heron's one menu bar item: the Heron icon, followed by every metric enabled in
/// Settings › Menu Bar, in order. The status bar can only show an image or text, so this view is
/// rendered into an NSImage (see `MenuBarRenderer`). It is drawn in black: as a "template" image
/// macOS re-tints it to match the menu bar. When a value warns (and "Turn red" is on) it is drawn
/// in the warning red, and with metric colours each metric in its colour; then the whole image is
/// drawn in the menu bar's own ink instead (a template cannot hold colour).
public struct MenuBarLabel: View {
    public var snapshot: Snapshot { didSet { segments = makeSegments() } }
    public var history: MetricHistory { didSet { segments = makeSegments() } }
    public var settings: AppSettings { didSet { segments = makeSegments() } }
    public var ink: Color = .black { didSet { recolour() } }
    /// The menu bar is dark: picks the dark half of each colour pair. Only matters when the image holds colour.
    public var dark: Bool = false { didSet { recolour() } }
    /// The AI accounts, for the AI usage item. Without it that item draws nothing.
    public var ai: AIUsageService? { didSet { segments = makeSegments() } }

    public init(snapshot: Snapshot, history: MetricHistory, settings: AppSettings, ink: Color = .black, dark: Bool = false, ai: AIUsageService? = nil) {
        self.snapshot = snapshot; self.history = history; self.settings = settings; self.ink = ink; self.dark = dark; self.ai = ai
        segments = []
        segments = makeSegments()
    }

    /// The shown items this Mac has a reading source for: no battery or no fans draws nothing
    /// (never a "—" or "0 rpm" placeholder). AI usage with no limit to show right now (nothing
    /// running out, "Icon only") draws nothing either.
    /// Built once in `init` (and again when an input above is replaced): the body, the warning
    /// and colour checks, the spoken value and the render key all read it.
    private(set) var segments: [MenuBarSegment]

    private func makeSegments() -> [MenuBarSegment] {
        settings.shownItems.filter { Self.hasSource($0.kind, style: settings.style(of: $0.kind), in: snapshot, ai: ai) }.map {
            MenuBarSegment(kind: $0.kind, style: settings.style(of: $0.kind), snapshot: snapshot, history: history, settings: settings, ink: ink, dark: dark, ai: ai)
        }
        .filter { !$0.drawsNothing }
    }

    /// The ink and mode change only how the segments are drawn, never which are drawn.
    private mutating func recolour() {
        for i in segments.indices { segments[i].ink = ink; segments[i].dark = dark }
    }

    /// Everything the rendered image depends on: `StatusBarController` redraws the item only when
    /// this changes. The segments' drawn values and look, the glyph, the spacing, the ink, the
    /// menu bar's mode and the screen's scale (`RenderKeyTests` checks that equal keys draw equal
    /// images).
    public struct RenderKey: Equatable {
        var segments: [MenuBarSegment.RenderKey]
        var showsIcon: Bool
        var gap: CGFloat
        var ink: Color
        var dark: Bool
        var scale: CGFloat
    }

    public func renderKey(scale: CGFloat) -> RenderKey {
        RenderKey(segments: segments.map(\.renderKey), showsIcon: showsIcon, gap: settings.spacing.gap, ink: ink, dark: dark, scale: scale)
    }

    /// AI usage: only with at least one account that has a reading. `style`: the item's stored
    /// look, when it needs a reading of its own (fans as a percentage need a fan that reports its
    /// maximum; a temperature needs its sensor on this Mac).
    static func hasSource(_ kind: MenuItemKind, style: MenuItemStyle? = nil, in snapshot: Snapshot, ai: AIUsageService? = nil) -> Bool {
        let variant = style.map { kind.variant(for: $0) }
        switch kind {
        case .battery: return snapshot.battery?.present == true
        case .fans: return variant == .percent ? FanSummary.fraction(snapshot.fans) != nil : !snapshot.fans.isEmpty
        case .temperature: return variant.map { SensorSummary.value($0.sensor ?? .hottest, in: snapshot) != nil } ?? true
        case .ai: return ai.map(AIMenuBarItem.hasSource) ?? false
        default: return true
        }
    }

    /// The Heron glyph: when the user asked for it, or when no segment would draw (so the item
    /// never vanishes from the menu bar).
    var showsIcon: Bool { settings.showIcon || segments.isEmpty }

    public var isWarning: Bool { segments.contains { $0.isWarning } }

    /// True when the image holds colour (a red value or metric colours), so it cannot be a template.
    public var isColoured: Bool { segments.contains { $0.isColoured } }

    /// What VoiceOver reads for the item: the image alone says nothing.
    public var spokenValue: String {
        let parts = segments.map(\.spokenValue)
        return parts.isEmpty ? "Heron" : parts.joined(separator: ", ")
    }

    /// The status item's tooltip: the hottest sensor's full name, which the bar itself never shows
    /// ("Hottest sensor: CPU 25 · 81°"). Nil when the item shows no hottest temperature.
    public var toolTip: String? {
        guard segments.contains(where: { $0.kind == .temperature && $0.variant == .hottest }),
            let name = SensorSummary.hottestName(in: snapshot), let celsius = SensorSummary.value(.hottest, in: snapshot)
        else { return nil }
        return "Hottest sensor: \(name) · \(Format.temperature(celsius, unit: settings.temperatureUnit))"
    }

    public var body: some View {
        HStack(spacing: settings.spacing.gap) {
            if showsIcon { HeronGlyph(ink: ink).frame(width: 16, height: 16) }
            ForEach(segments, id: \.kind) { $0 }
        }
        .frame(height: 18)
        .fixedSize()
    }
}

/// One metric inside the menu bar item. Every variant says what its number is: a tag
/// ("CPU 16%", "CPU ▲78°") or a word ("351 GB free", "2,779 rpm"). A tag or a bar's label can be
/// turned off per item (`AppSettings.showsLabel`).
public struct MenuBarSegment: View {
    public var kind: MenuItemKind { didSet { aiItem = makeAIItem() } }
    public var style: MenuItemStyle
    public var snapshot: Snapshot
    public var history: MetricHistory
    public var settings: AppSettings { didSet { aiItem = makeAIItem() } }
    public var ink: Color = .black
    public var dark: Bool = false
    /// The AI accounts, for the AI usage item only.
    public var ai: AIUsageService? { didSet { aiItem = makeAIItem() } }

    public init(
        kind: MenuItemKind, style: MenuItemStyle, snapshot: Snapshot, history: MetricHistory, settings: AppSettings, ink: Color = .black, dark: Bool = false,
        ai: AIUsageService? = nil
    ) {
        self.kind = kind; self.style = style; self.snapshot = snapshot; self.history = history; self.settings = settings; self.ink = ink; self.dark = dark
        self.ai = ai
        aiItem = nil
        aiItem = makeAIItem()
    }

    /// The variant drawn: a style this kind does not offer becomes the kind's default.
    var variant: MenuItemStyle { kind.variant(for: style) }

    /// The limits the AI usage item shows; nil for every other kind. Built once in `init`: the
    /// warning, colour, spoken value and body all read it.
    private(set) var aiItem: AIMenuBarItem?

    private func makeAIItem() -> AIMenuBarItem? { kind == .ai ? ai.map { AIMenuBarItem(service: $0, settings: settings) } : nil }

    /// What this segment's picture depends on, beyond the label's ink and mode: its kind and look,
    /// its label, warning and colour, every text it draws (`spokenValue` and `labelWord` carry
    /// them at the precision drawn) and the numbers its glyphs draw unrounded.
    public struct RenderKey: Equatable {
        var kind: MenuItemKind
        var variant: MenuItemStyle
        var showsLabel: Bool
        var isWarning: Bool
        var isColoured: Bool
        var metricColours: Bool
        var labelWord: String
        var spokenValue: String
        var drawn: [Double]
        var ai: [String]
    }

    var renderKey: RenderKey {
        RenderKey(
            kind: kind, variant: variant, showsLabel: settings.showsLabel(kind), isWarning: isWarning, isColoured: isColoured,
            metricColours: settings.colourMode == .metric, labelWord: labelWord, spokenValue: spokenValue, drawn: drawnNumbers, ai: aiLook)
    }

    /// The numbers a bar, gauge, graph or battery glyph draws, unrounded; empty for text-only looks.
    private var drawnNumbers: [Double] {
        let s = snapshot
        switch (kind, variant) {
        case (.cpu, .bar), (.cpu, .gauge): return [s.cpu?.total ?? 0]
        case (.gpu, .bar), (.gpu, .gauge): return [s.gpu?.device ?? 0]
        case (.memory, .bar), (.memory, .gauge): return [s.memory?.usedFraction ?? 0]
        case (.cpu, .graph): return history[.cpu].last(8)
        case (.gpu, .graph): return history[.gpu].last(8)
        case (.memory, .graph): return history[.memory].last(8)
        case (.network, .graph): return history.series(.networkDown, seconds: 60, points: 20)
        case (.disk, .bar): return [rootVolume?.usedFraction ?? 0]
        case (.battery, .percent): return []
        case (.battery, _): return [battery?.percent ?? 0, battery?.chargeLimit ?? -1]
        default: return []
        }
    }

    /// The AI item's look beyond its spoken value: each limit's tone, and how limits and providers are shown.
    private var aiLook: [String] {
        guard let item = aiItem else { return [] }
        return item.entries.map { "\($0.id) \($0.tone)" } + ["\(item.options.showLimitName) \(item.options.providersAs) \(item.options.display)"]
    }

    /// AI usage with no limit to show: the segment is left out (`MenuBarLabel.segments`).
    var drawsNothing: Bool { kind == .ai && (aiItem?.isEmpty ?? true) }

    /// True when the segment's values should be drawn in the warning red.
    public var isWarning: Bool {
        guard settings.warnRed, !isWaiting else { return false }
        switch kind {
        case .temperature: return SensorSummary.value(sensor, in: snapshot).map(Warnings.isHot) ?? false
        case .memory: return snapshot.memory?.pressure == .critical
        case .disk: return rootVolume.map(Warnings.isNearlyFull) ?? false
        case .battery: return snapshot.battery.map(Warnings.isLow) ?? false
        case .ai: return aiItem?.isWarning ?? false
        default: return false
        }
    }

    /// True when the segment is drawn in a colour (not the plain ink).
    public var isColoured: Bool {
        isWarning || (aiItem?.isColoured(metric: settings.colourMode == .metric) ?? false)
            || (settings.colourMode == .metric && Theme.Palette.pair(for: kind.color) != nil)
    }

    /// The ink the segment is drawn in: warning red, its metric colour, or the menu bar ink.
    /// AI usage colours each limit on its own (`AIMenuBarItem.Tone`), so it gets the plain ink.
    var valueInk: Color {
        if kind == .ai { return ink }
        if isWarning { return Theme.resolved(Theme.Palette.warning, dark: dark) }
        if settings.colourMode == .metric, let pair = Theme.Palette.pair(for: kind.color) { return Theme.resolved(pair, dark: dark) }
        return ink
    }

    /// No readings yet (`Snapshot.awaitingReadings`): the segment keeps its width and draws
    /// nothing, never "CPU 0%". AI usage has readings of its own.
    var isWaiting: Bool { snapshot.awaitingReadings && kind != .ai }

    public var body: some View {
        content(ink: valueInk)
            .opacity(isWaiting ? 0 : 1)
            .frame(height: 18)
            .fixedSize()
    }

    /// Widest text each value can take. Every number is drawn in a box this wide, so the menu bar
    /// items do not shift left and right as values gain or lose digits ("CPU 9%" → "CPU 10%").
    /// The value starts at the box's leading edge, right after its tag or glyph ("CPU 83°", not
    /// "CPU   83°"): the room a shorter value leaves falls after it, into the gap to the next part.
    /// Only digits are reserved, never a name: the hottest sensor's name is in the tooltip.
    enum Widest {
        static let percent = "100%"
        static let temperature = "100°"
        static let rate = "999 KB/s"
        static let disk = "999 GB"
        static let rpm = "9,999 rpm"
        static let memory = "99.9 GB"
        static let pressure = "Critical"
    }

    /// Space between a value and its tag or glyph.
    static let gap: CGFloat = 5

    private func number(_ text: String, ink: Color, widest: String) -> some View {
        ZStack(alignment: .leading) {
            Text(widest).hidden()
            Text(text)
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .foregroundStyle(ink)
    }

    /// The tag's type: small bold system type, slightly spaced, drawn at 70% of the ink.
    static let tagFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    static let tagTracking: CGFloat = 0.4

    /// What a number is ("CPU", "DISK", "PRESSURE"), in small system type before it.
    private func tag(_ text: String, ink: Color) -> some View {
        Text(text).font(Font(Self.tagFont)).tracking(Self.tagTracking).foregroundStyle(ink.opacity(0.7)).fixedSize()
    }

    /// The hottest temperature's marker, before its value: "CPU ▲81°".
    private func marker(ink: Color) -> some View {
        Text("▲").font(.system(size: 7, weight: .bold)).foregroundStyle(ink).fixedSize()
    }

    /// The value after its tag; with the item's label off (Settings › Menu Bar), the value alone.
    /// `marked`: the hottest sensor's ▲ before the value, with or without the tag.
    @ViewBuilder
    private func tagged(_ label: String, _ text: String, ink: Color, widest: String, marked: Bool = false) -> some View {
        HStack(spacing: Self.gap) {
            if settings.showsLabel(kind), !label.isEmpty { tag(label, ink: ink) }
            HStack(spacing: 2) {
                if marked { marker(ink: ink) }
                number(text, ink: ink, widest: widest)
            }
        }
    }

    private var sensor: AppSettings.SensorChoice { variant.sensor ?? .hottest }

    /// The word the look's label shows: over its bar or before its value ("CPU", "DISK",
    /// "PRESSURE", the hottest sensor's group). Settings › Menu Bar quotes it in the label's hint.
    var labelWord: String {
        switch kind {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return variant == .pressure ? "PRESSURE" : "MEM"
        case .temperature: return sensorTag
        case .disk: return "DISK"
        case .fans: return "FAN"
        case .network, .battery, .ai: return ""
        }
    }

    /// What a tagged look shows after its tag, the hottest marker included ("▲81°", "34%").
    var taggedValue: String {
        let s = snapshot
        switch kind {
        case .cpu: return Format.percent(s.cpu?.total ?? 0)
        case .gpu: return Format.percent(s.gpu?.device ?? 0)
        case .memory: return variant == .pressure ? pressureText : Format.percent(s.memory?.usedFraction ?? 0)
        case .temperature: return (sensor == .hottest ? "▲" : "") + temperatureText
        case .disk: return rootVolume.map { Format.percent($0.usedFraction) } ?? "–"
        case .fans: return fanPercent
        case .network, .battery, .ai: return ""
        }
    }

    /// The temperature's tag: the chosen sensor, or the hottest sensor's group ("CPU" for "CPU 25").
    private var sensorTag: String {
        switch sensor {
        case .hottest: return snapshot.hottest.map { Self.groupTag($0.group) } ?? ""
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        }
    }

    /// A sensor group as a menu bar tag: a short word in capitals, never the sensor's own name.
    static func groupTag(_ group: Sensor.Group) -> String {
        switch group {
        case .cpu, .cpuPerformance, .cpuEfficiency: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .ssd: return "SSD"
        case .battery: return "BAT"
        case .surface: return "CASE"
        case .wireless: return "WIFI"
        case .other: return "TEMP"
        }
    }

    private var temperatureText: String {
        SensorSummary.value(sensor, in: snapshot).map { Format.temperature($0, unit: settings.temperatureUnit) } ?? "–"
    }

    private var rootVolume: VolumeReading? { snapshot.rootVolume }
    private var battery: BatteryReading? { snapshot.battery.flatMap { $0.present ? $0 : nil } }

    /// Memory pressure as a percentage, or the level word when the kernel gives no number.
    private var pressureText: String {
        guard let m = snapshot.memory else { return "–" }
        return m.pressurePercent.map(Format.percent) ?? m.pressure.rawValue.capitalized
    }

    private var memoryUsed: String { snapshot.memory.map { Format.bytes($0.used) } ?? "–" }
    /// Free plus cached files: what apps can still get.
    private var memoryAvailable: String { snapshot.memory.map { Format.bytes($0.free + $0.cached) } ?? "–" }

    /// Every fan together (`FanSummary`), as the overview shows them.
    private var fanPercent: String { FanSummary.fraction(snapshot.fans).map(Format.percent) ?? "–" }
    private var fanRPM: String { FanSummary.rpm(snapshot.fans).map(Format.rpm) ?? "–" }

    private func rate(_ value: Double?) -> String { Format.rate(value ?? 0, bits: settings.networkInBits) }

    /// What VoiceOver reads for the item: the image alone says nothing.
    public var spokenValue: String {
        if isWaiting { return "\(kind.title), no reading yet" }
        let s = snapshot
        switch kind {
        case .cpu: return "CPU \(Format.percent(s.cpu?.total ?? 0))"
        case .gpu: return "GPU \(Format.percent(s.gpu?.device ?? 0))"
        case .memory:
            switch variant {
            case .usedGB: return "Memory \(memoryUsed) used"
            case .freeGB: return "Memory \(memoryAvailable) available"
            case .pressure: return "Memory pressure \(pressureText.lowercased())"
            default: return "Memory \(Format.percent(s.memory?.usedFraction ?? 0)) used"
            }
        case .temperature:
            // The hottest sensor's name is the item's tooltip (`MenuBarLabel.toolTip`), read as its help.
            return "\(sensor == .hottest ? "Hottest" : sensorTag) temperature \(temperatureText)"
        case .network:
            switch variant {
            case .both: return "Network down \(rate(s.network?.downBytesPerSecond)), up \(rate(s.network?.upBytesPerSecond))"
            case .up: return "Network up \(rate(s.network?.upBytesPerSecond))"
            default: return "Network down \(rate(s.network?.downBytesPerSecond))"
            }
        case .disk:
            guard let root = rootVolume else { return "Startup disk" }
            switch variant {
            case .used: return "Startup disk \(Format.diskBytes(root.used)) used"
            case .percent, .bar: return "Startup disk \(Format.percent(root.usedFraction)) used"
            default: return "Startup disk \(Format.diskBytes(root.available)) free"
            }
        case .fans:
            guard !s.fans.isEmpty else { return "No fans" }
            return variant == .percent ? "Fans \(fanPercent) of maximum" : "Fans \(fanRPM)"
        case .battery: return battery.map { "Battery \(Format.percent($0.percent))\($0.isCharging ? ", charging" : "")" } ?? "No battery"
        case .ai: return aiItem?.spokenValue ?? "AI usage"
        }
    }

    @ViewBuilder
    private func content(ink: Color) -> some View {
        let s = snapshot
        switch (kind, variant) {
        case (.cpu, _):
            percentItem(label: labelWord, value: s.cpu?.total ?? 0, metric: .cpu, ink: ink)
        case (.gpu, _):
            percentItem(label: labelWord, value: s.gpu?.device ?? 0, metric: .gpu, ink: ink)
        case (.memory, .usedGB):
            number("\(memoryUsed) used", ink: ink, widest: "\(Widest.memory) used")
        case (.memory, .freeGB):
            number("\(memoryAvailable) available", ink: ink, widest: "\(Widest.memory) available")
        case (.memory, .pressure):
            tagged(labelWord, pressureText, ink: ink, widest: s.memory?.pressurePercent == nil ? Widest.pressure : Widest.percent)
        case (.memory, _):
            percentItem(label: labelWord, value: s.memory?.usedFraction ?? 0, metric: .memory, ink: ink)
        case (.temperature, _):
            tagged(labelWord, temperatureText, ink: ink, widest: Widest.temperature, marked: sensor == .hottest)
        case (.network, .both):
            // Download above upload, each right-aligned so the units line up.
            ZStack(alignment: .trailing) {
                VStack(alignment: .trailing, spacing: -1) {
                    Text("↓ \(Widest.rate)"); Text("↑ \(Widest.rate)")
                }.hidden()
                VStack(alignment: .trailing, spacing: -1) {
                    Text("↓ \(rate(s.network?.downBytesPerSecond))")
                    Text("↑ \(rate(s.network?.upBytesPerSecond))")
                }
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(ink)
        case (.network, .up):
            number("↑ \(rate(s.network?.upBytesPerSecond))", ink: ink, widest: "↑ \(Widest.rate)")
        case (.network, .graph):
            HStack(spacing: Self.gap) {
                Sparkline(values: history.series(.networkDown, seconds: 60, points: 20), color: ink, fixedMax: nil, lineWidth: 1.5)
                    .frame(width: 28, height: 14)
                number("↓ \(rate(s.network?.downBytesPerSecond))", ink: ink, widest: "↓ \(Widest.rate)")
            }
        case (.network, _):
            number("↓ \(rate(s.network?.downBytesPerSecond))", ink: ink, widest: "↓ \(Widest.rate)")
        case (.disk, .used):
            number("\(rootVolume.map { Format.diskBytes($0.used) } ?? "–") used", ink: ink, widest: "\(Widest.disk) used")
        case (.disk, .percent):
            tagged(labelWord, rootVolume.map { Format.percent($0.usedFraction) } ?? "–", ink: ink, widest: Widest.percent)
        case (.disk, .bar):
            LabelledBar(label: labelWord, fraction: rootVolume?.usedFraction ?? 0, ink: ink, showLabel: settings.showsLabel(kind))
        case (.disk, _):
            number("\(rootVolume.map { Format.diskBytes($0.available) } ?? "–") free", ink: ink, widest: "\(Widest.disk) free")
        case (.fans, .percent):
            tagged(labelWord, fanPercent, ink: ink, widest: Widest.percent)
        case (.fans, _):
            number(fanRPM, ink: ink, widest: Widest.rpm)
        case (.battery, .icon):
            TemplateBattery(fraction: battery?.percent ?? 0, limit: battery?.chargeLimit, ink: ink)
        case (.battery, .percent):
            // A Mac without a battery shows a dash, not "0%".
            number(battery.map { Format.percent($0.percent) } ?? "–", ink: ink, widest: Widest.percent)
        case (.battery, _):
            HStack(spacing: Self.gap) {
                TemplateBattery(fraction: battery?.percent ?? 0, limit: battery?.chargeLimit, ink: ink)
                // A Mac without a battery shows a dash, not "0%" next to an empty battery.
                number(battery.map { Format.percent($0.percent) } ?? "–", ink: ink, widest: Widest.percent)
            }
        case (.ai, _):
            if let item = aiItem { AIMenuBarView(item: item, ink: ink, dark: dark, metric: settings.colourMode == .metric) }
        }
    }

    @ViewBuilder
    private func percentItem(label: String, value: Double, metric: Metric, ink: Color) -> some View {
        switch variant {
        case .bar:
            LabelledBar(label: label, fraction: value, ink: ink, showLabel: settings.showsLabel(kind))
        case .graph:
            HStack(spacing: Self.gap) {
                // The last 8 seconds, one bar each.
                BarGraph(values: history[metric].last(8), ink: ink)
                    .frame(width: 26, height: 14)
                number(Format.percent(value), ink: ink, widest: Widest.percent)
            }
        case .gauge:
            HStack(spacing: Self.gap) {
                GaugeGlyph(fraction: value, ink: ink).frame(width: 16, height: 16)
                number(Format.percent(value), ink: ink, widest: Widest.percent)
            }
        default:
            tagged(label, Format.percent(value), ink: ink, widest: Widest.percent)
        }
    }
}

// MARK: - AI usage

/// What the AI usage item shows: the limits "most urgent" ranks first (up to Settings › Menu Bar ›
/// How many, the rest as "+N"), or exactly the chosen limits in their order. Only limits with a
/// percentage (a bounded limit) show; a chosen limit whose account or metric is gone is skipped.
@MainActor
struct AIMenuBarItem {
    /// Orange at the warning threshold, red at critical or burning fast; only with Red warnings on.
    enum Tone: Equatable, Sendable { case plain, caution, warning }

    struct Entry: Identifiable {
        var line: AILimitLine
        /// "P", "A1" when the provider has several accounts.
        var initials: String?
        var tone: Tone
        var id: String { line.id }
    }

    var entries: [Entry]
    /// Limits "most urgent" would show beyond How many: the "+N" chip.
    var overflow: Int
    var options: AIUsageSettings

    init(service: AIUsageService, settings: AppSettings, now: Date = Date()) {
        self.init(service: service, options: settings.aiUsage, warnRed: settings.warnRed, now: now)
    }

    /// `options` on their own: Settings › Menu Bar previews the mode that is not chosen.
    init(service: AIUsageService, options o: AIUsageSettings, warnRed: Bool, now: Date = Date()) {
        options = o
        let lines = service.lines.filter { $0.percentLeft != nil }
        var shown: [AILimitLine]
        switch o.menuMode {
        case .mostUrgent:
            let ids = Set(lines.map(\.id))
            let ranked = AIPriorityBoard(lines: service.lines, options: o.boardOptions, now: now)
                .menuBar(alwaysShow: o.alwaysShow).map(\.line).filter { ids.contains($0.id) }
            let count = min(5, max(0, o.menuCount))
            shown = Array(ranked.prefix(count))
            overflow = count == 0 ? 0 : ranked.count - shown.count
        case .chosen:
            shown = o.menuChosen.compactMap { id in lines.first { $0.id == id } }
            overflow = 0
        }
        entries = shown.map { line in
            Entry(
                line: line, initials: service.initials(line.account),
                tone: Self.tone(line, o, warnRed: warnRed, now: now))
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    var isWarning: Bool { entries.contains { $0.tone == .warning } }
    /// A tone, or with Colour set to Metric a provider with its own colour (Claude's orange).
    func isColoured(metric: Bool) -> Bool {
        entries.contains { $0.tone != .plain || (metric && ProviderMark.menuPair($0.line.account.provider) != nil) }
    }

    /// An account with a reading: the item has something it can show.
    static func hasSource(_ service: AIUsageService) -> Bool {
        service.accounts.contains { !(service.readings[$0.id]?.metrics.isEmpty ?? true) }
    }

    nonisolated static func tone(_ line: AILimitLine, _ o: AIUsageSettings, warnRed: Bool, now: Date = Date()) -> Tone {
        guard warnRed else { return .plain }
        let severity = line.severity(o.thresholds)
        if severity == .critical || line.isBurningFast(now: now) { return .warning }
        return severity == .warning ? .caution : .plain
    }

    /// "49% left" or "51% used" (Settings › AI Usage › Show usage as).
    nonisolated static func valueText(_ line: AILimitLine, _ display: AIUsageSettings.Display) -> String {
        let left = line.remainingFraction ?? 0
        return display == .left ? "\(Format.percent(left)) left" : "\(Format.percent(1 - left)) used"
    }

    /// The widest value, reserved so the item keeps its width as numbers change.
    nonisolated static let widest = "100%"

    /// What the menu bar draws: the number alone ("35%"); left or used follows Show usage as, and
    /// the spoken value and the panel keep the word.
    nonisolated static func menuText(_ line: AILimitLine, _ display: AIUsageSettings.Display) -> String {
        let left = line.remainingFraction ?? 0
        return Format.percent(display == .left ? left : 1 - left)
    }

    /// "Claude Weekly 49% left, ChatGPT 5 hours 8% left, 2 more".
    var spokenValue: String {
        var parts = entries.map { e in
            [e.line.account.provider.name, e.initials, e.line.metric.title, Self.valueText(e.line, options.display)].compactMap { $0 }.joined(separator: " ")
        }
        if overflow > 0 { parts.append("\(overflow) more") }
        return parts.isEmpty ? "AI usage" : parts.joined(separator: ", ")
    }
}

/// The AI usage item: per limit the provider's mark (initials beside it for one of several accounts)
/// or its name, then the limit's name in small capitals over its value; "+N" for limits waiting.
struct AIMenuBarView: View {
    var item: AIMenuBarItem
    var ink: Color
    var dark: Bool
    /// Colour set to Metric: a provider with its own colour (Claude) draws its mark, tag and value
    /// in it; a running-out tone still wins, like the other metrics' warning red.
    var metric = false

    /// Space between two limits.
    static let spacing: CGFloat = 8
    static let markSize: CGFloat = 13

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(item.entries) { entry($0) }
            if item.overflow > 0 { overflowChip }
        }
    }

    /// The provider's ink: its own colour with Colour set to Metric, else the menu bar ink.
    private func providerInk(_ p: AIProvider) -> Color {
        if metric, let pair = ProviderMark.menuPair(p) { return Theme.resolved(pair, dark: dark) }
        return ink
    }

    private func toneInk(_ tone: AIMenuBarItem.Tone, _ p: AIProvider) -> Color {
        switch tone {
        case .plain: return providerInk(p)
        case .caution: return Theme.resolved(Theme.Palette.caution, dark: dark)
        case .warning: return Theme.resolved(Theme.Palette.warning, dark: dark)
        }
    }

    private func entry(_ e: AIMenuBarItem.Entry) -> some View {
        let valueInk = toneInk(e.tone, e.line.account.provider)
        let named = item.options.showLimitName
        let widest = AIMenuBarItem.widest
        return HStack(spacing: MenuBarSegment.gap - 1) {
            provider(e)
            VStack(alignment: .leading, spacing: -2) {
                if named {
                    Text(e.line.metric.title.uppercased()).font(.system(size: 7, weight: .bold)).tracking(0.2)
                        .foregroundStyle(valueInk.opacity(0.75)).fixedSize()
                }
                ZStack(alignment: .leading) {
                    Text(widest).hidden()
                    Text(AIMenuBarItem.menuText(e.line, item.options.display))
                }
                .font(.system(size: named ? 10.5 : 12, weight: .bold, design: .monospaced))
                .foregroundStyle(valueInk)
            }
        }
    }

    @ViewBuilder
    private func provider(_ e: AIMenuBarItem.Entry) -> some View {
        let p = e.line.account.provider
        let ink = providerInk(p)
        if item.options.providersAs == .name {
            Text(e.initials.map { "\(p.name) \($0)" } ?? p.name).font(.system(size: 11, weight: .bold)).foregroundStyle(ink).fixedSize()
        } else {
            HStack(alignment: .bottom, spacing: 1) {
                Image(nsImage: ProviderMark.templateImage(p, size: Self.markSize)).renderingMode(.template)
                    .foregroundStyle(ink).frame(width: Self.markSize, height: Self.markSize)
                if let initials = e.initials {
                    Text(initials).font(.system(size: 7.5, weight: .heavy)).foregroundStyle(ink).fixedSize().offset(y: 2)
                }
            }
        }
    }

    /// "+2": more limits are running out than How many shows. Room for one digit is kept.
    private var overflowChip: some View {
        ZStack {
            Text("+9").hidden()
            Text("+\(item.overflow)")
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(ink)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(ink.opacity(0.2), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Tiny glyphs drawn with Canvas (they must render offscreen, so no SF Symbols tinting tricks)

/// The mark in one ink for the menu bar: the dial faint, the filled part, head and beak solid.
struct HeronGlyph: View {
    var ink: Color
    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 100, y: size.height / 100)
            ctx.fill(Path(HeronShape.parts(glyph: true).track), with: .color(ink.opacity(HeronShape.glyphTrackOpacity)))
            for part in HeronShape.glyphSolid { ctx.fill(Path(part), with: .color(ink)) }
        }
    }
}

/// "CPU" in small capitals over a filled capsule: the track is the ink at 28%, the load the full
/// ink with round ends. A load above zero is never thinner than the capsule is tall, so a low
/// load still reads as a dot. No outline.
/// `showLabel` false (Settings › Menu Bar › the item's "Label above the bar") leaves the meter alone.
struct LabelledBar: View {
    var label: String
    var fraction: Double
    var ink: Color
    var showLabel = true

    static let size = CGSize(width: 26, height: 5)

    /// The load's width: its share of the track, at least the capsule's height when above zero.
    static func fill(_ fraction: Double) -> CGFloat {
        let f = CGFloat(min(1, max(0, fraction)))
        return f > 0 ? max(size.height, size.width * f) : 0
    }

    var body: some View {
        VStack(spacing: 2.5) {
            if showLabel { Text(label).font(.system(size: 7.5, weight: .bold)).tracking(0.5).foregroundStyle(ink).fixedSize() }
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.28))
                Capsule().fill(ink).frame(width: Self.fill(fraction))
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
        .frame(width: Self.size.width)
    }
}

struct BarGraph: View {
    var values: [Double]
    var ink: Color
    var body: some View {
        Canvas { ctx, size in
            let bars = max(values.count, 1)
            let w = size.width / CGFloat(bars)
            for (i, v) in values.enumerated() {
                let h = max(1, size.height * CGFloat(min(1, max(0, v))))
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(1, w - 1), height: h)), with: .color(ink))
            }
        }
    }
}

/// A dial open at the bottom (270°, from lower left to lower right) with a needle.
struct GaugeGlyph: View {
    var fraction: Double
    var ink: Color
    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height * 0.55)
            let r = side * 0.375
            var arc = Path()
            arc.addArc(center: center, radius: r, startAngle: .degrees(135), endAngle: .degrees(45), clockwise: false)
            ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            let angle = Angle.degrees(135 + 270 * min(1, max(0, fraction)))
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(x: center.x + cos(angle.radians) * side * 0.275, y: center.y + sin(angle.radians) * side * 0.275))
            ctx.stroke(needle, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }
}

/// A battery outline filled to the charge, with the nub, and a tick at the charge limit when known.
struct TemplateBattery: View {
    var fraction: Double
    var limit: Double?
    var ink: Color
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(ink, lineWidth: 1).frame(width: 20, height: 11)
                RoundedRectangle(cornerRadius: 1.5).fill(ink).frame(width: max(1, 16 * fraction), height: 7).padding(.leading, 2)
                if let limit {
                    // Taller than the outline so it reads as a mark, not part of the fill.
                    Rectangle().fill(ink).frame(width: 1.5, height: 15).offset(x: 2 + 16 * CGFloat(min(1, max(0, limit))) - 0.75)
                }
            }
            RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: 1.5, height: 4)
        }
    }
}

/// Renders a `MenuBarLabel` to an NSImage for the status item (`StatusBarController`).
@MainActor
public enum MenuBarRenderer {
    /// Any view as an image `scale` pixels per point, sized in points; nil when nothing renders.
    /// The one ImageRenderer-to-NSImage conversion (the menu bar, its Settings previews, a copied AI picture).
    static func image<V: View>(_ view: V, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    /// One segment as an image, in the ink it was given: Settings › Menu Bar's look tiles, which
    /// shrink a look wider than its tile instead of cutting it.
    static func image(of segment: MenuBarSegment, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> NSImage {
        image(segment, scale: scale) ?? NSImage(size: NSSize(width: 18, height: 18))
    }

    public static func image(for label: MenuBarLabel, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> NSImage {
        guard let image = image(label, scale: scale) else { return NSImage(size: NSSize(width: 18, height: 18)) }
        image.isTemplate = !label.isColoured
        return image
    }
}
