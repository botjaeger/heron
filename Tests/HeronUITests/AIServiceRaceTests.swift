import Foundation
import Testing

@testable import HeronCore

/// Answers every request of a test session from `handler`; nothing reaches the network.
nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {  // `body` is plain JSON values
        var status: Int
        var headers: [String: String] = [:]
        var body: Any = [String: Any]()
        var delay: TimeInterval = 0
    }
    struct Seen { var url: String; var body: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest, String) -> Reply)?
    nonisolated(unsafe) private static var _seen: [Seen] = []
    static var handler: ((URLRequest, String) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; _seen = []; lock.unlock() }
    }
    static var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return _seen }
    static func count(_ part: String) -> Int { seen.filter { $0.url.contains(part) }.count }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    private let stateLock = NSLock()
    private var stopped = false

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        let body = String(decoding: data, as: UTF8.self)
        Self.lock.lock(); Self._seen.append(Seen(url: request.url?.absoluteString ?? "", body: body)); let h = Self._handler; Self.lock.unlock()
        let reply = h?(request, body) ?? Reply(status: 404)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            stateLock.lock(); let gone = stopped; stateLock.unlock()
            guard !gone else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

/// A Keychain that refuses every write.
nonisolated final class RefusingTokenStore: AITokenStore, @unchecked Sendable {
    var stored: [String: AITokens] = [:]
    func load(_ id: String) -> AITokens? { stored[id] }
    func save(_ tokens: AITokens, for id: String) -> Bool { false }
    func delete(_ id: String) { stored[id] = nil }
}

@MainActor
func waitFor(_ seconds: Double = 3, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
}

/// Classes: concurrent token renewal; write after await to a removed entity; backoff and
/// Retry-After; stale snapshot written back; tokens the Keychain refused. One stub, so serialized.
@MainActor
@Suite(.serialized) struct AIServiceRaceTests {
    let usage = ClaudeAPI.usageURL
    let fresh = AITokens(access: "a1", refresh: "r1", expiresAt: Date().addingTimeInterval(3600))
    let expired = AITokens(access: "a1", refresh: "r1", expiresAt: Date().addingTimeInterval(-60))

    func make(_ tag: String, store: AITokenStore = MemoryTokenStore(), signIn: AISignIn = .oauth) -> (AIUsageService, AIAccount) {
        let s = AIUsageService(defaults: scratchDefaults(tag), tokens: store, session: StubProtocol.session())
        let a = AIAccount(id: "acct-\(tag)", provider: .claude, label: "Old", signIn: signIn)
        s.setPreview(accounts: [a], readings: [:])
        return (s, a)
    }

    func isUsage(_ r: URLRequest) -> Bool { r.url?.absoluteString == ClaudeAPI.usageURL }

    @Test func twoRefreshesOfOneAccountReadOnce() async {
        StubProtocol.handler = { r, _ in .init(status: 200, delay: self.isUsage(r) ? 0.2 : 0) }
        let store = MemoryTokenStore()
        let (s, a) = make("single-flight", store: store)
        store.tokens[a.id] = fresh
        async let one: Void = s.refresh(a, force: true)
        async let two: Void = s.refresh(a, force: true)
        _ = await (one, two)
        #expect(StubProtocol.seen.filter { $0.url == usage }.count == 1)
    }

    @Test func aRenewalRacingAnotherKeepsTheAccountSignedIn() async {
        var renewed = false
        StubProtocol.handler = { r, _ in
            guard r.url?.absoluteString == ClaudeAPI.tokenURL else { return .init(status: 200) }
            // The provider rotates the refresh token: a second use of r1 is refused as reused.
            if renewed { return .init(status: 400, body: ["error": "invalid_grant"], delay: 0.1) }
            renewed = true
            return .init(status: 200, body: ["access_token": "a2", "refresh_token": "r2", "expires_in": 3600], delay: 0.2)
        }
        let store = MemoryTokenStore()
        let (s, a) = make("renew-race", store: store)
        store.tokens[a.id] = expired
        // The timer's refresh and a reset claim, both renewing the same expired sign-in.
        async let read: Void = s.refresh(a, force: true)
        async let claim = s.renew(a, expired, force: true)
        _ = await (read, claim)
        #expect(StubProtocol.count(ClaudeAPI.tokenURL) == 1)
        #expect(store.tokens[a.id]?.refresh == "r2")
    }

