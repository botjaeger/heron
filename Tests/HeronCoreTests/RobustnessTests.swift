import Foundation
import Testing

@testable import HeronCore

/// Class: trusting server numbers. A NaN, an infinity or a 1e300 from a provider never traps an
/// `Int(...)`; it is dropped like any value Heron cannot read.
@Suite struct ServerNumberTests {
    @Test func nanInfinityAndHugeNumbersAreDropped() {
        for bad: Any in ["nan", "inf", "-inf", 1e300, "1e300"] {
            #expect(AIParse.number(bad) == nil, "\(bad) passed as a number")
        }
        #expect(AIParse.number("42") == 42)
        #expect(AIParse.int(.nan) == nil && AIParse.int(.infinity) == nil && AIParse.int(1e300) == nil)
        #expect(AIParse.int(2.5) == 3 && AIParse.int(2.9, .down) == 2)
    }

    @Test func absurdCountsNeverTrapTheMappers() {
        for bad: Any in ["nan", "inf", 1e300] {
            let grants: [String: Any] = ["cedar_ember": ["eligible": true, "grants": [["id": "g", "resets_left": bad, "usable_now": true]]]]
            #expect(ClaudeAPI.grants(grants).1.isEmpty)
            #expect(CodexAPI.resets(usage: ["rate_limit_reset_credits": ["available_count": bad]], list: nil).0 == nil)
            let days = CodexAPI.dailyTokens(["data": [["date": "2026-11-20", "totals": ["turns": 1, "text_total_tokens": bad]]]])
            #expect(days == ["2026-11-20": 0])
        }
        // A pace far outside any real range still reads as a sentence.
        _ = AIPace.tooltip(AIPace.Reading(status: .behind, share: 0.5, projectedFraction: 1e300, runway: 0))
    }

    /// Class: one bad entry hides the rest. A grant without an id is skipped, the others stay.
    @Test func aClaudeGrantWithoutAnIDSkipsOnlyThatGrant() {
        let body: [String: Any] = [
            "cedar_ember": [
                "eligible": true,
                "grants": [
                    ["resets_left": 1, "usable_now": true],
                    ["id": "good", "resets_left": 2, "usable_now": true],
                ],
            ]
        ]
        let (metric, grants) = ClaudeAPI.grants(body)
        #expect(grants.map(\.id) == ["good"])
        #expect(metric != nil)
    }
}

