import AppKit
import SwiftUI

/// The menu-bar tab for unattributed activity: connections no audience claimed.
///
/// It mirrors the audit window's "Unattributed traffic" pane, with the same
/// time-period filter, so the menu bar answers "what did I miss?" without
/// opening the full window. "Open Full View" hands off to the audit with no
/// audience selected, which is exactly that pane.
struct MiniMiscView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var windows: WindowManager
    let close: () -> Void

    @State private var timeWindow: ActivityTimeWindow = .all
    @State private var expandedKeys: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiniHeader(title: "Misc", systemImage: "questionmark.circle") {
                state.selectedAudienceId = nil
                close()
                windows.showAudit()
            }

            HStack(spacing: 8) {
                Text("Unattributed activity")
                    .font(.system(size: 11))
                    .foregroundColor(PSTheme.textMuted)
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
            .padding(.vertical, 8)

            Divider().background(PSTheme.stroke)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups) { group in
                        groupRow(group)
                    }
                    if connections.isEmpty {
                        MiniPlaceholder(emptyMessage: emptyMessage)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            state.refreshAudit()
            reload()
        }
        .onChange(of: timeWindow) { _ in reload() }
    }

    /// Live snapshot for "All time"; the persisted trail once a window is chosen.
    private var connections: [Connection] {
        if timeWindow == .all {
            return state.connections
                .filter { $0.audienceId == nil }
                .sorted { $0.lastSeen > $1.lastSeen }
        }
        return state.unattributedHistory.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// One collapsible group per process. Unattributed rows have no stable
    /// audience id, so the key is the process identity string.
    private struct ProcessGroup: Identifiable {
        let key: String
        let name: String
        let icon: NSImage?
        let connections: [Connection]
        var id: String { key }
    }

    private var groups: [ProcessGroup] {
        var order: [String] = []
        var buckets: [String: [Connection]] = [:]
        for connection in connections {
            let raw = connection.processBundleId ?? connection.processPath ?? connection.processName
            let groupKey = raw.isEmpty ? "Unknown" : raw
            if buckets[groupKey] == nil { order.append(groupKey) }
            buckets[groupKey, default: []].append(connection)
        }
        return order.map { key in
            let conns = buckets[key] ?? []
            let first = conns.first
            let name = first.flatMap { $0.processName.isEmpty ? nil : $0.processName } ?? key
            let icon = first.flatMap {
                AppIcon.resolve(bundleId: $0.processBundleId, path: $0.processPath, name: $0.processName)
            }
            return ProcessGroup(key: key, name: name, icon: icon, connections: conns)
        }
    }

    private func groupRow(_ group: ProcessGroup) -> some View {
        VStack(spacing: 0) {
            Button {
                toggle(group.key)
            } label: {
                HStack(spacing: 8) {
                    if let icon = group.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundColor(PSTheme.textSecondary)
                            .frame(width: 16, height: 16)
                    }
                    Text(group.name)
                        .font(.system(size: 12))
                        .foregroundColor(PSTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(group.connections.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(PSTheme.textSecondary)
                    Image(systemName: expandedKeys.contains(group.key) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(PSTheme.textMuted)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if expandedKeys.contains(group.key) {
                VStack(spacing: 0) {
                    ForEach(Array(group.connections.prefix(15))) { connection in
                        MiniConnectionRow(connection: connection)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func toggle(_ key: String) {
        if expandedKeys.contains(key) {
            expandedKeys.remove(key)
        } else {
            expandedKeys.insert(key)
        }
    }

    private var emptyMessage: String {
        timeWindow == .all
            ? "Every observed connection is attributed to an audience."
            : "No unattributed connections in this time window."
    }

    private func reload() {
        guard timeWindow != .all else { return }
        state.loadUnattributedHistory(since: timeWindow.cutoff, until: nil)
    }
}
