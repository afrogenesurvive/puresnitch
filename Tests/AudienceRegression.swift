import Foundation
import SQLite3

// Regression checks for audience attribution and persistence. Compiled by
// Scripts/test_hardening.sh; the runner lives in HardeningRegression.swift, so
// this file deliberately has no @main and carries its own helpers rather than
// reaching into that file's private ones.

private let AUDIENCE_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct AudienceRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private func requireAudience(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw AudienceRegressionFailure(description: message) }
}

private func requireAudienceThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        return
    }
    throw AudienceRegressionFailure(description: message)
}

private func audienceConnection(
    processPath: String = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
    processBundleId: String? = nil,
    processCwd: String? = nil,
    remoteHost: String = "203.0.113.10",
    remoteIP: String = "203.0.113.10",
    remotePort: Int = 443,
    bytesIn: Int64 = 0,
    bytesOut: Int64 = 0
) -> Connection {
    Connection(
        pid: 4242,
        processName: "node",
        processPath: processPath,
        processBundleId: processBundleId,
        remoteHost: remoteHost,
        remoteIP: remoteIP,
        remotePort: remotePort,
        status: .established,
        bytesIn: bytesIn,
        bytesOut: bytesOut,
        processCwd: processCwd
    )
}

// MARK: - model

private func testAudienceModelValidation() throws {
    let valid = Audience(
        name: "vscode",
        kind: .client,
        matchers: [
            AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/Visual Studio Code.app/"),
            AudienceMatcher(kind: .remotePort, pattern: "18080"),
            AudienceMatcher(kind: .remoteHost, pattern: "*.deepseek.com"),
        ]
    )
    try valid.validateForPersistence()

    try requireAudienceThrows("an empty audience name was persisted") {
        try Audience(name: "   ").validateForPersistence()
    }
    try requireAudienceThrows("an over-long audience name was persisted") {
        try Audience(name: String(repeating: "a", count: 65)).validateForPersistence()
    }
    try requireAudienceThrows("an empty matcher pattern was persisted") {
        try Audience(
            name: "blank",
            matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "")]
        ).validateForPersistence()
    }
    try requireAudienceThrows("a non-numeric port matcher was persisted") {
        try Audience(
            name: "bad-port",
            matchers: [AudienceMatcher(kind: .remotePort, pattern: "https")]
        ).validateForPersistence()
    }
    try requireAudienceThrows("an out-of-range port matcher was persisted") {
        try Audience(
            name: "wide-port",
            matchers: [AudienceMatcher(kind: .remotePort, pattern: "70000")]
        ).validateForPersistence()
    }
    try requireAudienceThrows("a malformed host matcher was persisted") {
        try Audience(
            name: "bad-host",
            matchers: [AudienceMatcher(kind: .remoteHost, pattern: "not a host")]
        ).validateForPersistence()
    }
}

// MARK: - resolution

private func testAudienceResolutionPrecedence() throws {
    let auto = Audience(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
        name: "vscode",
        kind: .client,
        source: .autoDiscovered,
        matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/Visual Studio Code.app/")]
    )
    let manual = Audience(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
        name: "vscode-manual",
        kind: .client,
        source: .manual,
        matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/Visual Studio Code.app/Contents/")]
    )
    let resolver = AudienceResolver(audiences: [auto, manual])
    let resolved = try requireAudienceUnwrap(
        resolver.resolve(audienceConnection()),
        "a manual audience did not outrank a discovered one"
    )
    try requireAudience(resolved.id == manual.id, "the discovered audience shadowed the manual audience")

    // Specificity decides between two audiences of the same source.
    let broad = Audience(
        name: "aaa-broad",
        source: .manual,
        matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/")]
    )
    let narrow = Audience(
        name: "zzz-narrow",
        source: .manual,
        matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/Visual Studio Code.app/")]
    )
    let specific = try requireAudienceUnwrap(
        AudienceResolver(audiences: [broad, narrow]).resolve(audienceConnection()),
        "the longest matching pattern did not win"
    )
    try requireAudience(specific.name == "zzz-narrow", "a shorter prefix outranked a longer one")

    // Equal scores fall back to the name so a snapshot resolves the same way.
    let twinA = Audience(name: "alpha", source: .manual, matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/")])
    let twinB = Audience(name: "beta", source: .manual, matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/")])
    let stable = try requireAudienceUnwrap(
        AudienceResolver(audiences: [twinB, twinA]).resolve(audienceConnection()),
        "a score tie resolved to nothing"
    )
    try requireAudience(stable.name == "alpha", "a score tie was not broken deterministically by name")

    // A disabled audience is not part of matching at all.
    let disabled = Audience(name: "off", enabled: false, matchers: [AudienceMatcher(kind: .remotePort, pattern: "443")])
    try requireAudience(AudienceResolver(audiences: [disabled]).resolve(audienceConnection()) == nil, "a disabled audience still matched")

    // Behaviour of every matcher kind.
    let bundleAudience = Audience(name: "bundle", matchers: [AudienceMatcher(kind: .processBundleId, pattern: "com.microsoft.VSCode")])
    try requireAudience(
        AudienceResolver(audiences: [bundleAudience]).resolve(audienceConnection(processBundleId: "com.microsoft.VSCode")) != nil,
        "a bundle identifier matcher did not match"
    )
    try requireAudience(
        AudienceResolver(audiences: [bundleAudience]).resolve(audienceConnection(processBundleId: "com.apple.Safari")) == nil,
        "a bundle identifier matcher matched the wrong bundle"
    )

    let cwdAudience = Audience(name: "repo", kind: .repo, matchers: [AudienceMatcher(kind: .cwdPrefix, pattern: "/Users/example/Documents/GitHub/sample_agent")])
    try requireAudience(
        AudienceResolver(audiences: [cwdAudience])
            .resolve(audienceConnection(processCwd: "/Users/example/Documents/GitHub/sample_agent/python-backend")) != nil,
        "a working directory matcher did not match a subdirectory"
    )
    try requireAudience(
        AudienceResolver(audiences: [cwdAudience]).resolve(audienceConnection(processCwd: nil)) == nil,
        "a working directory matcher matched a connection with no working directory"
    )

    let hostAudience = Audience(name: "provider", matchers: [AudienceMatcher(kind: .remoteHost, pattern: "*.deepseek.com")])
    try requireAudience(
        AudienceResolver(audiences: [hostAudience])
            .resolve(audienceConnection(remoteHost: "api.deepseek.com", remoteIP: "203.0.113.10")) != nil,
        "a host glob did not match the remote host"
    )

    let proxyAudience = Audience(name: "devmon-proxy", matchers: [AudienceMatcher(kind: .remoteHost, pattern: "127.0.0.1"), AudienceMatcher(kind: .remotePort, pattern: "18080")])
    try requireAudience(
        AudienceResolver(audiences: [proxyAudience])
            .resolve(audienceConnection(remoteHost: "127.0.0.1", remoteIP: "127.0.0.1", remotePort: 18080)) != nil,
        "loopback against the dev_mon proxy port did not match"
    )

    try requireAudience(
        AudienceResolver(audiences: [hostAudience, proxyAudience]).resolve(audienceConnection()) == nil,
        "an unrelated connection was attributed to an audience"
    )
}

/// Unwraps any optional fixture the checks rely on, so a failure names the
/// expectation instead of trapping in an `!`.
private func requireAudienceUnwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw AudienceRegressionFailure(description: message) }
    return value
}

