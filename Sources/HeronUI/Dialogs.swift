import HeronCore
import SwiftUI

// MARK: - Alert rules: the sentence, the readings, the preview

extension AlertRule {
    /// What "Add rule…" starts from: the CPU too hot for 30 seconds.
    static var newRule: AlertRule {
        let suggested = AlertRule.Subject.cpuTemperature.suggestedRule
        return AlertRule(subject: .cpuTemperature, comparison: suggested.comparison, threshold: suggested.threshold, seconds: 30)
    }
}

/// The rule editor's sentence, "Notify me when [CPU temperature] is [above] [95] °C for [30 s]",
/// in the unit the user reads; memory pressure "reaches [Critical]". Pure, so the round trip
/// from a rule to the sentence and back can be tested.
struct AlertSentence: Equatable {
    enum Level: String, CaseIterable { case critical = "Critical", warning = "Warning" }

    var subject: AlertRule.Subject
    var comparison: AlertRule.Comparison
    /// The limit as typed: temperatures in the user's unit, whole degrees.
    var limit: Double
    var level: Level
    var seconds: Int

    /// The waits the sentence offers; 0 sends as soon as the reading crosses the limit.
    static let durations = [0, 10, 30, 60, 300]
    /// Memory pressure is stored as a level number (1 warning, 2 critical); a rule fires above its threshold.
    static let pressureThreshold: [Level: Double] = [.critical: 1.5, .warning: 0.5]

    init(_ rule: AlertRule, unit: Format.TemperatureUnit) {
        subject = rule.subject
        comparison = rule.comparison
        limit = rule.subject.isTemperature ? Format.converted(rule.threshold, to: unit).rounded() : rule.threshold
        level = rule.threshold >= 1 ? .critical : .warning
        seconds = rule.seconds
    }

    /// `original` with this sentence's subject, limit and wait; its id, sound and switch stay.
    func rule(from original: AlertRule, unit: Format.TemperatureUnit) -> AlertRule {
        var rule = original
        rule.subject = subject
        rule.seconds = seconds
        if subject == .memoryPressure {
            rule.comparison = .above
            rule.threshold = Self.pressureThreshold[level] ?? 1.5
        } else {
            rule.comparison = comparison
            rule.threshold = subject.isTemperature ? Format.celsius(limit, from: unit) : limit
        }
        return rule
    }

    /// Another reading starts from a limit that makes sense for it (90 "GB free" did not).
    mutating func choose(_ new: AlertRule.Subject, unit: Format.TemperatureUnit) {
        guard new != subject else { return }
        let suggested = new.suggestedRule
        self = AlertSentence(AlertRule(subject: new, comparison: suggested.comparison, threshold: suggested.threshold, seconds: seconds), unit: unit)
    }

    /// The unit after the limit field: "°C", "%", "GB".
    func unitText(_ unit: Format.TemperatureUnit) -> String { subject.unit(unit) }

    /// The sentence as one line, as VoiceOver and the tests read it.
    func text(unit: Format.TemperatureUnit) -> String {
        let wait = seconds > 0 ? " for \(AlertRule.duration(seconds))" : ""
        if subject == .memoryPressure { return "Notify me when Memory pressure reaches \(level.rawValue)\(wait)" }
        let number = limit == limit.rounded() ? String(Int(limit)) : String(format: "%.1f", limit)
        let unitText = unitText(unit)
        return "Notify me when \(subject.title) is \(comparison.rawValue) \(number)\(unitText == "%" ? "" : " ")\(unitText)\(wait)"
    }
}

/// How Settings › Alerts and the rule editor word a rule's reading and say whether it would send.
enum AlertPreview {
    /// A reading just past the rule's limit, for the preview's wording.
    static func sample(_ rule: AlertRule) -> Double {
        let margin: Double
        switch rule.subject {
        case .memoryPressure: return rule.threshold >= 1 ? 2 : 1
        case .diskFreeGB: margin = 0.4
        default: margin = rule.subject.isTemperature ? 2 : 1
        }
        return rule.comparison == .above ? rule.threshold + margin : rule.threshold - margin
    }

