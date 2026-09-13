import Foundation

/// Where a remote address is, according to the on-device database.
///
/// Every field is optional on purpose: a range can be present in the database
/// without a city, and plenty of addresses are simply not in it. Callers must
/// treat "unknown" and "no data" the same way - they leave the corresponding
/// `Connection` fields nil rather than inventing a location.
public struct GeoRecord: Sendable, Equatable {
    public let country: String?
    public let countryCode: String?
    public let city: String?
    public let latitude: Double?
    public let longitude: Double?

    public init(
        country: String?,
        countryCode: String?,
        city: String?,
        latitude: Double?,
        longitude: Double?
    ) {
        self.country = country
        self.countryCode = countryCode
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Offline IP geolocation backed by a DB-IP Lite `.mmdb` file.
///
/// There is no network path here, deliberately. The addresses this app observes
/// are exactly the ones a user would least want sent to a third party, and a
/// lookup that cannot fail because the Wi-Fi is down is worth more than one that
/// can. The database ships inside the app bundle and is read through
/// `MMDBReader`, which memory-maps it.
public final class IPGeoDatabase: @unchecked Sendable {

    /// The file name `Scripts/fetch_geoip.sh` installs and `project.yml` bundles.
    public static let databaseFileName = "dbip-city-lite.mmdb"

    private let reader: MMDBReader
    private let lock = NSLock()
    private var cache: [String: GeoRecord] = [:]
    /// Addresses the database has no answer for. Cached too, or every poll would
    /// re-walk the tree for the same unmapped addresses.
    private var misses: Set<String> = []
    /// Both maps are cleared together when either grows past this. A crude cap,
    /// but it bounds memory without needing an LRU list on a hot path.
    private static let cacheLimit = 4096

    public init(url: URL) throws {
        self.reader = try MMDBReader(url: url)
    }

    /// What the database says about itself, for logs and the Settings row.
    public var databaseType: String { reader.metadata.databaseType }
    public var builtOn: Date? { reader.metadata.buildEpoch }
    public var addressFamily: String { "IPv\(reader.metadata.ipVersion)" }

    /// Looks up one address, consulting an in-process cache first.
    public func locate(_ address: String) -> GeoRecord? {
        guard let packed = MMDBReader.pack(address), Self.isRoutable(packed) else { return nil }

        lock.lock()
        if let hit = cache[address] {
            lock.unlock()
            return hit
        }
        if misses.contains(address) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let record = Self.record(from: reader.lookup(packed))

        lock.lock()
        if let record {
            cache[address] = record
        } else {
            misses.insert(address)
        }
        if cache.count + misses.count > Self.cacheLimit {
            cache.removeAll(keepingCapacity: true)
            misses.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        return record
    }

    /// Maps the DB-IP/MaxMind record schema onto our own type. Kept separate
    /// from the reader so the binary-format code stays schema-agnostic.
    private static func record(from value: MMDBValue?) -> GeoRecord? {
        guard let value, case .map = value else { return nil }
        let country = value["country"]
        let location = value["location"]
        let record = GeoRecord(
            country: englishName(country?["names"]),
            countryCode: country?["iso_code"]?.stringValue,
            city: englishName(value["city"]?["names"]),
            latitude: location?["latitude"]?.doubleValue,
            longitude: location?["longitude"]?.doubleValue
        )
        // A record with nothing but a country code is still worth keeping; one
        // with no fields at all is not.
        if record.country == nil, record.countryCode == nil,
           record.city == nil, record.latitude == nil, record.longitude == nil {
            return nil
        }
        return record
    }

    /// `names` is a locale map. English is the only language the Lite database
    /// always carries, with any other single entry as a fallback.
    private static func englishName(_ names: MMDBValue?) -> String? {
        guard let names else { return nil }
        if let english = names["en"]?.stringValue, !english.isEmpty { return english }
        if case .map(let all) = names {
            for key in all.keys.sorted() {
                if let value = all[key]?.stringValue, !value.isEmpty { return value }
            }
        }
        return nil
    }

    // MARK: - Routability

    /// Loopback, link-local, private, multicast and documentation ranges carry
    /// no meaningful location, and looking them up would be pure waste. This is
    /// also what keeps LAN addresses out of the UI entirely.
    public static func isRoutable(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let a = bytes[0], b = bytes[1], c = bytes[2]
            if a == 0 || a == 10 || a == 127 { return false }   // this network, private, loopback
            if a == 100, (64...127).contains(b) { return false } // 100.64.0.0/10 CGNAT
            if a == 169, b == 254 { return false }               // 169.254.0.0/16 link-local
            if a == 172, (16...31).contains(b) { return false }  // 172.16.0.0/12
            if a == 192, b == 0, c == 0 { return false }         // 192.0.0.0/24 IETF protocol
            if a == 192, b == 0, c == 2 { return false }         // 192.0.2.0/24 TEST-NET-1
            if a == 192, b == 168 { return false }               // 192.168.0.0/16
            if a == 198, b == 18 || b == 19 { return false }     // 198.18.0.0/15 benchmarking
            if a == 198, b == 51, c == 100 { return false }      // 198.51.100.0/24 TEST-NET-2
            if a == 203, b == 0, c == 113 { return false }       // 203.0.113.0/24 TEST-NET-3
            if a >= 224 { return false }                         // multicast, reserved, broadcast
            return true
        }
        guard bytes.count == 16 else { return false }
        // IPv4-mapped (::ffff:a.b.c.d) comes from an IPv4-only socket.
        if bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0,
           bytes[4] == 0, bytes[5] == 0, bytes[6] == 0, bytes[7] == 0,
           bytes[8] == 0, bytes[9] == 0, bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isRoutable(Array(bytes[12...]))
        }
        if bytes[0] == 0xFF { return false }                       // multicast
        if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return false } // fe80::/10
        if (bytes[0] & 0xFE) == 0xFC { return false }              // fc00::/7 ULA
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false } // 2001:db8::/32
        if bytes.allSatisfy({ $0 == 0 }) { return false }          // ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false } // ::1
        return true
    }

    // MARK: - Locating the database

    /// Finds the bundled database, returning nil when it is absent.
    ///
    /// The helper is a bare Mach-O copied to `<App>.app/Contents/MacOS`, so
    /// `Bundle.main.bundlePath` is that directory and the database sits one
    /// level up in `Resources`. The `resourceURL` candidate covers the case
    /// where the same code runs inside a real bundle.
    public static func defaultDatabaseURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["PURESNITCH_GEOIP_DB"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        let executableDirectory = URL(fileURLWithPath: Bundle.main.bundlePath, isDirectory: true)
        candidates.append(
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/GeoIP/\(databaseFileName)")
        )
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("GeoIP/\(databaseFileName)"))
        }
        candidates.append(
            URL(fileURLWithPath: "/Library/Application Support/PureSnitch/\(databaseFileName)")
        )
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Loads the bundled database, logging the resolved path once. Returns nil
    /// rather than throwing when it is missing: a build without the data file
    /// should still monitor traffic, just without locations.
    public static func loadDefault() -> IPGeoDatabase? {
        guard let url = defaultDatabaseURL() else {
            PSLog.error(
                PSLog.geo,
                "no GeoIP database found; connections will have no country or coordinates. Run Scripts/fetch_geoip.sh and rebuild."
            )
            return nil
        }
        do {
            let database = try IPGeoDatabase(url: url)
            let built = database.builtOn.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown date"
            PSLog.info(
                PSLog.geo,
                "loaded \(database.databaseType) (\(database.addressFamily), built \(built)) from \(url.path)"
            )
            return database
        } catch {
            PSLog.error(PSLog.geo, "GeoIP database at \(url.path) could not be opened: \(error)")
            return nil
        }
    }
}

