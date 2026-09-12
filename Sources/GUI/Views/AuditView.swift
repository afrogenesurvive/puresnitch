import AppKit
import SwiftUI

/// The AI activity audit: which audiences exist, what each one talked to, and
/// whether the clients that promised to use a local proxy actually did.
struct AuditView: View {
    @EnvironmentObject var state: AppState
    @State private var searchText = ""

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
        .preferredColorScheme(.dark)
        .onAppear { state.refreshAudit() }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                routingSection
                activitySection
            }
            .padding(16)
        }
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
            Text(selectedAudience.map { "Activity · \($0.name)" } ?? "Unattributed traffic")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(PSTheme.textMuted)
            if selectedActivity.isEmpty {
                Text(state.selectedAudienceId == nil
                     ? "Every observed connection is attributed to an audience."
                     : "No observed connections for this audience yet.")
                    .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
            } else {
                VStack(spacing: 0) {
                    columnHeader
                    ForEach(Array(selectedActivity.prefix(200).enumerated()), id: \.element.id) { index, connection in
                        activityRow(connection, alternate: index % 2 == 1)
                    }
                }
                .background(PSTheme.bgRow)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Process").frame(width: 190, alignment: .leading)
            Text("Repository").frame(width: 170, alignment: .leading)
            Text("Remote").frame(maxWidth: .infinity, alignment: .leading)
            Text("Seen").frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(PSTheme.textMuted)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(PSTheme.bgTertiary)
    }

    private func activityRow(_ connection: Connection, alternate: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(connection.processName.isEmpty ? "Unknown" : connection.processName)
                    .font(.system(size: 11)).foregroundColor(PSTheme.textPrimary).lineLimit(1)
                if let commandLine = connection.processCommandLine, !commandLine.isEmpty {
                    Text(commandLine)
                        .font(.system(size: 9)).foregroundColor(PSTheme.textMuted).lineLimit(1)
                }
            }
            .frame(width: 190, alignment: .leading)

            Text(connection.repoRoot.map { ($0 as NSString).lastPathComponent } ?? "—")
                .font(.system(size: 10)).foregroundColor(PSTheme.textSecondary).lineLimit(1)
                .frame(width: 170, alignment: .leading)

            HStack(spacing: 4) {
                Text(connection.remoteHost.isEmpty ? connection.remoteIP : connection.remoteHost)
                    .font(.system(size: 10)).foregroundColor(PSTheme.textSecondary).lineLimit(1)
                Text(":\(connection.remotePort)")
                    .font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
                if connection.remotePort == AppConstants.devmonProxyPort {
                    PSChip("proxy", color: PSTheme.accentGreen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(relativeTime(connection.lastSeen))
                .font(.system(size: 9)).foregroundColor(PSTheme.textMuted)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(alternate ? PSTheme.bgRowAlt : PSTheme.bgRow)
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
    private var selectedActivity: [Connection] {
        let matching = state.selectedAudienceId == nil
            ? state.connections.filter { $0.audienceId == nil }
            : state.connections.filter { $0.audienceId == state.selectedAudienceId }
        return matching.sorted { $0.lastSeen > $1.lastSeen }
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
