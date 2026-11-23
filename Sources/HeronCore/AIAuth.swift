import CryptoKit
import Foundation
import Network

// Sign-in plumbing for AI accounts: PKCE, a loopback callback server, the pasted-code fallback,
// and a device-code poller (OpenUsage's OAuthLoginSupport, LoopbackCallbackServer, DeviceCodePoller).

public enum AIAuthError: Error, Equatable {
    case invalidState, denied(String), timedOut, portInUse, invalidResponse, http(Int, String)
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URL
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !t.count.isMultiple(of: 4) { t += "=" }
        self.init(base64Encoded: t)
    }
}

public enum AIAuth {
    /// A pasted code: a full redirect URL, "code#state", or a bare code (refused: the state must match).
    public static func code(fromPasted text: String, expectedState: String) throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var code: String?, state: String?
        if let u = URLComponents(string: t), u.scheme != nil, u.host != nil {
            code = u.queryItems?.first { $0.name == "code" }?.value
            state = u.queryItems?.first { $0.name == "state" }?.value
        } else if let hash = t.firstIndex(of: "#") {
            code = String(t[..<hash]); state = String(t[t.index(after: hash)...])
        } else {
            code = t
        }
        guard let code, !code.isEmpty, state == expectedState else { throw AIAuthError.invalidState }
        return code
    }

    public static func authorizeURL(_ base: String, clientID: String, redirect: String, scope: String, pkce: PKCE, state: String, extra: [URLQueryItem]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems =
            [
                URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "code_challenge", value: pkce.challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
            ] + extra
        return c.url!
    }

    /// A JWT's payload as JSON (no signature check: Heron only reads its own token's claims).
    public static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URL: String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: HTTP

    public static func postJSON(_ url: String, _ fields: [String: Any], session: URLSession = .shared) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return try await send(r, session: session)
    }

    public static func postForm(_ url: String, _ fields: [(String, String)], session: URLSession = .shared) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        var c = URLComponents(); c.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        r.httpBody = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return try await send(r, session: session)
    }

    static func send(_ r: URLRequest, session: URLSession) async throws -> (Int, [String: Any]) {
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    /// The `error` of an OAuth reply (a string, `error.code`, or a top-level `code`).
    public static func errorCode(_ body: [String: Any]) -> String? {
        if let e = body["error"] as? String { return e }
        if let e = (body["error"] as? [String: Any])?["code"] as? String { return e }
        return body["code"] as? String
    }

    /// What an error reply says, for the person: `error.message` (Anthropic), `error_description`
    /// (OAuth), else the error code or type.
    public static func errorMessage(_ body: [String: Any]) -> String {
        let e = body["error"] as? [String: Any]
        return (e?["message"] as? String) ?? (body["error_description"] as? String) ?? errorCode(body) ?? (e?["type"] as? String) ?? ""
    }

    /// A renewal refused for good (the sign-in expired) rather than a passing failure.
    public static func isExpiredRenewal(status: Int, body: [String: Any]) -> Bool {
        guard [400, 401, 403].contains(status), let e = errorCode(body) else { return false }
        return ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(e)
    }

    public static func tokens(from body: [String: Any], now: Date = Date(), jwtExpiry: Bool = false) -> AITokens? {
        guard let access = body["access_token"] as? String, !access.isEmpty else { return nil }
        var expires = (AIParse.number(body["expires_in"])).map { now.addingTimeInterval($0) }
        if jwtExpiry, let exp = AIParse.number(jwtClaims(access)?["exp"]) { expires = Date(timeIntervalSince1970: exp) }
        return AITokens(access: access, refresh: body["refresh_token"] as? String, expiresAt: expires)
    }
}

/// Receives the browser's redirect on 127.0.0.1 (OpenUsage's LoopbackCallbackServer).
/// `@unchecked Sendable`: its mutable state is read and written under `lock` or on `queue`.
public final class AILoopbackServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public let path: String
    private let listener: NWListener
    private let expectedState: String
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.heron.ai.loopback")
    private var pending: Result<String, Error>?
    private var started = false

    public var redirectURI: String { "http://localhost:\(port)\(path)" }

    /// `port` 0 picks a free one; ChatGPT needs 1455.
    public init(port: UInt16 = 0, path: String = "/callback", state: String) throws {
        self.path = path; expectedState = state
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = true
        do { listener = try NWListener(using: params) } catch { throw AIAuthError.portInUse }
    }

    /// Starts listening; returns once the port is known.
    /// Every state that ends the wait resumes it: ready, failed, waiting (the port cannot be had
    /// now), cancelled (`stop()`), and the caller's task being cancelled.
    public func start() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                // Every handler runs on `queue` (serial), so `started`, `ready` and `early` need no lock.
                queue.async { self.wait(c) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = self.listener.port?.rawValue ?? 0; self.settle(.success(()))
                    case .failed: self.settle(.failure(AIAuthError.portInUse))
                    case .waiting: self.settle(.failure(AIAuthError.portInUse)); self.listener.cancel()
                    case .cancelled: self.settle(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
                listener.start(queue: queue)
            }
        } onCancel: {
            queue.async { self.settle(.failure(CancellationError())) }
            listener.cancel()
        }
    }

    private var ready: CheckedContinuation<Void, Error>?
    private var early: Result<Void, Error>?

    /// On `queue`: the start continuation, resumed at once if the outcome came first.
    private func wait(_ c: CheckedContinuation<Void, Error>) {
        if let early { started = true; self.early = nil; c.resume(with: early) } else { ready = c }
    }

    /// On `queue`: ends the start wait once; later outcomes do nothing.
    private func settle(_ result: Result<Void, Error>) {
        guard !started else { return }
        if let c = ready { started = true; ready = nil; c.resume(with: result) } else if early == nil { early = result }
    }

    /// Waits for the redirect's code.
    public func code() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            // A redirect that came before anyone waited is kept, not lost.
            if let early = pending { pending = nil; lock.unlock(); c.resume(with: early); return }
            continuation = c
            lock.unlock()
        }
    }

    public func stop() {
        // A listener cancelled before it started reports no state: end a waiting start() here.
        queue.async { self.settle(.failure(CancellationError())) }
        listener.cancel()
        finish(.failure(AIAuthError.timedOut))
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let c = continuation; continuation = nil
        if c == nil, pending == nil { pending = result }
        lock.unlock()
        c?.resume(with: result)
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global())
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            var status = "400 Bad Request", body = "Heron could not read this sign-in."
            if parts.count >= 2, parts[0] == "GET", let u = URLComponents(string: "http://localhost" + parts[1]), u.path == self.path {
                let q = { (n: String) in u.queryItems?.first { $0.name == n }?.value }
                // The state first: an `error` for another sign-in (or from any page) is ignored like
                // any callback that does not match, never allowed to end this one.
                if q("state") != self.expectedState {
                    body = "This sign-in does not match. Start it again from Heron."
                } else if let e = q("error") {
                    self.finish(.failure(AIAuthError.denied(e))); body = "Sign-in was cancelled."; status = "200 OK"
                } else if let code = q("code") {
                    self.finish(.success(code)); status = "200 OK"; body = "Sign-in complete. You may close this page."
                }
            }
            let html = "<!doctype html><meta charset=utf-8><title>Heron</title><body style=\"font:15px -apple-system;padding:40px\">\(body)</body>"
            let reply = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

/// The user code and address shown while a device-code sign-in waits.
public struct AIDeviceCode: Equatable, Sendable {
    public var userCode: String
    public var verificationURL: URL
    public var deviceCode: String
    public var interval: Double
    public var expiresIn: Double
}
