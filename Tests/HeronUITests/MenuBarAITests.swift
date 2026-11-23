import AppKit
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

// The AI usage menu bar item: hidden without accounts, "most urgent" order, count and "+N",
// chosen limits in order with stale ids skipped, left/used, orange/red only with Red warnings,
// providers as logo or name, initials for several accounts, and a width that never jitters.

@MainActor
@Suite struct MenuBarAITests {
    /// A percent limit with `left`% remaining, resetting in three days, no pace (never burning fast).
    func limit(_ key: String, _ title: String, left: Double) -> AIMetric {
        AIMetric(
            key: key, title: title,
            value: .limit(
                used: 100 - left, limit: 100, unit: .percent,
                resetsAt: Date().addingTimeInterval(3 * 86400), period: nil))
    }

    func service(_ accounts: [(AIAccount, [AIMetric])]) -> AIUsageService {
        let s = AIUsageService(defaults: scratchDefaults("ai-menubar-service"), tokens: MemoryTokenStore())
        s.setPreview(accounts: accounts.map(\.0), readings: Dictionary(uniqueKeysWithValues: accounts.map { ($0.0.id, AIReading(metrics: $0.1)) }))
        return s
    }

    let claude = AIAccount(id: "c", provider: .claude, label: "Personal", signIn: .borrowed)
    let codex = AIAccount(id: "x", provider: .codex, label: "Work", signIn: .borrowed)
    let opencode = AIAccount(id: "o", provider: .opencode, label: "Go", signIn: .borrowed)

    /// Claude weekly 21% (warning), ChatGPT 5 hours 8% (critical), OpenCode monthly 25% (warning),
    /// ChatGPT weekly 3% (critical), Claude 5 hours 49% (fine).
    func fourRunningOut() -> AIUsageService {
        service([
            (claude, [limit("weekly", "Weekly", left: 21), limit("session", "5 hours", left: 49)]),
            (codex, [limit("session", "5 hours", left: 8), limit("weekly", "Weekly", left: 3)]),
            (opencode, [limit("monthly", "Monthly", left: 25)]),
        ])
    }

    func settings(_ tag: String) -> AppSettings {
        let s = AppSettings(defaults: scratchDefaults(tag))
        s.setShown(.ai, true)
        return s
    }

    func label(_ s: AppSettings, _ ai: AIUsageService?, dark: Bool = false) -> MenuBarLabel {
        MenuBarLabel(snapshot: Snapshot(), history: MetricHistory(), settings: s, ink: dark ? .white : .black, dark: dark, ai: ai)
    }

    func width(_ s: AppSettings, _ ai: AIUsageService?) -> CGFloat {
        MenuBarRenderer.image(for: label(s, ai), scale: 2).size.width
    }

    // MARK: No placeholders

    @Test func offByDefaultAndHiddenWithoutAnAccountWithAReading() {
        #expect(!AppSettings(defaults: scratchDefaults("ai-default")).isShown(.ai))
        #expect(MenuItemKind.ai.title == "AI usage")
        let s = settings("ai-none")
        let empty = service([])
        let unread = AIUsageService(defaults: scratchDefaults("ai-unread"), tokens: MemoryTokenStore())
        unread.setPreview(accounts: [claude], readings: [:])
        for ai in [nil, empty, unread] {
            #expect(!MenuBarLabel.hasSource(.ai, in: Snapshot(), ai: ai))
            #expect(label(s, ai).segments.isEmpty)
            #expect(label(s, ai).spokenValue == "Heron")
        }
        // The icon alone, as wide as with the item off.
        let off = AppSettings(defaults: scratchDefaults("ai-off"))
        #expect(width(s, empty) == width(off, empty))
        #expect(MenuBarLabel.hasSource(.ai, in: Snapshot(), ai: fourRunningOut()))
    }

    // MARK: Most urgent

