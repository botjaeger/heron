import Foundation
import Observation

/// Owns every sampler, samples on a timer, and publishes the newest `Snapshot`.
///
/// `@Observable` (Swift's Observation framework) lets SwiftUI views redraw automatically
/// when `snapshot` or `history` change. Sampling runs on a background queue so the menu bar
/// never stutters; results are applied on the main thread, where SwiftUI reads them.
@MainActor
@Observable
public final class Monitor {
    public private(set) var snapshot: Snapshot = {
        var s = Snapshot()
        s.awaitingReadings = true
        return s
    }()
    public private(set) var history = MetricHistory()
    public private(set) var hasSMC = false
    /// Sensors without a known name, counted once at start (they are only read while shown).
    public private(set) var unnamedSensorCount = 0
    /// Read the unnamed SMC sensors too (Settings › Overview › Sensors › "Hide unnamed" off).
    public var includeUnnamedSensors = false
    public private(set) var hasPowerReadings = false

    /// Seconds between samples (0.5, 1, 2 or 5).
    public var interval: TimeInterval = 1 { didSet { if timer != nil { restart() } } }
    /// Sample every 5 s while on battery below 20%, if enabled in settings.
    public var slowOnLowBattery = true
    public var hideDiskImages = true {
        // The disk sampler lives on the sampler queue: hand the setting over there.
        didSet { let hide = hideDiskImages; queue.async { [samplers] in samplers.disk.hideDiskImages = hide } }
    }
    public var topProcessCount = 5

    /// Called on the main thread after every sample (the menu bar item and alerts hook in here).
    @ObservationIgnored public var onSample: ((Snapshot) -> Void)?

    // .userInitiated, not .utility: under full CPU load .utility work was starved and the
    // monitor skipped half its samples (4 in 8 s), exactly when readings matter most.
    @ObservationIgnored private let queue = DispatchQueue(label: "app.heron.sampler", qos: .userInitiated)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var appliedCount = 0
    @ObservationIgnored private let samplers = Samplers()

    public init() {}

    public func start() {
        guard timer == nil else { return }
        queue.async { [weak self, samplers] in
            // First touch of SMC and IOReport is slow (key scan); do it off the main thread.
            let smc = samplers.sensors.hasSMC, ioreport = samplers.power.isAvailable, unnamed = samplers.sensors.unnamedCount
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                hasSMC = smc; hasPowerReadings = ioreport; unnamedSensorCount = unnamed
            }
        }
        tick()
        scheduleTimer()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restart() { stop(); scheduleTimer() }

    private var effectiveInterval: TimeInterval {
        if slowOnLowBattery, let b = snapshot.battery, b.present, !b.onAC, b.percent < 0.2 { return max(interval, 5) }
        return interval
    }

    private func scheduleTimer() {
        let t = Timer(timeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }  // scheduled on the main run loop below
        }
        t.tolerance = effectiveInterval * 0.1  // lets macOS batch wake-ups, saves energy
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !busy else { return }  // never queue samples up if one is slow
        busy = true
        tickCount += 1
        let processCount = tickCount % 2 == 1 ? topProcessCount : nil
        let unnamed = includeUnnamedSensors
        queue.async { [weak self, samplers] in
            let (sample, top) = samplers.sample(includeUnnamed: unnamed, processCount: processCount)
            DispatchQueue.main.async { [weak self] in self?.apply(sample, top: top) }
        }
    }

    private func apply(_ sample: Snapshot, top: Samplers.Top?) {
        var s = sample
        if let top {
            s.topCPU = top.cpu; s.topMemory = top.memory
        } else {
            s.topCPU = snapshot.topCPU; s.topMemory = snapshot.topMemory
        }
        // Power and GPU need two samples; keep the last good value instead of blinking.
        if s.power == nil { s.power = snapshot.power }
        // A cluster idle for a whole tick has no clock; keep its last one.
        if let old = snapshot.clocks {
            var c = s.clocks ?? old
            c.efficiencyMHz = c.efficiencyMHz ?? old.efficiencyMHz
            c.performanceMHz = c.performanceMHz ?? old.performanceMHz
            s.clocks = c
        }
        appliedCount += 1
        // The first sample has no CPU, GPU or rates yet (they are differences between two).
        s.awaitingReadings = appliedCount < 2
        let wasSlow = effectiveInterval
        snapshot = s
        // A history point with no CPU reading would draw as 0%.
        if !s.awaitingReadings { history.record(s) }
        busy = false
        onSample?(s)
        if effectiveInterval != wasSlow { restart() }
        // The second sample half a second after the first, not a whole (up to 5 s) interval later.
        if s.awaitingReadings, interval > 0.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tick() }
        }
    }
}

/// Every sampler. They keep state between samples and are not thread-safe, so they are only ever
/// touched on `Monitor`'s serial sampler queue (`@unchecked Sendable` hands them over there).
private final class Samplers: @unchecked Sendable {
    typealias Top = (cpu: [ProcessUsage], memory: [ProcessUsage])
    let cpu = CPUSampler()
    let memory = MemorySampler()
    let disk = DiskSampler()
    let network = NetworkSampler()
    let battery = BatterySampler()
    let gpu = GPUSampler()
    lazy var sensors = SensorSampler()
    lazy var power = PowerSampler()
    lazy var clocks = ClockSampler()
    let processes = ProcessSampler()

    func sample(includeUnnamed: Bool, processCount: Int?) -> (Snapshot, Top?) {
        var s = Snapshot()
        s.cpu = cpu.sample()
        s.memory = memory.sample()
        s.disk = disk.sample()
        s.network = network.sample()
        s.battery = battery.sample()
        s.gpu = gpu.sample()
        s.sensors = sensors.temperatures(includeUnnamed: includeUnnamed)
        s.sensorNames = sensors.knownNames
        s.fans = sensors.fans()
        s.power = power.sample()
        s.clocks = clocks.sample()
        // No battery temperature from the battery itself: `Snapshot.batteryCelsius` falls back
        // to the average of its sensors (a component is its average, never its hottest sensor).
        return (s, processCount.map { processes.sample(limit: $0) })
    }
}
