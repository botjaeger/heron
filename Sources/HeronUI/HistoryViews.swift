import HeronCore
import SwiftUI

/// What every history row, link and button shares, like a menu item with a submenu: resting the
/// pointer on it opens its history beside the panel (`DetailPanels.pointerOnHistoryRow`), a click
/// opens it at once, and it reports its frame so the history lines up with it.
private struct HistoryHover: ViewModifier {
    var item: HistoryItem
    var panels: DetailPanels
    @Binding var hovered: Bool

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovered = inside
                panels.pointerOnHistoryRow(item, inside: inside)
            }
            .background {
                GeometryReader { geo in
                    // The panel's own space, never `.global` (see `CardFrameSpaceTests`).
                    let frame = geo.frame(in: .named(DetailPanels.space))
                    Color.clear
                        .onAppear { panels.reportHistoryFrame(item, frame) }
                        .onChange(of: frame) { _, new in panels.reportHistoryFrame(item, new) }
                }
            }
            .accessibilityAddTraits(panels.history == item ? .isSelected : [])
            .accessibilityHint(item.isAIResets ? "Shows each reset, what it refills and when it runs out" : "Shows its history")
    }
}

/// A panel row Heron keeps a history of: the row, then a chart glyph that brightens on hover;
/// resting on it (or clicking) opens that history beside the panel, and the row stays lit while
/// it is open. Without the panels (renders outside the app) the glyph still marks it.
struct HistoryRow<Content: View>: View {
    var item: HistoryItem
    @ViewBuilder var content: Content
    @Environment(DetailPanels.self) private var panels: DetailPanels?
    @State private var hovered = false

    var body: some View {
        let lit = hovered || panels?.history == item
        let row = HStack(spacing: 0) {
            content
            HeronIconView(.chart, size: 12, weight: 2)
                .foregroundStyle(lit ? Color.primary : Theme.muted)
                .frame(width: ChartGlyph.column, alignment: .trailing)
        }
        if let panels {
            Button {
                panels.showHistory(item)
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .background(Color.primary.opacity(lit ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, -6)
            .modifier(HistoryHover(item: item, panels: panels, hovered: $hovered))
        } else {
            row
        }
    }
}

/// Something that opens a history without a glyph of its own (a big rate figure).
struct HistoryLink<Content: View>: View {
    var item: HistoryItem
    @ViewBuilder var content: Content
    @Environment(DetailPanels.self) private var panels: DetailPanels?
    @State private var hovered = false

    var body: some View {
        if let panels {
            Button {
                panels.showHistory(item)
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered || panels.history == item ? 0.8 : 1)
            .modifier(HistoryHover(item: item, panels: panels, hovered: $hovered))
        } else {
            content
        }
    }
}

/// The small chart button beside a panel card's title: opens the history of its main number.
struct HistoryButton: View {
    var item: HistoryItem
    @Environment(DetailPanels.self) private var panels: DetailPanels?
    @State private var hovered = false

    var body: some View {
        let lit = hovered || panels?.history == item
        let button = Button {
            panels?.showHistory(item)
        } label: {
            HeronIconView(.chart, size: 12, weight: 2)
                .foregroundStyle(lit ? Color.primary : Theme.muted)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(lit ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title) history")
        if let panels {
            button.modifier(HistoryHover(item: item, panels: panels, hovered: $hovered))
        } else {
            button
        }
    }
}

/// A row's history in its own panel beside the open one (a submenu): `HistoryView` at the
/// prototype's 320 pt.
public struct HistoryPage: View {
    public var item: HistoryItem
    public static let width: CGFloat = 320

    public init(item: HistoryItem) { self.item = item }

    public var body: some View {
        Group {
            if case .aiResets(let account) = item.source {
                AIResetsPage(accountID: account)
            } else {
                HistoryView(item: item)
            }
        }
        .padding(14)
        .frame(width: Self.width)
    }
}

/// A row's history in its panel: the value now, the range under the title, an area chart over it
/// (1 min to 24 h) with gridlines, its scale and three time labels, a crosshair readout under the
/// pointer, and the range's low, average and high.
struct HistoryView: View {
    var item: HistoryItem
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(DetailPanels.self) private var panels: DetailPanels?

    /// Points drawn per range, as in the design.
    static func points(_ range: AppSettings.GraphRange) -> Int {
        switch range {
        case .oneMinute: return 60
        case .tenMinutes: return 120
        case .oneHour: return 180
        case .oneDay: return 240
        }
    }

    static func ago(_ range: AppSettings.GraphRange) -> String {
        switch range {
        case .oneMinute: return "1 min ago"
        case .tenMinutes: return "10 min ago"
        case .oneHour: return "1 hour ago"
        case .oneDay: return "24 hours ago"
        }
    }

    /// The axis's middle label: half the range ago.
    static func halfAgo(_ range: AppSettings.GraphRange) -> String { agoText(Double(range.rawValue) / 2) }

    /// "35 s ago", "4 min ago", "3 h ago".
    static func agoText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) min ago" }
        return "\(Int((Double(s) / 3600).rounded())) h ago"
    }

    static func text(_ value: Double, _ unit: HistoryItem.Unit, _ settings: AppSettings) -> String {
        switch unit {
        case .percent: return Format.percent(value)
        case .watts: return Format.watts(value)
        case .bytes: return Format.bytes(UInt64(max(0, value)))
        case .rate: return Format.rate(value)
        case .networkRate: return Format.rate(value, bits: settings.networkInBits)
        case .temperature: return Format.temperature(value, unit: settings.temperatureUnit)
        case .rpm: return Format.rpm(value)
        case .number: return String(format: "%.2f", value)
        case .count: return String(Int(value.rounded()))
        }
    }

    /// Low, average and high of what the chart shows; nil without values.
    static func stats(_ values: [Double]) -> (low: Double, average: Double, high: Double)? {
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low, values.reduce(0, +) / Double(values.count), high)
    }