    /// The reading as the rule list shows it: "79°", "61% · Warning", "351 GB free", "79% · on power
    /// adapter". Nil when this Mac has no such reading.
    static func reading(_ subject: AlertRule.Subject, in s: Snapshot, unit: Format.TemperatureUnit) -> String? {
        guard let value = subject.value(in: s) else { return nil }
        switch subject {
        case .cpuTemperature, .gpuTemperature, .ssdTemperature, .hottestTemperature: return Format.temperature(value, unit: unit)
        case .cpuLoad, .gpuLoad, .memoryUsed, .batteryHealth: return "\(Int(value.rounded()))%"
        case .memoryPressure:
            guard let m = s.memory else { return nil }
            return (m.pressurePercent.map { "\(Format.percent($0)) · " } ?? "") + m.pressure.rawValue.capitalized
        case .diskFreeGB:
            return s.rootVolume.map { "\(Format.diskBytes($0.available)) free" }
        case .batteryPercent:
            guard let b = s.battery else { return nil }
            return Format.percent(b.percent) + (b.onAC ? " · on power adapter" : "")
        }
    }

    /// A value in the threshold's unit, as the editor's status line writes it: "79 °C", "34%", "351 GB".
    static func shown(_ value: Double, _ subject: AlertRule.Subject, unit: Format.TemperatureUnit) -> String {
        switch subject {
        case .cpuTemperature, .gpuTemperature, .ssdTemperature, .hottestTemperature:
            return "\(Int(Format.converted(value, to: unit).rounded())) \(subject.unit(unit))"
        case .diskFreeGB: return value >= 100 || value == value.rounded() ? "\(Int(value.rounded())) GB" : String(format: "%.1f GB", value)
        case .memoryPressure: return value >= 2 ? "Critical" : (value >= 1 ? "Warning" : "Normal")
        default: return "\(Int(value.rounded()))%"
        }
    }

    /// The limit as the list writes it: "95°", "10%", "10 GB".
    static func limit(_ rule: AlertRule, unit: Format.TemperatureUnit) -> String {
        rule.subject.isTemperature ? Format.temperature(rule.threshold, unit: unit) : shown(rule.threshold, rule.subject, unit: unit)
    }

    /// "CPU temperature 79°, below 95°. Would not send." — the Alerts pane's "Right now".
    static func nowLine(_ rule: AlertRule, value: Double?, unit: Format.TemperatureUnit, snapshot: Snapshot) -> String {
        guard let value else { return "This Mac gives no reading for \(rule.subject.title), so the rule never sends." }
        let verdict =
            !rule.matches(value)
            ? "Would not send."
            : rule.seconds > 0 ? "Would send if it stays there for \(AlertRule.duration(rule.seconds))." : "Would send now."
        if rule.subject == .memoryPressure {
            return "Pressure \(reading(.memoryPressure, in: snapshot, unit: unit) ?? shown(value, .memoryPressure, unit: unit)). \(verdict)"
        }
        let now = reading(rule.subject, in: snapshot, unit: unit) ?? (rule.subject.isTemperature ? Format.temperature(value, unit: unit) : shown(value, rule.subject, unit: unit))
        let side = value > rule.threshold ? "above" : (value < rule.threshold ? "below" : "at")
        return "\(rule.subject.title) \(now), \(side) \(limit(rule, unit: unit)). \(verdict)"
    }

    /// The editor's status line: "Now: CPU temperature 79 °C. This rule would not send anything now."
    static func sheetLine(_ rule: AlertRule, value: Double?, unit: Format.TemperatureUnit, snapshot: Snapshot) -> String {
        guard let value else { return "This Mac gives no reading for \(rule.subject.title), so this rule never sends." }
        let verdict = rule.matches(value) ? "This rule would send a notification now." : "This rule would not send anything now."
        if rule.subject == .memoryPressure {
            return "Now: pressure \(reading(.memoryPressure, in: snapshot, unit: unit) ?? shown(value, .memoryPressure, unit: unit)). \(verdict)"
        }
        return "Now: \(rule.subject.title) \(shown(value, rule.subject, unit: unit)). \(verdict)"
    }