private func testAudienceAnnotation() throws {
    let audience = Audience(
        name: "agent",
        kind: .repo,
        matchers: [AudienceMatcher(kind: .processPathPrefix, pattern: "/usr/local/bin/node")]
    )
    let resolved = AudienceResolver(audiences: [audience]).annotate([
        audienceConnection(processPath: "/usr/local/bin/node"),
        audienceConnection(processPath: "/usr/bin/curl"),
    ])
    try requireAudience(resolved.count == 2, "annotation changed the number of connections")
    try requireAudience(resolved[0].audienceId == audience.id, "the matched connection was not tagged")
    try requireAudience(resolved[0].audienceName == "agent", "the matched connection did not carry the audience name")
    try requireAudience(resolved[1].audienceId == nil, "an unmatched connection was tagged with an audience")
    try requireAudience(resolved[1].audienceName == nil, "an unmatched connection kept an audience name")

    // Annotation must not disturb the fields the UI and the rules engine use.
    let original = audienceConnection(bytesIn: 11, bytesOut: 22)
    let annotated = AudienceResolver(audiences: []).annotate([original])
    try requireAudience(annotated[0].id == original.id, "annotation replaced the connection id")
    try requireAudience(annotated[0].remotePort == original.remotePort, "annotation changed the remote port")
    try requireAudience(annotated[0].bytesIn == 11 && annotated[0].bytesOut == 22, "annotation changed byte totals")
}

// MARK: - repository derivation

private func withAudienceTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("puresnitch-audience-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func testRepoRootDerivation() throws {
    try withAudienceTemporaryDirectory { root in
        let fileManager = FileManager.default
        let repo = root.appendingPathComponent("clone", isDirectory: true)
        let nested = repo.appendingPathComponent("python-backend/.venv", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let locator = RepoLocator()
        let expected = repo.standardizedFileURL.path
        try requireAudience(
            locator.repoRoot(forCwd: nested.path) == expected,
            "a nested working directory did not resolve to its repository root"
        )
        try requireAudience(
            locator.repoRoot(forCwd: repo.path) == expected,
            "a repository root did not resolve to itself"
        )
        // Cached second call must agree with the first.
        try requireAudience(
            locator.repoRoot(forCwd: nested.path) == expected,
            "the cached repository root disagreed with the first lookup"
        )

        // A worktree or submodule stores `.git` as a file, not a directory.
        let worktree = root.appendingPathComponent("worktree/sub", isDirectory: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: /tmp/elsewhere\n".write(
            to: root.appendingPathComponent("worktree/.git"),
            atomically: true,
            encoding: .utf8
        )
        try requireAudience(
            locator.repoRoot(forCwd: worktree.path) == root.appendingPathComponent("worktree").standardizedFileURL.path,
            "a `.git` file was not treated as a repository marker"
        )

        let outside = root.appendingPathComponent("plain/deep", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try requireAudience(
            locator.repoRoot(forCwd: outside.path) == nil,
            "a directory with no repository above it resolved to a root"
        )
        try requireAudience(RepoLocator(maxDepth: 1).repoRoot(forCwd: nested.path) == nil, "the depth bound was ignored")
        try requireAudience(locator.repoRoot(forCwd: "") == nil, "an empty working directory resolved to a root")
        try requireAudience(locator.repoRoot(forCwd: "relative/path") == nil, "a relative working directory resolved to a root")
    }
}

// MARK: - persistence

private func audienceRowCount(at path: String, table: String) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        if database != nil { sqlite3_close(database) }
        throw AudienceRegressionFailure(description: "could not reopen \(table)")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK else {
        throw AudienceRegressionFailure(description: "could not count \(table)")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw AudienceRegressionFailure(description: "counting \(table) returned no row")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func connectionColumnNames(at path: String) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        if database != nil { sqlite3_close(database) }
        throw AudienceRegressionFailure(description: "could not reopen the migrated database")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_info(connections);", -1, &statement, nil) == SQLITE_OK else {
        throw AudienceRegressionFailure(description: "could not read the migrated schema")
    }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let pointer = sqlite3_column_text(statement, 1) {
            names.append(String(cString: pointer))
        }
    }
    return names
}

