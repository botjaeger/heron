import Foundation
import Observation

/// Signs a new AI account in. Claude and ChatGPT: browser OAuth with PKCE, the redirect caught on
/// localhost or a pasted code. OpenCode: a device code shown in Heron, approved in the browser.
@MainActor @Observable
public final class AISignInFlow {
    public enum Step: Equatable {
        case idle
        /// The browser is open on `url`; a pasted code also finishes it.
        case browser(AIProvider, URL)
        case device(AIDeviceCode)
        case failed(String)
        case done(String)
    }
    public private(set) var step: Step = .idle

    @ObservationIgnored private let service: AIUsageService
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private var pasted: ResumeOnce?
    @ObservationIgnored private var state = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession

    public init(service: AIUsageService, openURL: @escaping (URL) -> Void, session: URLSession = .shared) {
        self.service = service; self.openURL = openURL; self.session = session
    }

    public func start(_ provider: AIProvider) {
        cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (account, tokens) = try await self.signIn(provider)
                // Cancelled (or restarted) while the last reply was on its way: add nothing.
                try Task.checkCancellation()
                self.service.add(account, tokens: tokens)
                self.step = .done(account.label)
            } catch {
                // A cancelled flow leaves `step` to whoever cancelled it (cancel() or the new flow);
                // its URLError.cancelled is the cancellation, not a failure.
                guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                self.step = .failed(Self.describe(error))
            }
        }
    }

    /// Adds Claude Code's or Codex's saved sign-in as a read-only account.
    public func borrow(_ provider: AIProvider) {
        switch provider {
        case .claude:
            guard BorrowedSignIn.claude() != nil else { step = .failed("Claude Code is not signed in on this Mac."); return }
            service.add(AIAccount(provider: .claude, label: "Claude Code", signIn: .borrowed, extras: ["identity": "borrowed:claude"]), tokens: nil)
            step = .done("Claude Code")
        case .codex:
            guard let (_, account) = BorrowedSignIn.codex() else { step = .failed("Codex is not signed in on this Mac."); return }
            service.add(AIAccount(provider: .codex, label: "Codex", signIn: .borrowed, extras: ["identity": "borrowed:codex", "chatgpt_account_id": account ?? ""]), tokens: nil)
            step = .done("Codex")
        case .opencode:
            // The OpenCode CLI's saved key is a Zen key; the Go usage endpoint refuses it (401,
            // heron-probe 2026-11-22), so OpenCode only signs in with a device code.
            step = .failed("OpenCode signs in with a device code.")
        }
    }

    public func submitPasted(_ text: String) {
        do { let code = try AIAuth.code(fromPasted: text, expectedState: state); pasted?.resume(.success(code)); pasted = nil } catch {
            step = .failed("That code does not belong to this sign-in. Start again.")
        }
    }

    public func cancel() {
        task?.cancel(); task = nil
        pasted?.resume(.failure(CancellationError())); pasted = nil
        step = .idle
    }

    static func describe(_ e: Error) -> String {
        switch e as? AIAuthError {
        case .portInUse?: return "Port 1455 is busy (Codex may be signing in). Close it and try again."
        case .denied(let s)?: return "Sign-in was refused (\(s))."
        case .timedOut?: return "The sign-in timed out."
        case .invalidState?: return "That code does not belong to this sign-in."
        case .http(429, let s)?: return "The provider is limiting sign-ins right now\(s.isEmpty ? "" : " (\(s))"). Wait a minute, then try again."
        case .http(let c, let s)?: return "The server answered \(c)\(s.isEmpty ? "" : ": \(s)")."
        case .invalidResponse?: return "The provider's answer was missing the sign-in. Try again."
        default:
            // Never hide the reason: a network error says what failed ("The request timed out.").
            let ns = e as NSError
            return "Sign-in failed: \(ns.localizedDescription)" + (ns.domain == NSURLErrorDomain ? " (\(ns.code))" : "")
        }
    }

    // MARK: Flows

    private func signIn(_ p: AIProvider) async throws -> (AIAccount, AITokens) {
        switch p {
        case .claude: return try await claude()
        case .codex: return try await codex()
        case .opencode: return try await opencode()
        }
    }

    /// Waits for the redirect or a pasted code, whichever comes first.
    private func browserCode(_ server: AILoopbackServer, url: URL, provider: AIProvider) async throws -> String {
        try Task.checkCancellation()
        step = .browser(provider, url)
        openURL(url)
        // One continuation, resumed once by whichever comes first: the redirect, a pasted code
        // (`submitPasted`), the 15-minute timeout, or `cancel()`. (A task group here waited for
        // its never-resumed paste child after the redirect won.)
        var timeout: Task<Void, Never>?
        // The timeout task ends with the flow, not 15 minutes later.
        defer { server.stop(); pasted = nil; timeout?.cancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            let once = ResumeOnce(c)
            pasted = once
            Task { do { once.resume(.success(try await server.code())) } catch { once.resume(.failure(error)) } }
            timeout = Task { do { try await Task.sleep(nanoseconds: 900_000_000_000); once.resume(.failure(AIAuthError.timedOut)) } catch {} }
        }
    }

    private func claude() async throws -> (AIAccount, AITokens) {
        state = UUID().uuidString
        let pkce = PKCE()
        let server = try AILoopbackServer(state: state)
        try await server.start()
        let url = AIAuth.authorizeURL(
            ClaudeAPI.authorizeURL, clientID: ClaudeAPI.clientID, redirect: server.redirectURI, scope: ClaudeAPI.scopes,
            pkce: pkce, state: state, extra: [URLQueryItem(name: "code", value: "true")])
        let code = try await browserCode(server, url: url, provider: .claude)
        let (s, body) = try await AIAuth.postJSON(
            ClaudeAPI.tokenURL,
            [
                "grant_type": "authorization_code", "client_id": ClaudeAPI.clientID, "code": code,
                "state": state, "redirect_uri": server.redirectURI, "code_verifier": pkce.verifier,
            ], session: session)
        guard (200..<300).contains(s), let t = AIAuth.tokens(from: body) else { throw AIAuthError.http(s, AIAuth.errorMessage(body)) }
        var r = ClaudeAPI.request(ClaudeAPI.profileURL, token: t.access, claudeCode: false); r.timeoutInterval = 10
        // The profile names the account; a failed read must not fail a sign-in that worked (the hourly read fills the plan in).
        let data = (try? await session.data(for: r))?.0 ?? Data()
        let profile = AIParse.json(data) ?? [:]
        let acct = profile["account"] as? [String: Any], org = profile["organization"] as? [String: Any]
        let email = (acct?["email"] as? String) ?? (profile["email"] as? String) ?? "Claude Account"
        let identity = "\(acct?["uuid"] as? String ?? email)/\(org?["uuid"] as? String ?? "")"
        return (AIAccount(provider: .claude, label: email, signIn: .oauth, extras: ["identity": identity, "org_uuid": ClaudeAPI.orgUUID(org?["uuid"]) ?? ""]), t)
    }

    private func codex() async throws -> (AIAccount, AITokens) {
        state = UUID().uuidString
        let pkce = PKCE()
        let server = try AILoopbackServer(port: CodexAPI.callbackPort, path: CodexAPI.callbackPath, state: state)
        try await server.start()
        let url = AIAuth.authorizeURL(
            CodexAPI.authorizeURL, clientID: CodexAPI.clientID, redirect: server.redirectURI, scope: CodexAPI.scopes,
            pkce: pkce, state: state, extra: CodexAPI.authorizeExtras)
        let code = try await browserCode(server, url: url, provider: .codex)
        let (s, body) = try await AIAuth.postForm(
            CodexAPI.tokenURL,
            [
                ("grant_type", "authorization_code"), ("client_id", CodexAPI.clientID), ("code", code),
                ("code_verifier", pkce.verifier), ("redirect_uri", server.redirectURI),
            ], session: session)
        guard (200..<300).contains(s), let t = AIAuth.tokens(from: body, jwtExpiry: true) else { throw AIAuthError.http(s, AIAuth.errorMessage(body)) }
        let account = CodexAPI.accountID(accessToken: t.access) ?? ""
        let email = (body["id_token"] as? String).flatMap { AIAuth.jwtClaims($0)?["email"] as? String } ?? "ChatGPT Account"
        return (AIAccount(provider: .codex, label: email, signIn: .oauth, extras: ["identity": "\(account)/\(email)", "chatgpt_account_id": account]), t)
    }

    /// The pause between device-code polls the server asked for, kept within 1 s and a minute.
    nonisolated static func pollPause(_ requested: Double) -> Double { min(60, max(1, requested)) }

    private func opencode() async throws -> (AIAccount, AITokens) {
        let (s, body) = try await AIAuth.postForm(OpenCodeAPI.deviceCodeURL, [("client_id", OpenCodeAPI.clientID), ("supports_org_scope", "true")], session: session)
        guard (200..<300).contains(s), let dc = OpenCodeAPI.deviceCode(body) else { throw AIAuthError.http(s, AIAuth.errorMessage(body)) }
        try Task.checkCancellation()
        step = .device(dc)
        openURL(dc.verificationURL)
        // At least a second between polls (an `interval` of 0 polled without a pause), at most a
        // minute, and an hour in all: a server's 1e15 overflowed the sleep's nanoseconds (a trap).
        var interval = Self.pollPause(dc.interval)
        let deadline = Date().addingTimeInterval(min(3600, dc.expiresIn))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard
                let (ps, pb) = try? await AIAuth.postForm(
                    OpenCodeAPI.tokenURL,
                    [
                        ("client_id", OpenCodeAPI.clientID), ("device_code", dc.deviceCode),
                        ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                    ], session: session)
            else { continue }
            if let t = AIAuth.tokens(from: pb) {
                guard let org = pb["org_id"] as? String else { throw AIAuthError.invalidResponse }
                var r = OpenCodeAPI.request(OpenCodeAPI.userURL, token: t.access, org: org, orgHeader: "x-org-id"); r.timeoutInterval = 10
                let user = (try? await session.data(for: r)).flatMap { AIParse.json($0.0) } ?? [:]
                let email = user["email"] as? String ?? "OpenCode Account"
                return (AIAccount(provider: .opencode, label: email, signIn: .oauth, extras: ["identity": "opencode:\(user["id"] as? String ?? email):\(org)", "org_id": org]), t)
            }
            switch AIAuth.errorCode(pb) {
            case "authorization_pending"?: continue
            case "slow_down"?: interval = Self.pollPause(interval + 5)
            case "expired_token"?: throw AIAuthError.timedOut
            case "access_denied"?: throw AIAuthError.denied("access_denied")
            default:
                // Any other 4xx is final (invalid_client, invalid_grant…): stop and say what the server said.
                if (400..<500).contains(ps) { throw AIAuthError.http(ps, AIAuth.errorMessage(pb)) }
            }
        }
        throw AIAuthError.timedOut
    }
}

/// Resumes a continuation exactly once, whichever caller comes first; later calls do nothing.
/// `@unchecked Sendable`: `continuation` is only touched under `lock`.
final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<String, Error>) { continuation = c }
    func resume(_ result: Result<String, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
}