    /// The scale under the status line, in the threshold's unit: 0 to 110 °C, 0 to 100%, 0 to the
    /// startup disk's size. Nil for memory pressure (a level, not a number).
    static func scaleMax(_ subject: AlertRule.Subject, snapshot: Snapshot) -> Double? {
        switch subject {
        case .memoryPressure: return nil
        case .cpuTemperature, .gpuTemperature, .ssdTemperature, .hottestTemperature: return 110
        case .diskFreeGB:
            return snapshot.rootVolume.map { max(1, (Double($0.total) / 1_000_000_000).rounded()) } ?? 1000
        default: return 100
        }
    }
}

/// A rule's icon: its reading's glyph in its colour on a 15% tint.
struct AlertRuleTile: View {
    var subject: AlertRule.Subject
    var body: some View {
        let (glyph, color): (HeronIcon, Color) =
            switch subject {
            case .cpuTemperature, .gpuTemperature, .ssdTemperature, .hottestTemperature: (.sensors, Theme.warning)
            case .cpuLoad: (.cpu, Theme.cpu)
            case .gpuLoad: (.gpu, Theme.gpu)
            case .memoryUsed, .memoryPressure: (.memory, Theme.memory)
            case .diskFreeGB: (.disk, .primary)
            case .batteryPercent, .batteryHealth: (.battery, Theme.memory)
            }
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15))
            HeronIconView(glyph, size: 15)
        }
        .foregroundStyle(color)
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

// MARK: - Alert rule editor