/// Class: UTC vs local days. Today and Yesterday are the user's own days, summed from the Codex
/// session logs by each event's timestamp; the analytics reply (whole UTC days) gives Last 30 days only.
@Suite struct LocalDayRowsTests {
    let manila = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Manila")!; return c
    }()

    func event(_ time: String, last: Int, total: Int) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1,"total_tokens":\#(last)},"total_token_usage":{"total_tokens":\#(total)}},"rate_limits":null}}"#
    }

    /// A temp sessions folder: `files` maps "YYYY/MM/DD/name.jsonl" to its lines.
    func sessions(_ files: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heron-days-\(UUID().uuidString)")
        for (path, lines) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { manila.date(from: DateComponents(year: y, month: m, day: d))! }

    @Test func aSessionAcrossLocalMidnightCountsEachEventOnItsOwnDay() throws {
        // Manila is UTC+8: 15:30Z on the 21st is 23:30 on the 21st there; 16:30Z is 00:30 on the 22nd.
        let root = try sessions([
            "2026/11/21/rollout-a.jsonl": [
                event("2026-11-21T15:30:00.000Z", last: 100, total: 100),
                #"{"timestamp":"2026-11-21T15:40:00Z","payload":{"type":"token_count","info":{"last_token_usage":"#,  // cut line
                event("2026-11-21T15:45:00.000Z", last: 100, total: 100),  // repeat, no new turn
                event("2026-11-21T16:30:00.000Z", last: 40, total: 140),
            ],
            "2026/11/22/rollout-b.jsonl": [
                event("2026-11-22T02:00:00.000Z", last: 7, total: 7),
                #"{"timestamp":"2026-11-22T02:01:00Z","type":"response_item","payload":{"type":"message"}}"#,
            ],
            "2026/11/19/rollout-old.jsonl": [event("2026-11-19T02:00:00.000Z", last: 999, total: 999)],  // untouched since: not read
            // Begun on the 15th, resumed today: the CLI keeps writing into the folder it began in.
            "2026/11/15/rollout-resumed.jsonl": [
                event("2026-11-15T02:00:00.000Z", last: 500, total: 500),
                event("2026-11-22T03:00:00.000Z", last: 3, total: 503),
            ],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        // Each log's modification date is its last write, as on a real disk.
        for (path, stamp) in [
            "2026/11/21/rollout-a.jsonl": "2026-11-21T16:30:00Z", "2026/11/22/rollout-b.jsonl": "2026-11-22T02:01:00Z",
            "2026/11/19/rollout-old.jsonl": "2026-11-19T02:00:00Z", "2026/11/15/rollout-resumed.jsonl": "2026-11-22T03:00:00Z",
        ] {
            try FileManager.default.setAttributes([.modificationDate: try #require(AIParse.date(stamp))], ofItemAtPath: root.appendingPathComponent(path).path)
        }
        let now = try #require(AIParse.date("2026-11-22T04:00:00Z"))  // 12:00 on the 22nd in Manila
        var read: [String] = []
        let days = try #require(
            BorrowedSignIn.codexDays(
                sessions: root, now: now, calendar: manila, cache: .init(),
                read: {
                    read.append($0.lastPathComponent); return try? Data(contentsOf: $0)
                }))
        #expect(!read.contains("rollout-old.jsonl"))
        #expect(days[day(2026, 11, 21)] == 100)
        #expect(days[day(2026, 11, 22)] == 50)
        let rows = CodexAPI.dayRows(days, now: now, calendar: manila)
        #expect(rows.map(\.title) == ["Today", "Yesterday"])
        #expect(rows.map(\.value) == [.tokens(50), .tokens(100)])
    }

    @Test func noSessionsFolderMeansNoRowsAndAnEmptyDayIsZero() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("heron-days-missing-\(UUID().uuidString)")
        #expect(BorrowedSignIn.codexDays(sessions: missing, calendar: manila, cache: .init()) == nil)
        let root = try sessions(["2026/11/01/rollout.jsonl": [event("2026-11-01T02:00:00Z", last: 5, total: 5)]])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(AIParse.date("2026-11-22T04:00:00Z"))
        let days = try #require(BorrowedSignIn.codexDays(sessions: root, now: now, calendar: manila, cache: .init()))
        #expect(CodexAPI.dayRows(days, now: now, calendar: manila).map(\.value) == [.tokens(0), .tokens(0)])
    }

    @Test func anUnchangedLogIsReadOnce() throws {
        let path = "2026/11/22/rollout.jsonl"
        let root = try sessions([path: [event("2026-11-22T02:00:00Z", last: 5, total: 5)]])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(AIParse.date("2026-11-22T04:00:00Z"))
        let cache = BorrowedSignIn.DayCache()
        var reads = 0
        let counting: (URL) -> Data? = {
            reads += 1; return try? Data(contentsOf: $0)
        }
        _ = BorrowedSignIn.codexDays(sessions: root, now: now, calendar: manila, cache: cache, read: counting)
        let again = BorrowedSignIn.codexDays(sessions: root, now: now, calendar: manila, cache: cache, read: counting)
        #expect(reads == 1)
        #expect(again?[day(2026, 11, 22)] == 5)
        // A new event changes the file: it is read again.
        try ([event("2026-11-22T02:00:00Z", last: 5, total: 5), event("2026-11-22T03:00:00Z", last: 6, total: 11)].joined(separator: "\n") + "\n")
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let changed = BorrowedSignIn.codexDays(sessions: root, now: now, calendar: manila, cache: cache, read: counting)
        #expect(reads == 2 && changed?[day(2026, 11, 22)] == 11)
    }

    @Test func theAnalyticsReplyGivesOnlyTheLast30Days() {
        let now = Date(timeIntervalSince1970: 1_763_600_000)  // 2025-11-20 00:53 UTC
        let rows = CodexAPI.tokenRows(["2025-11-20": 5, "2025-11-19": 7], now: now)
        #expect(rows.map(\.title) == ["Last 30 days"])
        #expect(rows.map(\.value) == [.tokens(12)])
    }
}

/// Reset kinds, decided as OpenUsage's `ClaudeResetGrantStatus` and Claude Code decide them.
@Suite struct ResetKindTests {
    @Test func everyRuleInOrder() {
        func kind(_ type: String?, _ clears: [String], _ back: Bool = false) -> AIResetKind { ClaudeAPI.kind(type: type, clears: clears, givesBackWeekly: back) }
        #expect(kind("session", ["five_hour"], true) == .fable)  // gives_back_weekly beats type
        #expect(kind(nil, [], true) == .fable)
        #expect(kind("session", ["seven_day"]) == .fiveHour)  // type beats clears
        #expect(kind("weekly", ["five_hour"]) == .weekly)
        #expect(kind("full", ["five_hour"]) == .full)
        #expect(kind("other", ["five_hour"]) == .fiveHour)  // unknown type: by clears
        #expect(kind(nil, ["five_hour"]) == .fiveHour)
        #expect(kind(nil, ["seven_day"]) == .weekly)
        #expect(kind(nil, ["seven_day", "seven_day_overage_included"]) == .weekly)
        #expect(kind(nil, ["seven_day_new"]) == .weekly)  // only non-five_hour windows
        #expect(kind(nil, ["five_hour", "seven_day"]) == .full)
        #expect(kind(nil, ["five_hour", "seven_day_new"]) == .full)  // an unknown window beside five_hour
        #expect(kind(nil, []) == .full)
    }

    @Test func grantsAndCreditsCarryTheirKindAndCount() {
        let body: [String: Any] = [
            "cedar_ember": [
                "eligible": true,
                "grants": [
                    ["id": "a", "resets_left": 2, "type": "weekly", "clears": ["five_hour"], "label": "Full reset", "usable_now": true],
                    ["id": "b", "resets_left": 1, "type": "session", "gives_back_weekly": true, "usable_now": true],
                ],
            ]
        ]
        let grants = ClaudeAPI.grants(body).1
        #expect(grants.map(\.kind) == [.weekly, .fable])  // `label` is never read
        #expect(grants.map(\.count) == [2, 1])
        let credits = CodexAPI.resets(usage: ["rate_limit_reset_credits": ["available_count": 1, "credits": [["id": "c", "status": "available"]]]], list: nil).1
        #expect(credits.map(\.kind) == [.full])
    }

    @Test func theListRepeatsAGrantPerResetInExpiryOrder() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let list = AIResetGrant.list([
            AIResetGrant(id: "x", expiresAt: nil, usableNow: true, detail: "", kind: .full),
            AIResetGrant(id: "w", expiresAt: t.addingTimeInterval(200), usableNow: true, detail: "", kind: .weekly, count: 2),
            AIResetGrant(id: "f", expiresAt: t.addingTimeInterval(100), usableNow: true, detail: "", kind: .fable),
        ])
        #expect(list.map(\.kind) == [.fable, .weekly, .weekly, .full])
    }
}

/// Class: backoff and Retry-After. Both header forms are read.
@Suite struct RetryAfterTests {
    @Test func deltaSecondsAndHTTPDateBothParse() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AIParse.retryAfter("120", now: now) == 120)
        let date = DateFormatter.http.string(from: now.addingTimeInterval(90))
        #expect(AIParse.retryAfter(date, now: now) == 90)
        #expect(AIParse.retryAfter("soon", now: now) == nil)
        #expect(AIParse.retryAfter(nil, now: now) == nil)
    }
}

