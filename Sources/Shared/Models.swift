import Foundation
import Darwin

public enum RuleAction: String, Codable, CaseIterable, Sendable {
    case allow
    case deny
    case ask
}

public enum RuleDirection: String, Codable, CaseIterable, Sendable {
    case outgoing
    case incoming
    case any
}

public enum RuleScope: String, Codable, CaseIterable, Sendable {
    case process
    case domain
    case ip
    case port
    case any
}

public enum AppMode: String, Codable, CaseIterable, Sendable {
    case alert
    case silentAllow
    case silentDeny
}

public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var processBundleId: String?
    public var processPath: String?
    public var processName: String?
    public var remoteHost: String?
    public var remoteIP: String?
    public var remotePort: Int?
    public var direction: RuleDirection
    public var action: RuleAction
    public var scope: RuleScope
    public var priority: Int
    public var profile: String
    public var groupName: String?
    public var notes: String?
    public var enabled: Bool
    public var temporary: Bool
    public var createdAt: Date
    public var expiresAt: Date?
    public var lastUsedAt: Date?
    public var hitCount: Int

    public init(
        id: UUID = UUID(),
        processBundleId: String? = nil,
        processPath: String? = nil,
        processName: String? = nil,
        remoteHost: String? = nil,
        remoteIP: String? = nil,
        remotePort: Int? = nil,
        direction: RuleDirection = .outgoing,
        action: RuleAction = .ask,
        scope: RuleScope = .domain,
        priority: Int = 100,
        profile: String = "default",
        groupName: String? = nil,
        notes: String? = nil,
        enabled: Bool = true,
        temporary: Bool = false,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        lastUsedAt: Date? = nil,
        hitCount: Int = 0
    ) {
        self.id = id
        self.processBundleId = processBundleId
        self.processPath = processPath
        self.processName = processName
        self.remoteHost = remoteHost
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.direction = direction
        self.action = action
        self.scope = scope
        self.priority = priority
        self.profile = profile
        self.groupName = groupName
        self.notes = notes
        self.enabled = enabled
        self.temporary = temporary
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.hitCount = hitCount
    }
}

public enum RuleValidationError: Error, LocalizedError, Sendable {
    case invalidRemoteHost
    case invalidRemoteIP
    case invalidRemotePort

    public var errorDescription: String? {
        switch self {
        case .invalidRemoteHost:
            return "The remote host is not a supported DNS, IPv4, or CIDR pattern."
        case .invalidRemoteIP:
            return "The remote IP is not a canonical IPv4 address or CIDR."
        case .invalidRemotePort:
            return "The remote port must be between 0 and 65535."
        }
    }
}

public extension Rule {
    /// Reject untrusted endpoint text before it can reach the root helper and
    /// become part of a pf ruleset. The helper must apply the same validation;
    /// this UI-side check gives immediate feedback and avoids optimistic state.
    func validateForPersistence() throws {
        if let host = remoteHost, !host.isEmpty,
           !Self.isValidRemoteHost(host) {
            throw RuleValidationError.invalidRemoteHost
        }
        if let ip = remoteIP, !ip.isEmpty,
           !Self.isValidRemoteIP(ip) {
            throw RuleValidationError.invalidRemoteIP
        }
        if let port = remotePort, !(0...65_535).contains(port) {
            throw RuleValidationError.invalidRemotePort
        }
    }

    static func isValidRemoteHost(_ raw: String) -> Bool {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.utf8.count <= 253,
              raw.unicodeScalars.allSatisfy(\.isASCII) else { return false }

        if isValidRemoteIP(raw) { return true }
        if raw.contains("."), raw.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || byte == 46
        }) {
            return false
        }

        let host: Substring
        if raw.hasPrefix("*.") {
            host = raw.dropFirst(2)
        } else if raw.hasPrefix(".") {
            host = raw.dropFirst()
        } else {
            host = raw[...]
        }
        guard !host.isEmpty, !host.hasSuffix(".") else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                Self.isASCIIAlphaNumeric(byte) || byte == 45 // "-"
            }
        }
    }

    static func isValidRemoteIP(_ raw: String) -> Bool {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.unicodeScalars.allSatisfy(\.isASCII) else { return false }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard canonicalIPv4(String(parts[0])) != nil,
                  let prefix = Int(parts[1]), String(prefix) == parts[1],
                  (0...32).contains(prefix) else { return false }
            return true
        }
        guard parts.count == 1 else { return false }
        return isIPv4Address(raw)
    }

    static func isIPv4Address(_ raw: String) -> Bool {
        canonicalIPv4(raw) != nil
    }

    /// IPv6 is detected so the UI can make the current IPv4-only rule
    /// limitation explicit instead of accidentally persisting a domain rule.
    static func isIPv6Address(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return false }
        var candidate = raw[...]
        if candidate.first == "[", candidate.last == "]" {
            candidate = candidate.dropFirst().dropLast()
        }
        let addressText: Substring
        if let zoneSeparator = candidate.lastIndex(of: "%") {
            let zoneStart = candidate.index(after: zoneSeparator)
            guard zoneSeparator != candidate.startIndex, zoneStart < candidate.endIndex else { return false }
            addressText = candidate[..<zoneSeparator]
        } else {
            addressText = candidate
        }
        var address = in6_addr()
        return String(addressText).withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    private static func canonicalIPv4(_ raw: String) -> String? {
        let octets = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var canonical: [String] = []
        for octet in octets {
            guard let value = Int(octet), (0...255).contains(value),
                  String(value) == octet else { return nil }
            canonical.append(String(value))
        }
        return canonical.joined(separator: ".")
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) ||
        (65...90).contains(byte) ||
        (97...122).contains(byte)
    }
}

