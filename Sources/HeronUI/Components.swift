import HeronCore
import SwiftUI

/// A rounded panel, the basic block of every popover.
struct Card<Content: View>: View {
    /// Extra room on the right, for a control drawn over the card's edge (the overview's ›).
    var trailingInset: CGFloat = 0
    var spacing: CGFloat = 8
    /// A lift over the card colour: an overview card under the pointer, or with its panel open.
    var highlight: Double = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(12)
            .padding(.trailing, trailingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(highlight)))
            }
    }
}

/// "31 KB/s" → ("31", "KB/s"): a formatted reading split at its last space, for a big number with
/// a small unit. A reading without a unit is all number.
enum NumberParts {
    static func split(_ text: String) -> (number: String, unit: String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

/// A big number with its unit smaller beside it ("34%", "27.5 of 36 GB"). A "%" or "°" sits
/// tight in the number's colour; a word unit gets a space and the muted colour unless `unitColor`.
struct BigNumber: View {
    var number: String
    var unit: String = ""
    var size: CGFloat = 20
    var unitSize: CGFloat = 11
    var color: Color = .primary
    var unitColor: Color?

    var body: some View {
        let tight = unit == "%" || unit == "°" || unit.isEmpty
        (Text(number).font(Theme.number(size)).foregroundStyle(color)
            + Text(tight ? unit : " " + unit).font(Theme.number(unitSize, weight: .semibold)).foregroundStyle(unitColor ?? (tight ? color : Theme.muted)))
            .lineLimit(1).fixedSize()
    }
}

/// A panel group's caption in small caps, with an optional note at the right ("14 total").
struct PanelCaption: View {
    var text: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1) }
        }
    }
}

/// Labels spread under a chart: "10 min ago … now", or three with a middle one.
struct AxisLabels: View {
    var labels: [String]
    var body: some View {
        HStack {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                if i > 0 { Spacer(minLength: 4) }
                Text(label).lineLimit(1)
            }
        }
        .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
    }
}

/// A chart's guides: a dashed line at half height and a solid baseline (and a dashed top when asked).
struct ChartGuides: View {
    var top = false
    var body: some View {
        Canvas { ctx, size in
            let dash = StrokeStyle(lineWidth: 1, dash: [2, 3])
            let color = GraphicsContext.Shading.color(Theme.track)
            func line(_ y: CGFloat) -> Path {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            if top { ctx.stroke(line(0.5), with: color, style: dash) }
            ctx.stroke(line((size.height / 2).rounded() + 0.5), with: color, style: dash)
            ctx.stroke(line(size.height - 0.5), with: color, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A panel's main card head: the title in the section colour, the chart button that opens its
/// history, and the big value on the right.
struct MetricHeader: View {
    var title: String
    var color: Color
    var history: HistoryItem?
    var number: String
    var unit: String = ""
    var numberColor: Color?
    var unitColor: Color?
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            if let history { HistoryButton(item: history) }
            Spacer(minLength: 8)
            BigNumber(number: number, unit: unit, size: size, unitSize: size * 15 / 28, color: numberColor ?? color, unitColor: unitColor)
        }
    }
}

/// A line graph of recent values. `fixedMax` = 1 for percentages; nil scales to the data.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var fixedMax: Double? = 1
    var lineWidth: CGFloat = 2
    var fill = false

    var body: some View {
        GeometryReader { geo in
            let top = max(fixedMax ?? (values.max() ?? 1), 0.0001)
            let points = values.enumerated().map { i, v in
                CGPoint(
                    x: values.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1) : geo.size.width,
                    y: geo.size.height - geo.size.height * CGFloat(min(1, max(0, v / top))))
            }
            ZStack {
                if fill, let first = points.first, let last = points.last {
                    Path { p in
                        // addLine, not addLines: addLines would start a new sub-path and break the fill.
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        for point in points { p.addLine(to: point) }
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        p.closeSubpath()
                    }.fill(color.opacity(0.15))
                }
                Path { p in p.addLines(points) }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

enum TimeAxis {
    /// `recorded` seconds of data over a `range`-second axis, 0...1.
    static func coverage(recorded: Int, range: Int) -> Double { range > 0 ? min(1, max(0, Double(recorded) / Double(range))) : 1 }
}

/// A graph under an "x ago … now" axis, drawn over the part of the axis its data covers: Heron
/// started 2 minutes ago, so a 24-hour graph is a sliver at the right, not 2 minutes stretched
/// to look like a day.
struct TimeCovered<Content: View>: View {
    /// Seconds of data over seconds of axis.
    var fraction: Double
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))), height: geo.size.height)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A thin horizontal bar, 0...1.
struct Meter: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityValue(Format.percent(fraction))
    }
}

