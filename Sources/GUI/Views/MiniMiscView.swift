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
                    ForEach(Array(connections.prefix(60))) { connection in
                        MiniConnectionRow(connection: connection)
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