public struct Connection: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case allowed
        case denied
        case pending
        case established
        case closed
    }

    public var id: UUID
    public var pid: Int32
    public var processName: String
    public var processPath: String
    public var processBundleId: String?
    public var localPort: Int
    public var remoteHost: String
    public var remoteIP: String
    public var remotePort: Int
    public var direction: RuleDirection
    public var status: Status
    public var protocolName: String
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var country: String?
    public var countryCode: String?
    public var latitude: Double?
    public var longitude: Double?
    public var firstSeen: Date
    public var lastSeen: Date

    // MARK: Audience attribution (audit)
    /// Audience this connection was attributed to, if any. Optional so a payload
    /// produced by a helper without audience support still decodes.
    public var audienceId: UUID?
    public var audienceName: String?
    /// Git repository root derived from the process working directory.
    public var repoRoot: String?
    /// Working directory observed at capture time. This is a kernel fact, unlike
    /// `repoRoot`, which is derived from it.
    public var processCwd: String?
    /// Provider classification (for example `openai`). Populated once DNS/SNI
    /// capture lands: the lsof-only path sees addresses, not hostnames.
    public var provider: String?
    /// Executable plus arguments, truncated. `lsof` reports only the command
    /// name, so this is what lets an audience distinguish a plain `node` from
    /// `node .../mcp/sample/index.js`.
    public var processCommandLine: String?

    public init(
        id: UUID = UUID(),
        pid: Int32,
        processName: String,
        processPath: String,
        processBundleId: String? = nil,
        localPort: Int = 0,
        remoteHost: String = "",
        remoteIP: String = "",
        remotePort: Int = 0,
        direction: RuleDirection = .outgoing,
        status: Status = .pending,
        protocolName: String = "tcp",
        bytesIn: Int64 = 0,
        bytesOut: Int64 = 0,
        country: String? = nil,
        countryCode: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        audienceId: UUID? = nil,
        audienceName: String? = nil,
        repoRoot: String? = nil,
        processCwd: String? = nil,
        provider: String? = nil,
        processCommandLine: String? = nil
    ) {
        self.id = id
        self.pid = pid
        self.processName = processName
        self.processPath = processPath
        self.processBundleId = processBundleId
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.direction = direction
        self.status = status
        self.protocolName = protocolName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.country = country
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.audienceId = audienceId
        self.audienceName = audienceName
        self.repoRoot = repoRoot
        self.processCwd = processCwd
        self.provider = provider
        self.processCommandLine = processCommandLine
    }
}

// MARK: - Audiences

/// What kind of AI activity an audience represents. Presentation only: it
/// groups the audit sidebar and never affects matching.
public enum AudienceKind: String, Codable, CaseIterable, Sendable {
    case client
    case repo
    case mcpServer
    case service
    case adHoc
}

/// Where an audience came from. Manual audiences always outrank discovered ones
/// so a rescan can never shadow an edit the user made.
public enum AudienceSource: String, Codable, CaseIterable, Sendable {
    case autoDiscovered
    case manual
}

/// Audiences are audit-only in this release. `observe` records traffic;
/// `alert` is reserved for a later release. Neither blocks anything.
///
/// This is deliberately not a `RuleAction` case: adding one would change
/// `RuleMatcher` and the generated `pf` anchor.
public enum AudienceMode: String, Codable, CaseIterable, Sendable {
    case observe
    case alert
}