private func testAudienceStoreRoundTrip() throws {
    try withAudienceTemporaryDirectory { root in
        let databaseURL = root.appendingPathComponent("store.sqlite")
        let store = try RuleStore(path: databaseURL.path)

        let client = Audience(
            name: "vscode",
            icon: "chevron.left.forwardslash.chevron.right",
            kind: .client,
            source: .autoDiscovered,
            matchers: [
                AudienceMatcher(kind: .processPathPrefix, pattern: "/Applications/Visual Studio Code.app/"),
                AudienceMatcher(kind: .remotePort, pattern: "18080"),
            ],
            notes: "editor and its MCP servers"
        )
        let repoAudience = Audience(
            name: "repo:sample_agent",
            kind: .repo,
            source: .autoDiscovered,
            matchers: [AudienceMatcher(kind: .cwdPrefix, pattern: "/Users/example/Documents/GitHub/sample_agent")]
        )
        try store.upsertAudience(client)
        try store.upsertAudience(repoAudience)

        let stored = store.allAudiences()
        try requireAudience(stored.count == 2, "audiences did not round-trip")
        try requireAudience(stored.map(\.name) == ["repo:sample_agent", "vscode"], "audiences were not returned in name order")
        let reloadedClient = try requireAudienceUnwrap(stored.first { $0.id == client.id }, "the client audience went missing")
        try requireAudience(reloadedClient.matchers.count == 2, "audience matchers did not round-trip")
        try requireAudience(reloadedClient.matchers[1].kind == .remotePort && reloadedClient.matchers[1].pattern == "18080", "a matcher lost its kind or pattern")
        try requireAudience(reloadedClient.notes == "editor and its MCP servers", "audience notes did not round-trip")
        try requireAudience(reloadedClient.kind == .client && reloadedClient.source == .autoDiscovered, "audience kind or source did not round-trip")
        try requireAudience(reloadedClient.mode == .observe, "audiences should default to observe")

        // Attribution survives the store, and the rollup counts proxy vs direct.
        let proxied = Connection(
            id: UUID(),
            pid: 99,
            processName: "node",
            processPath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            remoteHost: "127.0.0.1",
            remoteIP: "127.0.0.1",
            remotePort: AppConstants.devmonProxyPort,
            status: .established,
            bytesIn: 1_000,
            bytesOut: 2_000,
            audienceId: client.id,
            audienceName: client.name,
            repoRoot: "/Users/example/Documents/GitHub/sample_agent",
            processCwd: "/Users/example/Documents/GitHub/sample_agent/python-backend"
        )
        let direct = Connection(
            id: UUID(),
            pid: 100,
            processName: "node",
            processPath: "/usr/local/bin/node",
            remoteHost: "203.0.113.20",
            remoteIP: "203.0.113.20",
            remotePort: 443,
            status: .established,
            audienceId: repoAudience.id,
            audienceName: repoAudience.name,
            repoRoot: "/Users/example/Documents/GitHub/sample_agent"
        )
        try store.recordConnections([proxied, direct])

        let activity = store.recentAudienceActivity(audienceId: client.id)
        try requireAudience(activity.count == 1, "audience activity did not return the attributed connection")
        try requireAudience(activity[0].audienceId == client.id, "audience id did not survive persistence")
        try requireAudience(activity[0].audienceName == "vscode", "audience name did not survive persistence")
        try requireAudience(activity[0].bytesIn == 1_000 && activity[0].bytesOut == 2_000, "byte totals did not survive persistence")
        try requireAudience(
            activity[0].repoRoot == "/Users/example/Documents/GitHub/sample_agent",
            "repository root did not survive persistence"
        )
        try requireAudience(
            activity[0].processCwd == "/Users/example/Documents/GitHub/sample_agent/python-backend",
            "working directory did not survive persistence"
        )

        let summaries = store.audienceSummaries()
        try requireAudience(summaries.count == 2, "summaries did not cover every audience")
        let clientSummary = try requireAudienceUnwrap(summaries.first { $0.id == client.id }, "the client audience had no summary")
        try requireAudience(clientSummary.connectionCount == 1, "summary connection count was wrong")
        try requireAudience(clientSummary.proxiedCount == 1, "a proxied connection was not counted as proxied")
        try requireAudience(clientSummary.total == 3_000, "summary byte total was wrong")
        try requireAudience(clientSummary.firstSeen != nil && clientSummary.lastSeen != nil, "summary did not report observation times")
        let repoSummary = try requireAudienceUnwrap(summaries.first { $0.id == repoAudience.id }, "the repo audience had no summary")
        try requireAudience(repoSummary.proxiedCount == 0, "a direct connection was counted as proxied")
        try requireAudience(repoSummary.connectionCount == 1, "the repo audience missed its connection")

        // A late snapshot without attribution must not blank a stored value.
        let laterSnapshot = Connection(id: proxied.id, pid: 99, processName: "node", processPath: proxied.processPath, remotePort: AppConstants.devmonProxyPort)
        try store.recordConnections([laterSnapshot])
        let refreshed = try requireAudienceUnwrap(
            store.recentAudienceActivity(audienceId: client.id).first,
            "the attributed connection disappeared after an unattributed snapshot"
        )
        try requireAudience(refreshed.audienceId == client.id, "an unattributed snapshot cleared the stored audience")
        try requireAudience(
            refreshed.repoRoot == "/Users/example/Documents/GitHub/sample_agent",
            "an unattributed snapshot cleared the stored repository root"
        )

        try store.setAudienceEnabled(id: client.id, enabled: false)
        let disabled = try requireAudienceUnwrap(store.allAudiences().first { $0.id == client.id }, "the audience went missing after disabling")
        try requireAudience(!disabled.enabled, "disabling an audience did not persist")

        // Deleting an audience detaches history rather than destroying it.
        try store.deleteAudience(id: client.id)
        try requireAudience(store.allAudiences().count == 1, "a deleted audience was still returned")
        try requireAudience(
            store.recentConnections(limit: 100).contains { $0.id == proxied.id },
            "deleting an audience destroyed its audit rows"
        )
        try requireAudience(
            store.recentConnections(limit: 100).first { $0.id == proxied.id }?.audienceId == nil,
            "a deleted audience left its history attributed"
        )
    }
}