    @Test func aStaleRefusalNeverWipesNewerTokens() async {
        StubProtocol.handler = { _, _ in .init(status: 400, body: ["error": "invalid_grant"]) }
        let store = MemoryTokenStore()
        let (s, a) = make("stale-refusal", store: store)
        store.tokens[a.id] = AITokens(access: "a2", refresh: "r2", expiresAt: nil)
        _ = await s.renew(a, expired, force: true)  // sends r1, which another renewal replaced
        #expect(store.tokens[a.id]?.refresh == "r2")
        _ = await s.renew(a, store.tokens[a.id]!, force: true)  // the stored one refused: signed out
        #expect(store.tokens[a.id] == nil)
    }

    @Test func removedDuringARefreshLeavesNothingBehind() async {
        StubProtocol.handler = { r, _ in .init(status: 200, delay: self.isUsage(r) ? 0.3 : 0) }
        let store = MemoryTokenStore()
        let (s, a) = make("remove-read", store: store)
        store.tokens[a.id] = fresh
        let t = Task { await s.refresh(a, force: true) }
        await waitFor { StubProtocol.seen.contains { $0.url == usage } }
        s.remove(a.id)
        await t.value
        #expect(s.readings[a.id] == nil)
        #expect(store.tokens[a.id] == nil)
    }

    @Test func removedDuringARenewalSavesNoTokens() async {
        StubProtocol.handler = { r, _ in
            r.url?.absoluteString == ClaudeAPI.tokenURL
                ? .init(status: 200, body: ["access_token": "a2", "refresh_token": "r2", "expires_in": 3600], delay: 0.3)
                : .init(status: 200)
        }
        let store = MemoryTokenStore()
        let (s, a) = make("remove-renew", store: store)
        store.tokens[a.id] = expired
        let t = Task { await s.refresh(a, force: true) }
        await waitFor { StubProtocol.count(ClaudeAPI.tokenURL) == 1 }
        s.remove(a.id)
        await t.value
        #expect(store.tokens[a.id] == nil)
        #expect(s.readings[a.id] == nil)
    }

    @Test func aBorrowedSignInRefusedOnceRetriesOnTheNormalBackoff() async {
        StubProtocol.handler = { _, _ in .init(status: 401) }
        let (s, a) = make("borrowed-401", signIn: .borrowed)
        s.borrowedTokens = { _ in AITokens(access: "cli", refresh: nil, expiresAt: Date().addingTimeInterval(3600)) }
        let before = Date()
        await s.refresh(a, force: false)
        #expect(s.readings[a.id]?.problem == .signInExpired)
        let wait = (s.waitUntil[a.id] ?? .distantPast).timeIntervalSince(before)
        #expect(wait > 0 && wait <= AIUsageService.interval + 1)
    }

    @Test func aFirstEverReadThatIsRateLimitedKeepsItsRetryAfter() async {
        StubProtocol.handler = { _, _ in .init(status: 429, headers: ["Retry-After": "120"]) }
        let store = MemoryTokenStore()
        let (s, a) = make("first-429", store: store)
        store.tokens[a.id] = fresh
        let before = Date()
        await s.refresh(a, force: false)
        let wait = (s.waitUntil[a.id] ?? .distantPast).timeIntervalSince(before)
        #expect(wait > 115 && wait <= 121)
        let asked = StubProtocol.seen.count
        await s.refresh(a, force: true)  // ⌘R never skips a provider's Retry-After
        #expect(StubProtocol.seen.count == asked)
    }

