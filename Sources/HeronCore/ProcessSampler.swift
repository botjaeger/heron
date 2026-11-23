import Darwin
import Foundation

/// Top processes by CPU and by memory, like Activity Monitor's first rows.
/// Processes owned by other users (root daemons) may refuse to report; they are skipped.
public final class ProcessSampler {
    private var previous: [Int32: UInt64] = [:]  // pid -> cpu nanoseconds
    private var lastDate: Date?
    private let timebase: (numer: UInt64, denom: UInt64)
    /// Each process's shown name, kept for its life (pid and start time: a reused pid is renamed).
    private var names: [Int32: (start: UInt64, name: String)] = [:]
    /// An app or XPC bundle's display name, by bundle path.
    private var bundleNames: [String: String] = [:]

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(info.denom))
    }

    public func sample(limit: Int = 5) -> (cpu: [ProcessUsage], memory: [ProcessUsage]) {
        let now = Date()
        let dt = lastDate.map { now.timeIntervalSince($0) } ?? 0
        var current: [Int32: UInt64] = [:]
        var usages: [ProcessUsage] = []

        for pid in Self.allPIDs() {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            guard ok else { continue }
            // CPU times are in mach ticks; on Apple silicon a tick is not a nanosecond.
            let ns = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
            current[pid] = ns
            var cpu = 0.0
            if dt > 0, let old = previous[pid], ns >= old { cpu = Double(ns - old) / (dt * 1e9) }
            // Each process is named once for its life (a path lookup, and a bundle read per app).
            let start = info.ri_proc_start_abstime
            let name: String
            if let known = names[pid], known.start == start { name = known.name } else { name = appName(of: pid); names[pid] = (start, name) }
            usages.append(ProcessUsage(pid: pid, name: name, cpu: cpu, memory: info.ri_phys_footprint))
        }
        previous = current
        lastDate = now
        names = names.filter { current[$0.key] != nil }
        // An app's helpers count with it: "Microsoft Edge (6)", their CPU and memory summed.
        let groups = ProcessNaming.grouped(usages)
        let byCPU = Array(groups.sorted { $0.cpu > $1.cpu }.prefix(limit))
        let byMemory = Array(groups.sorted { $0.memory > $1.memory }.prefix(limit))
        return (dt > 0 ? byCPU : [], byMemory)
    }

    /// The app a process belongs to, by its bundle's display name ("Microsoft Edge" for every
    /// Edge helper), or the process's own name when it is in no app or XPC bundle.
    func appName(of pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, let bundle = ProcessNaming.appBundle(path: String(cBuffer: path)) else {
            return Self.name(of: pid)
        }
        if let known = bundleNames[bundle] { return known }
        let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") as? [String: Any] ?? [:]
        let name = ProcessNaming.bundleName(info: info) ?? Self.name(of: pid)
        bundleNames[bundle] = name
        return name
    }

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, count)))).filter { $0 > 0 }
    }

    static func name(of pid: Int32) -> String {
        // proc_pidpath gives the full executable path; its last part is the real name
        // (proc_name truncates to 16 characters).
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let display = ProcessNaming.display(path: String(cBuffer: path))
            // Versioned installs run a binary named after its version (".../versions/2.1.328").
            // That says nothing; the name the program was started as (argv[0]) does.
            if ProcessNaming.looksLikeVersion(display), let launched = argv0(of: pid) { return launched }
            return display
        }
        var name = [CChar](repeating: 0, count: 64)
        proc_name(pid, &name, UInt32(name.count))
        let short = String(cBuffer: name)
        return short.isEmpty ? "pid \(pid)" : short
    }

    /// The last path component of argv[0], from KERN_PROCARGS2 (layout: argc, exec path, NULs, argv…).
    static func argv0(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessNaming.argv0(procargs: Array(buffer.prefix(size)))
    }
}

/// Pure naming rules for the process list, unit tested.
public enum ProcessNaming {
    /// "/Applications/Safari.app/Contents/MacOS/Safari" → "Safari"; "/usr/bin/node" → "node".
    public static func display(path: String) -> String {
        if let app = path.range(of: ".app/Contents/MacOS/") {
            return URL(fileURLWithPath: String(path[..<app.lowerBound]) + ".app").deletingPathExtension().lastPathComponent
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// The bundle a process is named after: the outermost app in its path (an app's helpers live
    /// inside it), else the XPC service or extension it runs as; nil for a plain binary.
    /// ".../Microsoft Edge.app/.../Microsoft Edge Helper (Renderer).app/Contents/MacOS/..." → ".../Microsoft Edge.app".
    public static func appBundle(path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let index = parts.firstIndex { $0.hasSuffix(".app") } ?? parts.lastIndex { $0.hasSuffix(".xpc") || $0.hasSuffix(".appex") }
        guard let index, index < parts.count - 1 else { return nil }
        return parts[...index].joined(separator: "/")
    }

    /// A bundle's name as its Info.plist gives it: the display name, else the bundle name.
    public static func bundleName(info: [String: Any]) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        }
        return nil
    }

    /// One row per name: CPU, memory and process counts summed, the first row's pid kept.
    public static func grouped(_ rows: [ProcessUsage]) -> [ProcessUsage] {
        var order: [String] = []
        var byName: [String: ProcessUsage] = [:]
        for row in rows {
            if var group = byName[row.name] {
                group.cpu += row.cpu; group.memory += row.memory; group.count += row.count
                byName[row.name] = group
            } else {
                byName[row.name] = row
                order.append(row.name)
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// "2.1.328", "1.0" — a name made only of digits and dots.
    public static func looksLikeVersion(_ name: String) -> Bool {
        name.contains(".") && !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// argv[0]'s last component from a KERN_PROCARGS2 buffer, nil if it is malformed or itself a version.
    public static func argv0(procargs: [UInt8]) -> String? {
        let intSize = MemoryLayout<Int32>.size
        guard procargs.count > intSize else { return nil }
        var i = intSize
        while i < procargs.count, procargs[i] != 0 { i += 1 }  // the exec path
        while i < procargs.count, procargs[i] == 0 { i += 1 }  // its padding
        let start = i
        while i < procargs.count, procargs[i] != 0 { i += 1 }  // argv[0]
        guard i > start else { return nil }
        let name = display(path: String(decoding: procargs[start..<i], as: UTF8.self))
        return name.isEmpty || looksLikeVersion(name) ? nil : name
    }
}