/// The released schema has no audience columns. `CREATE TABLE IF NOT EXISTS`
/// will not add them, so an upgraded install depends entirely on the PRAGMA
/// probe in `migrateConnectionColumns`.
private let legacyConnectionsDDL = """
CREATE TABLE connections (
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
    last_seen REAL
);
"""

private func seedLegacyDatabase(at path: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
        if database != nil { sqlite3_close(database) }
        throw AudienceRegressionFailure(description: "could not create the legacy fixture")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, legacyConnectionsDDL, nil, nil, nil) == SQLITE_OK else {
        throw AudienceRegressionFailure(description: "could not create the legacy connections table")
    }
    var statement: OpaquePointer?
    let sql = "INSERT INTO connections(id,remote_ip,remote_port,status,first_seen,last_seen) VALUES(?,?,?,?,?,?);"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw AudienceRegressionFailure(description: "could not prepare the legacy row")
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, UUID().uuidString, -1, AUDIENCE_SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, "203.0.113.30", -1, AUDIENCE_SQLITE_TRANSIENT)
    sqlite3_bind_int(statement, 3, 443)
    sqlite3_bind_text(statement, 4, Connection.Status.established.rawValue, -1, AUDIENCE_SQLITE_TRANSIENT)
    sqlite3_bind_double(statement, 5, 5_000)
    sqlite3_bind_double(statement, 6, 5_100)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw AudienceRegressionFailure(description: "could not insert the legacy row")
    }
}

private func testConnectionColumnsMigrateFromLegacySchema() throws {
    try withAudienceTemporaryDirectory { root in
        let databaseURL = root.appendingPathComponent("legacy.sqlite")
        try seedLegacyDatabase(at: databaseURL.path)

        let before = try connectionColumnNames(at: databaseURL.path)
        try requireAudience(!before.contains("audience_id"), "the legacy fixture already had audience columns")

        do {
            let migrated = try RuleStore(path: databaseURL.path)
            let legacyRows = migrated.recentConnections(limit: 10)
            try requireAudience(legacyRows.count == 1, "the migration lost the pre-existing row")
            try requireAudience(legacyRows[0].audienceId == nil, "a legacy row came back with an audience")
            try requireAudience(legacyRows[0].remotePort == 443, "a legacy row lost its remote port")
        }

        let after = try connectionColumnNames(at: databaseURL.path)
        for column in ["audience_id", "audience_name", "repo_root", "process_cwd", "provider"] {
            try requireAudience(after.contains(column), "migration did not add \(column)")
            try requireAudience(after.filter { $0 == column }.count == 1, "migration added \(column) more than once")
        }

        // Opening the same database again must be a no-op, not a duplicate ALTER.
        do {
            let reopened = try RuleStore(path: databaseURL.path)
            try requireAudience(reopened.recentConnections(limit: 10).count == 1, "the second open lost the row")
            try reopened.upsertAudience(Audience(name: "after-migration", kind: .service))
            let summaries = reopened.audienceSummaries()
            try requireAudience(summaries.count == 1, "an audience added after migration was not readable")
            try requireAudience(summaries[0].connectionCount == 0, "an unused audience should still be reported")
        }

        let finalColumns = try connectionColumnNames(at: databaseURL.path)
        try requireAudience(finalColumns.filter { $0 == "audience_id" }.count == 1, "the second open duplicated audience_id")
        let persistedAudiences = try audienceRowCount(at: databaseURL.path, table: "audiences")
        try requireAudience(persistedAudiences == 1, "the audiences table was not persisted")
    }
}

private func testConnectionDecodesWithoutAudienceFields() throws {
    // Synthesized Codable encodes optionals with `encodeIfPresent`, so an
    // unattributed connection transmits no audience keys at all - which is
    // exactly the payload a helper built before audiences existed produces.
    let encoded = try JSONEncoder().encode(audienceConnection(bytesIn: 7))
    let json = try JSONSerialization.jsonObject(with: encoded)
    let object = try requireAudienceUnwrap(json as? [String: Any], "the connection fixture was not a JSON object")
    for key in ["audienceId", "audienceName", "repoRoot", "processCwd", "provider"] {
        try requireAudience(object[key] == nil, "an unattributed connection still transmitted \(key)")
    }

    let decoded = try JSONDecoder().decode(Connection.self, from: encoded)
    try requireAudience(decoded.audienceId == nil, "a payload without audience fields decoded a stale audience")
    try requireAudience(decoded.audienceName == nil, "a payload without audience fields decoded a stale audience name")
    try requireAudience(decoded.repoRoot == nil && decoded.processCwd == nil, "a payload without attribution decoded attribution")
    try requireAudience(decoded.provider == nil, "a payload without provider decoded a provider")
    try requireAudience(decoded.bytesIn == 7, "the payload lost a pre-existing field")
    try requireAudience(decoded.remotePort == 443, "the payload lost the remote port")

    // Attribution must survive the XPC hop in the other direction too.
    let attributed = Connection(
        id: UUID(),
        pid: 7,
        processName: "node",
        processPath: "/usr/local/bin/node",
        remotePort: 18080,
        status: .established,
        audienceId: UUID(),
        audienceName: "vscode",
        repoRoot: "/Users/example/Documents/GitHub/demo_project",
        processCwd: "/Users/example/Documents/GitHub/demo_project/mcp",
        provider: "deepseek"
    )
    let roundTripped = try JSONDecoder().decode(Connection.self, from: try JSONEncoder().encode(attributed))
    try requireAudience(roundTripped.audienceId == attributed.audienceId, "audience id did not survive encoding")
    try requireAudience(roundTripped.audienceName == "vscode", "audience name did not survive encoding")
    try requireAudience(roundTripped.repoRoot == attributed.repoRoot, "repository root did not survive encoding")
    try requireAudience(roundTripped.processCwd == attributed.processCwd, "working directory did not survive encoding")
    try requireAudience(roundTripped.provider == "deepseek", "provider did not survive encoding")
}

// MARK: - process resolver