    @Test func retryAfterIsReadInAnyCaseAndAsADate() async {
        for (header, expected) in [("retry-after", "120"), ("Retry-After", DateFormatter.http.string(from: Date().addingTimeInterval(90)))] {
            StubProtocol.handler = { _, _ in .init(status: 429, headers: [header: expected]) }
            let store = MemoryTokenStore()
            let (s, a) = make("retry-after-\(header)", store: store)
            store.tokens[a.id] = fresh
            let before = Date()
            await s.refresh(a, force: false)
            let wait = (s.waitUntil[a.id] ?? .distantPast).timeIntervalSince(before)
            let want: Double = header == "retry-after" ? 120 : 90
            #expect(abs(wait - want) < 3, "\(header): \(expected) waited \(wait)")
        }
    }

    @Test func theHourlyReadNeverWritesBackAStaleAccount() async {
        StubProtocol.handler = { r, _ in
            r.url?.absoluteString == ClaudeAPI.profileURL
                ? .init(status: 200, body: ["organization": ["uuid": Self.org]], delay: 0.3)
                : .init(status: 200)
        }
        let store = MemoryTokenStore()
        let (s, a) = make("hourly-stale", store: store)
        store.tokens[a.id] = fresh
        let t = Task { await s.refresh(a, force: true) }
        await waitFor { StubProtocol.count(ClaudeAPI.profileURL) == 1 }
        var renamed = a; renamed.label = "New"
        s.update(renamed)  // renamed in Settings while the profile is on its way
        await t.value
        #expect(s.accounts.first?.label == "New")
        #expect(s.accounts.first?.extras["org_uuid"] == Self.org)
    }

    @Test func tokensTheKeychainRefusedAreUsedForTheNextRenewal() async {
        var n = 0
        StubProtocol.handler = { r, _ in
            guard r.url?.absoluteString == ClaudeAPI.tokenURL else { return .init(status: 200) }
            n += 1
            // Expires at once, so the next refresh renews again.
            return .init(status: 200, body: ["access_token": "a\(n + 1)", "refresh_token": "r\(n + 1)", "expires_in": 0])
        }
        let store = RefusingTokenStore()
        let (s, a) = make("refused-write", store: store)
        store.stored[a.id] = expired
        await s.refresh(a, force: true)
        await s.refresh(a, force: true)
        let posts = StubProtocol.seen.filter { $0.url == ClaudeAPI.tokenURL }
        #expect(posts.count == 2)
        #expect(posts.last?.body.contains("\"refresh_token\":\"r2\"") == true)
    }
}

/// Classes: device-code polling that never stops; a cancelled sign-in that writes over the next one.
@MainActor
extension AIServiceRaceTests {
    func deviceCode(interval: Double, delay: TimeInterval = 0) -> StubProtocol.Reply {
        .init(status: 200, body: ["device_code": "dc", "user_code": "ABCD", "verification_uri": "https://opencode.ai/device", "interval": interval, "expires_in": 5], delay: delay)
    }

    func flow(_ tag: String) -> (AISignInFlow, AIUsageService) {
        let session = StubProtocol.session()
        let service = AIUsageService(defaults: scratchDefaults(tag), tokens: MemoryTokenStore(), session: session)
        return (AISignInFlow(service: service, openURL: { _ in }, session: session), service)
    }

    @Test func aFinalRefusalStopsThePollWithTheServersReason() async {
        StubProtocol.handler = { r, _ in
            r.url?.absoluteString == OpenCodeAPI.deviceCodeURL
                ? self.deviceCode(interval: 0)
                : .init(status: 400, body: ["error": "invalid_client", "error_description": "Unknown client"])
        }
        let (f, _) = flow("device-final")
        f.start(.opencode)
        await waitFor(7) {
            if case .failed = f.step { return true }; return false
        }
        guard case .failed(let message) = f.step else { Issue.record("still \(f.step)"); return }
        #expect(message.contains("Unknown client"))
        #expect(StubProtocol.count(OpenCodeAPI.tokenURL) == 1)
        f.cancel()
    }

