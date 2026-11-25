import Foundation
import Testing

@testable import HeronCore

// AUD-002 (docs/workstreams/heron-audit-2026-11-25.md). Here, not with the UI guards: those render
// on the main thread for tens of seconds, and this test needs the main queue to apply samples.

@MainActor
@Suite struct MonitorStartTests {
    /// A new monitor waits, and its readings settle soon after the first sample whatever the
    /// interval (the second sample comes half a second after the first, not one interval later).
    /// Reads this Mac's real counters.
    @Test func theMonitorSettlesWithoutWaitingAnInterval() async throws {
        let monitor = Monitor()
        #expect(monitor.snapshot.awaitingReadings)
        #expect(!Snapshot().awaitingReadings)  // fixtures and heron-snap draw as settled
        monitor.interval = 30  // far beyond any wait a busy test run adds
        // When each sample was taken (its own date, set on the sampler queue).
        var dates: [(Date, Bool)] = []
        monitor.onSample = { dates.append(($0.date, $0.awaitingReadings)) }
        let start = Date()
        monitor.start()
        defer { monitor.stop() }
        while monitor.snapshot.awaitingReadings, Date().timeIntervalSince(start) < 60 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!monitor.snapshot.awaitingReadings)
        #expect(monitor.snapshot.cpu != nil)
        let first = try #require(dates.first), settled = try #require(dates.first { !$0.1 })
        #expect(first.1)
        #expect(settled.0.timeIntervalSince(first.0) < 10, "second sample \(settled.0.timeIntervalSince(first.0)) s after the first")
    }
}
