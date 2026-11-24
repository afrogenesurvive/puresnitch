import AppKit
import SwiftUI

/// The menu-bar panel's tabs.
///
/// These are deliberately *separate* views from `NetworkMonitorView`,
/// `RulesManagerView` and `AuditView` rather than the full windows squeezed
/// small: each one answers the one question you ask from the menu bar, and
/// hands you off to the real window (`MiniHeader`'s "Open Full View") when you
/// need everything else. The right-click menu and the popover's own buttons
/// keep opening the full windows — the tabs never replace them.
enum PopoverTab: String, CaseIterable, Identifiable {
    case overview
    case network
    case rules
    case ai
    case misc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .network: return "Network"
        case .rules: return "Rules"
        case .ai: return "AI"
        case .misc: return "Misc"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .network: return "globe"
        case .rules: return "list.bullet.rectangle"
        case .ai: return "sparkles"
        case .misc: return "questionmark.circle"
        }
    }
}

struct PopoverTabBar: View {
    @Binding var selection: PopoverTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PopoverTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(selection == tab ? PSTheme.bgTertiary : Color.clear)
                    .foregroundColor(selection == tab ? PSTheme.accent : PSTheme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// Chrome shared by the mini views. The escape hatch back to the full window is
/// the point of the tabs — a glance here, the real thing one click away.
struct MiniHeader: View {
    let title: String
    let systemImage: String
    let openFull: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PSTheme.textMuted)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PSTheme.textSecondary)
            Spacer()
            Button(action: openFull) {
                HStack(spacing: 3) {
                    Text("Open Full View")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(PSTheme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the full window")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// "Recently Denied", shared by the Overview and Network tabs so the two can't
/// drift apart.
struct RecentDeniedRow: View {
    @EnvironmentObject var state: AppState
    let openFull: () -> Void

    var body: some View {
        Button(action: openFull) {
            HStack {
                ZStack {
                    Circle().fill(PSTheme.accentRed)
                    Text("\(state.deniedCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 22, height: 22)
                Text("Recently Denied")
                    .font(.system(size: 13))
                    .foregroundColor(PSTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(PSTheme.textMuted)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

/// Empty states must not claim the negative while the helper is unreachable:
/// an unanswered request and a genuine "nothing here" look identical to a list
/// view, and only one of them is the user's fault.
struct MiniPlaceholder: View {
    @EnvironmentObject var state: AppState
    let emptyMessage: String

    var body: some View {
        Text(state.helperConnected ? emptyMessage : "Waiting for the PureSnitch helper.")
            .font(.system(size: 11))
            .foregroundColor(PSTheme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }
}

// MARK: - Network

struct MiniNetworkMonitorView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var windows: WindowManager
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiniHeader(title: "Network", systemImage: "globe") {
                close()
                windows.showNetworkMonitor()
            }

            HStack(spacing: 8) {
                speedPill("↓ \(PSFormat.bytesPerSec(state.currentIn))", PSTheme.trafficIn)
                speedPill("↑ \(PSFormat.bytesPerSec(state.currentOut))", PSTheme.trafficOut)
            }
            .padding(.horizontal, 14)

            TrafficBarsChart(history: state.trafficHistory)
                .frame(height: 80)
                .background(PSTheme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14)
                .padding(.top, 10)

            sectionLabel("Top Processes")

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.topProcesses.prefix(12)), id: \.id) { process in
                        row(process)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider().background(PSTheme.stroke)
            RecentDeniedRow {
                close()
                windows.showNetworkMonitor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func row(_ process: AppState.ProcessStats) -> some View {
        HStack(spacing: 8) {
            if let icon = process.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundColor(PSTheme.textSecondary)
                    .frame(width: 16, height: 16)
            }
            Text(process.name)
                .font(.system(size: 12))
                .foregroundColor(PSTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(PSFormat.bytes(process.total))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(PSTheme.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    private func speedPill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(PSTheme.textMuted)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 3)
    }
}

// MARK: - Rules

struct MiniRulesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var windows: WindowManager
    let close: () -> Void

    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case allow
        case deny
        case ask

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var query = ""
    @State private var filter: Filter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiniHeader(title: "Rules", systemImage: "list.bullet.rectangle") {
                close()
                windows.showRulesManager()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(PSTheme.textMuted)
                TextField("Search rules", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundColor(PSTheme.textPrimary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(PSTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 14)

            HStack(spacing: 6) {
                ForEach(Filter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        Text(option.label)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(filter == option ? PSTheme.accent.opacity(0.20) : PSTheme.bgTertiary)
                            .foregroundColor(filter == option ? PSTheme.accent : PSTheme.textSecondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(filtered.count) of \(state.rules.count)")
                    .font(.system(size: 10))
                    .foregroundColor(PSTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(PSTheme.stroke)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.prefix(60)), id: \.id) { rule in
                        row(rule)
                    }
                    if filtered.isEmpty {
                        MiniPlaceholder(emptyMessage: "No rules match this filter.")
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var filtered: [Rule] {
        state.rules.filter { rule in
            let matchesAction: Bool
            switch filter {
            case .all: matchesAction = true
            case .allow: matchesAction = rule.action == .allow
            case .deny: matchesAction = rule.action == .deny
            case .ask: matchesAction = rule.action == .ask
            }
            guard matchesAction else { return false }
            guard !query.isEmpty else { return true }
            let haystack = [rule.processName, rule.remoteHost, rule.remoteIP, rule.notes]
                .compactMap { $0 }
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private func row(_ rule: Rule) -> some View {
        HStack(spacing: 8) {
            if let icon = AppIcon.resolve(bundleId: rule.processBundleId,
                                          path: rule.processPath,
                                          name: rule.processName) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "person.crop.circle.dashed")
                    .foregroundColor(PSTheme.textSecondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.processName ?? "Any Process")
                    .font(.system(size: 12))
                    .foregroundColor(PSTheme.textPrimary)
                    .lineLimit(1)
                Text(rule.remoteHost ?? rule.remoteIP ?? "Any")
                    .font(.system(size: 10))
                    .foregroundColor(PSTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            PSChip(actionLabel(rule), color: actionColor(rule))
            Button {
                setEnabled(rule, !rule.enabled)
            } label: {
                Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(rule.enabled ? PSTheme.accentGreen : PSTheme.textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(rule.enabled ? "Disable this rule" : "Enable this rule")
        }
        .opacity(rule.enabled ? 1 : 0.55)
        .padding(.horizontal, 14).padding(.vertical, 5)
    }

    /// The same upsert `RulesManagerView.toggleRule(_:)` performs. Only
    /// `enabled` is editable from the panel: changing a rule's *action* rewrites
    /// the pf anchor through `syncSharedRules()`, and that belongs in the full
    /// window where the consequence is visible.
    private func setEnabled(_ rule: Rule, _ enabled: Bool) {
        var copy = rule
        copy.enabled = enabled
        state.helper.addRule(copy)
        state.refreshRules()
    }

    private func actionLabel(_ rule: Rule) -> String {
        switch rule.action {
        case .allow: return "Allow"
        case .deny: return "Deny"
        case .ask: return "Ask"
        }
    }

    private func actionColor(_ rule: Rule) -> Color {
        switch rule.action {
        case .allow: return PSTheme.accentGreen
        case .deny: return PSTheme.accentRed
        case .ask: return PSTheme.accentYellow
        }
    }
}

// MARK: - AI Activity

struct MiniAuditView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var windows: WindowManager
    let close: () -> Void

    @State private var query = ""
    @State private var timeWindow: ActivityTimeWindow = .all
    @State private var expandedIds: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiniHeader(title: "AI Activity", systemImage: "sparkles") {
                close()
                windows.showAudit()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(PSTheme.textMuted)
                TextField("Search audiences", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundColor(PSTheme.textPrimary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(PSTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 14)

            summaryLine

            HStack(spacing: 8) {
                Spacer()
                Picker("", selection: $timeWindow) {
                    ForEach(ActivityTimeWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                .help("Show only connections active within this window")
            }
            .padding(.horizontal, 14)

            Divider().background(PSTheme.stroke)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.prefix(40)), id: \.id) { summary in
                        VStack(spacing: 0) {
                            row(summary)
                            if expandedIds.contains(summary.id) {
                                expandedConnections(summary)
                            }
                        }
                    }
                    if filtered.isEmpty {
                        MiniPlaceholder(emptyMessage: "No audiences discovered yet.")
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { state.refreshAudit() }
        .onChange(of: timeWindow) { _ in reloadExpanded() }
    }

    private var filtered: [AudienceSummary] {
        query.isEmpty
            ? state.audienceSummaries
            : state.audienceSummaries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var summaryLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(state.audienceSummaries.count) audiences · \(observedConnections) observed connections")
                .font(.system(size: 11))
                .foregroundColor(PSTheme.textMuted)

            if let report = state.proxyReport {
                if !report.unproxiedAudiences.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(PSTheme.accentYellow)
                        Text("Bypassing the proxy: \(report.unproxiedAudiences.joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundColor(PSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                // A report that hasn't arrived is not the same as one that says
                // nothing is declared, so this must not claim the negative.
                Text("Waiting for the helper to report proxy declarations…")
                    .font(.system(size: 10))
                    .foregroundColor(PSTheme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var observedConnections: Int {
        state.audienceSummaries.reduce(0) { $0 + $1.connectionCount }
    }

    /// Tapping the row expands or collapses the inline activity list instead of
    /// opening the full window; the trailing chevron is the state indicator.
    private func row(_ summary: AudienceSummary) -> some View {
        Button {
            toggle(summary.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: summary.icon.isEmpty ? "person.2" : summary.icon)
                    .font(.system(size: 12))
                    .foregroundColor(PSTheme.accentBlue)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.name)
                        .font(.system(size: 12))
                        .foregroundColor(PSTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(summary))
                        .font(.system(size: 10))
                        .foregroundColor(PSTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(PSFormat.compactCount(summary.connectionCount))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PSTheme.textSecondary)
                if summary.proxiedCount > 0 {
                    PSChip("proxied", color: PSTheme.accentGreen, icon: "checkmark.shield.fill")
                }
                Image(systemName: expandedIds.contains(summary.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(PSTheme.textMuted)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func expandedConnections(_ summary: AudienceSummary) -> some View {
        let conns = connections(for: summary)
        VStack(alignment: .leading, spacing: 0) {
            if conns.isEmpty {
                Text(state.helperConnected
                     ? "No connections in this time window."
                     : "Waiting for the PureSnitch helper.")
                    .font(.system(size: 10))
                    .foregroundColor(PSTheme.textMuted)
                    .padding(.horizontal, 30).padding(.vertical, 6)
            } else {
                ForEach(Array(conns.prefix(15))) { connection in
                    MiniConnectionRow(connection: connection)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func connections(for summary: AudienceSummary) -> [Connection] {
        (state.audienceHistory[summary.id] ?? []).sorted { $0.lastSeen > $1.lastSeen }
    }

    private func toggle(_ id: UUID) {
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            expandedIds.insert(id)
            state.loadAudienceHistory(id: id, since: timeWindow.cutoff, until: nil)
        }
    }

    private func reloadExpanded() {
        for id in expandedIds {
            state.loadAudienceHistory(id: id, since: timeWindow.cutoff, until: nil)
        }
    }

    private func subtitle(_ summary: AudienceSummary) -> String {
        var parts = ["↓ \(PSFormat.bytes(summary.bytesIn))", "↑ \(PSFormat.bytes(summary.bytesOut))"]
        if let lastSeen = summary.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append(formatter.localizedString(for: lastSeen, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }
}

/// A single connection row shared by the menu-bar AI and Misc tabs, so the two
/// lists can't drift apart.
struct MiniConnectionRow: View {
    @EnvironmentObject var state: AppState
    let connection: Connection

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.processName.isEmpty ? "Unknown" : connection.processName)
                    .font(.system(size: 12))
                    .foregroundColor(PSTheme.textPrimary)
                    .lineLimit(1)
                Text(detailText)
                    .font(.system(size: 10))
                    .foregroundColor(PSTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            if let label = AppConstants.serviceLabel(forPort: connection.remotePort) {
                PSChip(label, color: label == "proxy" ? PSTheme.accentGreen : PSTheme.accentBlue)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("↓ \(inText)  ↑ \(outText)")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundColor(PSTheme.textSecondary)
                Text(relativeTime(connection.lastSeen))
                    .font(.system(size: 9))
                    .foregroundColor(PSTheme.textMuted)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 4)
    }

    private var detailText: String {
        let repo = RepositoryLabel(connection: connection).text
        let host = connection.remoteHost.isEmpty ? connection.remoteIP : connection.remoteHost
        return "\(repo) · \(host):\(connection.remotePort)"
    }

    private var inText: String {
        guard let traffic = state.processTrafficByPID[connection.pid] else { return "—" }
        return PSFormat.bytes(traffic.bytesIn)
    }

    private var outText: String {
        guard let traffic = state.processTrafficByPID[connection.pid] else { return "—" }
        return PSFormat.bytes(traffic.bytesOut)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }
}
