import Foundation
import IOKit

/// Mounted volumes plus read/write throughput summed over every block device.
public final class DiskSampler {
    private var previous: (date: Date, read: UInt64, write: UInt64)?
    public var hideDiskImages = true { didSet { if hideDiskImages != oldValue { cachedVolumes = nil } } }
    /// Listing volumes costs ~9 ms (measured on an M3 Max); free space changes slowly, so the
    /// list is refreshed every `volumeRefresh` seconds, while throughput is still read every sample.
    public var volumeRefresh: TimeInterval = 5
    private var cachedVolumes: (date: Date, list: [VolumeReading])?

    public init() {}

    public func sample() -> DiskReading {
        let now = Date()
        let totals = Self.totalBytes()
        let (read, write) = totals ?? (0, 0)
        var readRate = 0.0, writeRate = 0.0
        if let previous {
            let dt = now.timeIntervalSince(previous.date)
            if dt > 0 {
                readRate = Double(read >= previous.read ? read - previous.read : 0) / dt
                writeRate = Double(write >= previous.write ? write - previous.write : 0) / dt
            }
        }
        previous = (now, read, write)
        if cachedVolumes.map({ now.timeIntervalSince($0.date) >= volumeRefresh || $0.date > now }) ?? true {
            cachedVolumes = (now, volumes())
        }
        return DiskReading(
            volumes: cachedVolumes?.list ?? [], readBytesPerSecond: readRate, writeBytesPerSecond: writeRate,
            bytesReadSinceBoot: totals?.0, bytesWrittenSinceBoot: totals?.1)
    }

    public func volumes() -> [VolumeReading] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
            .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true,
                let total = v.volumeTotalCapacity, total > 0
            else { return nil }
            let format = v.volumeLocalizedFormatDescription ?? ""
            let isImage = url.path.hasPrefix("/Volumes/") && v.volumeIsInternal != true && format.contains("Read-Only")
            if hideDiskImages && isImage { return nil }
            // "Important usage" includes purgeable space macOS will free on demand, like Finder shows.
            let available = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? UInt64(v.volumeAvailableCapacity ?? 0)
            return VolumeReading(
                name: v.volumeName ?? url.lastPathComponent, path: url.path, total: UInt64(total),
                available: available, isInternal: v.volumeIsInternal ?? false, format: format)
        }
    }

    /// Bytes read and written since boot, from every IOBlockStorageDriver's "Statistics"; nil when
    /// no driver publishes them.
    static func totalBytes() -> (UInt64, UInt64)? {
        var read: UInt64 = 0, write: UInt64 = 0, found = false
        Registry.forEachService("IOBlockStorageDriver") { service in
            guard let stats = Registry.property(service, "Statistics") as? [String: Any] else { return }
            found = true
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? (read, write) : nil
    }
}