    @Test func mostUrgentShowsTheClosestToRunningOutFirstUpToHowManyWithTheRestAsPlusN() {
        let s = settings("ai-urgent")
        let ai = fourRunningOut()
        s.aiUsage.menuCount = 2
        let item = AIMenuBarItem(service: ai, settings: s)
        #expect(item.entries.map(\.id) == ["x/weekly", "x/session"])
        #expect(item.overflow == 2)
        #expect(label(s, ai).spokenValue == "ChatGPT Weekly 3% left, ChatGPT 5 hours 8% left, 2 more")

        s.aiUsage.menuCount = 5  // only four are running out; the fine one never counts
        let all = AIMenuBarItem(service: ai, settings: s)
        #expect(all.entries.map(\.id) == ["x/weekly", "x/session", "c/weekly", "o/monthly"])
        #expect(all.overflow == 0)

        s.aiUsage.menuCount = 0  // "Icon only": nothing but the Heron icon, no "+N"
        let none = AIMenuBarItem(service: ai, settings: s)
        #expect(none.entries.isEmpty && none.overflow == 0)
        #expect(label(s, ai).segments.isEmpty)
    }

    @Test func alwaysShowListsTheFineLimitsAfterThoseRunningOut() {
        let s = settings("ai-always")
        let ai = fourRunningOut()
        s.aiUsage.menuCount = 5
        #expect(AIMenuBarItem(service: ai, settings: s).entries.count == 4)
        s.aiUsage.alwaysShow = true
        // Pinned first: pin Claude 5 hours (49% left, not running out).
        var pinned = claude; pinned.pinned = ["session"]
        ai.update(pinned)
        let item = AIMenuBarItem(service: ai, settings: s)
        #expect(item.entries.first?.id == "c/session")
        #expect(item.entries.count == 5)
    }

    @Test func nothingRunningOutDrawsNothingAndTheIconStays() {
        let s = settings("ai-calm")
        s.showIcon = false
        let ai = service([(claude, [limit("weekly", "Weekly", left: 80)])])
        #expect(MenuBarLabel.hasSource(.ai, in: Snapshot(), ai: ai))
        let l = label(s, ai)
        #expect(l.segments.isEmpty && l.showsIcon)  // never an empty item
    }

    // MARK: Chosen

