import Foundation
import Testing

@testable import HeronCore

/// The detail panels' row histories: every second, then 10-second and 2-minute averages.
@Suite struct TieredHistoryTests {
    @Test func coarserTiersAverageTheSecondsTheyCover() {
        var h = TieredHistory(layout: [(1, 600), (10, 360)])
        for v in 0..<25 { h.append(Double(v)) }
        // Two whole 10-second buckets (0...9, 10...19) and the bucket still filling (20...24).
        #expect(h.tiers[1].ring.last(10) == [4.5, 14.5])
        #expect(h.series(seconds: 3_600, points: 400) == [4.5, 14.5, 22])
    }

    @Test func eachRangeReadsTheFinestTierThatSpansIt() {
        var h = TieredHistory()
        for v in 0..<1_000 { h.append(Double(v)) }
        // 1 min: the last 60 seconds as they were.
        #expect(h.series(seconds: 60, points: 60) == (940..<1_000).map(Double.init))
        // 1 h: 10-second averages; 100 whole buckets, the newest ends at 999.
        let hour = h.series(seconds: 3_600, points: 400)
        #expect(hour.count == 100)
        #expect(hour.last == 994.5)
        // 24 h: 2-minute averages; 8 whole buckets and the filling one (960...999).
        let day = h.series(seconds: 86_400, points: 800)
        #expect(day.count == 9)
        #expect(day.first == 59.5)
        #expect(day.last == 979.5)
        // Older than 10 minutes is gone from the every-second tier but kept in the coarse ones.
        #expect(h.tiers[0].ring.count == 600)
    }

    @Test func aDayOfRowsStaysSmall() {
        #expect(TieredHistory().capacity == 1_680)
        // Every graph together: the ten every-second graphs, the rest tiered (under 8 MB).
        let full = Metric.allCases.filter(\.keepsEverySecond).count, tiered = Metric.allCases.count - full
        #expect(MetricHistory().storedValues == full * MetricHistory.capacity + tiered * 1_680)
        #expect(MetricHistory().storedValues * 8 < 8_000_000)
    }

    @Test func rowsAreRecordedSecondForSecond() {
        var h = MetricHistory()
        for t in 0..<4 {
            var s = Snapshot()
            s.date = Date(timeIntervalSince1970: 1_000 + Double(t) * 5)  // sampling every 5 s
            s.memory = MemoryReading(total: 100, app: UInt64(10 * (t + 1)), wired: 5, compressed: 0, cached: 0, free: 0, swapUsed: 0, pressure: .normal)
            s.sensors = [
                Sensor(id: "a", name: "SSD", group: .ssd, celsius: 40, isKnown: true),
                Sensor(id: "b", name: "SSD 2", group: .ssd, celsius: 50, isKnown: true),
            ]
            h.record(s)
        }
        #expect(h[.memoryApp].count == 16)
        #expect(h.series(.memoryApp, seconds: 5, points: 5) == [40, 40, 40, 40, 40])
        #expect(h.series(.sensorSSD, seconds: 60, points: 60).allSatisfy { $0 == 45 })
        #expect(h.series(.sensorGPU, seconds: 60, points: 60).isEmpty)  // no sensor, no history
    }
}