public enum AudienceMatcherKind: String, Codable, CaseIterable, Sendable {
    /// Matches when the process executable path starts with the pattern.
    case processPathPrefix
    /// Matches the enclosing `.app` bundle identifier exactly.
    case processBundleId
    /// Matches when the process working directory starts with the pattern.
    case cwdPrefix
    /// Matches when the captured command line contains the pattern. This is how
    /// an MCP server is identified: `lsof` sees `node`, and the server script
    /// path only exists in the arguments.
    case commandLineContains
    /// Matches the remote host or address, globs allowed.
    case remoteHost
    /// Matches the remote port exactly.
    case remotePort
}

/// One audience predicate.
///
/// Matchers in different groups are OR'd together, so an audience is the union
/// of everything its groups name. Matchers sharing a non-nil `group` must all
/// match, which is how "loopback host AND this port" is expressed without the
/// host matcher alone swallowing every local connection.
public struct AudienceMatcher: Codable, Hashable, Sendable {
    public var kind: AudienceMatcherKind
    public var pattern: String
    public var group: String?
    public init(kind: AudienceMatcherKind, pattern: String, group: String? = nil) {
        self.kind = kind
        self.pattern = pattern
        self.group = group
    }
}

public struct Audience: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var kind: AudienceKind
    public var source: AudienceSource
    public var mode: AudienceMode
    public var enabled: Bool
    public var matchers: [AudienceMatcher]
    public var notes: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "person.2",
        kind: AudienceKind = .adHoc,
        source: AudienceSource = .manual,
        mode: AudienceMode = .observe,
        enabled: Bool = true,
        matchers: [AudienceMatcher] = [],
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.kind = kind
        self.source = source
        self.mode = mode
        self.enabled = enabled
        self.matchers = matchers
        self.notes = notes
        self.createdAt = createdAt
    }
}

public enum AudienceValidationError: Error, LocalizedError, Sendable {
    case emptyName
    case nameTooLong
    case emptyPattern
    case patternTooLong
    case invalidPort
    case invalidHost

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "The audience name is empty."
        case .nameTooLong:
            return "The audience name is longer than 64 characters."
        case .emptyPattern:
            return "An audience matcher has an empty pattern."
        case .patternTooLong:
            return "An audience matcher pattern is longer than 512 characters."
        case .invalidPort:
            return "An audience port matcher must be a port number between 1 and 65535."
        case .invalidHost:
            return "An audience host matcher is not a supported DNS, IPv4, or CIDR pattern."
        }
    }
}

public extension Audience {
    /// Patterns reach the root helper and are persisted beside the rule store,
    /// so they get the same shape of validation `Rule` applies before storage.
    func validateForPersistence() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AudienceValidationError.emptyName }
        guard trimmedName.count <= 64 else { throw AudienceValidationError.nameTooLong }

        for matcher in matchers {
            let pattern = matcher.pattern
            guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AudienceValidationError.emptyPattern
            }
            guard pattern.count <= 512 else { throw AudienceValidationError.patternTooLong }
            switch matcher.kind {
            case .remotePort:
                guard let port = Int(pattern), (1...65_535).contains(port) else {
                    throw AudienceValidationError.invalidPort
                }
            case .remoteHost:
                guard Rule.isValidRemoteHost(pattern) || Rule.isIPv6Address(pattern) else {
                    throw AudienceValidationError.invalidHost
                }
            case .processPathPrefix, .processBundleId, .cwdPrefix, .commandLineContains:
                break
            }
        }
    }
}

/// Per-audience rollup for the audit UI. Computed on demand from stored
/// connections; it is a report, not a persisted row.
public struct AudienceSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AudienceKind
    public var icon: String
    public var connectionCount: Int
    public var bytesIn: Int64
    public var bytesOut: Int64
    /// Connections that reached the local dev_mon proxy port rather than the
    /// provider directly, which is the difference between a billed, recorded
    /// request and an invisible one.
    public var proxiedCount: Int
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(
        id: UUID,
        name: String,
        kind: AudienceKind,
        icon: String,
        connectionCount: Int = 0,
        bytesIn: Int64 = 0,
        bytesOut: Int64 = 0,
        proxiedCount: Int = 0,
        firstSeen: Date? = nil,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.icon = icon
        self.connectionCount = connectionCount
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.proxiedCount = proxiedCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    public var total: Int64 { bytesIn + bytesOut }
}

public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: AppMode
    public var icon: String
    public var isActive: Bool
    public init(id: UUID = UUID(), name: String, mode: AppMode = .alert, icon: String = "shield", isActive: Bool = false) {
        self.id = id
        self.name = name
        self.mode = mode
        self.icon = icon
        self.isActive = isActive
    }
}

