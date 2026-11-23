import Foundation
import HeronCore

// Prints every reading Heron can take, twice one second apart (rates need two samples).
// Run with:  swift run heron-probe

if CommandLine.arguments.contains("--energy") {
    // Raw IOReport cadence: CPU energy delta every 250 ms for 8 s.
    let power = PowerSampler()
    var last = Date()
    for _ in 0..<32 {
        Thread.sleep(forTimeInterval: 0.25)
        _ = power.debugRawSample()
        let now = Date()
        let cpu = power.lastChannels.first { $0.name == "CPU Energy" }
        print(String(format: "t+%.2fs cpu %@ %@", now.timeIntervalSince(last), String(cpu?.value ?? -1), cpu?.unit ?? ""))
        last = now
    }
    exit(0)
}

if CommandLine.arguments.contains("--channels") {
    // Every IOReport energy channel over 3 s, zero ones too (to find a new chip's names).
    let power = PowerSampler()
    Thread.sleep(forTimeInterval: 3)
    _ = power.debugRawSample()
    for c in power.lastChannels { print(c.name, c.value, c.unit) }
    exit(0)
}

if CommandLine.arguments.contains("--timing") {
    // How long each sampler takes, and whether power stays non-zero across samples.
    @discardableResult func time<T>(_ name: String, _ body: () -> T) -> T {
        let start = Date(); let value = body(); print(String(format: "%-10@ %6.1f ms", name, Date().timeIntervalSince(start) * 1000)); return value
    }
    let sensors = time("smc scan") { SensorSampler() }
    let power = PowerSampler(), processes = ProcessSampler(), disk = DiskSampler(), cpu = CPUSampler()
    for round in 1...4 {
        Thread.sleep(forTimeInterval: 1)
        print("-- round \(round)")
        time("cpu") { _ = cpu.sample() }
        time("temps") { _ = sensors.temperatures() }
        time("named") { _ = sensors.temperatures(includeUnnamed: false) }
        time("fans") { _ = sensors.fans() }
        time("power") { print("   power", power.sample()?.package ?? -1) }
        time("disk") { _ = disk.sample() }
        time("processes") { _ = processes.sample() }
    }
    exit(0)
}

