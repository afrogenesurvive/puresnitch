import Foundation

/// Regression coverage for on-device IP geolocation.
///
/// Deliberately hermetic: none of these touch the 121 MB DB-IP database. CI
/// builds from a clean checkout where it is absent (it is gitignored and fetched
/// by `Scripts/fetch_geoip.sh`), so anything that needed real data would fail
/// there. The reader is exercised against the real file manually - see the
/// verification notes in docs/architecture.md.
///
/// `require`/`RegressionFailure` are file-private in HardeningRegression.swift,
/// so this file defines its own, mirroring ConnectionHistoryRegression.swift.
private struct GeoRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private func requireGeo(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw GeoRegressionFailure(description: message) }
}

/// Address parsing is the one part of the reader that can be tested without a
/// database, and it is where a subtle mistake silently returns nil for a whole
/// address family.
func testGeoAddressParsing() throws {
    try requireGeo(MMDBReader.pack("8.8.8.8") == [8, 8, 8, 8], "IPv4 should parse to four bytes")
    try requireGeo(MMDBReader.pack("0.0.0.0") == [0, 0, 0, 0], "0.0.0.0 should parse")
    try requireGeo(MMDBReader.pack("255.255.255.255") == [255, 255, 255, 255], "broadcast should parse")
    try requireGeo(MMDBReader.pack("256.1.1.1") == nil, "an octet above 255 must not parse")
    try requireGeo(MMDBReader.pack("1.2.3") == nil, "a short IPv4 address must not parse")
    try requireGeo(MMDBReader.pack("1.2.3.4.5") == nil, "a long IPv4 address must not parse")

    let loopback = MMDBReader.pack("::1")
    try requireGeo(loopback?.count == 16, "IPv6 should parse to sixteen bytes")
    try requireGeo(loopback?[15] == 1, "::1 should end in one")
    try requireGeo(loopback?[0..<15].allSatisfy { $0 == 0 } == true, "::1 should be otherwise zero")

    let documentation = MMDBReader.pack("2001:db8::1")
    try requireGeo(
        documentation == [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        "2001:db8::1 expanded incorrectly"
    )

    // The IPv4-in-IPv6 tail is the form an IPv4 socket produces on a v6 stack.
    let mapped = MMDBReader.pack("::ffff:1.2.3.4")
    try requireGeo(mapped?.count == 16, "a mapped IPv4 address should be sixteen bytes")
    try requireGeo(mapped?[10] == 0xFF && mapped?[11] == 0xFF, "the ffff prefix was lost")
    try requireGeo(Array((mapped ?? [])[12...]) == [1, 2, 3, 4], "the embedded IPv4 address was lost")

    // Fully expanded form must agree with the compressed one.
    try requireGeo(
        MMDBReader.pack("2001:0db8:0000:0000:0000:0000:0000:0001") == documentation,
        "expanded and compressed IPv6 forms disagree"
    )
    try requireGeo(MMDBReader.pack("2001:db8:::1") == nil, "a malformed IPv6 address must not parse")
    try requireGeo(MMDBReader.pack("") == nil, "an empty address must not parse")
}

/// Private, loopback, link-local, multicast and documentation ranges have no
/// meaningful location. Getting this wrong is not cosmetic: it would send LAN
/// topology into the UI as if it were a real place.
func testGeoRoutabilityFiltering() throws {
    let unroutable = [
        "0.0.0.0", "10.0.0.1", "10.255.255.254", "100.64.0.1", "100.127.255.1",
        "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.1", "192.0.0.1",
        "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.51.100.1", "203.0.113.1",
        "224.0.0.1", "239.255.255.250", "255.255.255.255",
        "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1",
        "2001:db8::1", "::ffff:192.168.0.1",
    ]
    for address in unroutable {
        guard let packed = MMDBReader.pack(address) else {
            throw GeoRegressionFailure(description: "\(address) failed to parse in the filter test")
        }
        try requireGeo(
            !IPGeoDatabase.isRoutable(packed),
            "\(address) is not a routable address and must not be looked up"
        )
    }

    let routable = [
        "8.8.8.8", "1.1.1.1", "9.9.9.9", "93.184.216.34", "172.15.0.1",
        "172.32.0.1", "100.63.0.1", "100.128.0.1", "192.167.0.1", "192.169.0.1",
        "2001:4860:4860::8888", "2606:4700:4700::1111", "::ffff:8.8.8.8",
    ]
    for address in routable {
        guard let packed = MMDBReader.pack(address) else {
            throw GeoRegressionFailure(description: "\(address) failed to parse in the filter test")
        }
        try requireGeo(
            IPGeoDatabase.isRoutable(packed),
            "\(address) is routable and should be looked up"
        )
    }

    try requireGeo(!IPGeoDatabase.isRoutable([1, 2, 3]), "a three-byte address is not routable")
    try requireGeo(!IPGeoDatabase.isRoutable([]), "an empty address is not routable")
}

/// A build without the database (every CI run, and a fresh clone before the
/// fetch script) must keep working. Geolocation degrades to "no locations" rather
/// than failing, and a corrupt file is rejected instead of being misread.
func testGeoLookupDegradesWithoutDatabase() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("puresnitch-geo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Not a MaxMind DB at all: the header marker is absent.
    let junk = directory.appendingPathComponent("junk.mmdb")
    try Data(repeating: 0x41, count: 4096).write(to: junk)
    do {
        _ = try IPGeoDatabase(url: junk)
        throw GeoRegressionFailure(description: "a file that is not an MMDB was accepted")
    } catch is GeoRegressionFailure {
        throw GeoRegressionFailure(description: "a file that is not an MMDB was accepted")
    } catch {
        // Expected: metadataMarkerMissing.
    }

    // A truncated file must also be rejected.
    let empty = directory.appendingPathComponent("empty.mmdb")
    try Data().write(to: empty)
    do {
        _ = try IPGeoDatabase(url: empty)
        throw GeoRegressionFailure(description: "an empty file was accepted as a database")
    } catch is GeoRegressionFailure {
        throw GeoRegressionFailure(description: "an empty file was accepted as a database")
    } catch {
        // Expected.
    }

    // A collector with no database can never report itself enabled, even when
    // the stored preference says on.
    let withoutDatabase = ConnectionGeolocator(database: nil, enabled: true)
    try requireGeo(!withoutDatabase.isDatabaseLoaded, "a nil database must not report as loaded")
    try requireGeo(
        !withoutDatabase.isEnabled,
        "geolocation must not be enabled when there is no database to read"
    )

    // And annotation is a no-op rather than an error.
    var connection = Connection(
        pid: 1,
        processName: "Example",
        processPath: "/Applications/Example.app",
        remoteHost: "8.8.8.8",
        remoteIP: "8.8.8.8",
        status: .established
    )
    connection.country = "Untouched"
    let annotated = withoutDatabase.annotate([connection])
    try requireGeo(annotated.count == 1, "annotation changed the number of connections")
    try requireGeo(
        annotated[0].country == "Untouched",
        "a disabled collector must leave connections exactly as they were"
    )
    try requireGeo(
        annotated[0].latitude == nil,
        "a disabled collector must not invent coordinates"
    )
}

/// The stored preference is a plain string row; an absent row has to mean "on",
/// because the lookup is entirely local and a user who never opened Settings
/// should still get locations.
func testGeoSettingEncoding() throws {
    try requireGeo(ConnectionGeolocator.decodeEnabled(nil), "an absent preference should mean enabled")
    try requireGeo(ConnectionGeolocator.decodeEnabled("on"), "\"on\" should decode as enabled")
    try requireGeo(!ConnectionGeolocator.decodeEnabled("off"), "\"off\" should decode as disabled")
    // Only an explicit "off" disables. The sole writer is `encodeEnabled`, so a
    // value we cannot read is corruption rather than a decision to refuse, and
    // the safe reading of corruption for a local-only lookup is the default.
    try requireGeo(
        ConnectionGeolocator.decodeEnabled("banana"),
        "an unrecognised value should fall back to the on default, not silently disable geolocation"
    )
    try requireGeo(ConnectionGeolocator.decodeEnabled(""), "an empty value should mean the default")
    try requireGeo(ConnectionGeolocator.encodeEnabled(true) == "on", "true should encode as \"on\"")
    try requireGeo(ConnectionGeolocator.encodeEnabled(false) == "off", "false should encode as \"off\"")
    try requireGeo(
        ConnectionGeolocator.decodeEnabled(ConnectionGeolocator.encodeEnabled(true)),
        "the preference should survive a round trip"
    )
    try requireGeo(
        !ConnectionGeolocator.decodeEnabled(ConnectionGeolocator.encodeEnabled(false)),
        "the preference should survive a round trip"
    )
}

/// The geo columns include `city`, which is appended by an `ALTER TABLE` rather
/// than declared beside `country`/`latitude`, and a `SELECT *` reader matches
/// them by position. A mis-ordered append does not throw - it silently shifts
/// every column, so `country` reads back a city. Every field therefore carries a
/// DISTINCT sentinel here: identical values would make a shift invisible.
func testGeoColumnsRoundTripThroughStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("puresnitch-geo-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("store.sqlite").path
    let identifier = UUID()
    do {
        let store = try RuleStore(path: path)
        var connection = Connection(
            id: identifier,
            pid: 4242,
            processName: "Example",
            processPath: "/Applications/Example.app",
            remoteHost: "example.com",
            remoteIP: "8.8.8.8",
            remotePort: 443,
            status: .established
        )
        connection.country = "SentinelCountry"
        connection.countryCode = "SC"
        connection.city = "SentinelCity"
        connection.latitude = 12.5
        connection.longitude = -34.25
        connection.processCwd = "SentinelWorkingDirectory"
        connection.processCommandLine = "SentinelCommandLine"
        try store.recordConnections([connection])
    }

    let reopened = try RuleStore(path: path)
    let rows = reopened.recentConnections(limit: 10)
    try requireGeo(rows.count == 1, "the geolocated row was not persisted")
    let row = rows[0]
    try requireGeo(row.country == "SentinelCountry", "country did not read back; the columns may have shifted")
    try requireGeo(row.countryCode == "SC", "country_code did not read back; the columns may have shifted")
    try requireGeo(row.city == "SentinelCity", "city did not read back; the columns may have shifted")
    try requireGeo(row.latitude == 12.5, "latitude did not read back; the columns may have shifted")
    try requireGeo(row.longitude == -34.25, "longitude did not read back; the columns may have shifted")
    // The two columns either side of the append point, to catch an off-by-one.
    try requireGeo(
        row.processCwd == "SentinelWorkingDirectory",
        "process_cwd did not read back; the columns may have shifted"
    )
    try requireGeo(
        row.processCommandLine == "SentinelCommandLine",
        "process_command_line did not read back; the columns may have shifted"
    )
    try requireGeo(row.remotePort == 443, "remote_port did not read back; the columns may have shifted")

    // A later snapshot of the same session can legitimately arrive with no
    // location at all - a lookup miss, or the user switching geolocation off.
    // The geo columns mirror the snapshot they came from rather than being
    // sticky, matching how country/latitude/longitude always behaved. That is
    // also what makes switching the feature off stop accruing stored locations.
    let plain = Connection(
        id: identifier,
        pid: 4242,
        processName: "Example",
        processPath: "/Applications/Example.app",
        remoteHost: "example.com",
        remoteIP: "8.8.8.8",
        remotePort: 443,
        status: .established
    )
    try reopened.recordConnections([plain])
    let afterBlank = reopened.recentConnections(limit: 10)
    try requireGeo(afterBlank.count == 1, "the update inserted a second row instead of upserting")
    try requireGeo(
        afterBlank[0].city == nil,
        "a later snapshot without a location should clear the stored city"
    )
    try requireGeo(
        afterBlank[0].countryCode == nil,
        "a later snapshot without a location should clear the stored country"
    )
    try requireGeo(
        afterBlank[0].latitude == nil,
        "a later snapshot without a location should clear the stored coordinates"
    )
    // The other columns must survive the same update, or the blanking above is
    // just a broken row rather than intended behaviour.
    try requireGeo(
        afterBlank[0].processCommandLine == "SentinelCommandLine",
        "an unrelated column was lost when a snapshot without a location arrived"
    )
    try requireGeo(afterBlank[0].remotePort == 443, "remote_port was lost on update")
}

/// The ordering here is load-bearing and invisible: `ActiveConnectionTracker`
/// rebuilds every Connection from the current observation and carries only
/// `id`/`firstSeen` forward, so annotating *before* `reconcile` would silently
/// drop every location on the next poll - the feature would look like it worked
/// for two seconds and then stop forever.
func testGeoEnrichmentRunsAfterReconcile() throws {
    guard let repositoryPath = ProcessInfo.processInfo.environment["PURESNITCH_REPO_DIR"],
          !repositoryPath.isEmpty else {
        throw GeoRegressionFailure(description: "PURESNITCH_REPO_DIR was not provided")
    }
    let netmon = try String(
        contentsOf: URL(fileURLWithPath: repositoryPath)
            .appendingPathComponent("Sources/Helper/NetMonitor.swift"),
        encoding: .utf8
    )
    guard let reconcileRange = netmon.range(of: "connectionTracker.reconcile"),
          let annotateRange = netmon.range(of: "geolocator.annotate") else {
        throw GeoRegressionFailure(
            description: "NetMonitor no longer reconciles and annotates; geolocation is not wired"
        )
    }
    try requireGeo(
        reconcileRange.lowerBound < annotateRange.lowerBound,
        "geolocation is applied before reconcile, so locations are discarded on the next poll"
    )
    try requireGeo(
        netmon.contains("onConnections?(geolocator.annotate(conns))"),
        "the annotated snapshot is no longer what gets published"
    )
}
