import HeronCore
import SwiftUI

struct CPUSection: View {
    /// The readings drawn (the monitor's latest, or heron-snap's edge cases).
    var snapshot: Snapshot
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    var body: some View {
        let cpu = snapshot.cpu
        let user = cpu?.user ?? 0, system = cpu?.system ?? 0, total = cpu?.total ?? 0
        let range = settings.graphRange.rawValue
        let coverage = TimeAxis.coverage(recorded: monitor.history.seconds(.metric(.cpu)), range: range)
        let celsius = SensorSummary.value(.cpu, in: snapshot)
        // "79° · Idle 66%" under the chart.
        let idle = Text("Idle ") + Text(Format.percent(cpu?.idle ?? 1)).font(Theme.number(12, weight: .medium)).foregroundStyle(Color.primary)
        let trailing = celsius.map { temperatureText($0, settings) + Text(" · ") + idle } ?? idle
        VStack(spacing: 10) {
            // The main chart follows the overview card's style.
            Card(spacing: 10) {
                MetricHeader(
                    title: "Total load", color: Theme.cpu,
                    history: HistoryItem(part: .cpu, metric: .cpu, title: "Total load", unit: .percent, color: Theme.cpu),
                    number: wholePercent(total), unit: "%")
                switch settings.cardStyle(.cpu) {
                case .ring:
                    BigRing(parts: [(user, Theme.cpu), (system, UserSystemBars.systemColor)], size: 120, value: wholePercent(total), caption: "TOTAL")
                        .frame(maxWidth: .infinity)
                case .graph:
                    // Over the part of the axis the data covers (Heron started 2 minutes ago:
                    // a sliver at the right of "10 min ago … now").
                    TimeCovered(fraction: coverage) {
                        UserSystemArea(
                            total: monitor.history.series(.cpu, seconds: range, points: 60),
                            system: monitor.history.series(.cpuSystem, seconds: range, points: 60), height: 64)
                    }
                    .frame(height: 64)
                    .background(ChartGuides())
                    AxisLabels(labels: ["\(settings.graphRange.label) ago", "now"])
                default:
                    TimeCovered(fraction: coverage) {
                        UserSystemBars(
                            total: monitor.history.series(.cpu, seconds: range, points: 56),
                            system: monitor.history.series(.cpuSystem, seconds: range, points: 56),
                            user: user, systemNow: system, height: 64, slots: 56, legend: false)
                    }
                    .frame(height: 64)
                    .background(ChartGuides())
                    AxisLabels(labels: ["\(settings.graphRange.label) ago", "now"])
                }
                UserSystemLegend(user: user, system: system, trailing: trailing)
            }
            if settings.showCores, let cores = cpu?.cores, !cores.isEmpty {
                Card(spacing: 10) {
                    PanelCaption(text: "Cores", trailing: "\(cores.count) total")
                    CoreRings(cores: cores, showsKinds: false)
                    // Each kind's legend keeps its whole text ("10 Performance 100%"); when both
                    // do not fit on one line the second wraps under the first, never cut short.
                    WrapLayout(spacing: 12, lineSpacing: 4) {
                        ForEach([CoreLoad.Kind.efficiency, .performance, .unknown], id: \.self) { kind in
                            if let load = cores.averageLoad(of: kind) {
                                let count = cores.filter { $0.kind == kind }.count
                                let legend = HStack(spacing: 5) {
                                    Circle().fill(CoreRings.color(kind)).frame(width: 8, height: 8)
                                    Text(kind == .unknown ? "\(count) cores" : "\(count) \(kind == .efficiency ? "Efficiency" : "Performance")").foregroundStyle(Theme.muted)
                                    Text(Format.percent(load)).font(Theme.number(12, weight: .semibold))
                                }.font(.system(size: 12)).fixedSize()
                                switch kind {
                                case .efficiency:
                                    HistoryRow(item: HistoryItem(part: .cpu, metric: .cpuEfficiency, title: "Efficiency cores", unit: .percent, color: Theme.cpu)) { legend }
                                case .performance:
                                    HistoryRow(item: HistoryItem(part: .cpu, metric: .cpuPerformance, title: "Performance cores", unit: .percent, color: Theme.cpu)) { legend }
                                case .unknown: legend
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            let details = PanelRows.cpuDetails(snapshot, unit: settings.temperatureUnit)
            if !details.isEmpty {
                Card(spacing: 0) { ForEach(details) { PanelRowView(row: $0) } }
            }
            if settings.showCPUProcesses {
                ProcessList(
                    title: "Top processes", caption: "100% = one core",
                    rows: snapshot.topCPU.map { ProcessList.Row(name: $0.title, value: String(format: "%.1f%%", $0.cpu * 100), amount: $0.cpu) },
                    color: Theme.cpu)
            }
        }
    }
}

struct GPUSection: View {
    /// The readings drawn (the monitor's latest, or heron-snap's edge cases).
    var snapshot: Snapshot
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    /// The panel's line covers the last minute, as in the design.
    static let lineSeconds = 60
    var body: some View {
        let gpu = snapshot.gpu
        let device = gpu?.device ?? 0
        VStack(spacing: 10) {
            // The main chart follows the overview card's style (the bar style draws the line: the
            // big number already says what a bar would).
            Card(spacing: 10) {
                MetricHeader(
                    title: "Utilisation", color: Theme.gpu,
                    history: HistoryItem(part: .gpu, metric: .gpu, title: "GPU utilisation", unit: .percent, color: Theme.gpu),
                    number: wholePercent(device), unit: "%")
                if settings.cardStyle(.gpu) == .ring {
                    BigRing(parts: [(device, Theme.gpu)], size: 120, value: wholePercent(device), caption: "GPU").frame(maxWidth: .infinity)
                } else {
                    TimeCovered(fraction: TimeAxis.coverage(recorded: monitor.history.seconds(.metric(.gpu)), range: Self.lineSeconds)) {
                        Sparkline(values: monitor.history.series(.gpu, seconds: Self.lineSeconds, points: 60), color: Theme.gpu, lineWidth: 1.8, fill: true)
                    }
                    .frame(height: 72)
                    .background(ChartGuides())
                    AxisLabels(labels: ["\(Self.lineSeconds) s ago", "100% at top", "now"])
                }
                let notes = [
                    SensorSummary.value(.gpu, in: snapshot).map { temperatureText($0, settings) },
                    snapshot.power?.gpu.map { Text(Format.watts($0)) },
                ].compactMap { $0 }
                if let first = notes.first {
                    notes.dropFirst().reduce(first) { $0 + Text(" · ") + $1 }.font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            let details = PanelRows.gpuDetails(snapshot, unit: settings.temperatureUnit)
            if !details.isEmpty {
                Card(spacing: 0) { ForEach(details) { PanelRowView(row: $0) } }
            }
        }
    }
}

/// Memory pressure's zones on its bar, as shares of the bar: Normal, Warning, Critical. A picture
/// of the kernel's level, not a rule: the level itself comes from the kernel.
enum PressureZones {
    static let shares: [(title: String, share: Double, level: MemoryReading.Pressure)] = [("Normal", 0.5, .normal), ("Warning", 0.3, .warning), ("Critical", 0.2, .critical)]

    /// What the level means, in one line.
    static func meaning(_ p: MemoryReading.Pressure) -> String {
        switch p {
        case .critical: return "Memory is short; apps may slow down until some are quit."
        case .warning: return "macOS is compressing memory to keep apps responsive."
        default: return "There is room for what is running."
        }
    }
}

struct MemorySection: View {
    /// The readings drawn (the monitor's latest, or heron-snap's edge cases).
    var snapshot: Snapshot
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    var body: some View {
        let m = snapshot.memory
        let total = Double(max(1, m?.total ?? 1))
        let used = m?.usedFraction ?? 0
        let series = monitor.history.series(.memory, seconds: settings.graphRange.rawValue, points: 60)
        VStack(spacing: 10) {
            // The main chart follows the overview card's style.
            Card(spacing: 8) {
                MetricHeader(
                    title: "Used", color: Theme.memory,
                    history: HistoryItem(part: .memory, metric: .memory, title: "Memory used", unit: .percent, color: Theme.memory),
                    number: String(format: "%.1f", Double(m?.used ?? 0) / 1_073_741_824), unit: "of \(Format.bytes(m?.total ?? 0))",
                    unitColor: Theme.muted)
                switch settings.cardStyle(.memory) {
                case .ring:
                    let parts: [(fraction: Double, color: Color)] = [
                        (Double(m?.app ?? 0) / total, Theme.memory), (Double(m?.wired ?? 0) / total, Theme.cpu),
                        (Double(m?.compressed ?? 0) / total, Theme.gpu),
                    ]
                    BigRing(parts: parts, size: 120, value: wholePercent(used), caption: "MEMORY").frame(maxWidth: .infinity)
                case .graph: Sparkline(values: series, color: Theme.memory, fill: true).frame(height: 60).background(ChartGuides())
                default:
                    if let m {
                        let bytes = [m.app, m.wired, m.compressed, m.cached]
                        SplitMeter(parts: zip(bytes, PanelRows.memoryColors).map { (Double($0) / total, $1) }, height: 10)
                    }
                }
                VStack(spacing: 0) { ForEach(PanelRows.memoryParts(snapshot)) { PanelRowView(row: $0) } }
            }
            if let m {
                Card(spacing: 8) {
                    let header = HStack(spacing: 8) {
                        Text("Pressure").font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 8)
                        if let p = m.pressurePercent { BigNumber(number: wholePercent(p), unit: "%", size: 17) }
                        Text(m.pressure.rawValue.capitalized).font(.system(size: 13, weight: .semibold)).foregroundStyle(pressureColor(m.pressure))
                    }
                    // The kernel's percentage has a history; the level word alone has none.
                    if m.pressurePercent != nil { HistoryRow(item: PanelRows.pressureHistory) { header } } else { header }
                    if let p = m.pressurePercent { PressureBar(fraction: p, level: m.pressure) }
                    Text(PressureZones.meaning(m.pressure)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    PanelRowView(row: PanelRows.swap(m))
                }
            }
            if settings.showMemoryProcesses {
                ProcessList(
                    title: "Top processes", caption: nil,
                    rows: snapshot.topMemory.map { ProcessList.Row(name: $0.title, value: Format.bytes($0.memory), amount: Double($0.memory)) },
                    color: Theme.memory)
            }
        }
    }
}

/// Memory pressure as a bar over its three zones, filled to the kernel's percentage in the level's
/// colour, with a marker; the zone names under it, the current one in its colour.
struct PressureBar: View {
    var fraction: Double
    var level: MemoryReading.Pressure

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width, x = w * CGFloat(fraction.unitClamped)
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(PressureZones.shares, id: \.title) { zone in
                            Rectangle().fill(pressureColor(zone.level).opacity(0.22)).frame(width: max(0, w * zone.share - 2))
                        }
                    }
                    .clipShape(Capsule())
                    Capsule().fill(pressureColor(level)).frame(width: x)
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary).frame(width: 2, height: 14).offset(x: x - 1)
                }
            }
            .frame(height: 8)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(PressureZones.shares, id: \.title) { zone in
                        Text(zone.title).font(.system(size: 11, weight: zone.level == level ? .semibold : .regular))
                            .foregroundStyle(zone.level == level && level != .normal ? pressureColor(level) : Theme.muted)
                            .frame(width: geo.size.width * zone.share, alignment: .leading)
                    }
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory pressure \(Format.percent(fraction)), \(level.rawValue)")
    }
}

struct DiskSection: View {
    /// The readings drawn (the monitor's latest, or heron-snap's edge cases).
    var snapshot: Snapshot
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    var body: some View {
        let d = snapshot.disk
        let ssd = SensorSummary.value(.ssd, in: snapshot)
        VStack(spacing: 10) {
            ForEach(d?.volumes ?? []) { v in
                let color = Warnings.color(volume: v)
                Card(spacing: 8) {
                    HStack {
                        Text(v.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        let used = OverviewSection.usedOf(v.used, v.total)
                        BigNumber(number: used.number, unit: used.unit, size: 17)
                    }
                    // The startup disk follows the overview card's style.
                    if v.isRoot, settings.cardStyle(.disk) == .ring {
                        BigRing(parts: [(v.usedFraction, color)], size: 120, value: wholePercent(v.usedFraction), caption: "USED").frame(maxWidth: .infinity)
                    } else {
                        Meter(fraction: v.usedFraction, color: color, height: 8)
                    }
                    HStack {
                        Text(Format.diskBytes(v.available)).font(Theme.number(12, weight: .semibold)).foregroundStyle(Color.primary) + Text(" free")
                        Spacer(minLength: 8)
                        Text("\(v.format) · \(v.isInternal ? "internal" : "external")")
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    if v.isRoot, let ssd {
                        PanelRowView(
                            row: PanelRows.temperature(
                                "SSD temperature", ssd, settings.temperatureUnit,
                                history: HistoryItem(part: .disk, metric: .sensorSSD, title: "SSD temperature", unit: .temperature, color: Theme.warning)))
                    }
                }
            }
            Card(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Activity").font(.system(size: 13, weight: .semibold))
                    HistoryButton(item: HistoryItem(part: .disk, metric: .diskRead, title: "Disk read", unit: .rate, color: .primary))
                    Spacer()
                }
                // Read up in the text colour, write down in grey, one scale, named at the left.
                LabelledMirroredBars(
                    up: monitor.history[.diskRead].last(MirroredBars.slots), down: monitor.history[.diskWrite].last(MirroredBars.slots),
                    upColor: .primary, downColor: Theme.muted, upTitle: "Read", downTitle: "Write", format: { Format.rate($0) })
                AxisLabels(labels: ["\(MirroredBars.slots) s ago", "now"])
                if let d {
                    HStack(alignment: .top) {
                        RateFigure(
                            title: "Read", text: Format.rate(d.readBytesPerSecond), color: .primary, size: 22,
                            history: HistoryItem(part: .disk, metric: .diskRead, title: "Disk read", unit: .rate, color: .primary))
                        Spacer()
                        RateFigure(
                            title: "Write", text: Format.rate(d.writeBytesPerSecond), color: Theme.upload, size: 22, trailing: true,
                            history: HistoryItem(part: .disk, metric: .diskWrite, title: "Disk write", unit: .rate, color: Theme.upload))
                    }
                }
                VStack(spacing: 0) { ForEach(PanelRows.diskTotals(snapshot)) { PanelRowView(row: $0) } }
            }
        }
    }
}

/// "Download / ↓ 31 KB/s": a rate's name over its big value, clickable for its history.
private struct RateFigure: View {
    var title: String
    var text: String
    var color: Color
    var icon: HeronIcon?
    var size: CGFloat = 24
    var trailing = false
    var history: HistoryItem?

    var body: some View {
        let parts = NumberParts.split(text)
        let figure = VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack(spacing: 4) {
                if let icon { HeronIconView(icon, size: 16, weight: 2.2).foregroundStyle(color) }
                BigNumber(number: parts.number, unit: parts.unit, size: size, unitSize: size * 13 / 24, color: color, unitColor: color)
            }
        }
        if let history {
            HistoryLink(item: history) { figure }
        } else {
            figure
        }
    }
}

struct NetworkSection: View {
    /// The readings drawn (the monitor's latest, or heron-snap's edge cases).
    var snapshot: Snapshot
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    var body: some View {
        let n = snapshot.network
        let bits = settings.networkInBits
        VStack(spacing: 10) {
            Card(spacing: 10) {
                HStack(spacing: 8) {
                    Text("Traffic").font(.system(size: 13, weight: .semibold))
                    HistoryButton(item: HistoryItem(part: .network, metric: .networkDown, title: "Download", unit: .networkRate, color: Theme.network))
                    Spacer()
                }
                if settings.cardStyle(.network) == .graph {
                    let down = monitor.history.series(.networkDown, seconds: settings.graphRange.rawValue, points: 40)
                    let up = monitor.history.series(.networkUp, seconds: settings.graphRange.rawValue, points: 40)
                    let top = max(1, (down + up).max() ?? 1) * 1.15  // one scale for both lines
                    let coverage = TimeAxis.coverage(recorded: monitor.history.seconds(.metric(.networkDown)), range: settings.graphRange.rawValue)
                    TimeCovered(fraction: coverage) {
                        ZStack {  // download's area, upload's line, download's line on top
                            Sparkline(values: down, color: Theme.network, fixedMax: top, fill: true)
                            Sparkline(values: up, color: Theme.upload, fixedMax: top)
                            Sparkline(values: down, color: Theme.network, fixedMax: top)
                        }
                    }
                    .frame(height: 96)
                    .background(ChartGuides())
                    .overlay(alignment: .topTrailing) { Text(Format.rate(top, bits: bits)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit() }
                    AxisLabels(labels: ["\(settings.graphRange.label) ago", "now"])
                } else {
                    // Download up, upload down, one scale, named at the left.
                    LabelledMirroredBars(
                        up: monitor.history[.networkDown].last(MirroredBars.slots), down: monitor.history[.networkUp].last(MirroredBars.slots),
                        upColor: Theme.network, downColor: Theme.upload, upTitle: "Download", downTitle: "Upload",
                        format: { Format.rate($0, bits: bits) })
                    AxisLabels(labels: ["\(MirroredBars.slots) s ago", "now"])
                }
                HStack(alignment: .top) {
                    RateFigure(title: "Download", text: Format.rate(n?.downBytesPerSecond ?? 0, bits: bits), color: Theme.network, icon: .arrowDown)
                    Spacer()
                    RateFigure(title: "Upload", text: Format.rate(n?.upBytesPerSecond ?? 0, bits: bits), color: Theme.upload, icon: .arrowUp, trailing: true)
                }
            }
            Card(spacing: 0) {
                ForEach(PanelRows.networkAddress(snapshot)) { PanelRowView(row: $0) }
                if settings.showPublicIP {
                    HStack(spacing: 8) {
                        Text("Public IP").foregroundStyle(Theme.muted)
                        Text("asks a web service").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Spacer()
                        if let ip = services.publicIP {
                            Text(ip).font(Theme.number(13, weight: .semibold))
                        } else {
                            Button("Look up") { services.fetchPublicIP() }.buttonStyle(.link).font(.system(size: 13, weight: .semibold))
                        }
                        Color.clear.frame(width: ChartGlyph.column, height: 1)
                    }
                    .font(.system(size: 13))
                    .frame(minHeight: 28)
                }
                ForEach(PanelRows.networkSession(snapshot, bits: bits)) { PanelRowView(row: $0) }
            }
        }
    }
}

struct SensorsSection: View {
    /// The readings drawn (the monitor's latest, or heron-snap's edge cases).
    var snapshot: Snapshot
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @State private var showAll = false

    var body: some View {
        let s = snapshot
        let visible = s.sensors.filter { $0.isKnown || !settings.hideUnknownSensors }
        VStack(spacing: 10) {
            Card(spacing: 8) {
                PanelCaption(text: "Temperatures", trailing: visible.isEmpty ? nil : "hottest first")
                if visible.isEmpty {
                    Text("This Mac does not report any temperature sensors to Heron.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if let hottest = s.hottest, visible.contains(where: { $0.id == hottest.id }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("HOTTEST").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.Tint.warning.text)
                            Text(SensorSummary.hottestLabel(hottest)).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        let t = NumberParts.split(Format.temperature(hottest.celsius, unit: settings.temperatureUnit))
                        BigNumber(number: t.number, unit: t.unit, size: 22, unitSize: 12, color: Warnings.color(celsius: hottest.celsius))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.Tint.warning.fill, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(spacing: 0) {
                    ForEach(SensorSummary.hottestFirst(SensorSummary.groups(visible)), id: \.group) { item in
                        HistoryRow(
                            item: HistoryItem(
                                part: .sensors, metric: .sensor(item.group), title: "\(item.group.rawValue) temperature",
                                unit: .temperature, color: Theme.warning)
                        ) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.group.rawValue).foregroundStyle(Theme.muted).lineLimit(1)
                                    Meter(fraction: item.celsius / Warnings.barScaleCelsius, color: Theme.warning.opacity(0.7), height: 3)
                                }
                                .frame(width: 150)
                                Spacer(minLength: 8)
                                Text(Format.temperature(item.celsius, unit: settings.temperatureUnit)).font(Theme.number(13, weight: .semibold))
                                    .foregroundStyle(Warnings.color(celsius: item.celsius))
                            }
                            .font(.system(size: 13))
                            .frame(minHeight: 32)
                        }
                    }
                }
                if !visible.isEmpty {
                    DisclosureGroup(isExpanded: $showAll) {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(visible) { sensor in
                                    KeyValueRow(key: sensor.name, value: Format.temperature(sensor.celsius, unit: settings.temperatureUnit))
                                }
                            }
                        }.frame(maxHeight: 180)
                    } label: {
                        Text("All \(visible.count) sensors").font(.system(size: 13, weight: .medium))
                    }
                }
            }
            Card(spacing: 6) {
                let top = s.fans.map(\.maxRPM).max() ?? 0
                PanelCaption(text: "Fans", trailing: top > 0 ? "max \(Format.rpm(top))" : nil)
                if s.fans.isEmpty {
                    Text("This Mac has no fans.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(PanelRows.fans(s)) { row in
                    if let item = row.history {
                        HistoryRow(item: item) {
                            VStack(spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(row.key).foregroundStyle(Theme.muted).lineLimit(1)
                                    Spacer(minLength: 8)
                                    let rpm = NumberParts.split(row.value)
                                    Text(rpm.number).font(Theme.number(13, weight: .semibold)) + Text(" " + rpm.unit).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                    if let share = row.share {
                                        Text(Format.percent(share)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                                            .frame(width: 34, alignment: .trailing)
                                    }
                                }
                                .font(.system(size: 13))
                                if let share = row.share { Meter(fraction: share, color: Theme.fan, height: 4) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if !s.fans.isEmpty {
                    Text("macOS controls the fans; Heron only reads them.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            let power = PanelRows.power(s)
            if !power.isEmpty {
                Card(spacing: 4) {
                    PanelCaption(text: "Power")
                    VStack(spacing: 0) {
                        ForEach(power) { PanelRowView(row: $0) }
                    }
                }
            }
        }
    }
}

struct BatterySection: View {
    /// The readings drawn (the monitor's latest, or heron-snap's charge-limit case).
    var snapshot: Snapshot
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    var body: some View {
        let b = snapshot.battery
        VStack(spacing: 10) {
            if let b, b.present {
                Card(spacing: 10) {
                    MetricHeader(
                        title: b.isCharging ? "Charging" : (b.onAC ? "On power adapter" : "On battery"), color: .primary,
                        history: HistoryItem(part: .battery, metric: .battery, title: "Battery charge", unit: .percent, color: Theme.memory),
                        number: wholePercent(b.percent), unit: "%", numberColor: Warnings.isLow(b) ? Theme.warning : Theme.memory)
                    ChargeMeter(battery: b, height: 10, labelled: true)
                        .padding(.top, b.chargeLimit == nil ? 0 : 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BatteryStatus.text(b)).font(.system(size: 13, weight: .semibold))
                        if let limit = b.chargeLimit {
                            Text("macOS stops charging at \(wholePercent(limit))% to protect the battery.")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card(spacing: 0) { ForEach(PanelRows.battery(snapshot, unit: settings.temperatureUnit)) { PanelRowView(row: $0) } }
                if settings.showCPUProcesses {
                    ProcessList(
                        title: "Using the most CPU", caption: "100% = one core",
                        rows: snapshot.topCPU.prefix(3).map { ProcessList.Row(name: $0.title, value: String(format: "%.0f%%", $0.cpu * 100), amount: $0.cpu) },
                        color: Theme.memory)
                }
            } else {
                Card { Text("This Mac has no battery.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
        }
    }
}
