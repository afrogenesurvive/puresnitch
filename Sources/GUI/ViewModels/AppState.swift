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
    @Published var audiences: [Audience] = []
    @Published var audienceSummaries: [AudienceSummary] = []
    @Published var proxyReport: ProxyExpectationReport?
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

    func recomputeAggregates() async {
        let conns = self.connections
        let knownAudiences = self.audiences
        var byProc: [String: (Int64, Int64, NSImage?)] = [:]
        var byDom: [String: (Int64, Int64)] = [:]
        var byCountry: [String: (String, Int64, Int64)] = [:]
        for c in conns {
            let pkey = c.processBundleId ?? c.processPath
            let cur = byProc[pkey] ?? (0, 0, nil)
            byProc[pkey] = (cur.0 + c.bytesIn, cur.1 + c.bytesOut, cur.2 ?? AppIcon.resolve(bundleId: c.processBundleId, path: c.processPath, name: c.processName))
            let dom = c.remoteHost.isEmpty ? c.remoteIP : c.remoteHost
            let cd = byDom[dom] ?? (0, 0)
            byDom[dom] = (cd.0 + c.bytesIn, cd.1 + c.bytesOut)
            if let cc = c.countryCode, !cc.isEmpty {
                let cur = byCountry[cc] ?? (c.country ?? cc, 0, 0)
                byCountry[cc] = (cur.0, cur.1 + c.bytesIn, cur.2 + c.bytesOut)
            }
        }
        topProcesses = byProc.map { (k, v) in
            ProcessStats(id: k, name: (k as NSString).lastPathComponent, bytesIn: v.0, bytesOut: v.1, icon: v.2)
        }.sorted { $0.total > $1.total }.prefix(20).map { $0 }
        topDomains = byDom.map { (k, v) in
            DomainStats(id: k, domain: k, bytesIn: v.0, bytesOut: v.1)
        }.sorted { $0.total > $1.total }.prefix(20).map { $0 }
        topCountries = byCountry.map { (cc, v) in
            CountryStats(id: cc, country: v.0, countryCode: cc, bytesIn: v.1, bytesOut: v.2)
        }.sorted { $0.total > $1.total }.prefix(20).map { $0 }

        // Live per-audience rollup. Audiences with no traffic are still listed:
        // "declared but silent" is exactly what an audit needs to see.
        var byAudience: [UUID: (count: Int, bytesIn: Int64, bytesOut: Int64, proxied: Int, first: Date?, last: Date?)] = [:]
        for c in conns {
            guard let id = c.audienceId else { continue }
            var entry = byAudience[id] ?? (0, 0, 0, 0, nil, nil)
            entry.count += 1
            entry.bytesIn += c.bytesIn
            entry.bytesOut += c.bytesOut
            if c.remotePort == AppConstants.devmonProxyPort { entry.proxied += 1 }
            entry.first = min(entry.first ?? c.firstSeen, c.firstSeen)
            entry.last = max(entry.last ?? c.lastSeen, c.lastSeen)
            byAudience[id] = entry
        }
        audienceSummaries = knownAudiences.map { audience in
            let stats = byAudience[audience.id]
            return AudienceSummary(
                id: audience.id,
                name: audience.name,
                kind: audience.kind,
                icon: audience.icon,
                connectionCount: stats?.count ?? 0,
                bytesIn: stats?.bytesIn ?? 0,
                bytesOut: stats?.bytesOut ?? 0,
                proxiedCount: stats?.proxied ?? 0,
                firstSeen: stats?.first,
                lastSeen: stats?.last
            )
        }.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.name < rhs.name
        }
    }

}
