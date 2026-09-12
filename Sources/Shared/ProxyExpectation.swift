import Foundation

/// A client configuration that points provider traffic at a local proxy.
///
/// This is a declaration, not an observation: it records what a client *says*
/// it will do. `ProxyExpectation` compares it with the traffic that was actually
/// seen, which is the whole point of an audit. The value stored here is a base
/// URL for a provider, never a credential.
public struct ProxyDeclaration: Identifiable, Codable, Hashable, Sendable {
    /// What the base URL actually points at. A base URL aimed at a provider is
    /// not a proxy declaration - it is evidence that the client goes direct,
    /// which is the difference the audit exists to surface.
    public enum Target: String, Codable, Sendable {
        /// The local recording proxy: traffic here is captured.
        case localProxy
        /// Another loopback service, such as a local model server. Local, but
        /// not evidence that anything is being recorded.
        case localService
        /// A remote provider endpoint, reached without a proxy.
        case remoteEndpoint
    }

    public var id: UUID
    public var clientName: String
    /// Audience this client's processes belong to, when the scanner could work
    /// it out. Nil means "declared, but its traffic cannot be attributed yet".
    public var audienceName: String?
    public var sourcePath: String
    public var key: String
    public var url: String
    public var port: Int?

    public init(
        id: UUID = UUID(),
        clientName: String,
        audienceName: String? = nil,
        sourcePath: String,
        key: String,
        url: String,
        port: Int?
    ) {
        self.id = id
        self.clientName = clientName
        self.audienceName = audienceName
        self.sourcePath = sourcePath
        self.key = key
        self.url = url
        self.port = port
    }

    public var isLoopback: Bool { ProxyDeclarationScanner.isLoopbackURL(url) }

    /// Only the known recording proxy counts as proxied. A client pointed at a
    /// local model server is local, not recorded, and reporting it as proxied
    /// would be a false positive on the one question this audit exists for.
    /// A later release can let the user nominate additional proxy ports.
    public var target: Target {
        guard isLoopback else { return .remoteEndpoint }
        return port == AppConstants.devmonProxyPort ? .localProxy : .localService
    }
}

public enum ProxyExpectationVerdict: String, Codable, CaseIterable, Sendable {
    /// Declared against the recording proxy, and that port was observed in use.
    case proxied
    /// Declared, and remote traffic was observed for the same client. The client
    /// is running and its calls are still not being recorded.
    case bypassed
    /// Declared against a loopback service that is not the recording proxy: the
    /// client is local, and there is nothing for the proxy to record.
    case localEndpoint
    /// Declared, but no traffic was observed for this client at all.
    case idle
    /// Declared, but the client could not be tied to an audience, so there is
    /// nothing to compare the declaration against.
    case unattributed
}

public struct ProxyExpectation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var clientName: String
    public var audienceName: String?
    public var sourcePath: String
    public var key: String
    public var declaredURL: String
    public var declaredPort: Int?
    public var target: ProxyDeclaration.Target
    public var verdict: ProxyExpectationVerdict
    public var proxiedCount: Int
    public var directCount: Int
    /// Remote hosts reached directly for this client, most frequent first.
    public var directHosts: [String]

    public init(
        id: UUID = UUID(),
        clientName: String,
        audienceName: String?,
        sourcePath: String,
        key: String,
        declaredURL: String,
        declaredPort: Int?,
        target: ProxyDeclaration.Target,
        verdict: ProxyExpectationVerdict,
        proxiedCount: Int,
        directCount: Int,
        directHosts: [String]
    ) {
        self.id = id
        self.clientName = clientName
        self.audienceName = audienceName
        self.sourcePath = sourcePath
        self.key = key
        self.declaredURL = declaredURL
        self.declaredPort = declaredPort
        self.target = target
        self.verdict = verdict
        self.proxiedCount = proxiedCount
        self.directCount = directCount
        self.directHosts = directHosts
    }
}

public struct ProxyExpectationReport: Codable, Sendable {
    public var generatedAt: Date
    public var expectations: [ProxyExpectation]
    /// Audiences that reached remote hosts directly while no configuration
    /// pointed them at a local proxy. Derived from observed traffic rather than
    /// from declarations, so it names clients that never mentioned a proxy.
    public var unproxiedAudiences: [String]

    public init(generatedAt: Date, expectations: [ProxyExpectation], unproxiedAudiences: [String]) {
        self.generatedAt = generatedAt
        self.expectations = expectations
        self.unproxiedAudiences = unproxiedAudiences
    }
}