/// A thin bar split into coloured parts side by side (memory: App, Wired, Compressed), 0...1 each.
struct SplitMeter: View {
    var parts: [(fraction: Double, color: Color)]
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(BigRing.segments(parts.map(\.fraction)).enumerated()), id: \.offset) { i, seg in
                    Rectangle().fill(parts[i].color).frame(width: geo.size.width * CGFloat(seg.end - seg.start))
                }
                Spacer(minLength: 0)
            }
            .background(Theme.track)
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// "Label ........ value" row.
struct KeyValueRow: View {
    var key: String
    var value: String
    var valueColor: Color = .primary
    var dot: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let dot { RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 8, height: 8) }
            // One line, like every row: a long fan or sensor name is shortened, not wrapped.
            Text(key).foregroundStyle(dot == nil ? Theme.muted : .primary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value).font(Theme.number(12, weight: .medium)).foregroundStyle(valueColor).lineLimit(1)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}

/// CPU history as stacked bars: user load in the CPU colour at the bottom, system load in grey on
/// top, one bar per time bucket. Below it, a legend with the current user and system shares.
struct UserSystemBars: View {
    var total: [Double]  // MetricHistory .cpu, 0...1
    var system: [Double]  // MetricHistory .cpuSystem, same buckets
    var user: Double  // current readings for the legend
    var systemNow: Double
    var height: CGFloat = 50
    var trailing: Text?
    /// Bars across the full width. Fewer readings than that fill from the right (newest at the
    /// right edge), so a fresh launch shows a few thin bars instead of a few wide ones.
    var slots: Int = 60
    /// The legend under the chart (a panel draws its time axis between them instead).
    var legend = true

    static let systemColor = Theme.muted

    /// Index of the slot the oldest shown bar sits in.
    static func firstSlot(count: Int, slots: Int) -> Int { max(0, slots - count) }

    /// (user, system) per bucket, each clamped so the stack never goes below 0 or above 1.
    static func stacks(total: [Double], system: [Double]) -> [(user: Double, system: Double)] {
        // Align on the newest values when one series is shorter (it started later).
        let n = min(total.count, system.count)
        return zip(total.suffix(n), system.suffix(n)).map { all, sys in
            let a = all.unitClamped, s = min(sys.unitClamped, a)
            return (a - s, s)
        }
    }