/// Class: wall clock vs monotonic time in history. A clock set back keeps recording.
@Suite struct HistoryClockTests {
    @Test func aClockSetBackKeepsRecording() {
        var h = MetricHistory()
        var s = Snapshot()
        s.cpu = CPUReading(user: 0.5, system: 0, idle: 0.5, cores: [], loadAverage: [1])
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<5 { s.date = t0.addingTimeInterval(Double(i)); h.record(s) }
        let before = h.seconds(.metric(.cpu))
        // The clock goes back an hour: the next samples still land.
        for i in 0..<5 { s.date = t0.addingTimeInterval(-3600 + Double(i)); h.record(s) }
        #expect(h.seconds(.metric(.cpu)) == before + 5)
    }
}

/// Class: stale latched alert state. A rule's "held since" clears when it is off, when its
/// reading is missing, after a long gap (sleep), and when the rule is removed.
@Suite struct AlertLatchTests {
    func snapshot(_ c: Double?) -> Snapshot {
        var s = Snapshot()
        if let c { s.sensors = [Sensor(id: "smc:Tp01", name: "CPU 1", group: .cpu, celsius: c, isKnown: true)] }
        return s
    }
    let rule = AlertRule(subject: .cpuTemperature, comparison: .above, threshold: 90, seconds: 30)
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aRuleTurnedOffAndOnWaitsItsFullDuration() {
        var e = AlertEngine(cooldown: 0)
        _ = e.evaluate([rule], snapshot: snapshot(95), now: t0)
        var off = rule; off.enabled = false
        for i in 1...4 { _ = e.evaluate([off], snapshot: snapshot(95), now: t0 + Double(i * 5)) }
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 25).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 40).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 55).count == 1)
    }

    @Test func aMissingReadingRestartsTheDuration() {
        var e = AlertEngine(cooldown: 0)
        _ = e.evaluate([rule], snapshot: snapshot(95), now: t0)
        _ = e.evaluate([rule], snapshot: snapshot(nil), now: t0 + 10)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 20).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 40).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 50).count == 1)
    }

    @Test func aRemovedRuleLeavesNoStateBehind() {
        var e = AlertEngine(cooldown: 0)
        _ = e.evaluate([rule], snapshot: snapshot(95), now: t0)
        _ = e.evaluate([], snapshot: snapshot(95), now: t0 + 10)  // removed in Settings, then put back (undo)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 31).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 50).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 61).count == 1)
    }

    @Test func aLongGapRestartsTheDuration() {
        var e = AlertEngine(cooldown: 0)
        _ = e.evaluate([rule], snapshot: snapshot(95), now: t0)
        // Asleep for ten minutes, still hot on wake: the 30 s start now, not at t0.
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 600).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 620).isEmpty)
        #expect(e.evaluate([rule], snapshot: snapshot(95), now: t0 + 630).count == 1)
    }
}

