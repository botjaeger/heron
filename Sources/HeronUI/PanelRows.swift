import HeronCore
import SwiftUI

/// One key–value row of a detail panel. The rows come from pure functions of the snapshot
/// (`PanelRows`), so tests can check the rule every panel follows: a row whose reading this Mac
/// does not give is left out, never shown with a placeholder.
struct PanelRow: Identifiable {
    var key: String
    var value: String
    var valueColor: Color = .primary
    var dot: Color?
    /// Set when Heron keeps a history of the row: clicking it shows that history.
    var history: HistoryItem?
    /// A short note after the key, in the muted colour ("1, 5, 15 min", "Normal").
    var hint: String?
    /// A part of the row above it (the power rails under Package).
    var indented = false
    /// A total its indented rows make up (Package): its key in the text colour.
    var headline = false
    /// The swatch drawn as an outline (memory's Free: nothing in it).
    var outlined = false
    /// A share of a maximum, drawn as a bar under the row (a fan's speed of its top speed).
    var share: Double?
    var id: String { key }
}

/// A panel row: key (and its hint) on the left, the value on the right, then a column for the
/// chart glyph of a row with history (empty otherwise, so values line up). Clickable when it has
/// a history.
struct PanelRowView: View {
    var row: PanelRow
    var body: some View {
        let line = HStack(spacing: 8) {
            if let dot = row.dot {
                Group {
                    if row.outlined { RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.muted, lineWidth: 1) } else { RoundedRectangle(cornerRadius: 2).fill(dot) }
                }
                .frame(width: 9, height: 9)
            }
            // One line, like every row: a long fan or sensor name is shortened, not wrapped.
            Text(row.key).foregroundStyle(row.headline ? Color.primary : Theme.muted).lineLimit(1).truncationMode(.middle)
                .padding(.leading, row.indented ? 12 : 0)
            // The hint whole or not at all: "1, 5, 1…" reads as a different hint.
            if let hint = row.hint {
                ViewThatFits(in: .horizontal) {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            // The number never gives way: the hint (left out), then the key (shortened), go first.
            Text(row.value).font(Theme.number(13, weight: .semibold)).foregroundStyle(row.valueColor).lineLimit(1).layoutPriority(1)
        }
        .font(.system(size: 13))
        .frame(minHeight: 28)
        if let item = row.history {
            HistoryRow(item: item) { line }
        } else {
            HStack(spacing: 0) {
                line; Color.clear.frame(width: ChartGlyph.column, height: 1)
            }.accessibilityElement(children: .combine)
        }
    }
}

enum PanelRows {
    /// "Temperature ........ 79°", red from 90°.
    static func temperature(_ key: String, _ celsius: Double, _ unit: Format.TemperatureUnit, history: HistoryItem?) -> PanelRow {
        PanelRow(key: key, value: Format.temperature(celsius, unit: unit), valueColor: Warnings.color(celsius: celsius), history: history)
    }

    /// "E 2.0 · P 3.3 GHz": both clusters' clocks on one row (one cluster alone: "E 2.0 GHz").
    static func clocks(efficiencyMHz: Double?, performanceMHz: Double?) -> String? {
        let parts = [efficiencyMHz.map { ("E", $0) }, performanceMHz.map { ("P", $0) }].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.map { "\($0.0) \(String(format: "%.1f", $0.1 / 1000))" }.joined(separator: " · ") + " GHz"
    }

    /// CPU: load average, the clusters' clocks, power, temperature.
    static func cpuDetails(_ s: Snapshot, unit: Format.TemperatureUnit) -> [PanelRow] {
        var rows: [PanelRow] = []
        if let load = s.cpu?.loadAverage, !load.isEmpty {
            rows.append(
                PanelRow(
                    key: "Load average", value: load.map { String(format: "%.2f", $0) }.joined(separator: " · "),
                    history: HistoryItem(part: .cpu, metric: .loadAverage, title: "Load average (1 min)", unit: .number, color: Theme.cpu),
                    hint: load.count == 3 ? "1, 5, 15 min" : nil))
        }
        if let clocks = clocks(efficiencyMHz: s.clocks?.efficiencyMHz, performanceMHz: s.clocks?.performanceMHz) {
            rows.append(PanelRow(key: "Clocks", value: clocks))
        }
        if let w = s.power?.cpu {
            rows.append(
                PanelRow(
                    key: "Power", value: Format.watts(w),
                    history: HistoryItem(part: .cpu, metric: .cpuPower, title: "CPU power", unit: .watts, color: Theme.cpu)))
        }
        if let celsius = SensorSummary.value(.cpu, in: s) {
            rows.append(
                temperature(
                    "Temperature", celsius, unit,
                    history: HistoryItem(part: .cpu, metric: .cpuTemperature, title: "CPU temperature", unit: .temperature, color: Theme.warning)))
        }
        return rows
    }