/// Stamps location onto a batch of connections.
///
/// This is the seam `NetMonitor` uses. It is safe to touch from more than one
/// queue: the enable flag is lock-guarded because it is written by an XPC call
/// and read on the monitoring queue.
public final class ConnectionGeolocator: @unchecked Sendable {
    public static let enabledSettingKey = "geo_lookup_enabled"

    /// Stored as "on"/"off". Only an explicit "off" disables: an absent row
    /// means on, and so does anything unreadable. The lookup is entirely local,
    /// so there is nothing to opt into, and the only writer is `encodeEnabled` -
    /// a value we cannot read is corruption, not a user's decision to refuse.
    public static func decodeEnabled(_ raw: String?) -> Bool { raw != "off" }
    public static func encodeEnabled(_ enabled: Bool) -> String { enabled ? "on" : "off" }

    private let database: IPGeoDatabase?
    private let lock = NSLock()
    private var enabledStorage: Bool

    public init(database: IPGeoDatabase?, enabled: Bool) {
        self.database = database
        self.enabledStorage = enabled && database != nil
    }

    /// True only when the user wants lookups *and* the database actually loaded.
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabledStorage
        }
        set {
            lock.lock()
            enabledStorage = newValue && database != nil
            lock.unlock()
        }
    }

    public var isDatabaseLoaded: Bool { database != nil }

    /// Returns the connections unchanged when lookups are off, so the caller can
    /// call this unconditionally.
    public func annotate(_ connections: [Connection]) -> [Connection] {
        guard isEnabled, let database else { return connections }
        return connections.map { connection in
            guard let record = database.locate(connection.remoteIP) else { return connection }
            var located = connection
            located.country = record.country
            located.countryCode = record.countryCode
            located.city = record.city
            located.latitude = record.latitude
            located.longitude = record.longitude
            return located
        }
    }
}
