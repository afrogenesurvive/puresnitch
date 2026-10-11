import AppKit
import SwiftUI

/// The AI activity audit: which audiences exist, what each one talked to, and
/// whether the clients that promised to use a local proxy actually did.
struct AuditView: View {
    @EnvironmentObject var state: AppState
    @State private var searchText = ""
    @State private var timeWindow: TimeWindow = .all

    /// How far back the activity table looks. Backed by the connection rows the
    /// helper has already stored, so this is a filter over the audit trail, not a
    /// separate query.
    private enum TimeWindow: String, CaseIterable, Identifiable {
        case hour = "1h"
        case sixHours = "6h"
        case day = "24h"
        case all = "All"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .hour: return "Past hour"
            case .sixHours: return "Past 6 hours"
            case .day: return "Past 24 hours"
            case .all: return "All time"
            }
        }

        var cutoff: Date? {
            switch self {
            case .hour: return Date().addingTimeInterval(-3_600)
            case .sixHours: return Date().addingTimeInterval(-6 * 3_600)
            case .day: return Date().addingTimeInterval(-24 * 3_600)
            case .all: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HelperBanner()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 260)
                    .background(PSTheme.bgSidebar)
                Divider().background(PSTheme.stroke)
                mainPane
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                Divider().background(PSTheme.stroke)
                detailPane
                    .frame(width: 290)
                    .background(PSTheme.bgSecondary)
            }
        }
        .background(PSTheme.bgPrimary)
        .preferredColorScheme(state.themeMode.colorScheme)
        .onAppear {
            state.refreshAudit()
            reloadHistory()
        }
        .onChange(of: timeWindow) { _ in reloadHistory() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(PSTheme.textMuted)
                TextField("Search audiences", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(PSTheme.textPrimary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(PSTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    allAudiencesRow
                    ForEach(groupedSummaries, id: \.kind) { group in
                        Text(title(for: group.kind))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(PSTheme.textMuted)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                        ForEach(group.items) { summary in
                            audienceRow(summary)
                        }
                    }
                    if state.audienceSummaries.isEmpty {
                        emptySidebar
                    }
                }
                .padding(.bottom, 10)
            }

            Divider().background(PSTheme.stroke)
            Button(action: { state.rediscoverAudiences() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Rescan configuration").font(.system(size: 12))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundColor(PSTheme.textPrimary)
            .help("Re-read VS Code, MCP and repository configuration. Manual audiences are never changed.")
        }
    }

    private var allAudiencesRow: some View {
        Button(action: { state.selectedAudienceId = nil }) {
            HStack(spacing: 8) {
                Image(systemName: "asterisk.circle").foregroundColor(PSTheme.accentBlue)
                Text("Unattributed traffic").font(.system(size: 12)).foregroundColor(PSTheme.textPrimary)
                Spacer()
                Text("\(unattributedCount)").font(.system(size: 10)).foregroundColor(PSTheme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(state.selectedAudienceId == nil ? PSTheme.accent.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func audienceRow(_ summary: AudienceSummary) -> some View {
        Button(action: { state.selectedAudienceId = summary.id }) {
            HStack(spacing: 8) {
                Image(systemName: summary.icon)
                    .foregroundColor(summary.connectionCount > 0 ? PSTheme.accentGreen : PSTheme.textMuted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary.name)
                        .font(.system(size: 12))
                        .foregroundColor(PSTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(for: summary))
                        .font(.system(size: 9))
                        .foregroundColor(PSTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if summary.proxiedCount > 0 {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                        .foregroundColor(PSTheme.accentGreen)
                }
                Text(PSFormat.bytes(summary.total))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(PSTheme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(state.selectedAudienceId == summary.id ? PSTheme.accent.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptySidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No audiences yet").font(.system(size: 12)).foregroundColor(PSTheme.textSecondary)
            Text("Audiences are discovered from VS Code, MCP and repository configuration when the helper starts.")
                .font(.system(size: 10))
                .foregroundColor(PSTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    // MARK: - Main pane

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    routingSection
                }
            }
            .frame(maxHeight: 240)
            activitySection
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI Activity").font(.system(size: 22, weight: .bold)).foregroundColor(PSTheme.textPrimary)
            Text("\(state.audienceSummaries.count) audiences · \(observedCount) observed connections · \(unattributedCount) unattributed")
                .font(.system(size: 11)).foregroundColor(PSTheme.textMuted)
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proxy routing").font(.system(size: 11, weight: .semibold)).foregroundColor(PSTheme.textMuted)
            Text("What client configuration declares, compared with the traffic that was actually seen. Only traffic to the local proxy is recorded.")
                .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let report = state.proxyReport {
                if report.expectations.isEmpty {
                    Text("No client configuration declares a local proxy, so every audience is on the direct path.")
                        .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
                } else {
                    ForEach(report.expectations) { expectation in
                        expectationRow(expectation)
                    }
                }
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
                // A report that has not arrived is not the same as one that says
                // nothing is declared, so this must not claim the negative.
                Text(state.helperConnected
                     ? "Waiting for the helper to report proxy declarations…"
                     : "Waiting for the PureSnitch helper.")
                    .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PSTheme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func expectationRow(_ expectation: ProxyExpectation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(expectation.clientName).font(.system(size: 11, weight: .semibold)).foregroundColor(PSTheme.textPrimary)
                PSChip(verdictTitle(expectation.verdict), color: verdictColor(expectation.verdict))
                Spacer()
                if expectation.directCount > 0 {
                    Text("\(expectation.directCount) direct").font(.system(size: 9)).foregroundColor(PSTheme.accentRed)
                }
                if expectation.proxiedCount > 0 {
                    Text("\(expectation.proxiedCount) proxied").font(.system(size: 9)).foregroundColor(PSTheme.accentGreen)
                }
            }
            Text("\(expectation.key) = \(expectation.declaredURL)")
                .font(.system(size: 10))
                .foregroundColor(PSTheme.textSecondary)
                .lineLimit(1)
            if !expectation.directHosts.isEmpty {
                Text("direct to \(expectation.directHosts.joined(separator: ", "))")
                    .font(.system(size: 9))
                    .foregroundColor(PSTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(selectedAudience.map { "Activity · \($0.name)" } ?? "Unattributed traffic")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(PSTheme.textMuted)
                Spacer()
                if !selectedActivity.isEmpty {
                    Text("\(visibleActivity.count) of \(selectedActivity.count)")
                        .font(.system(size: 9)).foregroundColor(PSTheme.textMuted)
                }
                Picker("", selection: $timeWindow) {
                    ForEach(TimeWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                .help("Show only connections active within this window")
            }
            if selectedActivity.isEmpty {
                Text(state.selectedAudienceId == nil
                     ? "Every observed connection is attributed to an audience."
                     : "No observed connections for this audience yet.")
                    .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
                Spacer()
            } else if visibleActivity.isEmpty {
                Text("No connections in this time window.")
                    .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
                Spacer()
            } else {
                connectionsTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A real `Table`: the user can resize and reorder the columns, and adding a
    /// column costs one declaration. The process list in the Network Monitor is a
    /// sidebar, so this is the only surface that needs a grid.
    private var connectionsTable: some View {
        Table(visibleActivity) {
            TableColumn("Process") { connection in
                VStack(alignment: .leading, spacing: 0) {
                    Text(connection.processName.isEmpty ? "Unknown" : connection.processName)
                        .font(.system(size: 11)).foregroundColor(PSTheme.textPrimary).lineLimit(1)
                    if let commandLine = connection.processCommandLine, !commandLine.isEmpty {
                        Text(commandLine)
                            .font(.system(size: 9)).foregroundColor(PSTheme.textMuted).lineLimit(1)
                    }
                }
            }
            .width(min: 140, ideal: 200)

            TableColumn("PID") { connection in
                Text("\(connection.pid)")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundColor(PSTheme.textSecondary)
            }
            .width(min: 48, ideal: 64)

            TableColumn("Repository") { connection in
                repositoryCell(connection)
            }
            .width(min: 110, ideal: 170)

            TableColumn("Remote") { connection in
                remoteCell(connection)
            }
            .width(min: 150, ideal: 240)

            // Byte totals are per process, not per socket, so they are resolved
            // by PID and deliberately not sortable: the toolbar has nothing
            // meaningful to order them by.
            TableColumn("In") { connection in
                Text(inboundText(connection))
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundColor(PSTheme.textSecondary)
            }
            .width(min: 56, ideal: 76)

            TableColumn("Out") { connection in
                Text(outboundText(connection))
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundColor(PSTheme.textSecondary)
            }
            .width(min: 56, ideal: 76)

            TableColumn("Seen") { connection in
                Text(relativeTime(connection.lastSeen))
                    .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
            }
            .width(min: 48, ideal: 64)
        }
    }

    private func repositoryCell(_ connection: Connection) -> some View {
        let label = RepositoryLabel(connection: connection)
        let text: String
        switch label {
        case .repository: text = label.text
        case .directory: text = "\(label.text) (not a repo)"
        case .unknown: text = label.text
        }
        return Text(text)
            .font(.system(size: 10))
            .foregroundColor(label.isRepository ? PSTheme.textSecondary : PSTheme.textMuted)
            .lineLimit(1)
            .help(repositoryHelp(connection, label: label))
    }

    private func repositoryHelp(_ connection: Connection, label: RepositoryLabel) -> String {
        guard let cwd = connection.processCwd, !cwd.isEmpty else { return label.help }
        return "\(label.help)\nworking directory: \(cwd)"
    }

    private func remoteCell(_ connection: Connection) -> some View {
        HStack(spacing: 4) {
            Text(connection.remoteHost.isEmpty ? connection.remoteIP : connection.remoteHost)
                .font(.system(size: 10)).foregroundColor(PSTheme.textSecondary).lineLimit(1)
            Text(":\(connection.remotePort)")
                .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
            if connection.remotePort == AppConstants.devmonProxyPort {
                PSChip("proxy", color: PSTheme.accentGreen)
            }
        }
    }

    /// `lsof` reports no per-socket byte counters, so a connection shows the
    /// cumulative totals of the process that owns it (resolved through its PID).
    /// Every connection of one process therefore shares the same figure.
    private func inboundText(_ connection: Connection) -> String {
        guard let traffic = state.processTrafficByPID[connection.pid] else { return "—" }
        return PSFormat.bytes(traffic.bytesIn)
    }

    private func outboundText(_ connection: Connection) -> String {
        guard let traffic = state.processTrafficByPID[connection.pid] else { return "—" }
        return PSFormat.bytes(traffic.bytesOut)
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let audience = selectedAudience, let summary = selectedSummary {
                    Text(audience.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(PSTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        PSChip(title(for: audience.kind), color: PSTheme.accentBlue)
                        PSChip(audience.source == .manual ? "manual" : "discovered",
                               color: audience.source == .manual ? PSTheme.accent : PSTheme.textMuted)
                    }
                    Toggle("Observe this audience", isOn: Binding(
                        get: { audience.enabled },
                        set: { state.setAudienceEnabled(id: audience.id, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                    .foregroundColor(PSTheme.textPrimary)

                    statField("Connections", "\(summary.connectionCount)")
                    statField("Recorded via proxy", "\(summary.proxiedCount)")
                    statField("Downloaded", PSFormat.bytes(summary.bytesIn))
                    statField("Uploaded", PSFormat.bytes(summary.bytesOut))

                    sectionLabel("Matchers")
                    ForEach(Array(audience.matchers.enumerated()), id: \.offset) { _, matcher in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(matcherTitle(matcher.kind))
                                .font(.system(size: 9)).foregroundColor(PSTheme.textMuted)
                            Text(matcher.pattern)
                                .font(.system(size: 10)).foregroundColor(PSTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let group = matcher.group {
                                Text("group \(group)").font(.system(size: 9)).foregroundColor(PSTheme.textMuted)
                            }
                        }
                    }
                    if let notes = audience.notes {
                        sectionLabel("Notes")
                        Text(notes).font(.system(size: 10)).foregroundColor(PSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(role: .destructive, action: { state.removeAudience(id: audience.id) }) {
                        Text("Remove audience").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(PSTheme.accentRed)
                    .help("Removes the audience. Recorded traffic is kept and becomes unattributed.")
                } else {
                    Text("Audit").font(.system(size: 16, weight: .bold)).foregroundColor(PSTheme.textPrimary)
                    Text("Audiences group your AI activity by client, repository, MCP server and local service. "
                         + "Select one to see its matchers, or right-click a process in the Network Monitor and choose "
                         + "\"Watch this process\" to add one by hand.")
                        .font(.system(size: 10)).foregroundColor(PSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    statField("Audiences", "\(state.audiences.count)")
                    statField("Observed connections", "\(observedCount)")
                    statField("Unattributed", "\(unattributedCount)")
                }
            }
            .padding(14)
        }
    }

    private func statField(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(PSTheme.textMuted)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundColor(PSTheme.textPrimary)
        }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(PSTheme.textMuted)
    }

    // MARK: - Derived

    private var groupedSummaries: [(kind: AudienceKind, items: [AudienceSummary])] {
        let filtered = searchText.isEmpty
            ? state.audienceSummaries
            : state.audienceSummaries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return AudienceKind.allCases.compactMap { kind in
            let items = filtered.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind: kind, items: items)
        }
    }

    private var selectedAudience: Audience? {
        guard let id = state.selectedAudienceId else { return nil }
        return state.audiences.first { $0.id == id }
    }

    private var selectedSummary: AudienceSummary? {
        guard let id = state.selectedAudienceId else { return nil }
        return state.audienceSummaries.first { $0.id == id }
    }

    /// With nothing selected the pane shows what the audit cannot explain yet,
    /// which is the list that tells you what still needs an audience.
    /// Live snapshot for "All time"; the persisted trail once a window is chosen.
    private var sourceConnections: [Connection] {
        timeWindow == .all ? state.connections : state.auditHistory
    }

    private var selectedActivity: [Connection] {
        let matching: [Connection]
        if state.selectedAudienceId == nil {
            matching = sourceConnections.filter { $0.audienceId == nil }
        } else {
            matching = sourceConnections.filter { $0.audienceId == state.selectedAudienceId }
        }
        return matching.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Ordered newest-first. Column sorting is deliberately not offered: the
    /// sortable `TableColumn` overload needs macOS 14, and this app targets 13.
    /// Column resizing and reordering are unaffected by that.
    private var visibleActivity: [Connection] {
        selectedActivity
    }

    private func reloadHistory() {
        guard timeWindow != .all else { return }
        state.loadAuditHistory(since: timeWindow.cutoff, until: nil)
    }

    private var observedCount: Int { state.connections.count }

    private var unattributedCount: Int { state.connections.filter { $0.audienceId == nil }.count }

    private func subtitle(for summary: AudienceSummary) -> String {
        var parts = ["\(summary.connectionCount) conn"]
        if summary.proxiedCount > 0 { parts.append("\(summary.proxiedCount) proxied") }
        return parts.joined(separator: " · ")
    }

    private func title(for kind: AudienceKind) -> String {
        switch kind {
        case .client: return "CLIENTS"
        case .repo: return "REPOSITORIES"
        case .mcpServer: return "MCP SERVERS"
        case .service: return "LOCAL SERVICES"
        case .adHoc: return "WATCHED BY HAND"
        }
    }

    private func matcherTitle(_ kind: AudienceMatcherKind) -> String {
        switch kind {
        case .processPathPrefix: return "process path prefix"
        case .processBundleId: return "bundle identifier"
        case .cwdPrefix: return "working directory prefix"
        case .commandLineContains: return "command line contains"
        case .remoteHost: return "remote host"
        case .remotePort: return "remote port"
        }
    }

    private func verdictTitle(_ verdict: ProxyExpectationVerdict) -> String {
        switch verdict {
        case .proxied: return "recorded"
        case .bypassed: return "going direct"
        case .localEndpoint: return "local only"
        case .idle: return "idle"
        case .unattributed: return "not attributed"
        }
    }

    private func verdictColor(_ verdict: ProxyExpectationVerdict) -> Color {
        switch verdict {
        case .proxied: return PSTheme.accentGreen
        case .bypassed: return PSTheme.accentRed
        case .localEndpoint: return PSTheme.accentBlue
        case .idle: return PSTheme.textMuted
        case .unattributed: return PSTheme.accentYellow
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }
}
