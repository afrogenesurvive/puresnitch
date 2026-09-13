import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class RuleStore: @unchecked Sendable {
    static let connectionHistoryLimit = 5_000

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "io.moamenbasel.puresnitch.rulestore")
    public let path: String

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw NSError(domain: "RuleStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        try setup()
    }

    deinit { if db != nil { sqlite3_close(db) } }

    private func setup() throws {
        let ddl = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS rules (
            id TEXT PRIMARY KEY,
            process_bundle_id TEXT,
            process_path TEXT,
            process_name TEXT,
            remote_host TEXT,
            remote_ip TEXT,
            remote_port INTEGER,
            direction TEXT,
            action TEXT,
            scope TEXT,
            priority INTEGER,
            profile TEXT,
            group_name TEXT,
            notes TEXT,
            enabled INTEGER,
            temporary INTEGER,
            created_at REAL,
            expires_at REAL,
            last_used_at REAL,
            hit_count INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_rules_profile ON rules(profile);
        CREATE INDEX IF NOT EXISTS idx_rules_process ON rules(process_path);
        CREATE INDEX IF NOT EXISTS idx_rules_host ON rules(remote_host);

        CREATE TABLE IF NOT EXISTS connections (
            id TEXT PRIMARY KEY,
            pid INTEGER,
            process_name TEXT,
            process_path TEXT,
            process_bundle_id TEXT,
            local_port INTEGER,
            remote_host TEXT,
            remote_ip TEXT,
            remote_port INTEGER,
            direction TEXT,
            status TEXT,
            protocol_name TEXT,
            bytes_in INTEGER,
            bytes_out INTEGER,
            country TEXT,
            country_code TEXT,
            latitude REAL,
            longitude REAL,
            first_seen REAL,
            last_seen REAL,
            audience_id TEXT,
            audience_name TEXT,
            repo_root TEXT,
            process_cwd TEXT,
            provider TEXT,
            process_command_line TEXT,
            -- Appended last deliberately: the migration adds this with an ALTER,
            -- and the SELECT * reader depends on the DDL order matching that
            -- append order. Putting it beside the other geo columns would shift
            -- every index after it.
            city TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_conn_status ON connections(status);
        CREATE INDEX IF NOT EXISTS idx_conn_pid ON connections(pid);
        CREATE INDEX IF NOT EXISTS idx_conn_last_seen ON connections(last_seen DESC);

        CREATE TABLE IF NOT EXISTS profiles (
            id TEXT PRIMARY KEY,
            name TEXT UNIQUE,
            mode TEXT,
            icon TEXT,
            is_active INTEGER
        );

        CREATE TABLE IF NOT EXISTS blocklists (
            id TEXT PRIMARY KEY,
            name TEXT UNIQUE,
            url TEXT,
            enabled INTEGER,
            last_updated REAL,
            entry_count INTEGER
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE TABLE IF NOT EXISTS audiences (
            id TEXT PRIMARY KEY,
            name TEXT,
            icon TEXT,
            kind TEXT,
            source TEXT,
            mode TEXT,
            enabled INTEGER,
            matchers_json TEXT,
            notes TEXT,
            created_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_audiences_source ON audiences(source);
        """
        try exec(ddl)
        try migrateConnectionColumns()
        try seedProfiles()
        try seedBlocklists()
        try migrateDefaultBlocklistURLs()
        try pruneConnectionHistory()
    }

    private func seedProfiles() throws {
        let defaults: [Profile] = [
            Profile(name: "default", mode: .alert, icon: "shield", isActive: true),
            Profile(name: "home", mode: .silentAllow, icon: "house"),
            Profile(name: "public-wifi", mode: .alert, icon: "wifi.exclamationmark"),
            Profile(name: "lockdown", mode: .silentDeny, icon: "lock.shield")
        ]
        for p in defaults { try insertProfileIfMissing(p) }
    }

    private func seedBlocklists() throws {
        let defaults: [BlocklistInfo] = [
            BlocklistInfo(name: "1Hosts (Lite)", url: "https://o0.pages.dev/Lite/hosts.txt"),
            BlocklistInfo(name: "OISD (small)", url: "https://small.oisd.nl/"),
            BlocklistInfo(name: "StevenBlack unified", url: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"),
            BlocklistInfo(name: "AdGuard DNS", url: "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"),
            // HaGeZi deprecated the hosts format on 2026-08-01 and the GitHub
            // repository is gone, so the old raw.githubusercontent URL is a 404.
            // The GitLab mirror still publishes daily, in Adblock syntax, which
            // BlocklistManager already parses.
            BlocklistInfo(name: "HaGeZi Multi Light", url: "https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/light.txt"),
            BlocklistInfo(name: "URLhaus", url: "https://urlhaus.abuse.ch/downloads/hostfile/"),
            BlocklistInfo(name: "Anti-PopAds", url: "https://raw.githubusercontent.com/Yhonay/antipopads/master/hosts"),
            BlocklistInfo(name: "Peter Lowe", url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext")
        ]
        for b in defaults { try insertBlocklistIfMissing(b) }
    }

    /// Seed rows are unique by name, so changing a default does not update an
    /// existing installation. Rewrite only the retired built-in URL; a user
    /// supplied replacement is left untouched.
    private func migrateDefaultBlocklistURLs() throws {
        let oldURL = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt"
        let newURL = "https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/light.txt"
        try execute("UPDATE blocklists SET url=? WHERE name=? AND url=?;") { stmt in
            sqlite3_bind_text(stmt, 1, newURL, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, "HaGeZi Multi Light", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, oldURL, -1, SQLITE_TRANSIENT)
        }
    }

    private func insertProfileIfMissing(_ p: Profile) throws {
        let sql = "INSERT OR IGNORE INTO profiles(id,name,mode,icon,is_active) VALUES (?,?,?,?,?);"
        try execute(sql) { stmt in
            sqlite3_bind_text(stmt, 1, p.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, p.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, p.mode.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, p.icon, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, p.isActive ? 1 : 0)
        }
    }

    private func insertBlocklistIfMissing(_ b: BlocklistInfo) throws {
        let sql = "INSERT OR IGNORE INTO blocklists(id,name,url,enabled,last_updated,entry_count) VALUES (?,?,?,?,?,?);"
        try execute(sql) { stmt in
            sqlite3_bind_text(stmt, 1, b.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, b.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, b.url, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, b.enabled ? 1 : 0)
            if let d = b.lastUpdated { sqlite3_bind_double(stmt, 5, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_int(stmt, 6, Int32(b.entryCount))
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(domain: "RuleStore", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func execute(_ sql: String, _ bind: (OpaquePointer?) -> Void) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "RuleStore", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            bind(stmt)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE && rc != SQLITE_ROW {
                throw NSError(domain: "RuleStore", code: 4, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }

    public func upsertRule(_ r: Rule) throws {
        let sql = """
        INSERT OR REPLACE INTO rules(
            id, process_bundle_id, process_path, process_name, remote_host, remote_ip,
            remote_port, direction, action, scope, priority, profile, group_name, notes,
            enabled, temporary, created_at, expires_at, last_used_at, hit_count
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        try execute(sql) { stmt in
            sqlite3_bind_text(stmt, 1, r.id.uuidString, -1, SQLITE_TRANSIENT)
            bindOpt(stmt, 2, r.processBundleId)
            bindOpt(stmt, 3, r.processPath)
            bindOpt(stmt, 4, r.processName)
            bindOpt(stmt, 5, r.remoteHost)
            bindOpt(stmt, 6, r.remoteIP)
            if let p = r.remotePort { sqlite3_bind_int(stmt, 7, Int32(p)) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_text(stmt, 8, r.direction.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, r.action.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, r.scope.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 11, Int32(r.priority))
            sqlite3_bind_text(stmt, 12, r.profile, -1, SQLITE_TRANSIENT)
            bindOpt(stmt, 13, r.groupName)
            bindOpt(stmt, 14, r.notes)
            sqlite3_bind_int(stmt, 15, r.enabled ? 1 : 0)
            sqlite3_bind_int(stmt, 16, r.temporary ? 1 : 0)
            sqlite3_bind_double(stmt, 17, r.createdAt.timeIntervalSince1970)
            if let e = r.expiresAt { sqlite3_bind_double(stmt, 18, e.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 18) }
            if let l = r.lastUsedAt { sqlite3_bind_double(stmt, 19, l.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 19) }
            sqlite3_bind_int(stmt, 20, Int32(r.hitCount))
        }
    }

    public func deleteRule(id: UUID) throws {
        try execute("DELETE FROM rules WHERE id=?;") { stmt in
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        }
    }

    public func allRules(profile: String? = nil) -> [Rule] {
        queue.sync {
            var rules: [Rule] = []
            let sql: String
            if profile != nil {
                sql = "SELECT * FROM rules WHERE profile=? ORDER BY priority DESC, created_at DESC;"
            } else {
                sql = "SELECT * FROM rules ORDER BY priority DESC, created_at DESC;"
            }
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            if let profile = profile { sqlite3_bind_text(stmt, 1, profile, -1, SQLITE_TRANSIENT) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let r = readRule(stmt) { rules.append(r) }
            }
            return rules
        }
    }

    public func allProfiles() -> [Profile] {
        queue.sync {
            var out: [Profile] = []
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, "SELECT id,name,mode,icon,is_active FROM profiles ORDER BY name;", -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: text(stmt, 0)) ?? UUID()
                let name = text(stmt, 1)
                let mode = AppMode(rawValue: text(stmt, 2)) ?? .alert
                let icon = text(stmt, 3)
                let active = sqlite3_column_int(stmt, 4) == 1
                out.append(Profile(id: id, name: name, mode: mode, icon: icon, isActive: active))
            }
            return out
        }
    }

    public func setActiveProfile(name: String) throws {
        try exec("UPDATE profiles SET is_active=0;")
        try execute("UPDATE profiles SET is_active=1 WHERE name=?;") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        }
    }

    public func allBlocklists() -> [BlocklistInfo] {
        queue.sync {
            var out: [BlocklistInfo] = []
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, "SELECT id,name,url,enabled,last_updated,entry_count FROM blocklists ORDER BY name;", -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: text(stmt, 0)) ?? UUID()
                let name = text(stmt, 1)
                let url = text(stmt, 2)
                let enabled = sqlite3_column_int(stmt, 3) == 1
                let last: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let count = Int(sqlite3_column_int(stmt, 5))
                out.append(BlocklistInfo(id: id, name: name, url: url, enabled: enabled, lastUpdated: last, entryCount: count))
            }
            return out
        }
    }

    public func updateBlocklist(_ b: BlocklistInfo) throws {
        try execute("UPDATE blocklists SET enabled=?, last_updated=?, entry_count=? WHERE id=?;") { stmt in
            sqlite3_bind_int(stmt, 1, b.enabled ? 1 : 0)
            if let d = b.lastUpdated { sqlite3_bind_double(stmt, 2, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 2) }
            sqlite3_bind_int(stmt, 3, Int32(b.entryCount))
            sqlite3_bind_text(stmt, 4, b.id.uuidString, -1, SQLITE_TRANSIENT)
        }
    }

    public func recordConnection(_ c: Connection) throws {
        try recordConnections([c])
    }

    /// Persist one monitor snapshot atomically. Repeated observations carry a
    /// stable id from NetMonitor, so the primary-key upsert updates the active
    /// session instead of appending a fresh row every poll.
    public func recordConnections(_ connections: [Connection]) throws {
        guard !connections.isEmpty else { return }
        let sql = """
        INSERT INTO connections(
            id,pid,process_name,process_path,process_bundle_id,local_port,remote_host,remote_ip,
            remote_port,direction,status,protocol_name,bytes_in,bytes_out,country,country_code,
            latitude,longitude,first_seen,last_seen,
            audience_id,audience_name,repo_root,process_cwd,provider,process_command_line,city
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            pid=excluded.pid,
            process_name=excluded.process_name,
            process_path=excluded.process_path,
            process_bundle_id=excluded.process_bundle_id,
            local_port=excluded.local_port,
            remote_host=excluded.remote_host,
            remote_ip=excluded.remote_ip,
            remote_port=excluded.remote_port,
            direction=excluded.direction,
            status=excluded.status,
            protocol_name=excluded.protocol_name,
            bytes_in=excluded.bytes_in,
            bytes_out=excluded.bytes_out,
            country=excluded.country,
            country_code=excluded.country_code,
            latitude=excluded.latitude,
            longitude=excluded.longitude,
            first_seen=MIN(connections.first_seen, excluded.first_seen),
            last_seen=MAX(connections.last_seen, excluded.last_seen),
            -- Attribution is derived, and a later snapshot of the same session can
            -- legitimately arrive without it (resolver miss). COALESCE keeps the
            -- last known good value instead of blanking the row.
            audience_id=COALESCE(excluded.audience_id, connections.audience_id),
            audience_name=COALESCE(excluded.audience_name, connections.audience_name),
            repo_root=COALESCE(excluded.repo_root, connections.repo_root),
            process_cwd=COALESCE(excluded.process_cwd, connections.process_cwd),
            provider=COALESCE(excluded.provider, connections.provider),
            process_command_line=COALESCE(excluded.process_command_line, connections.process_command_line),
            -- Deliberately NOT COALESCE, unlike the attribution columns above:
            -- a location mirrors the snapshot it came from. That is how country,
            -- latitude and longitude already behave, and it is what makes
            -- switching geolocation off stop accruing locations in the history
            -- rather than quietly filling them in behind the user's back.
            city=excluded.city;
        """
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                do {
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                        throw databaseError(code: 3)
                    }
                    defer { sqlite3_finalize(stmt) }

                    for connection in connections {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        bindConnection(connection, to: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else {
                            throw databaseError(code: 4)
                        }
                    }
                }
                try pruneConnectionHistoryUnlocked()
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func recentConnections(limit: Int = 200, status: Connection.Status? = nil) -> [Connection] {
        queue.sync {
            var out: [Connection] = []
            let safeLimit = min(max(limit, 0), Self.connectionHistoryLimit)
            let sql: String
            if status != nil {
                sql = "SELECT * FROM connections WHERE status=? ORDER BY last_seen DESC LIMIT ?;"
            } else {
                sql = "SELECT * FROM connections ORDER BY last_seen DESC LIMIT ?;"
            }
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            if let status {
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(safeLimit))
            } else {
                sqlite3_bind_int64(stmt, 1, Int64(safeLimit))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = readConn(stmt) { out.append(c) }
            }
            return out
        }
    }

    // MARK: - audiences

    public func upsertAudience(_ audience: Audience) throws {
        let sql = """
        INSERT OR REPLACE INTO audiences(
            id,name,icon,kind,source,mode,enabled,matchers_json,notes,created_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?);
        """
        var encoded = "[]"
        if let data = try? JSONEncoder().encode(audience.matchers),
           let text = String(data: data, encoding: .utf8) {
            encoded = text
        }
        try execute(sql) { stmt in
            sqlite3_bind_text(stmt, 1, audience.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, audience.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, audience.icon, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, audience.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, audience.source.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, audience.mode.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 7, audience.enabled ? 1 : 0)
            sqlite3_bind_text(stmt, 8, encoded, -1, SQLITE_TRANSIENT)
            bindOpt(stmt, 9, audience.notes)
            sqlite3_bind_double(stmt, 10, audience.createdAt.timeIntervalSince1970)
        }
    }

    /// Detaches history instead of deleting it: the connection rows are the audit
    /// trail, and an audience can be recreated with the same matchers later.
    public func deleteAudience(id: UUID) throws {
        try execute("UPDATE connections SET audience_id=NULL, audience_name=NULL WHERE audience_id=?;") { stmt in
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        }
        try execute("DELETE FROM audiences WHERE id=?;") { stmt in
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        }
    }

    public func setAudienceEnabled(id: UUID, enabled: Bool) throws {
        try execute("UPDATE audiences SET enabled=? WHERE id=?;") { stmt in
            sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        }
    }

    public func allAudiences() -> [Audience] {
        queue.sync {
            var out: [Audience] = []
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, "SELECT * FROM audiences ORDER BY name ASC;", -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let audience = readAudience(stmt) { out.append(audience) }
            }
            return out
        }
    }

    /// Per-audience rollup over stored connections. Audiences with no traffic are
    /// still returned: "declared but unused" is exactly what an audit is looking
    /// for, and a missing row would read as "no such audience".
    public func audienceSummaries(proxyPort: Int = AppConstants.devmonProxyPort) -> [AudienceSummary] {
        let audiences = allAudiences()
        guard !audiences.isEmpty else { return [] }

        var aggregates: [String: (count: Int, bytesIn: Int64, bytesOut: Int64, proxied: Int, first: Date?, last: Date?)] = [:]
        queue.sync {
            let sql = """
            SELECT audience_id,
                   COUNT(*),
                   COALESCE(SUM(bytes_in),0),
                   COALESCE(SUM(bytes_out),0),
                   COALESCE(SUM(CASE WHEN remote_port = ? THEN 1 ELSE 0 END),0),
                   MIN(first_seen),
                   MAX(last_seen)
            FROM connections
            WHERE audience_id IS NOT NULL
            GROUP BY audience_id;
            """
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(proxyPort))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = text(stmt, 0)
                let first: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let last: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                aggregates[key] = (
                    Int(sqlite3_column_int(stmt, 1)),
                    sqlite3_column_int64(stmt, 2),
                    sqlite3_column_int64(stmt, 3),
                    Int(sqlite3_column_int(stmt, 4)),
                    first,
                    last
                )
            }
        }

        return audiences.map { audience in
            let aggregate = aggregates[audience.id.uuidString]
            return AudienceSummary(
                id: audience.id,
                name: audience.name,
                kind: audience.kind,
                icon: audience.icon,
                connectionCount: aggregate?.count ?? 0,
                bytesIn: aggregate?.bytesIn ?? 0,
                bytesOut: aggregate?.bytesOut ?? 0,
                proxiedCount: aggregate?.proxied ?? 0,
                firstSeen: aggregate?.first,
                lastSeen: aggregate?.last
            )
        }.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.name < rhs.name
        }
    }

    public func recentAudienceActivity(audienceId: UUID, limit: Int = 200) -> [Connection] {
        queue.sync {
            var out: [Connection] = []
            let safeLimit = min(max(limit, 0), Self.connectionHistoryLimit)
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            let sql = "SELECT * FROM connections WHERE audience_id=? ORDER BY last_seen DESC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, audienceId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(safeLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = readConn(stmt) { out.append(c) }
            }
            return out
        }
    }

    private func readAudience(_ stmt: OpaquePointer?) -> Audience? {
        guard let id = UUID(uuidString: text(stmt, 0)) else { return nil }
        var matchers: [AudienceMatcher] = []
        if let data = text(stmt, 7).data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AudienceMatcher].self, from: data) {
            matchers = decoded
        }
        return Audience(
            id: id,
            name: text(stmt, 1),
            icon: text(stmt, 2),
            kind: AudienceKind(rawValue: text(stmt, 3)) ?? .adHoc,
            source: AudienceSource(rawValue: text(stmt, 4)) ?? .manual,
            mode: AudienceMode(rawValue: text(stmt, 5)) ?? .observe,
            enabled: sqlite3_column_int(stmt, 6) == 1,
            matchers: matchers,
            notes: textOpt(stmt, 8),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        )
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?);") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        }
    }
    public func getSetting(_ key: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW { return text(stmt, 0) }
            return nil
        }
    }

    // MARK: - helpers
    private func bindOpt(_ stmt: OpaquePointer?, _ idx: Int32, _ s: String?) {
        if let s = s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindConnection(_ c: Connection, to stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, c.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, c.pid)
        sqlite3_bind_text(stmt, 3, c.processName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, c.processPath, -1, SQLITE_TRANSIENT)
        bindOpt(stmt, 5, c.processBundleId)
        sqlite3_bind_int(stmt, 6, Int32(c.localPort))
        sqlite3_bind_text(stmt, 7, c.remoteHost, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, c.remoteIP, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 9, Int32(c.remotePort))
        sqlite3_bind_text(stmt, 10, c.direction.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, c.status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 12, c.protocolName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 13, c.bytesIn)
        sqlite3_bind_int64(stmt, 14, c.bytesOut)
        bindOpt(stmt, 15, c.country)
        bindOpt(stmt, 16, c.countryCode)
        if let v = c.latitude { sqlite3_bind_double(stmt, 17, v) } else { sqlite3_bind_null(stmt, 17) }
        if let v = c.longitude { sqlite3_bind_double(stmt, 18, v) } else { sqlite3_bind_null(stmt, 18) }
        sqlite3_bind_double(stmt, 19, c.firstSeen.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 20, c.lastSeen.timeIntervalSince1970)
        bindOpt(stmt, 21, c.audienceId?.uuidString)
        bindOpt(stmt, 22, c.audienceName)
        bindOpt(stmt, 23, c.repoRoot)
        bindOpt(stmt, 24, c.processCwd)
        bindOpt(stmt, 25, c.provider)
        bindOpt(stmt, 26, c.processCommandLine)
        bindOpt(stmt, 27, c.city)
    }
    /// `CREATE TABLE IF NOT EXISTS` never adds columns to a database that already
    /// has the table, and this project has no migration framework, so new columns
    /// are probed with `PRAGMA table_info` and appended in a fixed order. `SELECT
    /// *` readers rely on that order matching the DDL above: both paths put the
    /// audience columns directly after `last_seen`.
    private func migrateConnectionColumns() throws {
        let existing = connectionColumnNames()
        let additions: [(name: String, type: String)] = [
            ("audience_id", "TEXT"),
            ("audience_name", "TEXT"),
            ("repo_root", "TEXT"),
            ("process_cwd", "TEXT"),
            ("provider", "TEXT"),
            ("process_command_line", "TEXT"),
            // Keep this last. This list IS the append order that `SELECT *`
            // readers depend on, and it has to match the DDL above.
            ("city", "TEXT")
        ]
        var added = false
        for addition in additions where !existing.contains(addition.name) {
            try exec("ALTER TABLE connections ADD COLUMN \(addition.name) \(addition.type);")
            added = true
        }
        if added || !existing.contains("audience_id") {
            // Created here rather than in the DDL: on an upgraded database the
            // column does not exist yet when the DDL runs, and indexing a
            // missing column would abort setup.
            try exec("CREATE INDEX IF NOT EXISTS idx_conn_audience ON connections(audience_id);")
        }
    }

    /// Runs during `init`, before any concurrent access, so it reads the schema
    /// without taking the queue.
    private func connectionColumnNames() -> Set<String> {
        var names: Set<String> = []
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(connections);", -1, &stmt, nil) == SQLITE_OK else {
            return names
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = text(stmt, 1)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    private func pruneConnectionHistory() throws {
        try queue.sync { try pruneConnectionHistoryUnlocked() }
    }
    private func pruneConnectionHistoryUnlocked() throws {
        let sql = """
        DELETE FROM connections
        WHERE rowid IN (
            SELECT rowid FROM connections
            ORDER BY last_seen DESC, rowid DESC
            LIMIT -1 OFFSET ?
        );
        """
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw databaseError(code: 3)
        }
        sqlite3_bind_int64(stmt, 1, Int64(Self.connectionHistoryLimit))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError(code: 4) }
    }
    private func databaseError(code: Int) -> NSError {
        NSError(
            domain: "RuleStore",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
    private func text(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }
    private func textOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return text(stmt, idx)
    }
    private func readRule(_ stmt: OpaquePointer?) -> Rule? {
        let id = UUID(uuidString: text(stmt, 0)) ?? UUID()
        let bundleId = textOpt(stmt, 1)
        let path = textOpt(stmt, 2)
        let name = textOpt(stmt, 3)
        let host = textOpt(stmt, 4)
        let ip = textOpt(stmt, 5)
        let port: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
        let dir = RuleDirection(rawValue: text(stmt, 7)) ?? .outgoing
        let action = RuleAction(rawValue: text(stmt, 8)) ?? .ask
        let scope = RuleScope(rawValue: text(stmt, 9)) ?? .domain
        let priority = Int(sqlite3_column_int(stmt, 10))
        let profile = text(stmt, 11)
        let group = textOpt(stmt, 12)
        let notes = textOpt(stmt, 13)
        let enabled = sqlite3_column_int(stmt, 14) == 1
        let temp = sqlite3_column_int(stmt, 15) == 1
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))
        let exp: Date? = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17))
        let last: Date? = sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 18))
        let hits = Int(sqlite3_column_int(stmt, 19))
        return Rule(id: id, processBundleId: bundleId, processPath: path, processName: name, remoteHost: host, remoteIP: ip, remotePort: port, direction: dir, action: action, scope: scope, priority: priority, profile: profile, groupName: group, notes: notes, enabled: enabled, temporary: temp, createdAt: created, expiresAt: exp, lastUsedAt: last, hitCount: hits)
    }
    private func readConn(_ stmt: OpaquePointer?) -> Connection? {
        let id = UUID(uuidString: text(stmt, 0)) ?? UUID()
        let pid = sqlite3_column_int(stmt, 1)
        let pname = text(stmt, 2)
        let ppath = text(stmt, 3)
        let bid = textOpt(stmt, 4)
        let lp = Int(sqlite3_column_int(stmt, 5))
        let host = text(stmt, 6)
        let ip = text(stmt, 7)
        let rp = Int(sqlite3_column_int(stmt, 8))
        let dir = RuleDirection(rawValue: text(stmt, 9)) ?? .outgoing
        let status = Connection.Status(rawValue: text(stmt, 10)) ?? .established
        let proto = text(stmt, 11)
        let bin = sqlite3_column_int64(stmt, 12)
        let bout = sqlite3_column_int64(stmt, 13)
        let cn = textOpt(stmt, 14)
        let cc = textOpt(stmt, 15)
        let lat: Double? = sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 16)
        let lon: Double? = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 17)
        let fs = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 18))
        let ls = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 19))
        let audienceId = UUID(uuidString: text(stmt, 20))
        let audienceName = textOpt(stmt, 21)
        let repoRoot = textOpt(stmt, 22)
        let processCwd = textOpt(stmt, 23)
        let provider = textOpt(stmt, 24)
        let processCommandLine = textOpt(stmt, 25)
        let city = textOpt(stmt, 26)
        return Connection(
            id: id,
            pid: pid,
            processName: pname,
            processPath: ppath,
            processBundleId: bid,
            localPort: lp,
            remoteHost: host,
            remoteIP: ip,
            remotePort: rp,
            direction: dir,
            status: status,
            protocolName: proto,
            bytesIn: bin,
            bytesOut: bout,
            country: cn,
            countryCode: cc,
            latitude: lat,
            longitude: lon,
            city: city,
            firstSeen: fs,
            lastSeen: ls,
            audienceId: audienceId,
            audienceName: audienceName,
            repoRoot: repoRoot,
            processCwd: processCwd,
            provider: provider,
            processCommandLine: processCommandLine
        )
    }
}