    /// GPU: renderer, tiler, power, temperature.
    static func gpuDetails(_ s: Snapshot, unit: Format.TemperatureUnit) -> [PanelRow] {
        var rows: [PanelRow] = []
        if let r = s.gpu?.renderer {
            rows.append(
                PanelRow(
                    key: "Renderer", value: Format.percent(r),
                    history: HistoryItem(part: .gpu, metric: .gpuRenderer, title: "GPU renderer", unit: .percent, color: Theme.gpu)))
        }
        if let t = s.gpu?.tiler {
            rows.append(
                PanelRow(
                    key: "Tiler", value: Format.percent(t),
                    history: HistoryItem(part: .gpu, metric: .gpuTiler, title: "GPU tiler", unit: .percent, color: Theme.gpu)))
        }
        if let w = s.power?.gpu {
            rows.append(
                PanelRow(
                    key: "Power", value: Format.watts(w),
                    history: HistoryItem(part: .gpu, metric: .gpuPower, title: "GPU power", unit: .watts, color: Theme.gpu)))
        }
        if let celsius = SensorSummary.value(.gpu, in: s) {
            rows.append(
                temperature(
                    "Temperature", celsius, unit,
                    history: HistoryItem(part: .gpu, metric: .sensorGPU, title: "GPU temperature", unit: .temperature, color: Theme.warning)))
        }
        return rows
    }

    /// The colour of each memory part, the same in the split bar and its rows.
    static let memoryColors: [Color] = [Theme.memory, Theme.cpu, Theme.gpu, Theme.muted]

    /// Memory: App memory, Wired, Compressed, Cached files, Free (an outlined swatch: nothing in it).
    static func memoryParts(_ s: Snapshot) -> [PanelRow] {
        guard let m = s.memory else { return [] }
        let parts: [(String, UInt64, Color, Metric)] = [
            ("App memory", m.app, memoryColors[0], .memoryApp), ("Wired", m.wired, memoryColors[1], .memoryWired),
            ("Compressed", m.compressed, memoryColors[2], .memoryCompressed),
            ("Cached files", m.cached, memoryColors[3], .memoryCached), ("Free", m.free, Theme.track, .memoryFree),
        ]
        return parts.map { name, bytes, color, metric in
            PanelRow(
                key: name, value: Format.bytes(bytes), dot: color,
                history: HistoryItem(part: .memory, metric: metric, title: name, unit: .bytes, color: Theme.memory), outlined: metric == .memoryFree)
        }
    }

    /// Memory pressure's history: the kernel's percentage (shown only when the kernel gives one).
    static let pressureHistory = HistoryItem(part: .memory, metric: .memoryPressure, title: "Memory pressure", unit: .percent, color: Theme.memory)

    /// "Swap used ........ 3.2 GB", with its history.
    static func swap(_ m: MemoryReading) -> PanelRow {
        PanelRow(
            key: "Swap used", value: Format.bytes(m.swapUsed),
            history: HistoryItem(part: .memory, metric: .swapUsed, title: "Swap used", unit: .bytes, color: Theme.memory))
    }

    /// Disk: bytes read and written since boot.
    static func diskTotals(_ s: Snapshot) -> [PanelRow] {
        var rows: [PanelRow] = []
        if let read = s.disk?.bytesReadSinceBoot { rows.append(PanelRow(key: "Read since boot", value: Format.bytes(read))) }
        if let written = s.disk?.bytesWrittenSinceBoot { rows.append(PanelRow(key: "Written since boot", value: Format.bytes(written))) }
        return rows
    }

    /// Network: the interface and local address (Public IP, a button, sits between these and the session).
    static func networkAddress(_ s: Snapshot) -> [PanelRow] {
        guard let n = s.network else { return [] }
        var rows = [PanelRow(key: "Interface", value: [n.interfaceKind, n.interface].compactMap { $0 }.joined(separator: " · "))]
        if let ip = n.localIP { rows.append(PanelRow(key: "Local IP", value: ip)) }
        return rows
    }

