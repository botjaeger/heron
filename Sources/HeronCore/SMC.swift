import CSystem
import Foundation

/// Swift-side wrapper around the C SMC functions, with value decoding.
public final class SMC {
    private let connection: io_connect_t

    public init?() {
        let conn = heron_smc_open()
        guard conn != 0 else { return nil }
        connection = conn
    }

    deinit { heron_smc_close(connection) }

    public struct Value: Sendable, Equatable {
        public var type: String
        public var bytes: [UInt8]
        public var number: Double? { SMCDecode.number(type: type, bytes: bytes) }
    }

    /// Type and size per key. They never change, and caching them halves the kernel calls of every
    /// read (the temperature sweep reads ~270 keys a second: 60 ms before, measured on an M3 Max).
    /// Only successful lookups are cached, so a key that appears later is still found.
    private var infoCache: [String: (type: String, size: UInt32)] = [:]
    private let cacheLock = NSLock()

    public func read(_ key: String) -> Value? {
        guard let info = keyInfo(key) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard heron_smc_read_sized(connection, key, info.size, &bytes) else { return nil }
        return Value(type: info.type, bytes: Array(bytes.prefix(Int(min(info.size, 32)))))
    }

    private func keyInfo(_ key: String) -> (type: String, size: UInt32)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = infoCache[key] { return cached }
        var type = [CChar](repeating: 0, count: 5)
        var size: UInt32 = 0
        guard heron_smc_key_info(connection, key, &type, &size) else { return nil }
        let info = (type: String(cBuffer: type), size: size)
        infoCache[key] = info
        return info
    }

    public func number(_ key: String) -> Double? { read(key)?.number }

    /// Every key name the SMC exposes (about 1,000–2,500 on Apple silicon).
    public func allKeys() -> [String] {
        let count = heron_smc_key_count(connection)
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        var name = [CChar](repeating: 0, count: 5)
        for index in 0..<count where heron_smc_key_at(connection, index, &name) {
            keys.append(String(cBuffer: name))
        }
        return keys
    }
}

/// Decoding of the SMC's data types. Pure functions, unit tested.
public enum SMCDecode {
    public static func number(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count >= 4:
            // Little-endian IEEE float (Apple silicon).
            return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case "fpe2" where bytes.count >= 2:
            // Big-endian unsigned fixed point, 2 fractional bits (Intel fans).
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78" where bytes.count >= 2:
            // Big-endian signed fixed point, 8 fractional bits (Intel temperatures).
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 " where bytes.count >= 1:
            return Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }
}
