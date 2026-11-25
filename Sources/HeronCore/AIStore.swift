import Foundation
import Security

// Where AI account sign-ins live: Heron's own Keychain items (one per account, service
// "app.heron.ai.accounts"), or, for a borrowed sign-in, the CLI's own store read each time.

public protocol AITokenStore: AnyObject {
    func load(_ accountID: String) -> AITokens?
    /// False when the write did not land (a locked or refusing Keychain).
    @discardableResult func save(_ tokens: AITokens, for accountID: String) -> Bool
    func delete(_ accountID: String)
}

public final class KeychainTokenStore: AITokenStore {
    public static let service = "app.heron.ai.accounts"
    public init() {}
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: id]
    }
    public func load(_ id: String) -> AITokens? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AITokens.self, from: data)
    }
    @discardableResult public func save(_ tokens: AITokens, for id: String) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
    public func delete(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

/// For tests and heron-snap: nothing touches the Keychain.
public final class MemoryTokenStore: AITokenStore {
    public var tokens: [String: AITokens] = [:]
    public init() {}
    public func load(_ id: String) -> AITokens? { tokens[id] }
    @discardableResult public func save(_ t: AITokens, for id: String) -> Bool { tokens[id] = t; return true }
    public func delete(_ id: String) { tokens[id] = nil }
}

/// Reads the sign-ins Claude Code and the Codex CLI already saved. Never renews or writes them:
/// a renewal would rotate the CLI's refresh token and sign the CLI out.
public enum BorrowedSignIn {
    public static func claude(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AITokens? {
        var data: Data?
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess { data = item as? Data }
        if data == nil { data = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")) }
        guard let data, let json = AIParse.json(data), let o = json["claudeAiOauth"] as? [String: Any],
            let token = o["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return AITokens(access: token, refresh: nil, expiresAt: AIParse.number(o["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    static func codexHome(_ home: URL) -> URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return home.appendingPathComponent(".codex")
    }

    /// The access token and ChatGPT account id from ~/.codex/auth.json.
    public static func codex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (AITokens, String?)? {
        guard let data = try? Data(contentsOf: codexHome(home).appendingPathComponent("auth.json")), let json = AIParse.json(data),
            let t = json["tokens"] as? [String: Any], let token = t["access_token"] as? String, !token.isEmpty
        else { return nil }
        let exp = AIParse.number(AIAuth.jwtClaims(token)?["exp"]).map { Date(timeIntervalSince1970: $0) }
        return (AITokens(access: token, refresh: nil, expiresAt: exp), t["account_id"] as? String ?? CodexAPI.accountID(accessToken: token))
    }

    public static var hasClaudeCode: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }
    public static var hasCodex: Bool {
        FileManager.default.fileExists(atPath: codexHome(FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("auth.json").path)
    }

    /// Codex writes its limits into each session log ("token_count" events): the newest one
    /// answers when the live read cannot (offline, expired token). As fresh as the last Codex use.
    /// Runs off the main actor (the walk and the read are file I/O), reads only the newest log's
    /// last `tailBytes`, and reuses the answer while that file is unchanged.
    public static func codexFromLog(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> AIReading? {
        let root = codexHome(home).appendingPathComponent("sessions")
        return await Task.detached(priority: .utility) { codexFromLog(sessions: root) }.value
    }

    /// How much of the newest session log is read: its last `rate_limits` event is near the end.
    static let tailBytes = 256 * 1024
    private static let logCache = LogCache()

    static func codexFromLog(sessions root: URL) -> AIReading? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if d > (newest?.date ?? .distantPast) { newest = (url, d) }
        }
        guard let newest else { return nil }
        if let hit = logCache.get(newest.url, newest.date) { return hit }
        guard let text = tail(of: newest.url, bytes: tailBytes) else { return nil }
        var reading: AIReading?
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let r = codexLogLine(Data(line.utf8)) { reading = r; break }
        }
        logCache.set(newest.url, newest.date, reading)
        return reading
    }

    /// The file's last `bytes`, starting at a whole line (the cut first line is dropped).
    static func tail(of url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? h.seek(toOffset: start)) != nil, let data = try? h.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }

    /// The last log answer, kept while the newest file's path and modification date stay the same.
    /// `@unchecked Sendable`: `entry` is only touched under `lock`.
    final class LogCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (url: URL, date: Date, reading: AIReading?)?
        func get(_ url: URL, _ date: Date) -> AIReading?? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entry, e.url == url, e.date == date else { return nil }
            return .some(e.reading)
        }
        func set(_ url: URL, _ date: Date, _ reading: AIReading?) { lock.lock(); entry = (url, date, reading); lock.unlock() }
    }

    /// Today and Yesterday, in the user's own days, for a Codex account whose use the CLI's session
    /// logs hold: the borrowed sign-in, or Heron's own sign-in to the CLI's ChatGPT account. No rows
    /// when there is no sessions folder (or the logs are another account's). Off the main actor.
    public static func codexDayRows(for account: AIAccount, home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [AIMetric] {
        guard account.provider == .codex else { return [] }
        return await Task.detached(priority: .utility) { () -> [AIMetric] in
            if account.signIn != .borrowed {
                guard let id = account.extras["chatgpt_account_id"], !id.isEmpty, codex(home: home)?.1 == id else { return [] }
            }
            let now = Date()
            return codexDays(sessions: codexHome(home).appendingPathComponent("sessions"), now: now).map { CodexAPI.dayRows($0, now: now) } ?? []
        }.value
    }

    static let dayCache = DayCache()

    /// Tokens per local day from the Codex session logs: each `token_count` event's
    /// `last_token_usage.total_tokens`, bucketed by the event's own timestamp in `calendar`, keyed
    /// by the day's start. A session keeps writing into the folder of the day it began, however many
    /// days it runs or is resumed (real logs, 2026-11-23: the 21–23 Oct folders held 24 Oct usage),
    /// so every log modified since yesterday began is read, wherever it sits. Each file's sums are
    /// kept while its path, size and modification date stay the same. Nil without a sessions folder.
    static func codexDays(
        sessions root: URL, now: Date = Date(), calendar: Calendar = .current, cache: DayCache = dayCache,
        read: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> [Date: Int]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var files: [URL] = []
        let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        while let url = walk?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                modified >= since
            else { continue }
            files.append(url)
        }
        files.sort { $0.path < $1.path }
        var out: [Date: Int] = [:]
        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = DayCache.Stamp(modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? -1, zone: calendar.timeZone.identifier)
            let sums: [Date: Int]
            if let hit = cache.get(url.path, stamp) {
                sums = hit
            } else {
                sums = read(url).map { codexDaySums($0, calendar: calendar) } ?? [:]
                cache.set(url.path, stamp, sums)
            }
            for (day, n) in sums { out[day] = (out[day] ?? 0).addingSaturated(n) }
        }
        cache.keep(Set(files.map(\.path)))
        return out
    }

    /// One log's tokens per local day. A line that is not a `token_count` event with a usage is
    /// skipped; an event that repeats the running total of the one before it (no new turn) counts once.
    static func codexDaySums(_ data: Data, calendar: Calendar) -> [Date: Int] {
        var out: [Date: Int] = [:]
        var lastTotal: Double?
        let needle = Data("\"token_count\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) where line.contains(needle) {
            guard let json = AIParse.json(Data(line)), let payload = json["payload"] as? [String: Any],
                payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                let last = info["last_token_usage"] as? [String: Any],
                let n = AIParse.int(AIParse.number(last["total_tokens"]), .towardZero), n > 0,
                let at = AIParse.date(json["timestamp"])
            else { continue }
            let total = AIParse.number((info["total_token_usage"] as? [String: Any])?["total_tokens"])
            if let total, total == lastTotal { continue }
            lastTotal = total
            let day = calendar.startOfDay(for: at); out[day] = (out[day] ?? 0).addingSaturated(n)
        }
        return out
    }

    /// Each session log's per-day sums, by path, while its size and modification date (and the
    /// time zone they were bucketed in) stay the same.
    /// `@unchecked Sendable`: `entries` is only touched under `lock`.
    final class DayCache: @unchecked Sendable {
        struct Stamp: Equatable { var modified: Date; var size: Int; var zone: String }
        private let lock = NSLock()
        private var entries: [String: (stamp: Stamp, sums: [Date: Int])] = [:]
        func get(_ path: String, _ stamp: Stamp) -> [Date: Int]? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[path], e.stamp == stamp else { return nil }
            return e.sums
        }
        func set(_ path: String, _ stamp: Stamp, _ sums: [Date: Int]) { lock.lock(); entries[path] = (stamp, sums); lock.unlock() }
        /// Forgets files no longer read (older folders, deleted logs).
        func keep(_ paths: Set<String>) { lock.lock(); entries = entries.filter { paths.contains($0.key) }; lock.unlock() }
    }

    public static func codexLogLine(_ data: Data) -> AIReading? {
        guard let json = AIParse.json(data), let payload = json["payload"] as? [String: Any],
            let rate = payload["rate_limits"] as? [String: Any]
        else { return nil }
        let pairs: [(String, String, String)] = [("primary", "session", "5 hours"), ("secondary", "weekly", "Weekly")]
        let metrics = pairs.compactMap { (k, key, title) -> AIMetric? in
            guard let w = rate[k] as? [String: Any], let used = AIParse.number(w["used_percent"]) else { return nil }
            let seconds = AIParse.number(w["window_minutes"]).map { $0 * 60 }
            let name = seconds == AIPeriod.week ? ("weekly", "Weekly") : seconds == AIPeriod.session ? ("session", "5 hours") : (key, title)
            return AIMetric(
                key: name.0, title: name.1, value: .limit(used: AIParse.clampPercent(used), limit: 100, unit: .percent, resetsAt: AIParse.date(w["resets_at"]), period: seconds))
        }
        guard !metrics.isEmpty else { return nil }
        return AIReading(plan: CodexAPI.plan(rate["plan_type"] as? String), metrics: metrics, fetchedAt: AIParse.date(json["timestamp"]) ?? Date())
    }
}