/// Class: counter restarts. A VPN's utun recreated with counters from 0 keeps the session total.
@Suite struct SessionCounterTests {
    @Test func aRestartedCounterCarriesTheTotal() {
        var c = NetworkSampler.SessionCounter(1_000)
        c.update(1_500)
        #expect(c.total == 500)
        c.update(200)  // torn down and made again: counters from 0
        #expect(c.total == 700)
        c.update(300)
        #expect(c.total == 800)
        c.update(50)  // and again
        #expect(c.total == 850)
    }
}

/// Class: callback state check order, and every listener state ends the start wait.
@Suite struct LoopbackOrderTests {
    func hit(_ server: AILoopbackServer, _ query: String) async throws -> (Int, String) {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)\(server.path)?\(query)")!)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test func anErrorForAnotherSignInIsIgnored() async throws {
        let server = try AILoopbackServer(state: "S1")
        try await server.start()
        let (status, page) = try await hit(server, "error=access_denied&state=OTHER")
        #expect(status == 400 && page.contains("does not match"))
        _ = try await hit(server, "code=abc&state=S1")
        #expect(try await server.code() == "abc")
        server.stop()
    }

    @Test func aCancelledStartThrows() async throws {
        let server = try AILoopbackServer(state: "S1")
        let t = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do { try await server.start(); return false } catch { return true }
        }
        t.cancel()
        #expect(await t.value)
        server.stop()
    }

    @Test func stopDuringStartEndsTheWait() async throws {
        let server = try AILoopbackServer(state: "S1")
        async let started: Void = server.start()
        server.stop()
        // Either it was ready first or the stop ended it; it never hangs.
        _ = try? await started
    }
}

/// R1: the Codex session log is read from its tail only.
@Suite struct CodexLogTailTests {
    @Test func theLastRateLimitsLineIsFoundInALargeLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heron-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = dir.appendingPathComponent("2026/11/23")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let line =
            #"{"timestamp":"2026-11-23T10:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42,"window_minutes":300},"secondary":{"used_percent":7,"window_minutes":10080}}}}"#
        let filler = String(repeating: #"{"payload":{"type":"other"}}"# + "\n", count: 40_000)  // ~1.1 MB
        try (filler + line + "\n").write(to: day.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let r = try #require(BorrowedSignIn.codexFromLog(sessions: dir))
        #expect(r.metrics.map(\.key) == ["session", "weekly"])
        let tail = try #require(BorrowedSignIn.tail(of: day.appendingPathComponent("s.jsonl"), bytes: BorrowedSignIn.tailBytes))
        #expect(tail.utf8.count <= BorrowedSignIn.tailBytes)
        #expect(tail.hasPrefix("{"))
    }
}
