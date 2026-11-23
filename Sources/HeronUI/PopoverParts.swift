import HeronCore
import SwiftUI

// MARK: - Shared pieces

/// The charge as a bar in the memory colour (red when low), with macOS's charge limit as a tick;
/// in the panel the part above the limit is hatched and the tick says "Limit 80%".
struct ChargeMeter: View {
    var battery: BatteryReading
    var height: CGFloat = 6
    var labelled = false

    var body: some View {
        let low = Warnings.isLow(battery)
        GeometryReader { geo in
            let w = geo.size.width
            let x = battery.chargeLimit.map { w * CGFloat($0.unitClamped) }
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Rectangle().fill(low ? Theme.warning : Theme.memory).frame(width: w * CGFloat(battery.percent.unitClamped))
                    if labelled, let x {
                        Hatch().fill(Color.primary.opacity(0.1)).frame(width: max(0, w - x)).offset(x: x)
                    }
                }
                .clipShape(Capsule())
                if let x, let limit = battery.chargeLimit {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary)
                        .frame(width: 2, height: height + (labelled ? 8 : 6)).offset(x: x - 1)
                    if labelled {
                        Text("Limit \(wholePercent(limit))%").font(.system(size: 11)).monospacedDigit().fixedSize()
                            .position(x: min(max(x, 30), w - 30), y: -12)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge \(Format.percent(battery.percent))" + (battery.chargeLimit.map { ", limit \(Format.percent($0))" } ?? ""))
    }
}

/// Diagonal stripes, 3 points on and 3 off at 135°: the charge macOS keeps back above its limit.
struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            var x = rect.minX - rect.height
            while x < rect.maxX {
                p.move(to: CGPoint(x: x, y: rect.maxY)); p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                p.addLine(to: CGPoint(x: x + rect.height + 3, y: rect.minY)); p.addLine(to: CGPoint(x: x + 3, y: rect.maxY)); p.closeSubpath()
                x += 6
            }
        }
        .intersection(Path(rect))
    }
}

/// One wording for the battery state everywhere: "Charging · 2h 15m to full"; with a macOS charge
/// limit, "Charging to 80% · 2h 15m" and, once there on the adapter, "Held at 80% limit".
enum BatteryStatus {
    static func text(_ b: BatteryReading) -> String {
        if let limit = b.chargeLimit {
            let cap = Int((limit.unitClamped * 100).rounded())
            if b.isCharging { return "Charging to \(cap)%" + (b.minutesRemaining.map { " · \(Format.minutes($0))" } ?? "") }
            if b.onAC && Int((b.percent.unitClamped * 100).rounded()) >= cap { return "Held at \(cap)% limit" }
        }
        var parts: [String] = []
        if b.isCharging { parts.append("Charging") } else if b.onAC { parts.append("On power adapter") } else { parts.append("On battery") }
        if let m = b.minutesRemaining { parts.append(b.isCharging ? "\(Format.minutes(m)) to full" : "\(Format.minutes(m)) left") }
        return parts.joined(separator: " · ")
    }
}

/// A panel's list of apps: a caption (and what 100% means), then each app's name and value over a
/// bar measured against the first.
struct ProcessList: View {
    struct Row {
        var name: String
        var value: String
        /// What the bar measures (CPU share, bytes); the first row's bar is full.
        var amount: Double
    }
    var title: String
    var caption: String?
    var rows: [Row]
    var color: Color

    var body: some View {
        Card(spacing: 6) {
            PanelCaption(text: title, trailing: caption)
            if rows.isEmpty { Text("Measuring…").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            let top = max(rows.map(\.amount).max() ?? 0, 1e-9)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(row.value).font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        Meter(fraction: row.amount / top, color: color.opacity(0.75), height: 3)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// 0.342 → "34" (the "%" drawn separately, smaller).
func wholePercent(_ fraction: Double) -> String { "\(Int((fraction.unitClamped * 100).rounded()))" }

/// A temperature in the text colour, red from 90°.
@MainActor func temperatureText(_ celsius: Double, _ settings: AppSettings) -> Text {
    Text(Format.temperature(celsius, unit: settings.temperatureUnit)).font(Theme.number(12, weight: .semibold))
        .foregroundStyle(Warnings.color(celsius: celsius))
}

/// "Temperature ........ 79°", red from 90°.
@MainActor func temperatureRow(_ key: String, _ celsius: Double, _ settings: AppSettings) -> KeyValueRow {
    KeyValueRow(key: key, value: Format.temperature(celsius, unit: settings.temperatureUnit), valueColor: Warnings.color(celsius: celsius))
}

/// The memory card's rings: pressure and memory used, 60 points each, and the App / Wired /
/// Compressed legend with their sizes, then swap.
struct MemoryRings: View {
    var memory: MemoryReading?

    var body: some View {
        let m = memory
        let total = Double(max(1, m?.total ?? 1))
        let parts: [(fraction: Double, color: Color)] = [
            (Double(m?.app ?? 0) / total, Theme.memory), (Double(m?.wired ?? 0) / total, Theme.cpu),
            (Double(m?.compressed ?? 0) / total, Theme.gpu),
        ]
        HStack(alignment: .top, spacing: 8) {
            if let p = m?.pressurePercent {
                ring("Pressure", [(p, pressureColor(m?.pressure))], text: "\(wholePercent(p))%", color: pressureColor(m?.pressure))
            } else {
                // No number from the kernel: the level word, in its colour.
                ring("Pressure", [], text: m?.pressure.rawValue.capitalized ?? "–", color: pressureColor(m?.pressure))
            }
            ring("Used", parts, text: "\(wholePercent(m?.usedFraction ?? 0))%", color: .primary)
            VStack(spacing: 3) {
                legend("App", Theme.memory, m?.app)
                legend("Wired", Theme.cpu, m?.wired)
                legend("Compressed", Theme.gpu, m?.compressed)
                Rectangle().fill(Theme.track).frame(height: 1).padding(.vertical, 2)
                legend("Swap", nil, m?.swapUsed)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func ring(_ caption: String, _ parts: [(fraction: Double, color: Color)], text: String, color: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().inset(by: 3).stroke(Theme.track, lineWidth: 6)
                ForEach(Array(BigRing.segments(parts.map(\.fraction)).enumerated()), id: \.offset) { i, seg in
                    Circle().inset(by: 3).trim(from: seg.start, to: seg.end).stroke(parts[i].color, lineWidth: 6).rotationEffect(.degrees(-90))
                }
                Text(text).font(Theme.number(14)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 8)
            }
            .frame(width: 60, height: 60)
            Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
        }
        .frame(width: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(text)")
    }

    private func legend(_ name: String, _ color: Color?, _ bytes: UInt64?) -> some View {
        HStack(spacing: 6) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8) } else { Color.clear.frame(width: 8, height: 8) }
            Text(name).foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            Text(Format.bytes(bytes ?? 0)).font(Theme.number(12, weight: .semibold)).fixedSize()
        }
        .font(.system(size: 12)).lineLimit(1).frame(height: 16)
    }
}

/// The chart glyph's column at a row's right edge.
enum ChartGlyph {
    static let column: CGFloat = 16
}
