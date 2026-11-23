import Foundation
import SQLite3

/// One request recorded by the dev_mon (DS-mon) local proxy.
///
/// This is a read-only projection of a row in dev_mon's `usage.db`. PureSnitch
/// never writes this database; it opens it with `SQLITE_OPEN_READONLY` and only
/// ever selects recent rows.
public struct DevMonRequest: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var timestamp: Date
    public var providerId: String
    public var model: String
    public var endpoint: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var cachedTokens: Int
    public var latencyMs: Double
    public var statusCode: Int
    public var userAgent: String
    public var repo: String

    public init(
        id: String,
        timestamp: Date,
        providerId: String,
        model: String,
        endpoint: String,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        cachedTokens: Int,
        latencyMs: Double,
        statusCode: Int,
        userAgent: String,
        repo: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.providerId = providerId
        self.model = model
        self.endpoint = endpoint
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
        self.latencyMs = latencyMs
        self.statusCode = statusCode
        self.userAgent = userAgent
        self.repo = repo
    }
}

/// Direct, read-only access to dev_mon's usage log.
///
/// dev_mon stores every proxied request in
/// `~/Library/Application Support/dev_mon/usage.db` (WAL mode). This reader is
/// deliberately defensive: a missing, migrating, or locked database yields an
/// empty list rather than an error, because the request log is an enhancement
/// on top of the connection observation PureSnitch already does itself.
public enum DevMonReader {
    public static var dbPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("dev_mon/usage.db").path
    }

    /// The most recent proxied requests, newest first.
    public static func recent(limit: Int = 50) -> [DevMonRequest] {
        guard limit > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        // Columns are named explicitly: the table was shaped by a sequence of
        // ALTER TABLE migrations, so a SELECT * would depend on their order.
        let sql = """
        SELECT uuid, timestamp, provider_id, model, endpoint,
               prompt_tokens, completion_tokens, total_tokens, cached_tokens,
               latency_ms, status_code, user_agent, repo
        FROM usage_log
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var requests: [DevMonRequest] = []
        requests.reserveCapacity(limit)
        while sqlite3_step(stmt) == SQLITE_ROW {
            requests.append(
                DevMonRequest(
                    id: text(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    providerId: text(stmt, 2),
                    model: text(stmt, 3),
                    endpoint: text(stmt, 4),
                    promptTokens: Int(sqlite3_column_int64(stmt, 5)),
                    completionTokens: Int(sqlite3_column_int64(stmt, 6)),
                    totalTokens: Int(sqlite3_column_int64(stmt, 7)),
                    cachedTokens: Int(sqlite3_column_int64(stmt, 8)),
                    latencyMs: sqlite3_column_double(stmt, 9),
                    statusCode: Int(sqlite3_column_int(stmt, 10)),
                    userAgent: text(stmt, 11),
                    repo: text(stmt, 12)
                )
            )
        }
        return requests
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let stmt, let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }
}
