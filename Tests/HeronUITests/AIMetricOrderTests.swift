import Foundation
import HeronCore
import Testing

@testable import HeronUI

@MainActor @Suite struct AIMetricOrderTests {
    func metric(_ key: String) -> AIMetric { AIMetric(key: key, title: key, value: .limit(used: 10, limit: 100, unit: .percent, resetsAt: nil, period: nil)) }

    @Test func theUsersOrderComesFirstAndNewKeysFollowInProviderOrder() {
        let a = AIAccount(provider: .claude, label: "a", signIn: .oauth, order: ["fable", "weekly"])
        #expect(a.ordered(["session", "weekly", "sonnet", "fable"].map(metric)).map(\.key) == ["fable", "weekly", "session", "sonnet"])
        #expect(AIAccount(provider: .claude, label: "a", signIn: .oauth).ordered(["b", "a"].map(metric)).map(\.key) == ["b", "a"])
    }

    @Test func draggingALimitReordersItEverywhere() {
        let ai = AIUsageService(defaults: scratchDefaults("ai-order"), tokens: MemoryTokenStore())
        let a = AIAccount(id: "acc", provider: .claude, label: "a", signIn: .oauth)
        ai.setPreview(accounts: [a], readings: ["acc": AIReading(metrics: ["session", "weekly", "sonnet"].map(metric))])
        ai.moveMetric("acc", "sonnet", before: "session")
        #expect(ai.readings["acc"]?.metrics.map(\.key) == ["sonnet", "session", "weekly"])
        #expect(ai.lines.map(\.metric.key) == ["sonnet", "session", "weekly"])
        ai.moveMetric("acc", "sonnet", before: nil)
        #expect(ai.accounts[0].order == ["session", "weekly", "sonnet"])
    }

    @Test func accountsSavedBeforeOrderExistedStillLoad() throws {
        let old = #"{"id":"x","provider":"codex","label":"me","signIn":"borrowed","extras":{},"hidden":["today"],"pinned":[]}"#
        let a = try JSONDecoder().decode(AIAccount.self, from: Data(old.utf8))
        #expect(a.order.isEmpty && a.hidden == ["today"] && a.provider == .codex)
    }
}