    /// The value under the pointer: `fraction` across the chart (0 left, 1 right), with the data
    /// drawn over the right `coverage` of it (`TimeCovered`). Nil left of the data or without any.
    static func index(at fraction: Double, count: Int, coverage: Double) -> Int? {
        guard count > 0, coverage > 0 else { return nil }
        let start = 1 - min(1, coverage)
        guard fraction >= start - 1e-9, fraction <= 1 + 1e-9 else { return nil }
        let t = coverage >= 1 ? fraction : (fraction - start) / min(1, coverage)
        return min(count - 1, max(0, Int((t * Double(count - 1)).rounded())))
    }

    /// How long ago value `index` of `count` was, the values spanning `span` seconds up to now.
    static func secondsAgo(index: Int, count: Int, span: Double) -> Double {
        count > 1 ? Double(count - 1 - index) / Double(count - 1) * span : 0
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        let range = panels?.historyRange ?? .tenMinutes
        let values = monitor.history.series(item.source, seconds: range.rawValue, points: Self.points(range))
        let top = item.unit == .percent ? 1 : max(values.max() ?? 0, 0.0001) * 1.1
        let coverage = TimeAxis.coverage(recorded: monitor.history.seconds(item.source), range: range.rawValue)
        VStack(alignment: .leading, spacing: 10) {
            Card(spacing: 10) {
                HStack(spacing: 8) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(item.color).lineLimit(1)
                    Spacer(minLength: 8)
                    // No sample yet: no number (never a "–"); the chart says "Collecting…".
                    if let latest = monitor.history.latest(item.source) {
                        let now = NumberParts.split(Self.text(latest, item.unit, settings))
                        BigNumber(number: now.number, unit: now.unit, size: 24, unitSize: 13, unitColor: .primary)
                    }
                }
                RangePicker(selection: range) { panels?.historyRange = $0 }
                Group {
                    if values.count > 1 {
                        chart(values: values, top: top, coverage: coverage, range: range)
                    } else {
                        Text("Collecting…").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 150)
                .padding(.top, 14)
                AxisLabels(labels: [Self.ago(range), Self.halfAgo(range), "now"])
                if let stats = Self.stats(values) {
                    HStack(alignment: .top, spacing: 8) {
                        stat("Low", stats.low)
                        stat("Average", stats.average)
                        stat("High", stats.high)
                    }
                    .padding(.top, 10)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.track).frame(height: 1) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(item.title) history")
        }
    }

    private func stat(_ title: String, _ value: Double) -> some View {
        let parts = NumberParts.split(Self.text(value, item.unit, settings))
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
            BigNumber(number: parts.number, unit: parts.unit, size: 15, unitColor: .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The area chart with its guides and scale, and the readout under the pointer.
    private func chart(values: [Double], top: Double, coverage: Double, range: AppSettings.GraphRange) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let hover = panels?.historyHover.flatMap { Self.index(at: $0, count: values.count, coverage: coverage) }
            ZStack(alignment: .topLeading) {
                ChartGuides(top: true)
                TimeCovered(fraction: coverage) {
                    Sparkline(values: values, color: item.color, fixedMax: top, lineWidth: 1.8, fill: true)
                }
                Text(Self.text(top, item.unit, settings)).position(x: w, y: 0).offset(x: -scaleWidth(top) / 2, y: -8)
                Text(Self.text(top / 2, item.unit, settings)).position(x: w, y: h / 2).offset(x: -scaleWidth(top / 2) / 2, y: -8)
                if let i = hover {
                    let n = values.count
                    let x = w * (1 - coverage) + (n > 1 ? w * coverage * CGFloat(i) / CGFloat(n - 1) : w)
                    let y = h - h * CGFloat(min(1, max(0, values[i] / top)))
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    }
                    .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                    Circle().fill(item.color).overlay(Circle().stroke(Theme.card, lineWidth: 2)).frame(width: 8, height: 8).position(x: x, y: y)
                    let ago = Self.secondsAgo(index: i, count: n, span: coverage * Double(range.rawValue))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Self.clock.string(from: Date().addingTimeInterval(-ago))) · \(ago < 1 ? "now" : Self.agoText(ago))")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Text(Self.text(values[i], item.unit, settings)).font(Theme.number(13)).foregroundStyle(Color.primary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.settingsSelection, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.settingsLine, lineWidth: 1))
                    .fixedSize()
                    .position(x: min(max(x, 60), w - 60), y: 22)
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): panels?.historyHover = w > 0 ? Double(p.x / w) : nil
                case .ended: panels?.historyHover = nil
                }
            }
        }
    }

    /// Roughly how wide a scale label is, to set it flush right.
    private func scaleWidth(_ value: Double) -> CGFloat { CGFloat(Self.text(value, item.unit, settings).count) * 6.2 }
}

/// 1 min · 10 min · 1 h · 24 h across the card's width, the chosen one raised.
struct RangePicker: View {
    var selection: AppSettings.GraphRange
    var choose: (AppSettings.GraphRange) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSettings.GraphRange.allCases, id: \.self) { range in
                let on = range == selection
                Button {
                    choose(range)
                } label: {
                    Text(range.label).font(.system(size: 12, weight: on ? .semibold : .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .foregroundStyle(on ? Color.primary : Theme.muted)
                        .background(on ? Theme.settingsSegment : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }
}
