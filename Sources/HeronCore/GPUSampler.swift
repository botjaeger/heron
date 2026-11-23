import Foundation
import IOKit

/// GPU load from the IOAccelerator's "PerformanceStatistics" dictionary.
/// Undocumented but readable without root; key names have been stable on Apple silicon.
public final class GPUSampler {
    public init() {}

    public func sample() -> GPUReading? {
        var best: GPUReading?
        Registry.forEachService("IOAccelerator") { service in
            guard let stats = Registry.property(service, "PerformanceStatistics") as? [String: Any] else { return }
            func percent(_ key: String) -> Double? { (stats[key] as? NSNumber).map { ($0.doubleValue / 100).unitClamped } }
            guard let device = percent("Device Utilization %") ?? percent("GPU Activity(%)") else { return }
            let name = Registry.property(service, "model") as? String ?? Registry.property(service, "IOClass") as? String
            let reading = GPUReading(device: device, renderer: percent("Renderer Utilization %"), tiler: percent("Tiler Utilization %"), name: name)
            if best == nil || reading.device > best!.device { best = reading }
        }
        return best
    }
}