private func testProcessResolverReadsOwnProcess() throws {
    let ownPID = getpid()
    let path = ProcessResolver.executablePath(pid: ownPID)
    try requireAudience(!path.isEmpty, "the resolver could not read its own executable path")
    try requireAudience(path.hasPrefix("/"), "the resolver returned a relative executable path")
    try requireAudience(ProcessResolver.executablePath(pid: 0).isEmpty, "pid 0 produced an executable path")
    try requireAudience(ProcessResolver.executablePath(pid: -1).isEmpty, "a negative pid produced an executable path")

    // The working directory is best effort: readable for the caller's own
    // processes and for every process when the caller is root.
    if let cwd = ProcessResolver.workingDirectory(pid: ownPID) {
        try requireAudience(cwd.hasPrefix("/"), "the resolver returned a relative working directory")
    }

    try requireAudience(ProcessResolver.bundleId(forPath: "") == nil, "an empty path produced a bundle identifier")
    try requireAudience(ProcessResolver.bundleId(forPath: "/usr/bin/curl") == nil, "a path outside an app bundle produced a bundle identifier")

    try withAudienceTemporaryDirectory { root in
        let app = root.appendingPathComponent("Example.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.audience-test"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = contents.appendingPathComponent("MacOS/Example")
        try requireAudience(
            ProcessResolver.bundleId(forPath: executable.path) == "com.example.audience-test",
            "the resolver did not read the enclosing bundle identifier"
        )
    }
}

// MARK: - matcher grouping and command lines

private func testAudienceMatcherGroups() throws {
    // Host and port share a group, so neither alone can attribute traffic.
    let proxy = Audience(
        name: "devmon-proxy",
        kind: .service,
        matchers: AudienceDiscovery.loopbackPortMatchers(port: 18080, group: "proxy")
    )
    let resolver = AudienceResolver(audiences: [proxy])

    try requireAudience(
        resolver.resolve(audienceConnection(remoteHost: "127.0.0.1", remoteIP: "127.0.0.1", remotePort: 18080)) != nil,
        "a grouped host and port did not match together"
    )
    try requireAudience(
        resolver.resolve(audienceConnection(remoteHost: "127.0.0.1", remoteIP: "127.0.0.1", remotePort: 9999)) == nil,
        "a grouped matcher matched on the host alone"
    )
    try requireAudience(
        resolver.resolve(audienceConnection(remoteHost: "203.0.113.9", remoteIP: "203.0.113.9", remotePort: 18080)) == nil,
        "a grouped matcher matched on the port alone"
    )

    // Ungrouped matchers keep the OR behaviour.
    let union = Audience(
        name: "union",
        matchers: [
            AudienceMatcher(kind: .remotePort, pattern: "11434"),
            AudienceMatcher(kind: .processPathPrefix, pattern: "/opt/tools/"),
        ]
    )
    let unionResolver = AudienceResolver(audiences: [union])
    try requireAudience(
        unionResolver.resolve(audienceConnection(remotePort: 11434)) != nil,
        "an ungrouped matcher stopped matching on its own"
    )
    try requireAudience(
        unionResolver.resolve(audienceConnection(processPath: "/opt/tools/agent")) != nil,
        "the second ungrouped matcher did not match"
    )
    try requireAudience(
        unionResolver.resolve(audienceConnection(processPath: "/opt/other/agent")) == nil,
        "an unrelated connection matched an ungrouped audience"
    )
}

private func testCommandLineMatcher() throws {
    let mcp = Audience(
        name: "mcp:sample",
        kind: .mcpServer,
        matchers: [AudienceMatcher(kind: .commandLineContains, pattern: "/Users/example/.vscode-mcp-servers/mcp/sample/index.js")]
    )
    let resolver = AudienceResolver(audiences: [mcp])
    let commandLine = "/Users/example/.nvm/versions/node/v18.12.1/bin/node /Users/example/.vscode-mcp-servers/mcp/sample/index.js"

    var connection = audienceConnection(processPath: "/Users/example/.nvm/versions/node/v18.12.1/bin/node")
    connection.processCommandLine = commandLine
    try requireAudience(resolver.resolve(connection) != nil, "an MCP server was not matched by its script path")

    var otherServer = audienceConnection(processPath: "/Users/example/.nvm/versions/node/v18.12.1/bin/node")
    otherServer.processCommandLine = "/Users/example/.nvm/versions/node/v18.12.1/bin/node /Users/example/.vscode-mcp-servers/mcp/other/index.js"
    try requireAudience(resolver.resolve(otherServer) == nil, "a different MCP server matched the sample audience")

    var noCommandLine = audienceConnection(processPath: "/usr/bin/node")
    noCommandLine.processCommandLine = nil
    try requireAudience(resolver.resolve(noCommandLine) == nil, "a missing command line matched a command-line audience")
}

private func testProcessCommandLineCapture() throws {
    let commandLine = ProcessResolver.commandLine(pid: getpid())
    try requireAudience(commandLine != nil, "the resolver could not read its own command line")
    try requireAudience(commandLine?.isEmpty == false, "the resolver returned an empty command line")
    try requireAudience(
        commandLine?.count ?? 0 <= ProcessResolver.maximumCommandLineLength,
        "the captured command line was not truncated"
    )
    try requireAudience(ProcessResolver.commandLine(pid: 0) == nil, "pid 0 produced a command line")
    try requireAudience(ProcessResolver.commandLine(pid: -1) == nil, "a negative pid produced a command line")
}

// MARK: - proxy declarations

private func testProxyDeclarationScanning() throws {
    for key in ["baseUrl", "baseURL", "BASE_URL", "api.baseUrlOverride", "anthropic_base_uri"] {
        try requireAudience(ProxyDeclarationScanner.isBaseURLKey(key), "\(key) was not recognised as a base URL key")
    }
    for key in ["url", "model", "chat.tools.urls.autoApprove", "endpoint"] {
        try requireAudience(!ProxyDeclarationScanner.isBaseURLKey(key), "\(key) was wrongly treated as a base URL key")
    }

    try requireAudience(ProxyDeclarationScanner.port(inURL: "http://localhost:18080") == 18080, "an explicit port was not read")
    try requireAudience(ProxyDeclarationScanner.port(inURL: "https://api.anthropic.com") == 443, "the https default port was not applied")
    try requireAudience(ProxyDeclarationScanner.port(inURL: "localhost:11434") == 11434, "a scheme-less host and port was not read")
    try requireAudience(ProxyDeclarationScanner.isLoopbackURL("http://127.0.0.1:18080"), "127.0.0.1 was not loopback")
    try requireAudience(ProxyDeclarationScanner.isLoopbackURL("http://localhost:18080"), "localhost was not loopback")
    try requireAudience(!ProxyDeclarationScanner.isLoopbackURL("https://api.deepseek.com"), "a public host was treated as loopback")

    // Only a real URL is a declaration. A `*_BASE_URL` holding a placeholder
    // must not become a provider endpoint reached on port 80.
    try requireAudience(ProxyDeclarationScanner.looksLikeURL("https://api.anthropic.com"), "an https URL was rejected")
    try requireAudience(ProxyDeclarationScanner.looksLikeURL("localhost:11434"), "a scheme-less host and port was rejected")
    for placeholder in ["ABC123", "", "not a url", "some/path"] {
        try requireAudience(
            !ProxyDeclarationScanner.looksLikeURL(placeholder),
            "the placeholder '\(placeholder)' was accepted as a URL"
        )
    }
    let placeholders = ProxyDeclarationScanner.declarations(
        inText: "AUTH0_ISSUER_BASE_URL=ABC123\nANTHROPIC_BASE_URL=https://api.anthropic.com",
        sourcePath: "/tmp/.env",
        clientName: "repo:x",
        audienceName: "repo:x"
    )
    try requireAudience(placeholders.count == 1, "a placeholder value produced \(placeholders.count) declarations instead of 1")
    try requireAudience(placeholders[0].key == "ANTHROPIC_BASE_URL", "the wrong declaration survived the URL check")

    // JSON: the nested key path is preserved.
    let json = Data("""
    { "provider": { "options": { "baseURL": "http://localhost:18080" } } }
    """.utf8)
    let nested = ProxyDeclarationScanner.declarations(
        inJSON: json,
        sourcePath: "/tmp/config.json",
        clientName: "opencode",
        audienceName: "opencode"
    )
    try requireAudience(nested.count == 1, "a nested base URL was not found")
    try requireAudience(nested[0].key == "provider.options.baseURL", "the nested key path was not preserved")
    try requireAudience(nested[0].target == .localProxy, "a loopback declaration was not classified as a local proxy")

    // JSONC: comments and a trailing comma defeat JSONSerialization, which is
    // why the line scanner is attempted as well.
    let jsonc = """
    {
      // point DeepSeek at the local recorder
      "deepseek-copilot.baseUrl": "http://localhost:18080",
      "zModels.api.baseUrlOverride": "http://localhost:18080",
    }
    """
    let fromJSONC = ProxyDeclarationScanner.declarations(
        inConfigFile: Data(jsonc.utf8),
        sourcePath: "/tmp/settings.json",
        clientName: "vscode",
        audienceName: "vscode"
    )
    try requireAudience(fromJSONC.count == 2, "a JSONC settings file yielded \(fromJSONC.count) declarations instead of 2")
    try requireAudience(fromJSONC.allSatisfy { $0.port == 18080 }, "a JSONC declaration lost its port")

    // Dotenv: commented lines are not declarations, and a provider URL is a
    // remote endpoint rather than a proxy.
    let dotenv = """
    # OPENAI_BASE_URL=
    ANTHROPIC_BASE_URL=https://api.anthropic.com
    LLM_PROVIDER=api
    """
    let fromEnv = ProxyDeclarationScanner.declarations(
        inText: dotenv,
        sourcePath: "/tmp/.env.example",
        clientName: "repo:agent",
        audienceName: "repo:agent"
    )
    try requireAudience(fromEnv.count == 1, "the dotenv scan found \(fromEnv.count) declarations instead of 1")
    try requireAudience(fromEnv[0].key == "ANTHROPIC_BASE_URL", "the dotenv key was misread")
    try requireAudience(fromEnv[0].target == .remoteEndpoint, "a provider URL was misclassified as a local proxy")
    try requireAudience(
        !fromEnv.contains { $0.key == "OPENAI_BASE_URL" },
        "a commented-out base URL was read as a declaration"
    )
}

private func testProxyExpectationVerdicts() throws {
    let declaration = ProxyDeclaration(
        clientName: "vscode",
        audienceName: "vscode",
        sourcePath: "/tmp/settings.json",
        key: "deepseek-copilot.baseUrl",
        url: "http://localhost:18080",
        port: 18080
    )
    func flow(audience: String?, host: String, port: Int) -> Connection {
        var connection = audienceConnection(remoteHost: host, remoteIP: host, remotePort: port)
        connection.audienceName = audience
        connection.audienceId = UUID()
        return connection
    }

    let proxied = ProxyExpectationBuilder.build(
        declarations: [declaration],
        observed: [flow(audience: "vscode", host: "127.0.0.1", port: 18080)]
    )
    try requireAudience(proxied.expectations[0].verdict == .proxied, "declared and observed traffic was not reported as proxied")
    try requireAudience(proxied.unproxiedAudiences.isEmpty, "a proxied audience was listed as unproxied")

    let bypassed = ProxyExpectationBuilder.build(
        declarations: [declaration],
        observed: [flow(audience: "vscode", host: "203.0.113.7", port: 443)]
    )
    try requireAudience(bypassed.expectations[0].verdict == .bypassed, "declared but direct traffic was not reported as bypassed")
    try requireAudience(bypassed.expectations[0].directCount == 1, "the bypassed declaration counted no direct traffic")
    try requireAudience(bypassed.expectations[0].directHosts == ["203.0.113.7"], "the direct host was not recorded")

    // A declared audience is reported through its verdict, so it must not also
    // appear in the unproxied list; an undeclared one only appears there.
    let mixed = ProxyExpectationBuilder.build(
        declarations: [declaration],
        observed: [
            flow(audience: "vscode", host: "203.0.113.7", port: 443),
            flow(audience: "mcp:sample", host: "203.0.113.8", port: 443),
        ]
    )
    try requireAudience(
        mixed.unproxiedAudiences == ["mcp:sample"],
        "the unproxied list was \(mixed.unproxiedAudiences) instead of just the undeclared audience"
    )

    // Local model traffic is neither proxied nor a provider call.
    let idle = ProxyExpectationBuilder.build(
        declarations: [declaration],
        observed: [flow(audience: "vscode", host: "127.0.0.1", port: 11434)]
    )
    try requireAudience(idle.expectations[0].verdict == .idle, "loopback traffic on another port was mistaken for a direct provider call")
    try requireAudience(idle.expectations[0].directCount == 0, "loopback traffic was counted as direct")

    // A base URL pointed at a local model server is local, not recorded. Reporting
    // it as proxied would be a false positive on the question this audit answers.
    let localModel = ProxyExpectationBuilder.build(
        declarations: [
            ProxyDeclaration(
                clientName: "repo:agent",
                audienceName: "repo:agent",
                sourcePath: "/tmp/.env",
                key: "OLLAMA_BASE_URL",
                url: "http://127.0.0.1:11434/v1",
                port: 11434
            )
        ],
        observed: [flow(audience: "repo:agent", host: "127.0.0.1", port: 11434)]
    )
    try requireAudience(
        localModel.expectations[0].verdict == .localEndpoint,
        "a local model server was reported as \(localModel.expectations[0].verdict.rawValue) instead of a local endpoint"
    )
    // Nothing is bypassed when all the traffic is local, so it must not be listed.
    try requireAudience(
        localModel.unproxiedAudiences.isEmpty,
        "a client whose only traffic is loopback was listed as bypassing the proxy"
    )
    // The moment that same client calls a provider directly, it is listed.
    let localModelWithDirect = ProxyExpectationBuilder.build(
        declarations: localModel.expectations.map {
            ProxyDeclaration(
                clientName: $0.clientName,
                audienceName: $0.audienceName,
                sourcePath: $0.sourcePath,
                key: $0.key,
                url: $0.declaredURL,
                port: $0.declaredPort
            )
        },
        observed: [
            flow(audience: "repo:agent", host: "127.0.0.1", port: 11434),
            flow(audience: "repo:agent", host: "203.0.113.9", port: 443),
        ]
    )
    try requireAudience(
        localModelWithDirect.unproxiedAudiences == ["repo:agent"],
        "a client using a local model server and calling a provider directly was not listed as bypassing"
    )

    let unattributed = ProxyExpectationBuilder.build(
        declarations: [
            ProxyDeclaration(clientName: "codex", audienceName: nil, sourcePath: "/tmp/config.toml", key: "base_url", url: "http://localhost:18080", port: 18080)
        ],
        observed: []
    )
    try requireAudience(unattributed.expectations[0].verdict == .unattributed, "a client with no audience was not reported as unattributed")

    // A client pointed at a provider endpoint is bypassing, not proxied.
    let remoteDeclaration = ProxyDeclaration(
        clientName: "repo:agent",
        audienceName: "repo:agent",
        sourcePath: "/tmp/.env",
        key: "ANTHROPIC_BASE_URL",
        url: "https://api.anthropic.com",
        port: 443
    )
    let remote = ProxyExpectationBuilder.build(
        declarations: [remoteDeclaration],
        observed: [flow(audience: "repo:agent", host: "160.79.104.10", port: 443)]
    )
    try requireAudience(remote.expectations[0].verdict == .bypassed, "a remote base URL was not reported as bypassing the proxy")
    try requireAudience(
        !remote.unproxiedAudiences.isEmpty,
        "a client pointed at a provider endpoint was treated as though it were proxied"
    )
}

// MARK: - discovery

private func withSyntheticHome(_ body: (URL) throws -> Void) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("puresnitch-discovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try body(home)
}

private func writeFixture(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func syntheticConfiguration(home: URL) -> AudienceDiscovery.Configuration {
    var configuration = AudienceDiscovery.Configuration.standard(homeDirectory: home)
    // The host machine's /Applications must not influence the fixture.
    configuration.applicationDirectories = []
    return configuration
}

private func testAudienceDiscoveryAgainstSyntheticHome() throws {
    try withSyntheticHome { home in
        let codeUser = home.appendingPathComponent("Library/Application Support/Code/User", isDirectory: true)
        let repositoryRoot = home.appendingPathComponent("Documents/GitHub", isDirectory: true)
        let repository = repositoryRoot.appendingPathComponent("agent_repo", isDirectory: true)

        try writeFixture("""
        {
          // point DeepSeek at the local recorder
          "deepseek-copilot.baseUrl": "http://localhost:18080",
        }
        """, to: codeUser.appendingPathComponent("settings.json"))

        try writeFixture("""
        {
          "servers": {
            "sample": {
              "type": "stdio",
              "command": "${userHome}/.nvm/versions/node/v18.12.1/bin/node",
              "args": ["${userHome}/.vscode-mcp-servers/mcp/sample/index.js"]
            },
            "npxy": {
              "type": "stdio",
              "command": "npx",
              "args": ["-y", "@scope/server"]
            }
          }
        }
        """, to: codeUser.appendingPathComponent("mcp.json"))

        try writeFixture("""
        [ { "name": "Ollama", "vendor": "ollama", "url": "http://127.0.0.1:11434" } ]
        """, to: codeUser.appendingPathComponent("chatLanguageModels.json"))

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".vscode-mcp-servers", isDirectory: true),
            withIntermediateDirectories: true
        )

        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeFixture("{ \"service\": { \"port\": 5001 } }", to: repository.appendingPathComponent("devmon.json"))
        try writeFixture("""
        # OPENAI_BASE_URL=
        ANTHROPIC_BASE_URL=https://api.anthropic.com
        """, to: repository.appendingPathComponent(".env.example"))

        let result = AudienceDiscovery(configuration: syntheticConfiguration(home: home)).scan()
        let names = Set(result.audiences.map(\.name))

        try requireAudience(names.contains("vscode-mcp"), "the MCP server directory audience was not discovered")
        try requireAudience(names.contains("mcp:sample"), "a declared MCP server did not get its own audience")
        try requireAudience(!names.contains("mcp:npxy"), "an npx MCP server was guessed at instead of reported")
        try requireAudience(
            result.warnings.contains { $0.contains("npxy") },
            "an unattributable MCP server was not reported"
        )
        try requireAudience(names.contains("ollama"), "the local model server was not discovered")
        try requireAudience(names.contains("repo:agent_repo"), "the repository audience was not discovered")
        try requireAudience(names.contains("service:agent_repo"), "the declared local service port was not discovered")

        let ollama = try requireAudienceUnwrap(result.audiences.first { $0.name == "ollama" }, "the ollama audience went missing")
        try requireAudience(
            ollama.matchers.allSatisfy { $0.group != nil },
            "the local model server matchers were not grouped, so a port alone would match"
        )

        let mcpSample = try requireAudienceUnwrap(result.audiences.first { $0.name == "mcp:sample" }, "the sample audience went missing")
        try requireAudience(
            mcpSample.matchers.contains { $0.pattern == home.path + "/.vscode-mcp-servers/mcp/sample/index.js" },
            "the ${userHome} placeholder was not expanded"
        )

        try requireAudience(
            result.declarations.contains { $0.key == "deepseek-copilot.baseUrl" && $0.clientName == "vscode" },
            "the VS Code base URL declaration was not found"
        )
        try requireAudience(
            result.declarations.contains { $0.key == "ANTHROPIC_BASE_URL" && $0.audienceName == "repo:agent_repo" },
            "the repository .env.example declaration was not found"
        )
        try requireAudience(
            !result.declarations.contains { $0.key == "OPENAI_BASE_URL" },
            "a commented-out base URL in .env.example was read as a declaration"
        )

        // The report ties the discovery back to observed traffic.
        var proxiedFlow = audienceConnection(remoteHost: "127.0.0.1", remoteIP: "127.0.0.1", remotePort: 18080)
        proxiedFlow.audienceName = "vscode"
        let report = ProxyExpectationBuilder.build(declarations: result.declarations, observed: [proxiedFlow])
        let vscodeExpectation = try requireAudienceUnwrap(
            report.expectations.first { $0.clientName == "vscode" },
            "the VS Code declaration produced no expectation"
        )
        try requireAudience(vscodeExpectation.verdict == .proxied, "the VS Code declaration was not matched to its observed traffic")
        try requireAudience(
            vscodeExpectation.declaredPort == 18080 && vscodeExpectation.target == .localProxy,
            "the VS Code declaration was not recognised as the recording proxy port"
        )
    }
}