    /// At most one bar per pixel: past that, every `stride`-th bucket counting back from the newest
    /// (which stays at the right edge), in proportionally fewer slots.
    static func downsampled(_ stacks: [(user: Double, system: Double)], slots: Int, pixels: Int) -> (stacks: [(user: Double, system: Double)], slots: Int) {
        let pixels = max(pixels, 1)
        guard slots > pixels else { return (stacks, slots) }
        let stride = (slots + pixels - 1) / pixels
        let kept = Swift.stride(from: stacks.count - 1, through: 0, by: -stride).reversed().map { stacks[$0] }
        return (kept, (slots + stride - 1) / stride)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let all = Array(Self.stacks(total: total, system: system).suffix(max(slots, 1)))
            // One Canvas instead of a view per bar; edges snapped to pixels as view layout snaps them.
            Canvas { ctx, size in
                let scale = ctx.environment.displayScale
                func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
                let (stacks, slots) = Self.downsampled(all, slots: max(slots, 1), pixels: Int(size.width * scale))
                let first = Self.firstSlot(count: stacks.count, slots: slots)
                let step = size.width / CGFloat(slots)
                let gap = step > 3 ? 1.0 : 0
                let width = max(step - gap, 1)
                func bar(_ x: CGFloat, top: CGFloat, bottom: CGFloat, _ shading: GraphicsContext.Shading) {
                    let x0 = px(x), x1 = px(x + width), y0 = px(top), y1 = px(bottom)
                    guard y1 > y0, x1 > x0 else { return }
                    ctx.fill(Path(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)), with: shading)
                }
                for (i, s) in stacks.enumerated() {
                    let x = CGFloat(first + i) * step
                    let user = size.height * CGFloat(s.user), sys = size.height * CGFloat(s.system)
                    bar(x, top: size.height - user - sys, bottom: size.height - user, .color(Self.systemColor.opacity(0.75)))
                    bar(x, top: size.height - user, bottom: size.height, .color(Theme.cpu))
                }
            }
            .frame(height: height)
            .background(ChartGuides())  // 50% and the baseline, behind the bars
            .accessibilityHidden(true)
            if legend { UserSystemLegend(user: user, system: systemNow, trailing: trailing) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU history. User \(Format.percent(user)), system \(Format.percent(systemNow))")
    }
}

/// Two rates as mirrored bars, one bar per second: the first series up from a centre line, the
/// second down (network: download up, upload down; disk: read up, write down). Both halves share
/// one scale, so a small write next to a big read stays small.
struct MirroredBars: View {
    var up: [Double]
    var down: [Double]
    var upColor: Color
    var downColor: Color

    /// Always 60 one-second slots, so every mirrored chart has the same bar width.
    static let slots = 60
    /// The busiest second stops 15% short of the edge.
    static let headroom = 1.15

    struct Bar: Equatable {
        var x: CGFloat
        var width: CGFloat
        var up: CGFloat
        var down: CGFloat
    }

    /// The bars of a chart `size` big. The newest reading sits in the right-most slot; fewer
    /// readings than slots leave the left slots empty (never stretched). Each bar is half a slot
    /// wide in the middle of its slot. A reading above zero is at least 1 point long.
    /// The value at the chart's top (and bottom) edge: the busiest second plus the headroom.
    /// Nil without readings.
    static func scale(up: [Double], down: [Double], slots: Int = slots) -> Double? {
        let n = min(up.count, down.count, slots)
        guard n > 0 else { return nil }
        return max((Array(up.suffix(n)) + Array(down.suffix(n))).max() ?? 0, 1e-9) * headroom
    }

    static func bars(up: [Double], down: [Double], size: CGSize, slots: Int = slots) -> [Bar] {
        let n = min(up.count, down.count, slots)
        guard n > 0, let top = scale(up: up, down: down, slots: slots) else { return [] }
        let a = Array(up.suffix(n)), b = Array(down.suffix(n))
        let step = size.width / CGFloat(slots), reach = max(0, size.height / 2 - 1)
        func length(_ v: Double) -> CGFloat { v > 0 ? max(1, CGFloat(v / top) * reach) : 0 }
        let first = slots - n
        return (0..<n).map { i in
            Bar(x: CGFloat(first + i) * step + step * 0.25, width: step * 0.5, up: length(a[i]), down: length(b[i]))
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            for bar in Self.bars(up: up, down: down, size: size) {
                if bar.up > 0 { ctx.fill(Path(CGRect(x: bar.x, y: mid - bar.up, width: bar.width, height: bar.up)), with: .color(upColor)) }
                if bar.down > 0 { ctx.fill(Path(CGRect(x: bar.x, y: mid, width: bar.width, height: bar.down)), with: .color(downColor)) }
            }
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(Theme.muted.opacity(0.45)))
        }
        .accessibilityHidden(true)
    }
}