    @Test func chosenShowsExactlyThoseLimitsInTheirOrderAndSkipsStaleOnes() {
        let s = settings("ai-chosen")
        let ai = fourRunningOut()
        s.aiUsage.menuMode = .chosen
        s.aiUsage.menuCount = 1  // How many is for Most urgent only
        s.aiUsage.menuChosen = ["x/session", "gone/weekly", "c/session", "c/nometric"]  // not account order
        let item = AIMenuBarItem(service: ai, settings: s)
        #expect(item.entries.map(\.id) == ["x/session", "c/session"])
        #expect(item.overflow == 0)
        // The list in Settings: chosen first in order, then the rest in account order.
        #expect(
            AIMenuBarOptions.listOrder(ai.lines, chosen: s.aiUsage.menuChosen).map(\.id)
                == ["x/session", "c/session", "c/weekly", "x/weekly", "o/monthly"])
        s.aiUsage.menuChosen = []
        #expect(label(s, ai).segments.isEmpty)
    }

    // MARK: Text and colour

    @Test func valuesFollowShowUsageAs() {
        let line = AILimitLine(account: claude, metric: limit("weekly", "Weekly", left: 49))
        #expect(AIMenuBarItem.valueText(line, .left) == "49% left")
        #expect(AIMenuBarItem.valueText(line, .used) == "51% used")
        let s = settings("ai-used")
        s.aiUsage.display = .used
        s.aiUsage.menuCount = 1
        #expect(label(s, fourRunningOut()).spokenValue == "ChatGPT Weekly 97% used, 3 more")
    }

    @Test func orangeAtWarningRedAtCriticalOnlyWithRedWarnings() {
        let s = settings("ai-tone")
        let ai = fourRunningOut()
        s.aiUsage.menuCount = 5
        let tones = Dictionary(uniqueKeysWithValues: AIMenuBarItem(service: ai, settings: s).entries.map { ($0.id, $0.tone) })
        #expect(tones == ["x/weekly": .warning, "x/session": .warning, "c/weekly": .caution, "o/monthly": .caution])
        #expect(label(s, ai).isWarning && label(s, ai).isColoured)
        #expect(!MenuBarRenderer.image(for: label(s, ai)).isTemplate)
        // Only orange: coloured (not a template), not a warning.
        s.aiUsage.menuMode = .chosen; s.aiUsage.menuChosen = ["c/weekly"]
        #expect(!label(s, ai).isWarning && label(s, ai).isColoured)
        // Red warnings off: plain ink, a template image macOS tints.
        s.aiUsage.menuMode = .mostUrgent
        s.warnRed = false
        #expect(AIMenuBarItem(service: ai, settings: s).entries.allSatisfy { $0.tone == .plain })
        #expect(!label(s, ai).isColoured && MenuBarRenderer.image(for: label(s, ai)).isTemplate)
    }

    @Test func burningFastIsRed() {
        let now = Date()
        // 40% used with 10% of a 5-hour window gone: runs out long before the reset.
        let metric = AIMetric(
            key: "session", title: "5 hours",
            value: .limit(
                used: 40, limit: 100, unit: .percent,
                resetsAt: now.addingTimeInterval(AIPeriod.session * 0.9), period: AIPeriod.session))
        let line = AILimitLine(account: claude, metric: metric)
        #expect(line.severity(AIThresholds.standard) == .normal && line.isBurningFast(now: now))
        #expect(AIMenuBarItem.tone(line, AIUsageSettings(), warnRed: true, now: now) == .warning)
        #expect(AIMenuBarItem.tone(line, AIUsageSettings(), warnRed: false, now: now) == .plain)
    }

    /// The orange is readable on the light and dark menu bars, like the red (`menuBarColoursMeetAAInBothModes`).
    @Test func cautionMeetsAAOnTheMenuBar() {
        for pair in [Theme.Palette.caution, Theme.Palette.claudeText] {
            let bgs = Theme.Palette.menuBarBackgrounds
            for bg in bgs.light { #expect(Theme.contrast(pair.light, bg) >= 4.5, "light on \(String(bg, radix: 16))") }
            for bg in bgs.dark { #expect(Theme.contrast(pair.dark, bg) >= 4.5, "dark on \(String(bg, radix: 16))") }
        }
    }

    /// Opaque orange pixels (red well above green, green above blue) in a rendered image. A hue
    /// check, not an exact match: the renderer shifts each channel by up to ~20 between colour spaces.
    func orangePixels(_ image: NSImage?) -> Int {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let rep = NSBitmapImageRep(cgImage: cg)
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                if c.redComponent - c.greenComponent > 0.12, c.greenComponent - c.blueComponent > 0.05 { n += 1 }
            }
        }
        return n
    }

    /// Colour set to Metric: Claude's mark, tag and value are its orange (user, 2026-11-23); ChatGPT
    /// keeps the ink, Monochrome keeps the ink, and a running-out tone still wins.
    @Test func claudeIsOrangeWithMetricColour() {
        let s = settings("ai-metric-colour")
        let ai = fourRunningOut()
        s.aiUsage.menuMode = .chosen; s.aiUsage.menuChosen = ["c/session"]  // 49% left: plain tone
        s.colourMode = .monochrome
        #expect(!label(s, ai).isColoured && MenuBarRenderer.image(for: label(s, ai)).isTemplate)
        let item = AIMenuBarItem(service: ai, settings: s)
        #expect(orangePixels(AIMenuBarOptions.image(item, dark: false, metric: false, scale: 2)) == 0)
        s.colourMode = .metric
        #expect(label(s, ai).isColoured && !MenuBarRenderer.image(for: label(s, ai)).isTemplate)
        #expect(orangePixels(AIMenuBarOptions.image(item, dark: false, metric: true, scale: 2)) > 200)
        #expect(orangePixels(AIMenuBarOptions.image(item, dark: true, metric: true, scale: 2)) > 200)
        // The live menu bar item draws the same orange.
        #expect(orangePixels(MenuBarRenderer.image(for: label(s, ai), scale: 2)) > 200)
        s.aiUsage.menuChosen = ["x/session"]; s.warnRed = false  // ChatGPT, plain tone
        #expect(!AIMenuBarItem(service: ai, settings: s).isColoured(metric: true))
    }

    // MARK: Providers and accounts

    @Test func providersAsNameReplacesTheMark() {
        let s = settings("ai-name")
        let ai = fourRunningOut()
        s.aiUsage.menuCount = 1
        let logo = width(s, ai)
        s.aiUsage.providersAs = .name
        let name = width(s, ai)
        // "ChatGPT" in 11 pt bold is far wider than the 13 pt mark.
        #expect(name > logo + 20, "logo \(logo), name \(name)")
        #expect(label(s, ai).spokenValue == "ChatGPT Weekly 3% left, 3 more")
    }

    @Test func severalAccountsOfAProviderGetInitials() {
        let personal = AIAccount(id: "p", provider: .claude, label: "Personal", signIn: .oauth)
        let work = AIAccount(id: "w", provider: .claude, label: "Attention Machine 1", signIn: .oauth)
        let ai = service([
            (personal, [limit("weekly", "Weekly", left: 9)]), (work, [limit("session", "5 hours", left: 12)]),
            (codex, [limit("session", "5 hours", left: 20)]),
        ])
        let s = settings("ai-initials")
        let item = AIMenuBarItem(service: ai, settings: s)
        #expect(item.entries.map(\.initials) == ["P", "A1", nil])
        #expect(ai.initials(AIAccount(provider: .claude, label: "jane@example.com", signIn: .oauth)) == "JE")
    }

    // MARK: Width

    /// Class: a value that gains digits must not resize the status item. Every option, left and used,
    /// from 0% to 100%, mark or name, with and without the limit's name.
    @Test func theItemKeepsItsWidthAsValuesChange() {
        for display in AIUsageSettings.Display.allCases {
            for providers in AIUsageSettings.ProvidersAs.allCases {
                for named in [true, false] {
                    let s = settings("ai-width")
                    s.warnRed = false
                    s.aiUsage.menuMode = .chosen
                    s.aiUsage.menuChosen = ["c/weekly", "x/session"]
                    s.aiUsage.display = display; s.aiUsage.providersAs = providers; s.aiUsage.showLimitName = named
                    var widths: [CGFloat] = []
                    for (a, b) in [(0.0, 100.0), (8, 9), (100, 0), (49, 51)] {
                        widths.append(width(s, service([(claude, [limit("weekly", "Weekly", left: a)]), (codex, [limit("session", "5 hours", left: b)])])))
                    }
                    #expect(Set(widths).count == 1, "\(display) \(providers) named \(named): \(widths)")
                }
            }
        }
        // "+N" keeps room for one digit: +1 and +9 are as wide.
        let s = settings("ai-plus")
        s.aiUsage.menuCount = 1
        let metrics = (0..<10).map { limit("m\($0)", "M\($0)", left: Double($0 + 1)) }  // all critical, none used up
        let two = width(s, service([(claude, Array(metrics.prefix(2)))]))
        let ten = width(s, service([(claude, metrics)]))
        #expect(two == ten, "+1 \(two), +9 \(ten)")
    }

    /// Class: the value sits right after its mark ("◆ 8% left", not "◆    8% left"), with the shortest value.
    @Test func theValueSitsNextToItsMark() {
        for named in [true, false] {
            for providers in AIUsageSettings.ProvidersAs.allCases {
                let s = settings("ai-tight")
                s.aiUsage.menuMode = .chosen
                s.aiUsage.menuChosen = ["c/weekly"]
                s.aiUsage.showLimitName = named; s.aiUsage.providersAs = providers
                let ai = service([(claude, [limit("weekly", "Weekly", left: 1)])])
                let segment = MenuBarSegment(kind: .ai, style: .text, snapshot: Snapshot(), history: MetricHistory(), settings: s, ai: ai)
                let gap = MenuBarTightnessTests().widestInnerGap(segment)
                #expect(gap <= 9.5, "named \(named) \(providers): \(gap) pt gap")
            }
        }
    }
}
