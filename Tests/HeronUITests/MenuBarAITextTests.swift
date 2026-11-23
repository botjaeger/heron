import Foundation
import HeronCore
import Testing

@testable import HeronUI

/// The menu bar draws the number alone ("35%"), never "35% left"; the spoken value keeps the word.
@Suite struct MenuBarAITextTests {
    let line = AILimitLine(
        account: AIAccount(provider: .claude, label: "a", signIn: .oauth),
        metric: AIMetric(key: "weekly", title: "Weekly", value: .limit(used: 65, limit: 100, unit: .percent, resetsAt: nil, period: AIPeriod.week)))

    @Test func theMenuBarShowsTheNumberAlone() {
        #expect(AIMenuBarItem.menuText(line, .left) == Format.percent(0.35))
        #expect(AIMenuBarItem.menuText(line, .used) == Format.percent(0.65))
        #expect(!AIMenuBarItem.menuText(line, .left).contains("left") && !AIMenuBarItem.menuText(line, .used).contains("used"))
        #expect(AIMenuBarItem.widest == "100%")
    }

    @Test func theSpokenValueKeepsTheWord() {
        #expect(AIMenuBarItem.valueText(line, .left).hasSuffix("left"))
    }
}
