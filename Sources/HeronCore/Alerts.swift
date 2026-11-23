import Foundation

/// A user-defined alert: "when <subject> is <above/below> <threshold> for <duration>, notify".
public struct AlertRule: Codable, Identifiable, Hashable, Sendable {
    public enum Subject: String, Codable, CaseIterable, Sendable {
        case cpuLoad, cpuTemperature, gpuTemperature, ssdTemperature, hottestTemperature
        case memoryUsed, memoryPressure, diskFreeGB, batteryPercent, batteryHealth, gpuLoad

        public var title: String {
            switch self {
            case .cpuLoad: return "CPU load"
            case .cpuTemperature: return "CPU temperature"
            case .gpuTemperature: return "GPU temperature"
            case .ssdTemperature: return "SSD temperature"
            case .hottestTemperature: return "Hottest sensor"
            case .memoryUsed: return "Memory used"
            case .memoryPressure: return "Memory pressure"
            case .diskFreeGB: return "Free space on the startup disk"
            case .batteryPercent: return "Battery charge"
            case .batteryHealth: return "Battery health"
            case .gpuLoad: return "GPU load"
            }
        }

        public var isTemperature: Bool {
            switch self {
            case .cpuTemperature, .gpuTemperature, .ssdTemperature, .hottestTemperature: return true
            default: return false
            }
        }

        /// Unit shown next to the threshold. Temperatures are stored in °C and shown in `temperature`.
        public func unit(_ temperature: Format.TemperatureUnit = .celsius) -> String {
            switch self {
            case .cpuLoad, .memoryUsed, .batteryPercent, .batteryHealth, .gpuLoad: return "%"
            case .cpuTemperature, .gpuTemperature, .ssdTemperature, .hottestTemperature: return temperature == .celsius ? "°C" : "°F"
            case .memoryPressure: return "(1 warning, 2 critical)"
            case .diskFreeGB: return "GB"
            }
        }

        /// A sensible limit for a newly chosen subject, in the stored unit.
        public var suggestedRule: (comparison: Comparison, threshold: Double) {
            switch self {
            case .cpuLoad, .gpuLoad: return (.above, 90)
            case .cpuTemperature, .gpuTemperature, .hottestTemperature: return (.above, 95)
            case .ssdTemperature: return (.above, 70)
            case .memoryUsed: return (.above, 90)
            case .memoryPressure: return (.above, 1.5)
            case .diskFreeGB: return (.below, 10)
            case .batteryPercent: return (.below, 10)
            case .batteryHealth: return (.below, 80)
            }
        }

        /// The current value from a snapshot, in the same unit as the threshold.
        public func value(in s: Snapshot) -> Double? {
            // Component temperatures are averages (see SensorStats); "Hottest sensor" is the maximum.
            let known = s.sensors.filter(\.isKnown)
            switch self {
            case .cpuLoad: return s.cpu.map { $0.total * 100 }
            case .gpuLoad: return s.gpu.map { $0.device * 100 }
            case .cpuTemperature: return SensorStats.average(known, in: SensorStats.cpuGroups)
            case .gpuTemperature: return SensorStats.average(known, in: [.gpu])
            case .ssdTemperature: return SensorStats.average(known, in: [.ssd])
            case .hottestTemperature: return s.hottest?.celsius
            case .memoryUsed: return s.memory.map { $0.usedFraction * 100 }
            case .memoryPressure:
                guard let p = s.memory?.pressure else { return nil }
                return p == .critical ? 2 : (p == .warning ? 1 : 0)
            case .diskFreeGB:
                return s.rootVolume.map { Double($0.available) / 1_000_000_000 }
            case .batteryPercent: return s.battery.flatMap { $0.present ? $0.percent * 100 : nil }
            case .batteryHealth: return s.battery?.maxCapacityFraction.map { $0 * 100 }
            }
        }
    }

    public enum Comparison: String, Codable, CaseIterable, Sendable { case above, below }

    public var id = UUID()
    public var subject: Subject
    public var comparison: Comparison
    public var threshold: Double
    public var seconds: Int
    public var playSound = false
    public var enabled = true

    public init(id: UUID = UUID(), subject: Subject, comparison: Comparison, threshold: Double, seconds: Int, playSound: Bool = false, enabled: Bool = true) {
        self.id = id; self.subject = subject; self.comparison = comparison; self.threshold = threshold
        self.seconds = seconds; self.playSound = playSound; self.enabled = enabled
    }

    public func matches(_ value: Double) -> Bool {
        comparison == .above ? value > threshold : value < threshold
    }

