import Foundation
import SystemConfiguration

/// Network throughput for the primary interface.
/// Uses sysctl(NET_RT_IFLIST2): unlike getifaddrs, its byte counters are 64-bit and do not wrap at 4 GB.
public final class NetworkSampler {
    private var previous: (date: Date, counters: [String: InterfaceCounters])?
    private var session: [String: (received: SessionCounter, sent: SessionCounter)] = [:]
    /// Created once: a dynamic store per sample was a Mach session setup every second.
    private lazy var store = SCDynamicStoreCreate(nil, "Heron" as CFString, nil, nil)
    /// Interface kinds do not change while an interface exists; listing every interface each second did.
    private var kinds: [String: String] = [:]

    public init() {}

    public func sample() -> NetworkReading {
        let now = Date()
        let counters = Self.readCounters()
        let primary = Self.primaryInterface(store: store)
        if let primary, kinds[primary] == nil { kinds[primary] = Self.kind(of: primary) }
        var down = 0.0, up = 0.0
        if let primary, let previous, let old = previous.counters[primary], let new = counters[primary] {
            let dt = now.timeIntervalSince(previous.date)
            if dt > 0 {
                down = Double(new.received >= old.received ? new.received - old.received : 0) / dt
                up = Double(new.sent >= old.sent ? new.sent - old.sent : 0) / dt
            }
        }
        for (name, value) in counters {
            if session[name] == nil {
                session[name] = (SessionCounter(value.received), SessionCounter(value.sent))
            } else {
                session[name]!.received.update(value.received); session[name]!.sent.update(value.sent)
            }
        }
        previous = (now, counters)
        var sessionDown: UInt64 = 0, sessionUp: UInt64 = 0
        if let primary, let s = session[primary] { sessionDown = s.received.total; sessionUp = s.sent.total }
        return NetworkReading(
            interface: primary, interfaceKind: primary.flatMap { kinds[$0] } ?? "Offline",
            localIP: primary.flatMap(Self.ipv4Address(of:)),
            downBytesPerSecond: down, upBytesPerSecond: up, sessionDown: sessionDown, sessionUp: sessionUp)
    }

    public struct InterfaceCounters: Sendable, Equatable {
        public var received: UInt64
        public var sent: UInt64
    }

    /// Bytes through one counter since Heron started, across counter restarts: an interface that
    /// is torn down and made again (a VPN's utun) starts its counters from 0. Pure, unit tested.
    public struct SessionCounter: Sendable, Equatable {
        private var start: UInt64
        private var last: UInt64
        private var carried: UInt64 = 0

        public init(_ first: UInt64) { start = first; last = first }

        public mutating func update(_ current: UInt64) {
            if current < last {
                // Restarted: keep what was counted before, and count the new run from 0.
                carried &+= last - start
                start = 0
            }
            last = current
        }

        public var total: UInt64 { carried &+ (last - start) }
    }

    /// Byte counters for every interface, keyed by BSD name ("en0", "utun3", ...).
    public static func readCounters() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr2>.size
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + headerSize + 8 <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    // A sockaddr_dl follows the header; the interface name starts at byte 8 of it.
                    let sdlOffset = offset + headerSize
                    let nameLength = Int(raw[sdlOffset + 5])  // sdl_nlen
                    if nameLength > 0, sdlOffset + 8 + nameLength <= length {
                        let nameBytes = raw[(sdlOffset + 8)..<(sdlOffset + 8 + nameLength)]
                        let name = String(decoding: nameBytes, as: UTF8.self)
                        result[name] = InterfaceCounters(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    /// The interface macOS currently routes internet traffic through.
    public static func primaryInterface(store: SCDynamicStore? = nil) -> String? {
        guard let store = store ?? SCDynamicStoreCreate(nil, "Heron" as CFString, nil, nil),
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    public static func kind(of bsdName: String) -> String {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }),
            let type = SCNetworkInterfaceGetInterfaceType(match)
        else { return bsdName.hasPrefix("utun") ? "VPN" : "Network" }
        switch type {
        case kSCNetworkInterfaceTypeIEEE80211: return "Wi-Fi"
        case kSCNetworkInterfaceTypeEthernet: return "Ethernet"
        case kSCNetworkInterfaceTypeBluetooth: return "Bluetooth"
        default: return (SCNetworkInterfaceGetLocalizedDisplayName(match) as String?) ?? "Network"
        }
    }

    public static func ipv4Address(of bsdName: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard String(cString: item.ifa_name) == bsdName, let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cBuffer: host)
            }
        }
        return nil
    }
}
