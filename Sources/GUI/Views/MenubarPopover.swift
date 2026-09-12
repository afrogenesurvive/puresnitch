import SwiftUI

struct MenubarPopoverView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var windows: WindowManager
    let close: () -> Void
    /// Wired to `MenubarPanelController`. The view owns the grip because that is
    /// where the gesture has to live; the controller owns the frame.
    let onResize: (CGSize) -> Void
    let onResizeEnd: () -> Void

    @State private var showModePicker = false
    @State private var showThemePicker = false
    @State private var tab: PopoverTab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            HelperBanner(compact: true)

            PopoverTabBar(selection: $tab)

            switch tab {
            case .overview:
                overviewTab
            case .network:
                MiniNetworkMonitorView(close: close)
            case .rules:
                MiniRulesView(close: close)
            case .ai:
                MiniAuditView(close: close)
            }
        }
        .frame(minWidth: MenubarPanelController.minimumSize.width,
               minHeight: MenubarPanelController.minimumSize.height)
        // A strip along the bottom belongs to the resize grip. Without it the
        // grip sits on top of the last row of the Overview tab and eats clicks
        // meant for "PureSnitch Settings…".
        .padding(.bottom, 16)
        .background(PSTheme.bgPrimary)
        // The panel is a transparent borderless window, so the corners and the
        // edge have to be drawn here; AppKit draws nothing for it.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PSTheme.stroke, lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            PanelResizeGrip(onDrag: onResize, onEnd: onResizeEnd)
        }
        .preferredColorScheme(state.themeMode.colorScheme)
    }

    /// Everything that used to be the whole popover.
    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    trafficGraph
                        .padding(.horizontal, 12)

                    Text("Recent Network Activity")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(PSTheme.textSecondary)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

                    recentActivityList

                    HStack {
                        RecentDeniedRow {
                            close()
                            windows.showNetworkMonitor()
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .frame(maxHeight: .infinity)

            Divider().background(PSTheme.stroke)

            fullWindowButtons
        }
    }

    /// The "existing views" half of the deal: every one of these still opens the
    /// full window, so the tabs never become the only way to reach anything.
    private var fullWindowButtons: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { close(); windows.showRulesManager() }) {
                HStack {
                    Text("Manage Rules…").font(.system(size: 13))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundColor(PSTheme.textPrimary)

            Button(action: { close(); windows.showNetworkMonitor() }) {
                HStack {
                    Text("Network Monitor…").font(.system(size: 13))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundColor(PSTheme.textPrimary)

            Button(action: { close(); windows.showAudit() }) {
                HStack {
                    Text("AI Activity…").font(.system(size: 13))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundColor(PSTheme.textPrimary)

            Button(action: { close(); windows.showSettings() }) {
                HStack {
                    Text("PureSnitch Settings…").font(.system(size: 13))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundColor(PSTheme.textPrimary)
        }
        .padding(.bottom, 8)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            ModeButton(mode: state.mode, showing: $showModePicker)
                .popover(isPresented: $showModePicker, arrowEdge: .bottom) {
                    ModePicker(current: state.mode) { m in
                        state.setMode(m)
                        showModePicker = false
                    }
                }
            Spacer()
            Button { showThemePicker.toggle() } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 14))
                    .foregroundColor(PSTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(PSTheme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Appearance")
            .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
                ThemePicker(current: state.themeMode) { mode in
                    state.themeMode = mode
                    showThemePicker = false
                }
            }
            Button(action: { close(); windows.showSettings() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(PSTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(PSTheme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("PureSnitch Settings")
            Button(action: { close(); windows.showNetworkMonitor() }) {
                Image(systemName: "globe")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color(red: 0.30, green: 0.55, blue: 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Network Monitor")
        }
    }

    private var trafficGraph: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(PSTheme.bgTertiary)
            TrafficBarsChart(history: state.trafficHistory)
                .padding(8)
            VStack(alignment: .leading) {
                HStack {
                    Text(PSFormat.bytes(state.totalOut))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(PSTheme.outPillFill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Spacer()
                }
                Spacer()
                HStack {
                    Text(PSFormat.bytes(state.totalIn))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(PSTheme.inPillFill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Spacer()
                }
                HStack {
                    Text("5 minutes ago")
                        .font(.system(size: 10))
                        .foregroundColor(PSTheme.textMuted)
                    Spacer()
                    Text("now")
                        .font(.system(size: 10))
                        .foregroundColor(PSTheme.textMuted)
                }
            }
            .padding(10)
        }
        .frame(height: 160)
    }

    private var recentActivityList: some View {
        VStack(spacing: 0) {
            ForEach(uniqueRecentProcesses().prefix(3)) { ps in
                HStack(spacing: 10) {
                    if let icon = ps.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").foregroundColor(PSTheme.textSecondary)
                            .frame(width: 18, height: 18)
                    }
                    Text(ps.name).font(.system(size: 13))
                        .foregroundColor(PSTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 5)
            }
        }
    }

    private func uniqueRecentProcesses() -> [AppState.ProcessStats] {
        state.topProcesses
    }
}

struct ModeButton: View {
    let mode: AppMode
    @Binding var showing: Bool
    var body: some View {
        Button(action: { showing.toggle() }) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(modeColor)
                    Image(systemName: modeIcon).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                }.frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mode").font(.system(size: 10)).foregroundColor(PSTheme.textMuted)
                    Text(modeLabel).font(.system(size: 13, weight: .semibold)).foregroundColor(PSTheme.textPrimary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(PSTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    private var modeColor: Color {
        switch mode {
        case .alert: return PSTheme.accentYellow
        case .silentAllow: return PSTheme.accentGreen
        case .silentDeny: return PSTheme.accentRed
        }
    }
    private var modeIcon: String {
        switch mode {
        case .alert: return "bell.fill"
        case .silentAllow: return "checkmark"
        case .silentDeny: return "xmark"
        }
    }
    private var modeLabel: String {
        switch mode {
        case .alert: return "Alert"
        case .silentAllow: return "Silent Allow"
        case .silentDeny: return "Silent Deny"
        }
    }
}

struct ModePicker: View {
    let current: AppMode
    let onPick: (AppMode) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").foregroundColor(PSTheme.textSecondary)
                Text("Mode").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(PSTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(PSTheme.bgTertiary)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                pickerRow(.alert, "Alert", "bell.fill", PSTheme.accentYellow)
                pickerRow(.silentAllow, "Silent Allow", "checkmark", PSTheme.accentGreen)
                pickerRow(.silentDeny, "Silent Deny", "xmark", PSTheme.accentRed)
            }
            .padding(.vertical, 8)
        }
        .frame(width: 240)
        .background(PSTheme.bgPrimary)
    }
    private func pickerRow(_ m: AppMode, _ label: String, _ icon: String, _ color: Color) -> some View {
        Button(action: { onPick(m) }) {
            HStack(spacing: 12) {
                if current == m {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundColor(PSTheme.textPrimary)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                ZStack {
                    Circle().fill(color)
                    Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                }.frame(width: 22, height: 22)
                Text(label).font(.system(size: 13)).foregroundColor(PSTheme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

/// Mirrors `ModePicker` on purpose. A SwiftUI `Menu` would be less code, but a
/// native `NSMenu` presents outside the panel and can dismiss it mid-selection —
/// and this file already proved the nested-popover route works.
struct ThemePicker: View {
    let current: ThemeMode
    let onPick: (ThemeMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "circle.lefthalf.filled").foregroundColor(PSTheme.textSecondary)
                Text("Appearance").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(PSTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(PSTheme.bgTertiary)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                pickerRow(.system, "System", "laptopcomputer")
                pickerRow(.light, "Light", "sun.max.fill")
                pickerRow(.dark, "Dark", "moon.fill")
            }
            .padding(.vertical, 8)
        }
        .frame(width: 200)
        .background(PSTheme.bgPrimary)
    }

    private func pickerRow(_ mode: ThemeMode, _ label: String, _ icon: String) -> some View {
        Button { onPick(mode) } label: {
            HStack(spacing: 12) {
                if current == mode {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundColor(PSTheme.textPrimary)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(PSTheme.textSecondary)
                    .frame(width: 18)
                Text(label).font(.system(size: 13)).foregroundColor(PSTheme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

struct TrafficBarsChart: View {
    let history: [TrafficSample]
    var body: some View {
        GeometryReader { geo in
            let samples = Array(history.suffix(80))
            let count = max(samples.count, 1)
            let availW = geo.size.width
            let barW = max(2, (availW - CGFloat(count - 1) * 1.5) / CGFloat(count))
            let midY = geo.size.height / 2
            let maxIn = max(1, CGFloat(samples.map { $0.bytesIn }.max() ?? 1))
            let maxOut = max(1, CGFloat(samples.map { $0.bytesOut }.max() ?? 1))
            ZStack(alignment: .center) {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(0..<samples.count, id: \.self) { i in
                        let s = samples[i]
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(LinearGradient(colors: [Color.purple.opacity(0.95), Color.purple.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                                .frame(width: barW, height: max(2, CGFloat(s.bytesOut)/maxOut * midY * 0.95))
                            Rectangle()
                                .fill(LinearGradient(colors: [Color.blue.opacity(0.7), Color.blue.opacity(0.95)], startPoint: .top, endPoint: .bottom))
                                .frame(width: barW, height: max(2, CGFloat(s.bytesIn)/maxIn * midY * 0.95))
                        }
                    }
                }
            }
        }
    }
}