    @Test func anIntervalOfZeroStillPausesBetweenPolls() async {
        StubProtocol.handler = { r, _ in
            r.url?.absoluteString == OpenCodeAPI.deviceCodeURL ? self.deviceCode(interval: 0) : .init(status: 400, body: ["error": "authorization_pending"])
        }
        let (f, _) = flow("device-interval")
        f.start(.opencode)
        try? await Task.sleep(nanoseconds: 600_000_000)
        f.cancel()
        #expect(StubProtocol.count(OpenCodeAPI.tokenURL) <= 1)
    }

    @Test func cancellingWhileARequestIsOutLeavesTheFlowIdle() async {
        StubProtocol.handler = { _, _ in self.deviceCode(interval: 1, delay: 0.5) }
        let (f, _) = flow("cancel-idle")
        f.start(.opencode)
        await waitFor { StubProtocol.count(OpenCodeAPI.deviceCodeURL) == 1 }
        f.cancel()
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(f.step == .idle)
    }

    @Test func aSignInCancelledAtTheLastStepAddsNoAccount() async {
        StubProtocol.handler = { r, _ in
            switch r.url?.absoluteString {
            case OpenCodeAPI.deviceCodeURL?: return self.deviceCode(interval: 1)
            case OpenCodeAPI.tokenURL?: return .init(status: 200, body: ["access_token": "t", "refresh_token": "r", "org_id": "o"])
            default: return .init(status: 200, body: ["email": "x@example.com"], delay: 1)
            }
        }
        let (f, service) = flow("cancel-add")
        f.start(.opencode)
        await waitFor(4) { StubProtocol.count(OpenCodeAPI.userURL) == 1 }
        f.cancel()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(service.accounts.isEmpty)
        #expect(f.step == .idle)
    }
}

/// Classes: data lifecycle on removal (claim ids, the hourly mark); a reading kept vs replaced when
/// a secondary read fails; a server string in a URL path; readings saved by every refresh.
@MainActor
extension AIServiceRaceTests {
    static let org = "3f2a1c4e-5b6d-4e7f-8a9b-0c1d2e3f4a5b"
    var grant: AIResetGrant { AIResetGrant(id: "g1", expiresAt: nil, usableNow: true, detail: "") }

    @Test func removingAnAccountForgetsItsClaimIDs() async {
        StubProtocol.handler = { _, _ in .init(status: 500) }
        let store = MemoryTokenStore()
        let (s, base) = make("claim-ids", store: store)
        var a = base; a.extras["org_uuid"] = Self.org; s.update(a)
        store.tokens[a.id] = fresh
        _ = await s.claim(a, grant)  // not confirmed: the id is kept for the retry
        #expect(s.claimIDs.keys.contains("\(a.id)/g1"))
        s.remove(a.id)
        #expect(s.claimIDs.isEmpty)
    }

    @Test func aClaimForAnAccountRemovedMidwayReadsNothingAfterIt() async {
        StubProtocol.handler = { r, _ in
            r.httpMethod == "POST" ? .init(status: 200, body: ["result": "reset"], delay: 0.3) : .init(status: 200)
        }
        let (s, base) = make("claim-removed", signIn: .borrowed)
        var a = base; a.extras["org_uuid"] = Self.org; s.update(a)
        s.borrowedTokens = { _ in AITokens(access: "cli", refresh: nil, expiresAt: Date().addingTimeInterval(3600)) }
        let t = Task { await s.claim(a, self.grant) }
        await waitFor { StubProtocol.seen.count == 1 }
        s.remove(a.id)
        _ = await t.value
        #expect(StubProtocol.seen.count == 1)  // the claim only: no refresh of a removed account
        #expect(s.readings[a.id] == nil && s.claimIDs.isEmpty)
    }