private func testAudienceDiscoveryRefusesEscapingSymlinks() throws {
    try withSyntheticHome { home in
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("puresnitch-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let secret = outside.appendingPathComponent("config.toml")
        try writeFixture("base_url = \"http://localhost:18080\"", to: secret)

        let link = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        let result = AudienceDiscovery(configuration: syntheticConfiguration(home: home)).scan()
        try requireAudience(
            !result.declarations.contains { $0.key == "base_url" },
            "a symlink pointing outside the owner's home was followed"
        )
    }
}

private func testAudienceSeederReconciliation() throws {
    let stored = Audience(
        id: UUID(),
        name: "vscode-mcp",
        kind: .mcpServer,
        source: .autoDiscovered,
        enabled: false,
        matchers: [AudienceMatcher(kind: .cwdPrefix, pattern: "/old/path")],
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
    let manual = Audience(id: UUID(), name: "vscode", kind: .client, source: .manual, matchers: [])
    let discovered = [
        Audience(name: "vscode-mcp", kind: .mcpServer, source: .autoDiscovered, matchers: [AudienceMatcher(kind: .cwdPrefix, pattern: "/new/path")]),
        Audience(name: "vscode", kind: .client, source: .autoDiscovered, matchers: []),
        Audience(name: "repo:agent_repo", kind: .repo, source: .autoDiscovered, matchers: []),
    ]

    let plan = AudienceSeeder.plan(discovered: discovered, existing: [stored, manual])
    try requireAudience(plan.skipped == ["vscode"], "a manual audience was not protected from discovery")
    try requireAudience(plan.upserts.count == 2, "the seeding plan upserted \(plan.upserts.count) audiences instead of 2")

    let refreshed = try requireAudienceUnwrap(plan.upserts.first { $0.name == "vscode-mcp" }, "the discovered audience was dropped")
    try requireAudience(refreshed.id == stored.id, "re-discovery replaced the audience identity")
    try requireAudience(refreshed.createdAt == stored.createdAt, "re-discovery reset the audience creation date")
    try requireAudience(!refreshed.enabled, "re-discovery re-enabled an audience the user disabled")
    try requireAudience(refreshed.matchers.first?.pattern == "/new/path", "re-discovery did not refresh the matchers")

    try requireAudience(
        plan.upserts.contains { $0.name == "repo:agent_repo" },
        "a newly discovered audience was not seeded"
    )
}

// MARK: - entry point

func testAudienceAttributionAndPersistence() throws {
    try testAudienceModelValidation()
    try testAudienceResolutionPrecedence()
    try testAudienceAnnotation()
    try testAudienceMatcherGroups()
    try testCommandLineMatcher()
    try testProcessCommandLineCapture()
    try testRepoRootDerivation()
    try testAudienceStoreRoundTrip()
    try testConnectionColumnsMigrateFromLegacySchema()
    try testConnectionDecodesWithoutAudienceFields()
    try testProcessResolverReadsOwnProcess()
    try testProxyDeclarationScanning()
    try testProxyExpectationVerdicts()
    try testAudienceDiscoveryAgainstSyntheticHome()
    try testAudienceDiscoveryRefusesEscapingSymlinks()
    try testAudienceSeederReconciliation()
}