/// Compares what clients declare with what was observed.
public enum ProxyExpectationBuilder {
    /// Anything in this set, or in the whole 127/8 block, counts as loopback.
    public static let loopbackHostNames: Set<String> = ["localhost", "::1", "0:0:0:0:0:0:0:1"]

    public static func isLoopback(host: String) -> Bool {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if loopbackHostNames.contains(value) { return true }
        return value.hasPrefix("127.")
    }

    public static func build(
        declarations: [ProxyDeclaration],
        observed: [Connection],
        generatedAt: Date = Date()
    ) -> ProxyExpectationReport {
        var expectations: [ProxyExpectation] = []
        expectations.reserveCapacity(declarations.count)

        for declaration in declarations {
            let proxied: [Connection]
            if let port = declaration.port {
                proxied = observed.filter { isLoopback(host: $0.remoteHost) && $0.remotePort == port }
            } else {
                proxied = []
            }

            let clientObserved: [Connection]
            if let audienceName = declaration.audienceName {
                clientObserved = observed.filter { $0.audienceName == audienceName }
            } else {
                clientObserved = []
            }
            // Loopback traffic on another port (a local model server, for
            // example) is neither proxied nor a direct provider call.
            let direct = clientObserved.filter { !isLoopback(host: $0.remoteHost) }

            let verdict: ProxyExpectationVerdict
            if declaration.target == .remoteEndpoint {
                // Configured to reach the provider directly: it is running, and
                // it is not being recorded.
                verdict = direct.isEmpty ? .idle : .bypassed
            } else if !direct.isEmpty {
                // Direct provider traffic outranks a local declaration: this is
                // the client the audit is looking for.
                verdict = .bypassed
            } else if !proxied.isEmpty {
                verdict = declaration.target == .localProxy ? .proxied : .localEndpoint
            } else if declaration.audienceName == nil {
                verdict = .unattributed
            } else {
                verdict = .idle
            }

            expectations.append(
                ProxyExpectation(
                    id: declaration.id,
                    clientName: declaration.clientName,
                    audienceName: declaration.audienceName,
                    sourcePath: declaration.sourcePath,
                    key: declaration.key,
                    declaredURL: declaration.url,
                    declaredPort: declaration.port,
                    target: declaration.target,
                    verdict: verdict,
                    proxiedCount: proxied.count,
                    directCount: direct.count,
                    directHosts: mostFrequentHosts(in: direct)
                )
            )
        }

        // Only a loopback declaration puts an audience on the recorded path. A
        // client pointed at a provider endpoint still counts as unproxied.
        let declaredAudiences = Set(
            declarations.filter { $0.target == .localProxy }.compactMap { $0.audienceName }
        )
        var remoteCounts: [String: Int] = [:]
        for connection in observed where !isLoopback(host: connection.remoteHost) {
            guard let name = connection.audienceName, !name.isEmpty else { continue }
            remoteCounts[name, default: 0] += 1
        }
        let unproxied = remoteCounts
            .filter { !declaredAudiences.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { $0.key }

        return ProxyExpectationReport(
            generatedAt: generatedAt,
            expectations: expectations,
            unproxiedAudiences: unproxied
        )
    }

    private static func mostFrequentHosts(in connections: [Connection], limit: Int = 5) -> [String] {
        var counts: [String: Int] = [:]
        for connection in connections {
            let host = connection.remoteHost.isEmpty ? connection.remoteIP : connection.remoteHost
            guard !host.isEmpty else { continue }
            counts[host, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.prefix(limit).map { $0.key }
    }
}

/// Finds base-URL settings in client configuration.
///
/// Only keys whose name contains `baseurl`/`baseuri` are read, and only the URL
/// value is kept. Everything else in the file is ignored and never stored, which
/// matters because these files also carry API keys.
public enum ProxyDeclarationScanner {
    public static let maximumLineLength = 4_096

    /// `deepseek-copilot.baseUrl`, `baseURL`, `OPENAI_BASE_URL` and
    /// `anthropic_base_uri` all have to be recognised.
    public static func isBaseURLKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        return normalized.contains("baseurl") || normalized.contains("baseuri")
    }

    /// A declaration is only useful when the value is actually a URL. Requiring
    /// a scheme, or a host and port, keeps placeholders like `ABC123` out of the
    /// report; without this a `*_BASE_URL` variable holding a placeholder was
    /// recorded as a provider endpoint reached on port 80.
    public static func looksLikeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return true }
        guard let separator = trimmed.lastIndex(of: ":") else { return false }
        let host = String(trimmed[trimmed.startIndex..<separator])
        let port = String(trimmed[trimmed.index(after: separator)...])
        guard !host.isEmpty, !host.contains("/") else { return false }
        return Int(port).map { (1...65_535).contains($0) } ?? false
    }

