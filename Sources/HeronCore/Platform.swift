import Foundation
import IOKit

// Small helpers for talking to the kernel (sysctl) and the IOKit registry.

enum Sysctl {
    /// Reads an integer sysctl such as "hw.ncpu". Returns nil if it does not exist.
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some sysctls are 32-bit; only the low `size` bytes are filled.
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }

    /// Reads a sysctl that returns a C struct, e.g. "vm.swapusage".
    static func value<T>(_ name: String, as: T.Type) -> T? {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0 else { return nil }
        return pointer.pointee
    }
}

enum Registry {
    /// Calls `body` for every IOKit service whose class matches `className`.
    static func forEachService(_ className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// All properties of a registry entry as a Swift dictionary.
    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dict
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

extension Double {
    /// Clamps a value into 0...1, used for every percentage the samplers produce (and the UI draws).
    public var unitClamped: Double { Swift.min(1, Swift.max(0, self.isFinite ? self : 0)) }
}

extension FixedWidthInteger {
    /// `self + other`, stopping at the type's bounds instead of trapping: totals of counts read
    /// from a server or a log file (a malformed one can repeat 1e15 thousands of times).
    public func addingSaturated(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other > 0 ? .max : .min
    }
}

extension String {
    /// Text from a NUL-terminated C buffer (`String(cString:)` on an array is deprecated).
    init(cBuffer: [CChar]) {
        self.init(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