/// The rule sheet: the rule as a sentence of pop-up menus, what the reading is now against the
/// limit, the notification it sends, and Delete (saved rules only), Cancel and Save.
public struct AlertRuleEditor: View {
    @State private var rule: AlertRule
    @State private var sentence: AlertSentence
    var unit: Format.TemperatureUnit
    var onSave: (AlertRule) -> Void
    /// nil for a rule that is not saved yet: there is nothing to delete.
    var onDelete: ((AlertRule) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(Monitor.self) private var monitor

    public init(rule: AlertRule, unit: Format.TemperatureUnit = .celsius, onSave: @escaping (AlertRule) -> Void, onDelete: ((AlertRule) -> Void)?) {
        _rule = State(initialValue: rule)
        _sentence = State(initialValue: AlertSentence(rule, unit: unit))
        self.unit = unit
        self.onSave = onSave
        self.onDelete = onDelete
    }

    /// The sheet's size, as in the design.
    public static let size = CGSize(width: 520, height: 420)

    /// The rule as the sentence says it now.
    private var edited: AlertRule { sentence.rule(from: rule, unit: unit) }

    private var subject: Binding<AlertRule.Subject> {
        Binding {
            sentence.subject
        } set: {
            sentence.choose($0, unit: unit)
        }
    }

    public var body: some View {
        let edited = edited
        let value = edited.subject.value(in: monitor.snapshot)
        let sample = AlertPreview.sample(edited)
        VStack(alignment: .leading, spacing: 0) {
            Text(onDelete == nil ? "New rule" : "Edit rule").font(.system(size: 15, weight: .bold))
            sentenceView
                .padding(.top, 14)
            status(edited, value: value)
                .padding(.top, 16)
            SettingsCaption("You will get").padding(.top, 16)
            NotificationBanner(
                title: AlertEngine.title(edited, value: sample, unit: unit),
                message: AlertEngine.body(edited, value: sample, unit: unit, snapshot: monitor.snapshot), width: nil
            )
            .padding(.top, 6)
            HStack {
                Text("Play a sound").font(.system(size: 13, weight: .medium))
                Spacer()
                SettingsSwitch(title: "Play a sound", isOn: $rule.playSound)
            }
            .padding(.top, 10)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if let onDelete {
                    Button {
                        onDelete(edited); dismiss()
                    } label: {
                        Text("Delete rule").foregroundStyle(Theme.warning)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(edited); dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    /// "Notify me when [CPU temperature] is [above] [95] °C for [30 s]", wrapping like a sentence.
    private var sentenceView: some View {
        WrapLayout(spacing: 8, lineSpacing: 8) {
            Text("Notify me when")
            // A menu as wide as the reading picked (a pop-up is as wide as its longest choice,
            // which pushed the rest of the sentence onto a second line).
            Menu {
                Picker("Reading", selection: subject) {
                    ForEach(AlertRule.Subject.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(sentence.subject.title)
            }
            .fixedSize()
            .accessibilityLabel("Reading")
            .accessibilityValue(sentence.subject.title)
            if sentence.subject == .memoryPressure {
                Text("reaches")
                Picker("Pressure level", selection: $sentence.level) {
                    ForEach(AlertSentence.Level.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
            } else {
                Text("is")
                Picker("Above or below", selection: $sentence.comparison) {
                    Text("above").tag(AlertRule.Comparison.above)
                    Text("below").tag(AlertRule.Comparison.below)
                }
                .labelsHidden().fixedSize()
                HStack(spacing: 4) {
                    TextField("Limit", value: $sentence.limit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 64)
                        .accessibilityLabel("Limit in \(sentence.unitText(unit))")
                    Text(sentence.unitText(unit)).foregroundStyle(Theme.muted)
                }
            }
            if sentence.seconds > 0 { Text("for") }
            Picker("How long", selection: $sentence.seconds) {
                ForEach(AlertSentence.durations, id: \.self) { Text($0 == 0 ? "right away" : AlertRule.duration($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        .font(.system(size: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sentence.text(unit: unit))
    }

    /// The dot (red: it would send now), the line, and the scale with the limit and the reading.
    private func status(_ rule: AlertRule, value: Double?) -> some View {
        let fires = value.map(rule.matches) ?? false
        // The scale runs in the stored unit (°C), so 0 sits at the left in °F too.
        let max = AlertPreview.scaleMax(rule.subject, snapshot: monitor.snapshot)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(value == nil ? Theme.muted : (fires ? Theme.warning : Theme.memory)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(AlertPreview.sheetLine(rule, value: value, unit: unit, snapshot: monitor.snapshot))
                    .font(.system(size: 12)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            if let max {
                AlertScale(limit: rule.threshold / max, now: value.map { $0 / max }, above: rule.comparison == .above)
                    .padding(.top, 12).padding(.horizontal, 4)
                HStack {
                    Text(AlertPreview.shown(0, rule.subject, unit: unit))
                    Spacer()
                    Text(AlertPreview.shown(max, rule.subject, unit: unit))
                }
                .font(.system(size: 10)).foregroundStyle(Theme.muted).monospacedDigit()
                .padding(.top, 4)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.settingsPreview, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
    }
}

/// The rule's scale: the side that sends tinted red, the limit as a red tick, the reading now as a dot.
struct AlertScale: View {
    /// Where the limit and the reading sit, 0…1 of the scale.
    var limit: Double
    var now: Double?
    var above: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let l = CGFloat(limit.unitClamped) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.settingsLine).frame(height: 6)
                Capsule().fill(Theme.warning.opacity(0.45)).frame(width: above ? w - l : l, height: 6).offset(x: above ? l : 0)
                RoundedRectangle(cornerRadius: 1).fill(Theme.warning).frame(width: 2, height: 14).offset(x: l - 1)
                if let now {
                    Circle().fill(Color.primary).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Theme.settingsPreview, lineWidth: 2).padding(-2))
                        .offset(x: CGFloat(now.unitClamped) * w - 6)
                }
            }
            .frame(height: 14)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Onboarding

/// The first run's three steps and what their buttons do, as pure rules.
enum OnboardingFlow {
    enum Step: Int, CaseIterable { case welcome, items, alerts }

    /// "Step 2 of 3".
    static func caption(_ step: Step) -> String { "Step \(step.rawValue + 1) of \(Step.allCases.count)" }

    /// The step after `step`; nil after the last (the first run is finished).
    static func next(_ step: Step) -> Step? { Step(rawValue: step.rawValue + 1) }

    /// Back: the step before (the first stays where it is).
    static func back(_ step: Step) -> Step { Step(rawValue: step.rawValue - 1) ?? step }

    /// The main button: Continue, then on the alerts step "Allow Notifications…" while a rule is
    /// on, "Finish" when every rule is off (there is nothing to allow).
    static func primaryTitle(_ step: Step, anyAlertOn: Bool) -> String {
        guard step == .alerts else { return "Continue" }
        return anyAlertOn ? "Allow Notifications…" : "Finish"
    }

    /// The alerts step's main button asks macOS for permission first only while a rule is on.
    static func asksPermission(anyAlertOn: Bool) -> Bool { anyAlertOn }

    /// "Not now" (finish without asking) is offered only while there is something to allow.
    static func offersNotNow(anyAlertOn: Bool) -> Bool { anyAlertOn }
}

/// The first run's width hint under the live menu bar strip: how much of the menu bar the item
/// takes, amber advice above `notchWarning` (a notch hides items past it), and the icon alone when
/// nothing is ticked. `points` is the rendered item's width; it is rounded to tens ("about").
enum MenuBarWidthHint {
    /// About the room left of a MacBook's notch once the system's own items are in the bar.
    static let notchWarning: CGFloat = 340

    static func rounded(_ points: CGFloat) -> Int { Int((points / 10).rounded()) * 10 }

    static func isWide(_ points: CGFloat) -> Bool { CGFloat(rounded(points)) > notchWarning }

    static func text(points: CGFloat, items: Int) -> String {
        let pt = rounded(points)
        if items == 0 { return "Only the Heron icon will show · about \(pt) pt of your menu bar" }
        if isWide(points) { return "About \(pt) pt wide. On a MacBook with a notch some items may hide; untick a few to fit." }
        return "Takes about \(pt) pt of your menu bar"
    }
}

/// The first run's alert rules: the three default rules in plain words, each switch bound to the
/// real rule in `AppSettings.alertRules`.
enum FirstRunAlerts {
    static let rows: [(subject: AlertRule.Subject, title: String)] = [
        (.cpuTemperature, "CPU running hot"), (.memoryPressure, "Memory running out"),
        (.batteryPercent, "Battery low"),
    ]

    /// "Above 95° for 30 seconds", "Memory pressure reaches Critical for 10 seconds", "Below 10%".
    static func hint(_ rule: AlertRule, unit: Format.TemperatureUnit) -> String {
        let held = rule.seconds > 0 ? " for \(AlertEngine.spokenDuration(rule.seconds))" : ""
        let side = rule.comparison == .above ? "Above" : "Below"
        if rule.subject == .memoryPressure { return "Memory pressure reaches \(rule.threshold >= 1 ? "Critical" : "Warning")\(held)" }
        return "\(side) \(AlertPreview.limit(rule, unit: unit))\(held)"
    }
}

public struct OnboardingView: View {
    @State private var step: OnboardingFlow.Step
    /// Every item starts ticked the first time the list opens; going back and forth keeps the user's picks.
    @State private var prefilled = false
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(Monitor.self) private var monitor
    @Environment(\.colorScheme) private var colorScheme
    /// `step` 1 opens on the item list, 2 on the alerts (heron-snap).
    public init(step: Int = 0) { _step = State(initialValue: OnboardingFlow.Step(rawValue: step) ?? .welcome) }

    /// The first time the item list opens, every item is ticked; later visits keep the user's picks.
    static func tickEverything(_ settings: AppSettings, prefilled: inout Bool) {
        guard !prefilled else { return }
        prefilled = true
        for kind in MenuItemKind.allCases { settings.setShown(kind, true) }
    }

    /// Each step's size, as in the design.
    static func size(_ step: OnboardingFlow.Step) -> CGSize { step == .items ? CGSize(width: 560, height: 520) : CGSize(width: 480, height: 420) }

    public var body: some View {
        let size = Self.size(step)
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .welcome: welcome
            case .items: pickItems
            case .alerts: alerts
            }
        }
        // Room for the traffic lights over the content (the window has no title bar of its own).
        .padding(.top, 40).padding(.horizontal, step == .welcome ? 32 : 28).padding(.bottom, step == .welcome ? 24 : 22)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Theme.settingsWindow)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                HeronMark(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Heron").font(.system(size: 22, weight: .bold)).tracking(-0.2)
                    Text("Everything your Mac is doing, one glance away.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                benefit(
                    .menuBar, Theme.cpu, "Live readings in the menu bar",
                    "CPU, GPU, memory, temperature, network, disk, fans and battery — pick the ones you want next to the Heron icon.")
                benefit(
                    .overview, Theme.memory, "Details one click away",
                    "Click the icon for an overview. Hover a section for graphs and top processes; click a row for its history.")
                benefit(
                    .alerts, Theme.warning, "Warnings before it hurts",
                    "A notification when your Mac runs hot, runs out of memory or runs low on battery.")
            }
            .padding(.top, 24)
            Spacer(minLength: 12)
            footer {
                Button(OnboardingFlow.primaryTitle(.welcome, anyAlertOn: false)) {
                    Self.tickEverything(settings, prefilled: &prefilled)
                    step = .items
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pickItems: some View {
        let dark = colorScheme == .dark
        let label = MenuBarLabel(snapshot: monitor.snapshot, history: monitor.history, settings: settings, ink: dark ? .white : .black, dark: dark)
        let width = MenuBarRenderer.image(for: label).size.width
        // Menu bar order; an item this Mac has no reading for (no battery, no fans) is not offered.
        let kinds = settings.menuItems.map(\.kind).filter { MenuBarLabel.hasSource($0, in: monitor.snapshot) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Choose what sits next to the Heron icon").font(.system(size: 20, weight: .bold)).tracking(-0.2)
            Text("This is how your menu bar will look. Untick everything to keep just the icon.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            MenuBarStrip(dark: dark, height: 30).padding(.top, 14)
            Text(MenuBarWidthHint.text(points: width, items: label.segments.count))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(MenuBarWidthHint.isWide(width) ? Theme.caution : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(kinds) { itemTile($0, dark: dark) }
            }
            .padding(.top, 12)
            Spacer(minLength: 12)
            footer(note: "Change it any time in Settings") {
                Button("Back") { step = OnboardingFlow.back(.items) }
                Button(OnboardingFlow.primaryTitle(.items, anyAlertOn: false)) { step = .alerts }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var alerts: some View {
        let unit = settings.temperatureUnit
        // The rules this Mac can send: no battery, no battery rule.
        let rows = FirstRunAlerts.rows.compactMap { row -> (index: Int, title: String)? in
            guard row.subject != .batteryPercent || monitor.snapshot.battery?.present == true,
                let index = settings.alertRules.firstIndex(where: { $0.subject == row.subject })
            else { return nil }
            return (index, row.title)
        }
        let anyOn = rows.contains { settings.alertRules[$0.index].enabled }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Get warned before it’s too late").font(.system(size: 20, weight: .bold)).tracking(-0.2)
            Text("Heron watches in the background and sends a notification only when something needs you.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                    let rule = settings.alertRules[row.index]
                    HStack(spacing: 12) {
                        AlertRuleTile(subject: rule.subject)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.system(size: 13, weight: .medium))
                            Text(FirstRunAlerts.hint(rule, unit: unit)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        SettingsSwitch(
                            title: row.title,
                            isOn: Binding(
                                get: { settings.alertRules[row.index].enabled },
                                set: { settings.alertRules[row.index].enabled = $0 }))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .overlay(alignment: .top) { if offset > 0 { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
                }
            }
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
            .padding(.top, 18)
            Text("Change the limits or add your own rules later in Settings › Alerts.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.horizontal, 2)
            Spacer(minLength: 12)
            footer {
                Button("Back") { step = OnboardingFlow.back(.alerts) }
                if OnboardingFlow.offersNotNow(anyAlertOn: anyOn) {
                    Button("Not now") { services.finishOnboarding() }
                }
                Button(OnboardingFlow.primaryTitle(.alerts, anyAlertOn: anyOn)) {
                    if OnboardingFlow.asksPermission(anyAlertOn: anyOn) { services.requestNotifications() }
                    services.finishOnboarding()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Pieces

    /// The step dots and "Step n of 3" on the left, the step's buttons on the right.
    private func footer<Buttons: View>(note: String? = nil, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(OnboardingFlow.Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Color.primary : Theme.muted.opacity(0.45)).frame(width: s == step ? 16 : 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            Text(OnboardingFlow.caption(step) + (note.map { " · \($0)" } ?? "")).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 8) { buttons() }.controlSize(.large)
        }
    }

    /// An item to tick: the box, its tile and name, and its look as the menu bar draws it.
    private func itemTile(_ kind: MenuItemKind, dark: Bool) -> some View {
        let on = settings.isShown(kind)
        let accent = Color(nsColor: NSColor(hex: Theme.Palette.accent))
        let image = MenuBarRenderer.image(
            of: MenuBarSegment(
                kind: kind, style: settings.style(of: kind), snapshot: monitor.snapshot,
                history: monitor.history, settings: settings, ink: MenuBarPane.ink(dark), dark: dark))
        return Button {
            settings.setShown(kind, !on)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if on {
                        RoundedRectangle(cornerRadius: 4).fill(accent)
                        HeronIconView(.check, size: 11, weight: 2.6).foregroundStyle(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.muted, lineWidth: 1.5)
                    }
                }
                .frame(width: 16, height: 16)
                kind.tile(battery: monitor.snapshot.battery, size: 26)
                // The name stays whole; a wide look shrinks in its chip instead.
                Text(kind.title).font(.system(size: 13, weight: .medium)).fixedSize()
                Spacer(minLength: 4)
                Image(nsImage: image)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(minWidth: 0, maxWidth: min(image.size.width, 96), maxHeight: image.size.height)
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .background(MenuBarPane.barColor(dark), in: RoundedRectangle(cornerRadius: 6))
                    .opacity(on ? 1 : 0.45)
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(height: 50)
            .background(on ? Theme.settingsCard : Theme.settingsWindow, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(kind.title) in the menu bar")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func benefit(_ icon: HeronIcon, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15))
                HeronIconView(icon, size: 16)
            }
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).lineSpacing(2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Changelog

/// One change: a short title, a line on it, and the glyph and colour of what it is about.
public struct ChangelogItem: Hashable, Sendable {
    public var title: String
    public var body: String
    var icon: HeronIcon
    var color: Color

    init(_ title: String, _ body: String, icon: HeronIcon, color: Color) {
        self.title = title; self.body = body; self.icon = icon; self.color = color
    }
}

public struct ChangelogEntry: Identifiable, Sendable {
    public var id: String { version }
    public var version: String
    public var date: String
    /// "NEW", "IMPROVED", "FIXED", each with its changes.
    public var groups: [(title: String, items: [ChangelogItem])]
    /// The release's notes on the web; nil when there is no such page (What's New then shows no link).
    public var notesURL: URL?
}

public enum Changelog {
    /// Newest first. Add an entry here with every release; "What's new" opens after an update.
    public static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.1.1", date: "November 2026",
            groups: [
                (
                    "FIXED",
                    [
                        ChangelogItem(
                            "A blank menu bar item stays blank", "Before the first readings, an item could show an old picture instead of nothing.",
                            icon: .menuBar, color: Theme.network)
                    ]
                )
            ]),
        ChangelogEntry(
            version: "1.1.0", date: "November 2026",
            groups: [
                (
                    "NEW",
                    [
                        ChangelogItem("Updates on their own", "Heron checks once a day and puts a dot on its icon when a new version is out.", icon: .updates, color: Theme.cpu),
                        ChangelogItem(
                            "Install when you choose", "Install from the update window, restart now, or let it install when you quit.", icon: .check, color: Theme.memory),
                    ]
                )
            ]),
        ChangelogEntry(
            version: "1.0.0", date: "2026",
            groups: [
                (
                    "NEW",
                    [
                        ChangelogItem("One menu bar item", "The Heron icon, with the readings you choose beside it.", icon: .menuBar, color: Theme.cpu),
                        ChangelogItem("Overview and panels", "Hover a section for graphs, cores, processes and sensors.", icon: .overview, color: Theme.memory),
                        ChangelogItem("History for any row", "Click a row with a chart mark to see 1 minute to 24 hours.", icon: .chart, color: Theme.network),
                        ChangelogItem("Battery health", "Charge, health, cycles and the charge limit macOS sets.", icon: .battery, color: Theme.memory),
                        ChangelogItem("Alerts", "Heat, memory pressure, disk space and low battery.", icon: .alerts, color: Theme.warning),
                        ChangelogItem("Light, dark and updates", "Follows your appearance setting and keeps itself up to date.", icon: .updates, color: Theme.muted),
                    ]
                )
            ]),
    ]

    /// A group's caption colour: new in the memory green, fixes in the network amber, the rest in the CPU blue.
    static func color(_ group: String) -> Color { group == "NEW" ? Theme.memory : (group == "FIXED" ? Theme.network : Theme.cpu) }
}

/// What's New: the release's version and date, its changes grouped in cards, and Done. A list of
/// releases beside it only when there is more than one; a link to the notes only when they exist.
public struct ChangelogView: View {
    @State private var selected: String = Changelog.entries.first?.version ?? ""
    @Environment(AppServices.self) private var services
    var entries: [ChangelogEntry]
    var onDone: () -> Void

    public init(onDone: @escaping () -> Void = {}) { self.init(entries: Changelog.entries, onDone: onDone) }
    init(entries: [ChangelogEntry], onDone: @escaping () -> Void = {}) { self.entries = entries; self.onDone = onDone }

    /// The window's size, as in the design.
    public static let size = CGSize(width: 640, height: 440)

    /// The list of releases shows only when there is more than one to pick from.
    static func showsSidebar(_ entries: [ChangelogEntry]) -> Bool { entries.count > 1 }

    public var body: some View {
        let entry = entries.first { $0.version == selected } ?? entries.first
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                if Self.showsSidebar(entries) {
                    List(entries, selection: $selected) { e in Text("\(e.version) · \(e.date)").tag(e.version) }
                        .frame(width: 160)
                }
                if let entry {
                    ScrollView { release(entry).padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 16) }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                if let url = entry?.notesURL {
                    Button("Full release notes on the website") { services.openURL(url) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                Spacer()
                Button("Done", action: onDone).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
            .padding(.leading, 32).padding(.trailing, 20)
            .frame(height: 56)
            .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.settingsWindow)
    }

    private func release(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                HeronMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Heron \(entry.version)").font(.system(size: 20, weight: .bold)).tracking(-0.2)
                    Text(entry.version == services.appVersion ? "\(entry.date) · You’re on this version" : entry.date)
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            ForEach(entry.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(group.title).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Changelog.color(group.title))
                        Rectangle().fill(Theme.settingsLine).frame(height: 1)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], spacing: 10) {
                        ForEach(group.items, id: \.self) { item($0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(_ item: ChangelogItem) -> some View {
        ChangeCard(icon: item.icon, color: item.color, title: item.title, text: item.body)
    }
}