    public static func host(inURL url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = URL(string: trimmed)?.host, !host.isEmpty { return host }
        if let host = URL(string: "http://" + trimmed)?.host, !host.isEmpty { return host }
        return nil
    }

    public static func port(inURL url: String) -> Int? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = URL(string: trimmed)?.host == nil ? "http://" + trimmed : trimmed
        guard let parsed = URL(string: candidate), parsed.host != nil else { return nil }
        if let port = parsed.port { return port }
        switch parsed.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    public static func isLoopbackURL(_ url: String) -> Bool {
        guard let host = host(inURL: url) else { return false }
        return ProxyExpectationBuilder.isLoopback(host: host)
    }

    /// Any object key naming a base URL, at any depth: VS Code settings keep them
    /// at the top level, other clients nest them under provider options.
    public static func declarations(
        inJSON data: Data,
        sourcePath: String,
        clientName: String,
        audienceName: String?
    ) -> [ProxyDeclaration] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: [(key: String, url: String)] = []
        collectBaseURLs(root, path: [], into: &found)
        return found.map { entry in
            ProxyDeclaration(
                clientName: clientName,
                audienceName: audienceName,
                sourcePath: sourcePath,
                key: entry.key,
                url: entry.url,
                port: port(inURL: entry.url)
            )
        }
    }

    /// Line-shaped `key = value` / `"key": "value"` scanning for the files that
    /// are not strict JSON: dotenv files, TOML, and JSONC with comments or
    /// trailing commas, which `JSONSerialization` refuses outright.
    public static func declarations(
        inText text: String,
        sourcePath: String,
        clientName: String,
        audienceName: String?
    ) -> [ProxyDeclaration] {
        var declarations: [ProxyDeclaration] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rawLine.count <= maximumLineLength else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            guard let separator = firstSeparator(in: line) else { continue }
            let key = trimDelimiters(String(line[line.startIndex..<separator]))
            let value = trimDelimiters(String(line[line.index(after: separator)...]))
            guard isBaseURLKey(key), !value.isEmpty, looksLikeURL(value) else { continue }
            declarations.append(
                ProxyDeclaration(
                    clientName: clientName,
                    audienceName: audienceName,
                    sourcePath: sourcePath,
                    key: key,
                    url: value,
                    port: port(inURL: value)
                )
            )
        }
        return declarations
    }

    /// JSON first, then the line scanner. A JSONC file with a trailing comma
    /// parses as neither, which is exactly why both are attempted.
    public static func declarations(
        inConfigFile data: Data,
        sourcePath: String,
        clientName: String,
        audienceName: String?
    ) -> [ProxyDeclaration] {
        let parsed = declarations(inJSON: data, sourcePath: sourcePath, clientName: clientName, audienceName: audienceName)
        if !parsed.isEmpty { return parsed }
        return declarations(
            inText: String(decoding: data, as: UTF8.self),
            sourcePath: sourcePath,
            clientName: clientName,
            audienceName: audienceName
        )
    }

    private static func collectBaseURLs(_ node: Any, path: [String], into found: inout [(key: String, url: String)]) {
        switch node {
        case let dictionary as [String: Any]:
            for key in dictionary.keys.sorted() {
                guard let value = dictionary[key] else { continue }
                let keyPath = (path + [key]).joined(separator: ".")
                if let text = value as? String, isBaseURLKey(key) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, looksLikeURL(trimmed) { found.append((keyPath, trimmed)) }
                } else {
                    collectBaseURLs(value, path: path + [key], into: &found)
                }
            }
        case let array as [Any]:
            for (index, value) in array.enumerated() {
                collectBaseURLs(value, path: path + [String(index)], into: &found)
            }
        default:
            break
        }
    }

    private static func firstSeparator(in line: String) -> String.Index? {
        let equals = line.firstIndex(of: "=")
        let colon = line.firstIndex(of: ":")
        switch (equals, colon) {
        case let (equals?, colon?): return min(equals, colon)
        case let (equals?, nil): return equals
        case let (nil, colon?): return colon
        default: return nil
        }
    }

    private static func trimDelimiters(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        while let last = value.last, last == "," || last == ";" {
            value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
