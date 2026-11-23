import Foundation
import Testing

@testable import HeronCore

/// The notifications' words: the reading in the title, then the app behind it or the time left
/// and what to do. And the two histories the panels gained, and the CPU share the card shows.
@Suite struct NotificationTextTests {
    /// A 14-core Mac whose top CPU app uses 10.38 cores (Activity Monitor's 1038%), its top memory
    /// app 9.2 GB of 36, on battery with 40 minutes left.
    func busy() -> Snapshot {
        var s = Snapshot()
        s.cpu = CPUReading(user: 0.6, system: 0.3, idle: 0.1, cores: (0..<14).map { CoreLoad(id: $0, kind: .performance, load: 0.9) }, loadAverage: [])
        s.memory = MemoryReading(
            total: 36 * 1_073_741_824, app: 30 * 1_073_741_824, wired: 3 * 1_073_741_824, compressed: 2 * 1_073_741_824,
            cached: 0, free: 1_073_741_824, swapUsed: 0, pressure: .critical)
        s.topCPU = [ProcessUsage(pid: 1, name: "Xcode", cpu: 10.38, memory: 0, count: 3)]
        s.topMemory = [ProcessUsage(pid: 2, name: "Safari", cpu: 0, memory: UInt64(9.2 * 1_073_741_824))]
        s.battery = BatteryReading(present: true, percent: 0.19, isCharging: false, onAC: false, minutesRemaining: 40)
        return s
    }

    @Test func titlesCarryTheReading() {
        let hot = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 95, seconds: 30)
        #expect(AlertEngine.title(hot, value: 96, unit: .celsius) == "CPU running hot · 96°")
        #expect(AlertEngine.title(hot, value: 96, unit: .fahrenheit) == "CPU running hot · 205°")
        let low = AlertRule(subject: .batteryPercent, comparison: .below, threshold: 20, seconds: 0)
        #expect(AlertEngine.title(low, value: 19, unit: .celsius) == "Battery low · 19%")
        let disk = AlertRule(subject: .diskFreeGB, comparison: .below, threshold: 10, seconds: 0)
        #expect(AlertEngine.title(disk, value: 8.24, unit: .celsius) == "Startup disk almost full · 8.2 GB free")
        let load = AlertRule(subject: .cpuLoad, comparison: .above, threshold: 90, seconds: 0)
        #expect(AlertEngine.title(load, value: 96.4, unit: .celsius) == "CPU load high · 96%")
        let health = AlertRule(subject: .batteryHealth, comparison: .below, threshold: 80, seconds: 0)
        #expect(AlertEngine.title(health, value: 79, unit: .celsius) == "Battery health dropped · 79%")
        // Pressure's level is its value.
        let pressure = AlertRule(subject: .memoryPressure, comparison: .above, threshold: 1.5, seconds: 10)
        #expect(AlertEngine.title(pressure, value: 2, unit: .celsius) == "Memory pressure is critical")
    }

    @Test func bodiesAddTheTopAppOrTheTimeLeft() {
        let s = busy()
        let hot = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 95, seconds: 30)
        // The app's share of the whole Mac (10.38 of 14 cores), by its app name, not "Xcode (3)".
        #expect(AlertEngine.body(hot, value: 96, unit: .celsius, snapshot: s) == "Above 95° for 30 seconds. Using the most: Xcode at 74% of CPU.")
        let pressure = AlertRule(subject: .memoryPressure, comparison: .above, threshold: 1.5, seconds: 10)
        #expect(AlertEngine.body(pressure, value: 2, unit: .celsius, snapshot: s) == "35.0 GB of 36.0 GB in use. Using the most: Safari at 9.2 GB.")
        let low = AlertRule(subject: .batteryPercent, comparison: .below, threshold: 20, seconds: 0)
        #expect(AlertEngine.body(low, value: 19, unit: .celsius, snapshot: s) == "About 40 minutes left. Connect the power adapter.")
        var charging = s
        charging.battery?.isCharging = true
        #expect(AlertEngine.body(low, value: 19, unit: .celsius, snapshot: charging) == "Charging now.")
        // No reading to name an app from: the rule alone, never an invented app or time.
        #expect(AlertEngine.body(hot, value: 96, unit: .celsius) == "Above 95° for 30 seconds.")
        #expect(AlertEngine.body(low, value: 19, unit: .celsius) == "Connect the power adapter.")
        #expect(AlertEngine.body(pressure, value: 2, unit: .celsius) == "Apps may slow down. Quit apps you are not using.")
    }

    @Test func firedAlertsUseTheSnapshotTheyFiredOn() {
        var e = AlertEngine(cooldown: 0)
        var s = busy()
        s.sensors = [Sensor(id: "a", name: "CPU 1", group: .cpuPerformance, celsius: 97, isKnown: true)]
        let rule = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 95, seconds: 0)
        let fired = e.evaluate([rule], snapshot: s, now: Date(timeIntervalSince1970: 0))
        #expect(fired.first?.title == "CPU running hot · 97°")
        #expect(fired.first?.body.hasSuffix("Using the most: Xcode at 74% of CPU.") == true)
    }

    @Test func durationsAreSpokenInWords() {
        #expect(AlertEngine.spokenDuration(30) == "30 seconds")
        #expect(AlertEngine.spokenDuration(60) == "1 minute")
        #expect(AlertEngine.spokenDuration(300) == "5 minutes")
        #expect(AlertEngine.spokenDuration(90) == "90 seconds")
    }

    @Test func aProcessShareIsOfTheWholeMac() {
        // Activity Monitor's 1038% on 14 cores is 74% of the Mac.
        #expect(Int((ProcessUsage.cpuShare(10.38, cores: 14) * 100).rounded()) == 74)
        #expect(ProcessUsage.cpuShare(0.5, cores: 10) == 0.05)
        #expect(ProcessUsage.cpuShare(30, cores: 8) == 1)  // never above the whole Mac
        #expect(ProcessUsage.cpuShare(2, cores: 0) == 0)  // no core count: no share
    }

    @Test func theNewRowHistoriesAreRecordedEverySecond() {
        var h = MetricHistory()
        for t in 0..<3 {
            var s = Snapshot()
            s.date = Date(timeIntervalSince1970: 1_000 + Double(t))
            s.gpu = GPUReading(device: 0.3, renderer: 0.25, tiler: 0.1, name: nil)
            s.memory = MemoryReading(total: 100, app: 10, wired: 5, compressed: 0, cached: 0, free: 0, swapUsed: 3_200, pressure: .warning, pressurePercent: 0.61)
            h.record(s)
        }
        #expect(h.series(.gpuRenderer, seconds: 60, points: 60) == [0.25, 0.25, 0.25])
        #expect(h.series(.gpuTiler, seconds: 60, points: 60) == [0.1, 0.1, 0.1])
        #expect(h.series(.memoryPressure, seconds: 60, points: 60) == [0.61, 0.61, 0.61])
        #expect(h.series(.swapUsed, seconds: 60, points: 60) == [3_200, 3_200, 3_200])
        // A kernel without a pressure percentage: no history, never a made-up one.
        var bare = MetricHistory()
        var s = Snapshot()
        s.memory = MemoryReading(total: 100, app: 10, wired: 5, compressed: 0, cached: 0, free: 0, swapUsed: 0, pressure: .normal)
        bare.record(s)
        #expect(bare.series(.memoryPressure, seconds: 60, points: 60).isEmpty)
        #expect(!Metric.gpuRenderer.keepsEverySecond && !Metric.swapUsed.keepsEverySecond)  // 13 KB each, not 0.7 MB
    }
}