    /// Since Heron started, then each direction now with its history.
    static func networkSession(_ s: Snapshot, bits: Bool = false) -> [PanelRow] {
        guard let n = s.network else { return [] }
        return [
            PanelRow(key: "Since Heron started", value: "↓ \(Format.bytes(n.sessionDown))  ↑ \(Format.bytes(n.sessionUp))"),
            PanelRow(
                key: "Download", value: Format.rate(n.downBytesPerSecond, bits: bits),
                history: HistoryItem(part: .network, metric: .networkDown, title: "Download", unit: .networkRate, color: Theme.network)),
            PanelRow(
                key: "Upload", value: Format.rate(n.upBytesPerSecond, bits: bits),
                history: HistoryItem(part: .network, metric: .networkUp, title: "Upload", unit: .networkRate, color: Theme.upload)),
        ]
    }

    /// One row per fan, each with its own history and its share of its top speed (when it has one).
    static func fans(_ s: Snapshot) -> [PanelRow] {
        s.fans.map { fan in
            PanelRow(
                key: fan.name, value: Format.rpm(fan.rpm),
                history: HistoryItem(part: .sensors, source: .item(ItemKey(.fanRPM, id: fan.id)), title: "\(fan.name) fan", unit: .rpm, color: .primary),
                share: fan.maxRPM > 0 ? fan.rpm / fan.maxRPM : nil)
        }
    }

    /// The power rails that report: Package, the parts inside it indented, then the display apart.
    static func power(_ s: Snapshot) -> [PanelRow] {
        guard let p = s.power else { return [] }
        let rails: [(String, Double?, Metric, Bool)] = [
            ("Package", p.package, .power, false), ("CPU", p.cpu, .cpuPower, true),
            ("Memory", p.dram, .dramPower, true), ("GPU", p.gpu, .gpuPower, true),
            ("Neural Engine", p.ane, .anePower, true), ("Display", p.display, .displayPower, false),
        ]
        return rails.compactMap { name, watts, metric, inside in
            watts.map {
                PanelRow(
                    key: name, value: Format.watts($0),
                    history: HistoryItem(part: .sensors, metric: metric, title: "\(name) power", unit: .watts, color: Theme.cpu),
                    indented: inside && p.package != nil, headline: !inside && p.package != nil)
            }
        }
    }

    /// "Connected · not charging": the adapter, and whether it charges.
    static func adapter(_ b: BatteryReading) -> String {
        guard b.onAC else { return "Not connected" }
        return b.isCharging ? "Connected · charging" : "Connected · not charging"
    }

    /// Battery: health (and its condition), cycles, power, adapter, temperature; "Charge limit Off"
    /// when Heron could read that macOS sets none (a set limit is drawn on the charge bar). None
    /// without a battery.
    static func battery(_ s: Snapshot, unit: Format.TemperatureUnit) -> [PanelRow] {
        guard let b = s.battery, b.present else { return [] }
        var rows: [PanelRow] = []
        if b.chargeLimitKnown && b.chargeLimit == nil {
            rows.append(PanelRow(key: "Charge limit", value: "Off"))
        }
        if let h = b.maxCapacityFraction {
            rows.append(
                PanelRow(
                    key: "Health", value: Format.percent(h), valueColor: h < 0.8 ? Theme.warning : .primary,
                    history: HistoryItem(part: .battery, metric: .batteryHealth, title: "Maximum capacity", unit: .percent, color: Theme.memory),
                    hint: b.condition))
        } else if let c = b.condition {
            rows.append(PanelRow(key: "Condition", value: c))
        }
        if let c = b.cycleCount {
            rows.append(
                PanelRow(
                    key: "Cycle count", value: "\(c)",
                    history: HistoryItem(part: .battery, metric: .batteryCycles, title: "Cycle count", unit: .count, color: Theme.memory)))
        }
        if let w = b.watts {
            rows.append(
                PanelRow(
                    key: w < 0 ? "Charging at" : "Power draw", value: Format.watts(abs(w)),
                    history: HistoryItem(part: .battery, metric: .batteryPower, title: "Battery power", unit: .watts, color: Theme.memory)))
        }
        rows.append(PanelRow(key: "Power adapter", value: adapter(b)))
        if let t = s.batteryCelsius {
            rows.append(
                temperature(
                    "Temperature", t, unit,
                    history: HistoryItem(part: .battery, metric: .batteryTemperature, title: "Battery temperature", unit: .temperature, color: Theme.warning)))
        }
        return rows
    }
}