    /// "CPU temperature above 95° for 30 s", "Startup disk below 10 GB free", "Battery below 10%":
    /// the rule as Settings › Alerts lists it, temperatures in the user's unit.
    public func summary(unit temperature: Format.TemperatureUnit = .celsius) -> String {
        let duration = seconds > 0 ? " for \(Self.duration(seconds))" : ""
        // Pressure is a level (1 warning, 2 critical): a limit of 1 or more fires at critical only.
        if subject == .memoryPressure { return threshold >= 1 ? "Memory pressure critical\(duration)" : "Memory pressure high\(duration)" }
        let value = subject.isTemperature ? Format.converted(threshold, to: temperature) : threshold
        let shown = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        switch subject {
        case .diskFreeGB: return "Startup disk \(comparison.rawValue) \(shown) GB free\(duration)"
        case .batteryPercent: return "Battery \(comparison.rawValue) \(shown)%\(duration)"
        default:
            let unit = subject.isTemperature ? "°" : subject.unit(temperature)
            return "\(subject.title) \(comparison.rawValue) \(shown)\(unit)\(duration)"
        }
    }

    /// 30 → "30 s", 60 → "1 min", 300 → "5 min".
    public static func duration(_ seconds: Int) -> String {
        seconds >= 60 && seconds.isMultiple(of: 60) ? "\(seconds / 60) min" : "\(seconds) s"
    }

    public static let defaults: [AlertRule] = [
        AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 95, seconds: 30, playSound: true),
        AlertRule(subject: .memoryPressure, comparison: .above, threshold: 1.5, seconds: 10),
        AlertRule(subject: .diskFreeGB, comparison: .below, threshold: 10, seconds: 0),
        AlertRule(subject: .batteryPercent, comparison: .below, threshold: 10, seconds: 0),
        AlertRule(subject: .batteryHealth, comparison: .below, threshold: 80, seconds: 0, enabled: false),
    ]
}

public struct FiredAlert: Sendable, Equatable {
    public var rule: AlertRule
    public var value: Double
    public var title: String
    public var body: String
}

/// Decides when a rule fires. Fires once when the condition has held for the rule's duration,
/// then stays quiet until the condition clears AND the cooldown has passed. Pure logic: the
/// caller passes the time, so tests can fast-forward.
public struct AlertEngine: Sendable {
    public var cooldown: TimeInterval
    private var trueSince: [UUID: Date] = [:]
    private var lastFired: [UUID: Date] = [:]
    private var armed: Set<UUID> = []
    private var lastEvaluated: Date?
    /// A longer pause between evaluations (sleep, a stalled sampler) means the condition was not
    /// watched: its "held for" clock starts again. Samples come every 0.5–5 s.
    static let maxGap: TimeInterval = 30

    public init(cooldown: TimeInterval = 600) { self.cooldown = cooldown }

    public mutating func evaluate(_ rules: [AlertRule], snapshot: Snapshot, now: Date, unit: Format.TemperatureUnit = .celsius) -> [FiredAlert] {
        var fired: [FiredAlert] = []
        if let last = lastEvaluated, now.timeIntervalSince(last) > Self.maxGap || now < last { trueSince.removeAll() }
        lastEvaluated = now
        // A removed rule leaves no state behind.
        let ids = Set(rules.map(\.id))
        trueSince = trueSince.filter { ids.contains($0.key) }
        lastFired = lastFired.filter { ids.contains($0.key) }
        armed.formIntersection(ids)
        for rule in rules {
            // A rule that is off, or a reading that is missing, is not "still true": re-enabled or
            // back, the rule waits its full duration again.
            guard rule.enabled else { trueSince[rule.id] = nil; continue }
            guard let value = rule.subject.value(in: snapshot) else { trueSince[rule.id] = nil; continue }
            guard rule.matches(value) else {
                trueSince[rule.id] = nil
                armed.insert(rule.id)
                continue
            }
            let since = trueSince[rule.id] ?? now
            trueSince[rule.id] = since
            let heldLongEnough = now.timeIntervalSince(since) >= TimeInterval(rule.seconds)
            let cooledDown = lastFired[rule.id].map { now.timeIntervalSince($0) >= cooldown } ?? true
            let isArmed = armed.contains(rule.id) || lastFired[rule.id] == nil
            if heldLongEnough && cooledDown && isArmed {
                lastFired[rule.id] = now
                armed.remove(rule.id)
                fired.append(
                    FiredAlert(
                        rule: rule, value: value, title: Self.title(rule, value: value, unit: unit),
                        body: Self.body(rule, value: value, unit: unit, snapshot: snapshot)))
            }
        }
        return fired
    }