    @Test func removedDuringTheHourlyReadLeavesNoMark() async {
        StubProtocol.handler = { r, _ in .init(status: 200, delay: r.url?.absoluteString == ClaudeAPI.profileURL ? 0.3 : 0) }
        let store = MemoryTokenStore()
        let (s, a) = make("hourly-removed", store: store)
        store.tokens[a.id] = fresh
        let t = Task { await s.refresh(a, force: true) }
        await waitFor { StubProtocol.count(ClaudeAPI.profileURL) == 1 }
        s.remove(a.id)
        await t.value
        #expect(s.lastHourly[a.id] == nil)
    }

    @Test func aFailedResetsReadKeepsTheLastResets() async {
        let ahead = AIParse.iso.string(from: Date().addingTimeInterval(3 * 86400))
        var round = 1
        StubProtocol.handler = { r, _ in
            switch r.url?.absoluteString {
            case ClaudeAPI.usageURL?: return .init(status: 200, body: ["seven_day": ["utilization": round == 1 ? 50 : 10, "resets_at": ahead]])
            case ClaudeAPI.grantsURL?:
                guard round == 1 else { return .init(status: 503) }
                return .init(status: 200, body: ["cedar_ember": ["eligible": true, "grants": [["id": "g1", "resets_left": 1, "usable_now": true]]]])
            default: return .init(status: 200)
            }
        }
        let store = MemoryTokenStore()
        let (s, a) = make("hourly-kept", store: store)
        store.tokens[a.id] = fresh
        await s.refresh(a, force: true)
        #expect(s.readings[a.id]?.grants.map(\.id) == ["g1"])
        // The weekly limit refilled early (a reset spent elsewhere): the resets are read again, and that read fails.
        round = 2
        await s.refresh(a, force: true)
        #expect(StubProtocol.count("cedar_ember") == 2)
        #expect(s.readings[a.id]?.grants.map(\.id) == ["g1"])
        #expect(s.readings[a.id]?.metrics.contains { $0.key == "resets" } == true)
    }

    @Test func anOrganizationThatIsNotAUUIDIsNeitherKeptNorSent() async {
        StubProtocol.handler = { r, _ in
            r.url?.absoluteString == ClaudeAPI.profileURL ? .init(status: 200, body: ["organization": ["uuid": "../../v1/messages"]]) : .init(status: 200)
        }
        let store = MemoryTokenStore()
        let (s, a) = make("org-path", store: store)
        store.tokens[a.id] = fresh
        await s.refresh(a, force: true)
        #expect(s.accounts.first?.extras["org_uuid"] == nil)
        var saved = a; saved.extras["org_uuid"] = "../../v1/messages"  // saved by an older version
        s.update(saved)
        let asked = StubProtocol.seen.count
        #expect(await s.claim(saved, grant) == .failed("Organization unknown yet; try after the next refresh"))
        #expect(StubProtocol.seen.count == asked)
    }

    @Test func aSingleRefreshIsSavedForTheExport() async {
        StubProtocol.handler = { _, _ in .init(status: 200, body: ["five_hour": ["utilization": 40]]) }
        let d = scratchDefaults("refresh-saved")
        let store = MemoryTokenStore()
        let s = AIUsageService(defaults: d, tokens: store, session: StubProtocol.session())
        let a = AIAccount(id: "acct-saved", provider: .claude, label: "Old", signIn: .oauth)
        s.setPreview(accounts: [a], readings: [:])
        d.set(try? JSONEncoder().encode([a]), forKey: "aiAccounts")
        store.tokens[a.id] = fresh
        await s.refresh(a, force: true)  // a Settings or panel Refresh, or a claim's: not the timer's pass
        #expect(AIUsageExport.run(defaults: d).status == 0)
    }
}