/// A panel's mirrored chart: the bars with the two series named at the left ("Download" above,
/// "Upload" below) and the scale at the top right.
struct LabelledMirroredBars: View {
    var up: [Double]
    var down: [Double]
    var upColor: Color
    var downColor: Color
    var upTitle: String
    var downTitle: String
    /// How the scale reads ("64 KB/s").
    var format: (Double) -> String
    var height: CGFloat = 96

    var body: some View {
        // The bars keep clear of the labels: a line of room above and below them.
        MirroredBars(up: up, down: down, upColor: upColor, downColor: downColor)
            .padding(.vertical, 14)
            .frame(height: height)
            .overlay(alignment: .topLeading) { Text(upTitle) }
            .overlay(alignment: .bottomLeading) { Text(downTitle) }
            .overlay(alignment: .topTrailing) {
                if let top = MirroredBars.scale(up: up, down: down) { Text(format(top)).monospacedDigit() }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.muted)
    }
}

/// "● User 16%  ● System 18%", then an optional trailing note. Every CPU style shows it.
struct UserSystemLegend: View {
    var user: Double
    var system: Double
    var trailing: Text?

    var body: some View {
        HStack(spacing: 12) {
            legend("User", Theme.cpu, user)
            legend("System", UserSystemBars.systemColor, system)
            Spacer(minLength: 4)
            if let trailing { trailing.foregroundStyle(Theme.muted).lineLimit(1) }
        }
        .font(.system(size: 12))
    }

    private func legend(_ title: String, _ color: Color, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(Theme.muted)
            Text(Format.percent(value)).font(Theme.number(12, weight: .semibold))
        }
    }
}

/// One ring per logical core, filled to its load: efficiency cores in the primary text colour,
/// performance cores in the CPU colour. Below it, the average load of each kind.
struct CoreRings: View {
    var cores: [CoreLoad]
    /// The per-kind averages under the rings (off when the panel draws them as history rows).
    var showsKinds = true

    /// Rings per row: one row up to 8 cores, otherwise rows of equal length, never more than 8
    /// (14 cores = 2 rows of 7, 24 = 3 rows of 8).
    static func columns(for count: Int) -> Int {
        guard count > 8 else { return max(count, 1) }
        let rows = (count + 7) / 8
        return (count + rows - 1) / rows
    }

    static func color(_ kind: CoreLoad.Kind) -> Color { kind == .efficiency ? .primary : Theme.cpu }

    var body: some View {
        let kinds = [CoreLoad.Kind.efficiency, .performance, .unknown].filter { showsKinds && cores.averageLoad(of: $0) != nil }
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.columns(for: cores.count)), spacing: 8) {
                ForEach(cores) { core in
                    ZStack {
                        Circle().inset(by: 2).stroke(Theme.track, lineWidth: 4)
                        Circle().inset(by: 2).trim(from: 0, to: CGFloat(core.load.unitClamped))
                            .stroke(Self.color(core.kind), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(maxWidth: 34)
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 6) {
                    Circle().fill(Self.color(kind)).frame(width: 8, height: 8)
                    Text(Self.title(kind))
                    Spacer()
                    Text(Format.percent(cores.averageLoad(of: kind) ?? 0)).font(Theme.number(12))
                }
                .font(.system(size: 12))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cores.count) cores. " + kinds.map { "\(Self.title($0)) \(Format.percent(cores.averageLoad(of: $0) ?? 0))" }.joined(separator: ", "))
    }

    static func title(_ kind: CoreLoad.Kind) -> String {
        switch kind {
        case .efficiency: return "Efficiency cores"
        case .performance: return "Performance cores"
        case .unknown: return "Cores"
        }
    }
}