public struct TrafficSample: Codable, Sendable {
    public let timestamp: Date
    public let bytesIn: Int64
    public let bytesOut: Int64
    public init(timestamp: Date, bytesIn: Int64, bytesOut: Int64) {
        self.timestamp = timestamp
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct HelperStatus: Codable, Sendable {
    public let version: String
    public let mode: AppMode
    public let enforcementDesired: Bool
    public let legacyPFMigrationPending: Bool
    public let legacyPFReconciliationSucceeded: Bool
    public let running: Bool
    public let pfctlActive: Bool
    public let dnsProxyActive: Bool
    public let dnsProxyPort: Int
    public let activeRules: Int
    public let blockedToday: Int
    public init(version: String, mode: AppMode, enforcementDesired: Bool, legacyPFMigrationPending: Bool, legacyPFReconciliationSucceeded: Bool, running: Bool, pfctlActive: Bool, dnsProxyActive: Bool, dnsProxyPort: Int, activeRules: Int, blockedToday: Int) {
        self.version = version
        self.mode = mode
        self.enforcementDesired = enforcementDesired
        self.legacyPFMigrationPending = legacyPFMigrationPending
        self.legacyPFReconciliationSucceeded = legacyPFReconciliationSucceeded
        self.running = running
        self.pfctlActive = pfctlActive
        self.dnsProxyActive = dnsProxyActive
        self.dnsProxyPort = dnsProxyPort
        self.activeRules = activeRules
        self.blockedToday = blockedToday
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case mode
        case enforcementDesired
        case legacyPFMigrationPending
        case legacyPFReconciliationSucceeded
        case running
        case pfctlActive
        case dnsProxyActive
        case dnsProxyPort
        case activeRules
        case blockedToday
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        mode = try container.decodeIfPresent(AppMode.self, forKey: .mode) ?? .alert
        enforcementDesired = try container.decodeIfPresent(Bool.self, forKey: .enforcementDesired) ?? false
        legacyPFMigrationPending = try container.decodeIfPresent(
            Bool.self,
            forKey: .legacyPFMigrationPending
        ) ?? false
        legacyPFReconciliationSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .legacyPFReconciliationSucceeded
        ) ?? false
        running = try container.decode(Bool.self, forKey: .running)
        pfctlActive = try container.decode(Bool.self, forKey: .pfctlActive)
        dnsProxyActive = try container.decode(Bool.self, forKey: .dnsProxyActive)
        dnsProxyPort = try container.decode(Int.self, forKey: .dnsProxyPort)
        activeRules = try container.decode(Int.self, forKey: .activeRules)
        blockedToday = try container.decode(Int.self, forKey: .blockedToday)
    }
}

public struct BlocklistInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var url: String
    public var enabled: Bool
    public var lastUpdated: Date?
    public var entryCount: Int
    public init(id: UUID = UUID(), name: String, url: String, enabled: Bool = true, lastUpdated: Date? = nil, entryCount: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.lastUpdated = lastUpdated
        self.entryCount = entryCount
    }
}

public struct AppConstants {
    public static let bundleIdGUI = "io.moamenbasel.puresnitch"
    public static let bundleIdHelper = "io.moamenbasel.puresnitch.helper"
    public static let bundleIdNetExt = "io.moamenbasel.puresnitch.netext"
    public static let xpcMachServiceName = "io.moamenbasel.puresnitch.helper"
    /// App<->extension XPC. Must be prefixed by an app group the process owns,
    /// so a regular (non-daemon) app can vend it via NSXPCListener.
    public static let ipcMachServiceName = "H3WXHVTP97.io.moamenbasel.puresnitch.ipc"
    public static let appGroup = "H3WXHVTP97.io.moamenbasel.puresnitch"
    public static let teamID = "H3WXHVTP97"
    public static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.1"
    public static let dnsProxyPort: UInt16 = 53
    public static let defaultDoHUpstream = "https://cloudflare-dns.com/dns-query"
    /// Port dev_mon (DS-mon) proxies provider API calls on. Loopback traffic on
    /// this port is "proxied" and recorded there; anything else is a direct
    /// provider call that dev_mon never sees.
    public static let devmonProxyPort = 18080
    public static let ollamaPort = 11434

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("PureSnitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var sharedDataDir: URL {
        let dir = URL(fileURLWithPath: "/Library/Application Support/PureSnitch", isDirectory: true)
        return dir
    }
}
