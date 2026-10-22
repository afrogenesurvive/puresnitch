import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var mode: AppMode = .alert
    @Published var connections: [Connection] = []
    @Published var rules: [Rule] = []
    @Published var blocklists: [BlocklistInfo] = []
    @Published var profiles: [Profile] = []
    @Published var activeProfile: String = "default"
    @Published var trafficHistory: [TrafficSample] = []
    @Published var currentIn: Int64 = 0
    @Published var currentOut: Int64 = 0
    @Published var totalIn: Int64 = 0
    @Published var totalOut: Int64 = 0
    @Published var deniedCount: Int = 0
    @Published var unconfirmedCount: Int = 0
    @Published var incomingCount: Int = 0
    @Published var pendingAlerts: [PendingAlert] = []
    @Published var helperConnected: Bool = false
    /// Whether the helper is observing traffic (lsof/nettop polling). True on
    /// launch; the menu-bar switch turns the whole monitor off and on.
    @Published var monitoringEnabled: Bool = true
    @Published var helperStatusLoaded: Bool = false
    @Published var helperInstallState: HelperInstallState = .unknown
    @Published var helperNeedsRepair: Bool = false
    @Published var pfctlEnabled: Bool = false
    @Published var dnsProxyEnabled: Bool = false
    /// Helper-owned IP geolocation, mirrored from `HelperStatus`. `enabled` is
    /// the user's preference; `available` is false when the build shipped
    /// without the database, which the Settings row reports separately.
    @Published var geoLookupEnabled: Bool = false
    @Published var geoDatabaseAvailable: Bool = false
    @Published var enforcementRequestInFlight: Bool = false
    @Published var modeRequestInFlight: Bool = false
    @Published var logs: [LogEntry] = []
    @Published var topProcesses: [ProcessStats] = []
    @Published var topDomains: [DomainStats] = []
    @Published var topCountries: [CountryStats] = []
    /// Per-process cumulative bytes from `nettop`, keyed by PID. This is the
    /// single source of every byte figure in the UI: the `lsof` connections
    /// carry no byte counters of their own.
    @Published var processTrafficByPID: [Int32: ProcessTraffic] = [:]
    @Published var audiences: [Audience] = []
    @Published var audienceSummaries: [AudienceSummary] = []
    @Published var proxyReport: ProxyExpectationReport?
    /// A time window pulled from the persisted audit trail. The live snapshot the
    /// helper pushes is capped, so a window can reach rows the UI never saw.
    @Published var auditHistory: [Connection] = []
    @Published var selectedAudienceId: UUID?
    @Published var searchQuery: String = ""

    /// Menu-bar speed readout. Off by default: the status item is a plain
    /// template glyph unless the user asks for numbers.
    @Published var showSpeedsInMenuBar: Bool = UserDefaults.standard.bool(forKey: Prefs.showSpeeds) {
        didSet { UserDefaults.standard.set(showSpeedsInMenuBar, forKey: Prefs.showSpeeds) }
    }
    @Published var showAlertsOnAllSpaces: Bool = UserDefaults.standard.object(forKey: Prefs.alertsAllSpaces) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAlertsOnAllSpaces, forKey: Prefs.alertsAllSpaces) }
    }

    /// Appearance. `.system` — the default — follows macOS. `applyTheme()` fans
    /// this out to AppKit, which is what makes window chrome, the menu-bar
    /// panel, `NSMenu` and the alert panel agree with what SwiftUI draws.
    @Published var themeMode: ThemeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: Prefs.themeMode) ?? "") ?? .system {
        didSet {
            guard oldValue != themeMode else { return }
            UserDefaults.standard.set(themeMode.rawValue, forKey: Prefs.themeMode)
            applyTheme()
        }
    }

    /// Root/helper-owned desired state. Status assigns this directly; only the
    /// explicit request method below sends a mutation.
    @Published var enforcementEnabled: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var helperConnectionEpoch = 0
    private var rulesRequestGeneration = 0
    private var historyRequestGeneration = 0
    private var hasLoadedRulesFromHelper = false
    private var hasLoadedStatusFromHelper = false

    func requestEnforcementDesired(_ value: Bool) {
        guard value != enforcementEnabled,
              !enforcementRequestInFlight,
              !modeRequestInFlight else { return }
        enforcementEnabled = value
        enforcementRequestInFlight = true
        helper.setEnforcementEnabled(value)
    }

    /// Pins AppKit's appearance so everything SwiftUI can't reach matches the
    /// rest of the app. The system path has to *assign* nil — skipping the
    /// assignment would leave a previously pinned appearance in place forever.
    func applyTheme() {
        guard let name = themeMode.appearanceName else {
            NSApp.appearance = nil
            return
        }
        NSApp.appearance = NSAppearance(named: name)
    }

    enum Prefs {
        static let showSpeeds = "PSShowSpeedsInMenuBar"
        static let alertsAllSpaces = "PSShowAlertsOnAllSpaces"
        static let themeMode = "PSThemeMode"
    }

    let helper = HelperClient()
    private let store: RuleStore? = {
        try? RuleStore(path: AppConstants.supportDir.appendingPathComponent("ui-cache.sqlite").path)
    }()

    struct PendingAlert: Identifiable {
        let id = UUID()
        let connection: Connection
        let reply: (Bool, Bool) -> Void
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: String
        let message: String
    }

    struct ProcessStats: Identifiable {
        let id: String
        let name: String
        let bytesIn: Int64
        let bytesOut: Int64
        let icon: NSImage?
        /// Every PID seen for this process. A row aggregates by bundle id or
        /// executable path, so more than one PID can land in a single row.
        var pids: [Int32] = []
        var total: Int64 { bytesIn + bytesOut }
    }

    struct DomainStats: Identifiable {
        let id: String
        let domain: String
        let bytesIn: Int64
        let bytesOut: Int64
        var total: Int64 { bytesIn + bytesOut }
    }

    struct CountryStats: Identifiable {
        let id: String
        let country: String
        let countryCode: String
        let bytesIn: Int64
        let bytesOut: Int64
        var total: Int64 { bytesIn + bytesOut }
    }

    init() {
        helper.state = self
        helper.$status
            .compactMap { $0 }
            .sink { [weak self] status in
                self?.applyHelperStatus(status)
            }
            .store(in: &cancellables)
    }

    /// Status is authoritative after reconnect/restart. Assigning mode directly
    /// avoids sending the same value back to the helper in a feedback loop.
    private func applyHelperStatus(_ status: HelperStatus) {
        guard status.version == AppConstants.version else { return }
        let firstStatusInEpoch = !hasLoadedStatusFromHelper
        let modeChanged = mode != status.mode
        pfctlEnabled = status.pfctlActive
        dnsProxyEnabled = status.dnsProxyActive
        enforcementEnabled = status.enforcementDesired
        monitoringEnabled = status.running
        geoLookupEnabled = status.geoLookupEnabled
        geoDatabaseAvailable = status.geoDatabaseAvailable
        if !helper.keepsEnforcementControlsLocked {
            enforcementRequestInFlight = false
        }
        hasLoadedStatusFromHelper = true
        helperStatusLoaded = true
        mode = status.mode
        if !helper.keepsModeControlsLocked {
            modeRequestInFlight = false
        }
        if firstStatusInEpoch || modeChanged {
            syncSharedRules()
        }
    }

    /// Called before any request is sent on a replacement XPC connection.
    /// A snapshot is published only after both status and rules arrive from
    /// this epoch, preserving the prior last-known-good policy in between.
    func beginHelperConnectionEpoch() {
        helperConnectionEpoch &+= 1
        rulesRequestGeneration &+= 1
        hasLoadedRulesFromHelper = false
        hasLoadedStatusFromHelper = false
        helperStatusLoaded = false
    }

    /// Runs once the helper is reachable. Monitoring only: pf enforcement and
    /// the optional local DNS proxy stay behind an explicit Settings opt-in.
    func bootstrap() {
        helper.startMonitoring()
        refreshRules()
        refreshAudit()
    }

    /// Starts or stops observation entirely. Off means no lsof/nettop polling:
    /// the helper observes nothing and pushes no traffic. Optimistic like the
    /// mode switch — the next status poll (every 3 s) puts the authoritative
    /// value back if the helper refused.
    func setMonitoringEnabled(_ enabled: Bool) {
        guard enabled != monitoringEnabled else { return }
        monitoringEnabled = enabled
        if enabled {
            helper.startMonitoring()
        } else {
            helper.stopMonitoring()
        }
    }

    /// Audience list plus the declaration-vs-observation report. Both are cheap
    /// and both are re-read on demand so the audit window never shows stale
    /// routing facts.
    func refreshAudit() {
        helper.listAudiences { [weak self] audiences in
            guard let self else { return }
            self.audiences = audiences
            Task { await self.recomputeAggregates() }
        }
        helper.proxyExpectationReport { [weak self] report in
            self?.proxyReport = report
        }
    }

    /// Pulls a time window from the persisted audit trail. The live snapshot is
    /// capped at a few hundred rows, so a window can legitimately reach rows the
    /// UI never received.
    func loadAuditHistory(since: Date?, until: Date?) {
        historyRequestGeneration &+= 1
        let generation = historyRequestGeneration
        let query = ConnectionQuery(since: since, until: until, limit: 2_000)
        helper.connectionHistory(query) { [weak self] connections in
            guard let self, generation == self.historyRequestGeneration else { return }
            self.auditHistory = connections
        }
    }

    func rediscoverAudiences() {
        helper.rediscoverAudiences { [weak self] audiences in
            guard let self else { return }
            self.audiences = audiences
            self.refreshAudit()
        }
    }

    /// "Watch this process": build a manual audience from an observed connection
    /// so an agent or MCP server that no configuration names can still be pulled
    /// into the audit.
    @discardableResult
    func watchProcess(of connection: Connection) -> Audience? {
        var matchers: [AudienceMatcher] = []
        if !connection.processPath.isEmpty {
            matchers.append(AudienceMatcher(kind: .processPathPrefix, pattern: connection.processPath))
        }
        if let cwd = connection.processCwd, !cwd.isEmpty {
            matchers.append(AudienceMatcher(kind: .cwdPrefix, pattern: cwd))
        }
        if let commandLine = connection.processCommandLine,
           let token = Self.scriptToken(in: commandLine), !token.isEmpty {
            matchers.append(AudienceMatcher(kind: .commandLineContains, pattern: token))
        }
        guard !matchers.isEmpty else {
            appendLog(level: "error", message: "This connection exposes no process detail to watch yet.")
            return nil
        }

        let base = "watch:" + (connection.processName.isEmpty ? "unknown" : connection.processName)
        let audience = Audience(
            name: uniqueAudienceName(base),
            icon: "eye",
            kind: .adHoc,
            source: .manual,
            matchers: matchers,
            notes: "Created from the connection list"
        )
        guard (try? audience.validateForPersistence()) != nil else {
            appendLog(level: "error", message: "The watched process could not be turned into an audience.")
            return nil
        }
        audiences.append(audience)          // optimistic: the list updates even if the helper is down
        helper.addAudience(audience)
        selectedAudienceId = audience.id
        refreshAudit()
        return audience
    }

    func removeAudience(id: UUID) {
        audiences.removeAll { $0.id == id }
        audienceSummaries.removeAll { $0.id == id }
        if selectedAudienceId == id { selectedAudienceId = nil }
        helper.removeAudience(id: id)
        refreshAudit()
    }

    func setAudienceEnabled(id: UUID, enabled: Bool) {
        if let index = audiences.firstIndex(where: { $0.id == id }) {
            audiences[index].enabled = enabled
        }
        helper.setAudienceEnabled(id: id, enabled: enabled)
        refreshAudit()
    }

    /// The script an interpreter was asked to run, which is what identifies an
    /// MCP server: `node .../mcp/sample/index.js` shares its executable with
    /// every other node process on the machine.
    static func scriptToken(in commandLine: String) -> String? {
        let scripts = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".sh"]
        for token in commandLine.split(separator: " ") {
            let candidate = String(token)
            guard candidate.hasPrefix("/"), scripts.contains(where: { candidate.hasSuffix($0) }) else { continue }
            return candidate
        }
        return nil
    }

    private func uniqueAudienceName(_ base: String) -> String {
        let taken = Set(audiences.map(\.name))
        guard taken.contains(base) else { return base }
        for suffix in 2...99 {
            let candidate = "\(base) \(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    func refreshRules() {
        let epoch = helperConnectionEpoch
        rulesRequestGeneration &+= 1
        let generation = rulesRequestGeneration
        helper.listRules { [weak self] rules in
            guard let self,
                  epoch == self.helperConnectionEpoch,
                  generation == self.rulesRequestGeneration else { return }
            self.rules = rules
            self.hasLoadedRulesFromHelper = true
            self.syncSharedRules()
        }
    }

    /// Mirror the active rules + mode into the app-group container so the
    /// Network System Extension (which can't read the helper DB) can enforce them.
    func syncSharedRules() {
        // Preserve the last-known-good app-group snapshot until the helper has
        // actually answered. Status often arrives before the rule list.
        guard hasLoadedRulesFromHelper, hasLoadedStatusFromHelper else { return }
        SharedRuleBridge.write(mode: mode, rules: rules)
    }

    func setMode(_ m: AppMode) {
        guard m != mode,
              !modeRequestInFlight,
              !enforcementRequestInFlight else { return }
        modeRequestInFlight = true
        helper.setMode(m)
    }

    /// Geolocation is a display preference with no enforcement consequence, so
    /// this is optimistic and has none of the generation/timeout machinery the
    /// enforcement toggle needs: if the helper refuses, the next status poll
    /// (every 3 s) puts the authoritative value back.
    func requestGeoLookupEnabled(_ value: Bool) {
        guard value != geoLookupEnabled else { return }
        geoLookupEnabled = value
        helper.setGeoLookupEnabled(value)
    }

    func updateConnections(_ conns: [Connection]) {
        connections = conns
        deniedCount = conns.filter { $0.status == .denied }.count
        incomingCount = conns.filter { $0.direction == .incoming }.count
        unconfirmedCount = conns.filter { $0.status == .pending }.count
        Task { await self.recomputeAggregates() }
    }

    func appendSample(_ s: TrafficSample) {
        trafficHistory.append(s)
        if trafficHistory.count > 600 { trafficHistory.removeFirst(trafficHistory.count - 600) }
        currentIn = s.bytesIn
        currentOut = s.bytesOut
        totalIn &+= s.bytesIn
        totalOut &+= s.bytesOut
    }

    func presentAlert(for c: Connection, reply: @escaping (Bool, Bool) -> Void) {
        pendingAlerts.append(PendingAlert(connection: c, reply: reply))
    }

    func resolveAlert(_ alert: PendingAlert, allow: Bool, remember: Bool) {
        var rememberedRule: Rule?
        if remember {
            let rawHost = alert.connection.remoteHost
            let rawIP = alert.connection.remoteIP
            let hostIsIPv4 = Rule.isIPv4Address(rawHost)
            let hasHost = !rawHost.isEmpty && !hostIsIPv4
            let endpointIP = hostIsIPv4 ? rawHost : rawIP
            let hasIP = !endpointIP.isEmpty
            if !hasHost && !hasIP {
                appendLog(level: "error", message: "Decision applied once but was not remembered: the connection has no remote endpoint.")
            } else if Rule.isIPv6Address(rawHost) || Rule.isIPv6Address(endpointIP) {
                appendLog(level: "error", message: "Decision applied once but was not remembered: IPv6 rules are not supported in this release.")
            } else {
                let rule = Rule(
                    processBundleId: alert.connection.processBundleId,
                    processPath: alert.connection.processPath,
                    processName: alert.connection.processName,
                    remoteHost: hasHost ? rawHost : nil,
                    remoteIP: hasHost ? nil : endpointIP,
                    remotePort: alert.connection.remotePort > 0 ? alert.connection.remotePort : nil,
                    direction: alert.connection.direction,
                    action: allow ? .allow : .deny,
                    scope: hasHost ? .domain : .ip,
                    priority: 100,
                    profile: activeProfile,
                    groupName: nil,
                    notes: "Created from alert"
                )
                do {
                    try rule.validateForPersistence()
                    rememberedRule = rule
                } catch {
                    appendLog(level: "error", message: "Decision applied once but was not remembered: \(error.localizedDescription)")
                }
            }
        }

        alert.reply(allow, rememberedRule != nil)
        pendingAlerts.removeAll { $0.id == alert.id }
        if let rule = rememberedRule {
            rules.append(rule)        // optimistic: extension sees it even if the helper is down
            helper.addRule(rule)
            syncSharedRules()
            refreshRules()
        }
    }

    func appendLog(level: String, message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logs.append(entry)
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
    }

    /// Per-process byte counters arrive on their own cadence (once per `nettop`
    /// frame), so they are folded into the same aggregate pass as connections.
    func updateProcessTraffic(_ traffic: [ProcessTraffic]) {
        processTrafficByPID = Dictionary(
            traffic.map { ($0.pid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        Task { await self.recomputeAggregates() }
    }

    func recomputeAggregates() async {
        let conns = self.connections
        let knownAudiences = self.audiences
        let traffic = self.processTrafficByPID

        // nettop counts bytes per process, not per socket, so a byte figure is
        // attributed by the *distinct* PIDs in each bucket: a PID is counted
        // once per bucket, never once per connection. Without this, a process
        // with several open sockets would be multiplied by the number of rows
        // it appears in. The result is an upper bound for destinations (a
        // process talking to N hosts contributes its whole total to each), which
        // is the honest reading of a per-process counter.
        func bytes(for pids: Set<Int32>) -> (inBytes: Int64, outBytes: Int64) {
            var i: Int64 = 0
            var o: Int64 = 0
            for pid in pids {
                guard let t = traffic[pid] else { continue }
                i += t.bytesIn
                o += t.bytesOut
            }
            return (i, o)
        }

        var procPIDs: [String: (pids: Set<Int32>, icon: NSImage?, name: String)] = [:]
        var domPIDs: [String: Set<Int32>] = [:]
        var countryPIDs: [String: (name: String, pids: Set<Int32>)] = [:]
        var audiencePIDs: [UUID: (pids: Set<Int32>, count: Int, proxied: Int, first: Date?, last: Date?)] = [:]

        for c in conns {
            let pkey = c.processBundleId ?? c.processPath
            let fallbackName: String = {
                let preferred = traffic[c.pid]?.processName ?? c.processName
                return preferred.isEmpty ? (pkey as NSString).lastPathComponent : preferred
            }()
            var proc = procPIDs[pkey] ?? (pids: [], icon: nil, name: fallbackName)
            proc.pids.insert(c.pid)
            if proc.name.isEmpty { proc.name = fallbackName }
            if proc.icon == nil {
                proc.icon = AppIcon.resolve(bundleId: c.processBundleId, path: c.processPath, name: c.processName)
            }
            procPIDs[pkey] = proc

            let dom = c.remoteHost.isEmpty ? c.remoteIP : c.remoteHost
            domPIDs[dom, default: []].insert(c.pid)

            if let cc = c.countryCode, !cc.isEmpty {
                var entry = countryPIDs[cc] ?? (c.country ?? cc, [])
                entry.pids.insert(c.pid)
                countryPIDs[cc] = entry
            }

            if let id = c.audienceId {
                var entry = audiencePIDs[id] ?? ([], 0, 0, nil, nil)
                entry.pids.insert(c.pid)
                entry.count += 1
                if c.remotePort == AppConstants.devmonProxyPort { entry.proxied += 1 }
                entry.first = min(entry.first ?? c.firstSeen, c.firstSeen)
                entry.last = max(entry.last ?? c.lastSeen, c.lastSeen)
                audiencePIDs[id] = entry
            }
        }

        topProcesses = procPIDs.map { key, value in
            let totals = bytes(for: value.pids)
            return ProcessStats(
                id: key,
                name: value.name,
                bytesIn: totals.inBytes,
                bytesOut: totals.outBytes,
                icon: value.icon,
                pids: value.pids.sorted()
            )
        }.sorted { $0.total > $1.total }.prefix(20).map { $0 }

        topDomains = domPIDs.map { domain, pids in
            let totals = bytes(for: pids)
            return DomainStats(id: domain, domain: domain, bytesIn: totals.inBytes, bytesOut: totals.outBytes)
        }.sorted { $0.total > $1.total }.prefix(20).map { $0 }

        topCountries = countryPIDs.map { code, value in
            let totals = bytes(for: value.pids)
            return CountryStats(id: code, country: value.name, countryCode: code, bytesIn: totals.inBytes, bytesOut: totals.outBytes)
        }.sorted { $0.total > $1.total }.prefix(20).map { $0 }

        // Live per-audience rollup. Audiences with no traffic are still listed:
        // "declared but silent" is exactly what an audit needs to see.
        audienceSummaries = knownAudiences.map { audience in
            let entry = audiencePIDs[audience.id]
            let totals = bytes(for: entry?.pids ?? [])
            return AudienceSummary(
                id: audience.id,
                name: audience.name,
                kind: audience.kind,
                icon: audience.icon,
                connectionCount: entry?.count ?? 0,
                bytesIn: totals.inBytes,
                bytesOut: totals.outBytes,
                proxiedCount: entry?.proxied ?? 0,
                firstSeen: entry?.first,
                lastSeen: entry?.last
            )
        }.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.name < rhs.name
        }
    }

}