if CommandLine.arguments.contains("--ai") {
    // AI plan usage through the same code the app uses, from the sign-ins Claude Code and the
    // Codex CLI already saved (borrowed, read-only; Claude asks for the Keychain once), in a
    // scratch defaults suite and an in-memory token store. No email, id or token is printed.
    // OpenCode has no sign-in to borrow (its CLI's Zen key gets 401 from Go usage).
    let suite = "app.heron.probe.ai"
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let service = AIUsageService(defaults: UserDefaults(suiteName: suite)!, tokens: MemoryTokenStore())
        // Today and Yesterday in local days (\(TimeZone.current.identifier)), from the Codex CLI's session logs only.
        let days = await BorrowedSignIn.codexDayRows(for: AIAccount(provider: .codex, label: "probe", signIn: .borrowed))
        print("== Codex session logs, local days (\(TimeZone.current.identifier)):", days.isEmpty ? "no sessions folder" : "")
        for m in days { if case .tokens(let n) = m.value { print("   \(m.title): \(n) tokens") } }
        fflush(stdout)  // before Claude's Keychain read, which can wait on a prompt
        for provider in [AIProvider.claude, .codex] {
            let account = AIAccount(provider: provider, label: "probe", signIn: .borrowed)
            let r = await service.read(account, forceHourly: true)
            print("== \(provider.name) plan \(r.plan ?? "-") problem \(r.problem.map { "\($0)" } ?? "none") at \(r.fetchedAt)")
            for m in r.metrics {
                switch m.value {
                case .limit(let used, let limit, let unit, let reset, let period):
                    print("   \(m.title): \(used) of \(limit) \(unit.rawValue), resets \(reset.map { "\($0)" } ?? "-"), window \(period.map { "\(Int($0)) s" } ?? "-")")
                case .amount(let v, let unit, let label): print("   \(m.title): \(v) \(unit.rawValue) \(label)")
                case .resets(let n, let e): print("   \(m.title): \(n) available, expiries \(e)")
                case .tokens(let n): print("   \(m.title): \(n) tokens")
                }
            }
            for g in r.grants { print("   grant \(g.kind.title) ×\(g.count) usable \(g.usableNow) expires \(g.expiresAt.map { "\($0)" } ?? "-"): \(g.detail)") }
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        done.signal()
    }
    while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

let cpu = CPUSampler()
let memory = MemorySampler()
let disk = DiskSampler()
let network = NetworkSampler()
let battery = BatterySampler()
let gpu = GPUSampler()
let sensors = SensorSampler()
let power = PowerSampler()
let processes = ProcessSampler()
let clocks = ClockSampler()

_ = cpu.sample(); _ = disk.sample(); _ = network.sample(); _ = processes.sample()
Thread.sleep(forTimeInterval: 1)

func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
func gb(_ v: UInt64) -> String { String(format: "%.2f GB", Double(v) / 1_073_741_824) }

print("== Mac product-name:", SystemInfo.productName ?? "(none)", "| friendly:", SystemInfo.friendlyName)
print("== System")
print(
    "chip:", SystemInfo.chipName, "| model:", SystemInfo.modelIdentifier,
    "| cores:", SystemInfo.logicalCores, "P:", SystemInfo.performanceCores ?? -1, "E:", SystemInfo.efficiencyCores ?? -1)
if let c = cpu.sample() {
    print("== CPU total", pct(c.total), "user", pct(c.user), "system", pct(c.system), "idle", pct(c.idle), "load", c.loadAverage.map { String(format: "%.2f", $0) })
    let k = clocks.sample()
    print(
        "   clocks (IOReport + pmgr, available \(clocks.isAvailable)): E", k?.efficiencyMHz.map { String(format: "%.0f MHz", $0) } ?? "unavailable",
        "P", k?.performanceMHz.map { String(format: "%.0f MHz", $0) } ?? "unavailable", "GPU unavailable (table does not match its states)")
    print("   cores:", c.cores.map { "\($0.kind.rawValue.prefix(1))\($0.id)=\(Int($0.load * 100))" }.joined(separator: " "))
}
if let m = memory.sample() {
    print(
        "== Memory total", gb(m.total), "used", gb(m.used), "app", gb(m.app), "wired", gb(m.wired), "compressed", gb(m.compressed),
        "cached", gb(m.cached), "free", gb(m.free), "swap", gb(m.swapUsed), "pressure", m.pressure.rawValue,
        "pressure %", m.pressurePercent.map(pct) ?? "unavailable (kern.memorystatus_level)")
}
let d = disk.sample()
for v in d.volumes { print("== Volume", v.name, v.path, gb(v.used), "/", gb(v.total), "avail", gb(v.available), v.isInternal ? "internal" : "external", v.format) }
print(
    "   disk read", Int(d.readBytesPerSecond), "B/s write", Int(d.writeBytesPerSecond), "B/s",
    "· since boot read", d.bytesReadSinceBoot.map(gb) ?? "unavailable", "written", d.bytesWrittenSinceBoot.map(gb) ?? "unavailable")
let n = network.sample()
print("== Network", n.interface ?? "-", n.interfaceKind, n.localIP ?? "-", "down", Int(n.downBytesPerSecond), "B/s up", Int(n.upBytesPerSecond), "B/s")
let b = battery.sample()
print(
    "== Battery present", b.present, pct(b.percent), "charging", b.isCharging, "AC", b.onAC, "min", b.minutesRemaining ?? -1,
    "cycles", b.cycleCount ?? -1, "health", b.maxCapacityFraction.map(pct) ?? "-", "cond", b.condition ?? "-",
    "temp", b.temperatureC ?? -1, "W", b.watts.map { String(format: "%.2f", $0) } ?? "-",
    "charge limit", b.chargeLimit.map(pct) ?? (b.chargeLimitKnown ? "off" : "unknown (\(ChargeLimitSource.path))"))
if let g = gpu.sample() {
    print("== GPU", g.name ?? "-", "device", pct(g.device), "renderer", g.renderer.map(pct) ?? "-", "tiler", g.tiler.map(pct) ?? "-")
} else {
    print("== GPU unavailable")
}
print("== SMC available:", sensors.hasSMC)
let temps = sensors.temperatures()
print("== Temperatures (\(temps.count), known \(temps.filter(\.isKnown).count))")
for t in temps { print("   \(t.id) \(t.name) [\(t.group.rawValue)] \(String(format: "%.1f", t.celsius))°") }
let names = sensors.knownNames
print(
    "== Named sensors (\(names.count)), longest name:", names.max { $0.count < $1.count } ?? "-", "· hottest:", temps.filter(\.isKnown).max { $0.celsius < $1.celsius }?.name ?? "-"
)
let hid = sensors.hidTemperatures()
print("== HID temperatures (\(hid.count))")
for t in hid.prefix(40) { print("   \(t.id) \(String(format: "%.1f", t.celsius))°") }
print("== Fans")
for f in sensors.fans() { print("  ", f.name, Int(f.rpm), "rpm (min \(Int(f.minRPM)) max \(Int(f.maxRPM)) target \(f.targetRPM.map { String(Int($0)) } ?? "-"))") }
// Power needs two energy lumps (about 2 s apart); sample for up to 8 s.
var powerReading: PowerReading?
for _ in 0..<8 where powerReading == nil { Thread.sleep(forTimeInterval: 1); powerReading = power.sample() }
for _ in 0..<4 { Thread.sleep(forTimeInterval: 1); powerReading = power.sample() ?? powerReading }
if let p = powerReading {
    print("== Power cpu", p.cpu ?? -1, "gpu", p.gpu ?? -1, "ane", p.ane ?? -1, "dram", p.dram ?? -1, "display", p.display ?? -1, "package", p.package ?? -1)
    print("   channels:", power.lastChannels.filter { $0.value != 0 }.map { "\($0.name)=\($0.value)\($0.unit)" }.joined(separator: " "))
} else {
    print("== Power unavailable (IOReport:", power.isAvailable, ")")
}
let top = processes.sample()
print("== Top CPU:", top.cpu.map { "\($0.title) \(String(format: "%.1f", $0.cpu * 100))%" })
print("== Top memory:", top.memory.map { "\($0.title) \(gb($0.memory))" })
