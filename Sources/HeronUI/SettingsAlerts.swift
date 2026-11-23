import HeronCore
import SwiftUI

// MARK: - Alerts

/// Settings › Alerts: whether macOS lets Heron notify, every rule in one list with its reading
/// now, and the selected rule's notification as it would arrive.
struct AlertsPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(Monitor.self) private var monitor
    @State private var editing: AlertRule?
    /// The rule the preview shows.
    @State private var selected: UUID?

    var body: some View {
        @Bindable var settings = settings
        let rules = settings.alertRules
        let shown = rules.first { $0.id == selected } ?? rules.first
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(pane: .alerts)
            permissionRow.padding(.top, 16)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsCaption("Rules")
                    VStack(spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                            ruleRow(rule, first: index == 0, selected: rule.id == shown?.id)
                        }
                        HStack {
                            Button {
                                editing = AlertRule.newRule
                            } label: {
                                Label {
                                    Text("Add rule…")
                                } icon: {
                                    HeronIconView(.plus, size: 12, weight: 2.4)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(alignment: .top) { if !rules.isEmpty { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
                    }
                    .background(Theme.settingsCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
                }
                .frame(width: 352)
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsCaption("What you get")
                        whatYouGet(shown)
                    }
                    SettingsGroup("For every rule", top: 16) {
                        SettingsRow(
                            title: "Limit repeats",
                            subtitle: settings.alertCooldown ? "Each rule notifies at most once every 10 minutes" : "A rule notifies every time its condition comes true",
                            first: true, minHeight: 52
                        ) {
                            SettingsSwitch(title: "Limit repeats", isOn: $settings.alertCooldown)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, 16)
        }
        .onAppear { services.refreshNotificationPermission() }
        .sheet(item: $editing) { rule in
            // A rule that is not saved yet has nothing to delete: the editor offers Cancel only.
            let isNew = !settings.alertRules.contains { $0.id == rule.id }
            let delete: ((AlertRule) -> Void)? = isNew ? nil : { deleted in settings.alertRules.removeAll { $0.id == deleted.id } }
            AlertRuleEditor(
                rule: rule, unit: settings.temperatureUnit,
                onSave: { saved in
                    if let i = settings.alertRules.firstIndex(where: { $0.id == saved.id }) { settings.alertRules[i] = saved } else { settings.alertRules.append(saved) }
                    selected = saved.id
                }, onDelete: delete)
        }
    }

    /// "Notifications are allowed" with a dot, or what to do when they are not.
    private var permissionRow: some View {
        let permission = services.notificationPermission
        let dot: Color =
            switch permission {
            case .allowed: Theme.memory
            case .denied: Theme.warning
            case .notAsked: Theme.network
            case .unavailable: Theme.muted
            }
        return SettingsCard {
            HStack(spacing: 12) {
                Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title).font(.system(size: 13, weight: .medium))
                    Text(permission.hint).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let title = permission.actionTitle {
                    Button(title) {
                        switch permission.action {
                        case .ask?: services.requestNotifications()
                        default: services.openURL(AppServices.notificationSettings)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 52)
            .accessibilityElement(children: .contain)
        }
    }

    private func ruleRow(_ rule: AlertRule, first: Bool, selected: Bool) -> some View {
        let text = rule.summary(unit: settings.temperatureUnit)
        let now = AlertPreview.reading(rule.subject, in: monitor.snapshot, unit: settings.temperatureUnit)
        return HStack(spacing: 10) {
            Button {
                self.selected = rule.id
            } label: {
                HStack(spacing: 10) {
                    AlertRuleTile(subject: rule.subject).opacity(rule.enabled ? 1 : 0.55)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text).font(.system(size: 13, weight: selected ? .semibold : .medium)).monospacedDigit().lineLimit(1)
                        Text(rule.enabled ? (now.map { "Now \($0)" } ?? "No reading on this Mac") : "Off")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 51)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .simultaneousGesture(TapGesture(count: 2).onEnded { editing = rule })
            SettingsSwitch(
                title: "Send “\(text)”",
                isOn: Binding(
                    get: { settings.alertRules.first { $0.id == rule.id }?.enabled ?? false },
                    set: { on in if let i = settings.alertRules.firstIndex(where: { $0.id == rule.id }) { settings.alertRules[i].enabled = on } }
                ))
        }
        .padding(.leading, 12).padding(.trailing, 14)
        .frame(height: 52)
        .background(selected ? Theme.settingsSelection : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Color(nsColor: NSColor(hex: Theme.Palette.accent))).frame(width: 3) } }
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.settingsLine).frame(height: 1) } }
        .contextMenu {
            Button("Edit Rule…") { editing = rule }
            Button("Delete Rule") { settings.alertRules.removeAll { $0.id == rule.id } }
        }
    }

    /// The selected rule's notification (dimmed when the rule is off), and whether it would go out now.
    @ViewBuilder private func whatYouGet(_ rule: AlertRule?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rule {
                let unit = settings.temperatureUnit
                let value = AlertPreview.sample(rule)
                NotificationBanner(
                    title: AlertEngine.title(rule, value: value, unit: unit),
                    message: AlertEngine.body(rule, value: value, unit: unit, snapshot: monitor.snapshot), width: nil
                )
                .opacity(rule.enabled ? 1 : 0.5)
                if !rule.enabled {
                    Text("This rule is off, so Heron will not send it.").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 8)
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Right now").font(.system(size: 13, weight: .medium))
                        Text(AlertPreview.nowLine(rule, value: rule.subject.value(in: monitor.snapshot), unit: unit, snapshot: monitor.snapshot))
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Edit rule…") { editing = rule }
                }
                .frame(minHeight: 44)
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.settingsLine).frame(height: 1) }
                .padding(.top, 12)
            } else {
                Text("No rules yet. Add one to get a notification when something needs you.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsLine, lineWidth: 1))
    }
}