    /// The notification's title carries the reading: "CPU running hot · 96°", "Battery low · 19%",
    /// "Startup disk almost full · 8.2 GB free". Memory pressure's level is its value.
    public static func title(_ rule: AlertRule, value: Double, unit: Format.TemperatureUnit) -> String {
        let name = rule.subject.title.replacingOccurrences(of: " temperature", with: "")
        let above = rule.comparison == .above
        let percent = "\(Int(value.rounded()))%"
        switch rule.subject {
        case .cpuTemperature, .gpuTemperature, .ssdTemperature, .hottestTemperature:
            return "\(name) \(above ? "running hot" : "below your limit") · \(Format.temperature(value, unit: unit))"
        case .memoryPressure: return rule.threshold >= 1 ? "Memory pressure is critical" : "Memory pressure is high"
        case .diskFreeGB: return "\(above ? "Startup disk" : "Startup disk almost full") · \(gigabytes(value)) free"
        case .batteryHealth: return "\(above ? "Battery health" : "Battery health dropped") · \(percent)"
        case .batteryPercent: return "\(above ? "Battery charged" : "Battery low") · \(percent)"
        case .cpuLoad, .gpuLoad, .memoryUsed: return "\(rule.subject.title) \(above ? "high" : "low") · \(percent)"
        }
    }

    /// The notification's text: the rule in plain words, then what the user wants to know next —
    /// the app using the most CPU or memory, or the time the battery has left — and what to do.
    /// `snapshot` is the reading the rule fired on; without it the text names no app.
    public static func body(_ rule: AlertRule, value: Double, unit: Format.TemperatureUnit, snapshot: Snapshot? = nil) -> String {
        let held = rule.seconds > 0 ? " for \(spokenDuration(rule.seconds))" : ""
        let side = rule.comparison == .above ? "Above" : "Below"
        let cores = snapshot?.cpu?.cores.count ?? 0
        let topCPU =
            snapshot?.topCPU.first.flatMap { app in
                cores > 0 ? " Using the most: \(app.name) at \(Format.percent(ProcessUsage.cpuShare(app.cpu, cores: cores))) of CPU." : nil
            } ?? ""
        let topMemory = snapshot?.topMemory.first.map { " Using the most: \($0.name) at \(Format.bytes($0.memory))." } ?? ""
        let inUse = snapshot?.memory.map { "\(Format.bytes($0.used)) of \(Format.bytes($0.total)) in use." }
        switch rule.subject {
        case .cpuTemperature, .hottestTemperature:
            return "\(side) \(Format.temperature(rule.threshold, unit: unit))\(held).\(topCPU)"
        case .gpuTemperature, .ssdTemperature:
            return "\(side) \(Format.temperature(rule.threshold, unit: unit))\(held)."
        case .cpuLoad:
            return "\(side) \(Int(rule.threshold.rounded()))%\(held).\(topCPU)"
        case .gpuLoad:
            return "\(side) \(Int(rule.threshold.rounded()))%\(held)."
        case .memoryUsed:
            return "\(inUse ?? "\(side) \(Int(rule.threshold.rounded()))%\(held).")\(topMemory)"
        case .memoryPressure:
            guard let inUse else { return "Apps may slow down. Quit apps you are not using." }
            return inUse + (topMemory.isEmpty ? " Quit apps you are not using." : topMemory)
        case .diskFreeGB:
            return "\(gigabytes(value)) left on the startup disk." + (rule.comparison == .below ? " Empty the Bin or move large files elsewhere." : "")
        case .batteryHealth:
            return "Maximum capacity is \(Int(value.rounded()))% of new. System Settings › Battery shows whether it needs service."
        case .batteryPercent:
            guard rule.comparison == .below else { return "Charged to \(Int(value.rounded()))%. You can unplug the power adapter." }
            let battery = snapshot?.battery
            if battery?.isCharging == true { return "Charging now." }
            let left = battery?.minutesRemaining.flatMap { $0 > 0 ? "About \($0 < 60 ? "\($0) minutes" : Format.minutes($0)) left. " : nil } ?? ""
            return left + "Connect the power adapter."
        }
    }

    /// 30 → "30 seconds", 60 → "1 minute", 300 → "5 minutes".
    public static func spokenDuration(_ seconds: Int) -> String {
        if seconds >= 60 && seconds.isMultiple(of: 60) { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// Free space as the rule stores it (decimal GB): "8.2 GB", "120 GB".
    static func gigabytes(_ value: Double) -> String { String(format: value >= 100 ? "%.0f GB" : "%.1f GB", value) }
}
