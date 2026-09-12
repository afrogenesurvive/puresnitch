import Darwin
import Foundation

/// Scans the owner's client configuration and turns it into audiences.
///
/// The helper runs as root, so the owner's home is resolved from the claimed
/// owner UID (falling back to the console user) rather than from
/// `NSHomeDirectory()`, which would be root's home. Only an allow-list of paths
/// inside that home is read, symlinks that escape it are refused, and nothing is
/// ever written there.
struct AudienceDiscovery {
    struct Configuration: Sendable {
        var homeDirectory: URL
        var codeUserDirectory: URL
        var vscodeMCPServersDirectory: URL
        var repositoryRoots: [URL]
        var applicationDirectories: [URL]
        var extraClientConfigurationURLs: [URL]
        var maximumRepositories: Int
        var maximumFileBytes: Int

        static func standard(homeDirectory: URL) -> Configuration {
            let applicationSupport = homeDirectory.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
            return Configuration(
                homeDirectory: homeDirectory,
                codeUserDirectory: applicationSupport.appendingPathComponent("Code/User", isDirectory: true),
                vscodeMCPServersDirectory: homeDirectory.appendingPathComponent(".vscode-mcp-servers", isDirectory: true),
                repositoryRoots: [homeDirectory.appendingPathComponent("Documents/GitHub", isDirectory: true)],
                applicationDirectories: [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    homeDirectory.appendingPathComponent("Applications", isDirectory: true),
                ],
                extraClientConfigurationURLs: [
                    homeDirectory.appendingPathComponent(".config/opencode/opencode.jsonc"),
                    homeDirectory.appendingPathComponent(".codex/config.toml"),
                    homeDirectory.appendingPathComponent(".claude/settings.json"),
                ],
                maximumRepositories: 200,
                maximumFileBytes: 1 << 20
            )
        }
    }

    struct Result: Sendable {
        var audiences: [Audience] = []
        var declarations: [ProxyDeclaration] = []
        var warnings: [String] = []
    }

    let configuration: Configuration
    let fileManager: FileManager

    init(configuration: Configuration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    /// Home directory for a UID. `getpwuid` rather than `NSHomeDirectory()`,
    /// because the helper is root and would otherwise read root's home.
    static func homeDirectory(forUID uid: uid_t) -> URL? {
        guard let entry = getpwuid(uid), let directory = entry.pointee.pw_dir else { return nil }
        let path = String(cString: directory)
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func scan() -> Result {
        var result = Result()

        if let audience = visualStudioCodeAudience() { result.audiences.append(audience) }
        if let audience = mcpServerDirectoryAudience() { result.audiences.append(audience) }
        let mcpServers = mcpServerAudiences()
        result.audiences.append(contentsOf: mcpServers.audiences)
        result.warnings.append(contentsOf: mcpServers.warnings)
        if let audience = localModelServerAudience() { result.audiences.append(audience) }
        result.audiences.append(contentsOf: extraClientAudiences())

        for configurationURL in clientConfigurationURLs() {
            let candidate = configurationURL.url
            guard let data = read(candidate) else { continue }
            result.declarations.append(
                contentsOf: ProxyDeclarationScanner.declarations(
                    inConfigFile: data,
                    sourcePath: candidate.path,
                    clientName: configurationURL.clientName,
                    audienceName: configurationURL.audienceName
                )
            )
        }

        if let audience = proxyAudience(declarations: result.declarations) { result.audiences.append(audience) }

        for root in configuration.repositoryRoots {
            for repo in repositoryDirectories(under: root) {
                let name = repo.lastPathComponent
                result.audiences.append(repositoryAudience(name: name, path: repo.path))
                if let port = localServicePort(in: repo) {
                    result.audiences.append(localServiceAudience(name: name, port: port))
                }
            }
        }

        scanDotEnvFiles(&result)
        return result
    }

    /// `.env` inside each repository is the usual place a provider base URL is
    /// set for an agent, so both the real file and the committed example are
    /// read. Only base-URL keys are extracted; the rest of the file is ignored.
    /// Shared so the `.env` declarations and the repository audience always agree
    /// on the name they are keyed by.
    static func repositoryAudienceName(_ name: String) -> String {
        boundedName("repo:\(name)")
    }

    private func scanDotEnvFiles(_ result: inout Result) {
        for root in configuration.repositoryRoots {
            for repo in repositoryDirectories(under: root) {
                let name = Self.repositoryAudienceName(repo.lastPathComponent)
                for file in [".env", ".env.example"] {
                    let url = repo.appendingPathComponent(file)
                    guard let data = read(url) else { continue }
                    result.declarations.append(
                        contentsOf: ProxyDeclarationScanner.declarations(
                            inConfigFile: data,
                            sourcePath: url.path,
                            clientName: name,
                            audienceName: name
                        )
                    )
                }
            }
        }
    }

    // MARK: - clients

    private struct ClientConfig {
        var url: URL
        var clientName: String
        var audienceName: String?
    }

    private func clientConfigurationURLs() -> [ClientConfig] {
        var configs: [ClientConfig] = [
            ClientConfig(
                url: configuration.codeUserDirectory.appendingPathComponent("settings.json"),
                clientName: "vscode",
                audienceName: "vscode"
            ),
            ClientConfig(
                url: configuration.codeUserDirectory.appendingPathComponent("mcp.json"),
                clientName: "vscode-mcp",
                audienceName: "vscode-mcp"
            ),
        ]
        for path in configuration.extraClientConfigurationURLs {
            guard fileManager.fileExists(atPath: path.path) else { continue }
            let name = path.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: ".", with: "")
            configs.append(
                ClientConfig(url: path, clientName: name.isEmpty ? "cli" : name, audienceName: name.isEmpty ? nil : name)
            )
        }
        return configs
    }

    private func visualStudioCodeAudience() -> Audience? {
        var matchers: [AudienceMatcher] = []
        for directory in configuration.applicationDirectories {
            let app = directory.appendingPathComponent("Visual Studio Code.app", isDirectory: true)
            guard fileManager.fileExists(atPath: app.path) else { continue }
            matchers.append(AudienceMatcher(kind: .processPathPrefix, pattern: app.path + "/"))
        }
        guard !matchers.isEmpty else { return nil }
        // Only additive: helper processes report an Electron helper identifier,
        // so the path prefix above is what actually carries the coverage.
        matchers.append(AudienceMatcher(kind: .processBundleId, pattern: "com.microsoft.VSCode"))
        return Audience(
            name: "vscode",
            icon: "chevron.left.forwardslash.chevron.right",
            kind: .client,
            source: .autoDiscovered,
            matchers: matchers,
            notes: "Visual Studio Code, its extension host and its renderer helpers"
        )
    }

    private func mcpServerDirectoryAudience() -> Audience? {
        let directory = configuration.vscodeMCPServersDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        let prefix = directory.path + "/"
        return Audience(
            name: "vscode-mcp",
            icon: "puzzlepiece.extension",
            kind: .mcpServer,
            source: .autoDiscovered,
            matchers: [
                AudienceMatcher(kind: .cwdPrefix, pattern: prefix),
                AudienceMatcher(kind: .commandLineContains, pattern: prefix),
            ],
            notes: "MCP servers run out of ~/.vscode-mcp-servers"
        )
    }

    /// One audience per MCP server declared in VS Code's `mcp.json`.
    ///
    /// The launcher is `node`, and only the arguments name the server, so the
    /// script path from `args` is the matcher. A server declared without an
    /// absolute path (an `npx` package, for example) cannot be attributed and is
    /// reported instead of guessed at.
    private func mcpServerAudiences() -> (audiences: [Audience], warnings: [String]) {
        var audiences: [Audience] = []
        var warnings: [String] = []
        let url = configuration.codeUserDirectory.appendingPathComponent("mcp.json")
        guard let data = read(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["servers"] as? [String: Any] else {
            return (audiences, warnings)
        }

        for name in servers.keys.sorted() {
            guard let entry = servers[name] as? [String: Any] else { continue }
            let arguments = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            var matchers: [AudienceMatcher] = []
            for argument in arguments {
                let expanded = Self.expandPlaceholders(argument, home: configuration.homeDirectory)
                guard expanded.hasPrefix("/") else { continue }
                if !matchers.contains(where: { $0.pattern == expanded }) {
                    matchers.append(AudienceMatcher(kind: .commandLineContains, pattern: expanded))
                }
            }
            guard !matchers.isEmpty else {
                warnings.append("mcp server '\(name)' declares no absolute script path and cannot be attributed")
                continue
            }
            audiences.append(
                Audience(
                    name: "mcp:\(name)",
                    icon: "puzzlepiece",
                    kind: .mcpServer,
                    source: .autoDiscovered,
                    matchers: matchers,
                    notes: "MCP server declared in VS Code mcp.json"
                )
            )
        }
        return (audiences, warnings)
    }

    private func localModelServerAudience() -> Audience? {
        let url = configuration.codeUserDirectory.appendingPathComponent("chatLanguageModels.json")
        guard let data = read(url), let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        for element in root {
            guard let entry = element as? [String: Any],
                  let rawURL = entry["url"] as? String,
                  let host = ProxyDeclarationScanner.host(inURL: rawURL),
                  ProxyExpectationBuilder.isLoopback(host: host),
                  let port = ProxyDeclarationScanner.port(inURL: rawURL) else { continue }
            return Audience(
                name: "ollama",
                icon: "brain",
                kind: .service,
                source: .autoDiscovered,
                matchers: Self.loopbackPortMatchers(port: port, group: "local-model-\(port)"),
                notes: "Local model server declared in VS Code chatLanguageModels.json"
            )
        }
        return nil
    }

    /// Client CLIs that are identified by name on the command line. This is a
    /// substring match, so it is deliberately limited to CLIs the user actually
    /// has a configuration directory for.
    private func extraClientAudiences() -> [Audience] {
        let candidates: [(path: URL, name: String, icon: String)] = [
            (configuration.homeDirectory.appendingPathComponent(".config/opencode/opencode.jsonc"), "opencode", "terminal"),
            (configuration.homeDirectory.appendingPathComponent(".codex/config.toml"), "codex", "terminal"),
            (configuration.homeDirectory.appendingPathComponent(".claude/settings.json"), "claude", "terminal"),
        ]
        return candidates.compactMap { candidate in
            guard fileManager.fileExists(atPath: candidate.path.path) else { return nil }
            return Audience(
                name: candidate.name,
                icon: candidate.icon,
                kind: .client,
                source: .autoDiscovered,
                matchers: [AudienceMatcher(kind: .commandLineContains, pattern: candidate.name)],
                notes: "Agent CLI recognised by its configuration directory"
            )
        }
    }

    /// The proxy itself, as a destination. Seeded from what clients declared
    /// plus, when the app is installed, dev_mon's well-known port.
    private func proxyAudience(declarations: [ProxyDeclaration]) -> Audience? {
        var ports = Set(declarations.filter { $0.isLoopback }.compactMap { $0.port })
        let devmonApps = ["dev_mon.app", "dev-mon.app", "DS-mon.app"]
        let devmonInstalled = configuration.applicationDirectories.contains { directory in
            devmonApps.contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        if devmonInstalled { ports.insert(AppConstants.devmonProxyPort) }
        guard !ports.isEmpty else { return nil }

        var matchers: [AudienceMatcher] = []
        for port in ports.sorted() {
            matchers.append(contentsOf: Self.loopbackPortMatchers(port: port, group: "proxy-\(port)"))
        }
        return Audience(
            name: "devmon-proxy",
            icon: "arrow.triangle.2.circlepath",
            kind: .service,
            source: .autoDiscovered,
            matchers: matchers,
            notes: "Local provider proxy: traffic here is recorded, traffic that skips it is not"
        )
    }

    /// Host and port have to match together, so both matchers share a group.
    static func loopbackPortMatchers(port: Int, group: String? = nil) -> [AudienceMatcher] {
        [
            AudienceMatcher(kind: .remoteHost, pattern: "127.0.0.1", group: group),
            AudienceMatcher(kind: .remotePort, pattern: String(port), group: group),
        ]
    }

    // MARK: - repositories

    private func repositoryDirectories(under root: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var repositories: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard repositories.count < configuration.maximumRepositories else { break }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard fileManager.fileExists(atPath: entry.appendingPathComponent(".git").path) else { continue }
            repositories.append(entry)
        }
        return repositories
    }

    private func repositoryAudience(name: String, path: String) -> Audience {
        Audience(
            name: Self.repositoryAudienceName(name),
            icon: "folder",
            kind: .repo,
            source: .autoDiscovered,
            matchers: [
                AudienceMatcher(kind: .cwdPrefix, pattern: path),
                AudienceMatcher(kind: .commandLineContains, pattern: path),
            ],
            notes: "Working directory or command line pointing at \(path)"
        )
    }

    /// A local service a repository declares in its `devmon.json`, matched as a
    /// destination: this attributes the *clients* of that service, not the
    /// service's own listener.
    private func localServicePort(in repo: URL) -> Int? {
        let url = repo.appendingPathComponent("devmon.json")
        guard let data = read(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let service = root["service"] as? [String: Any],
              let port = service["port"] as? Int, (1...65_535).contains(port) else { return nil }
        return port
    }

    private func localServiceAudience(name: String, port: Int) -> Audience {
        Audience(
            name: Self.boundedName("service:\(name)"),
            icon: "antenna.radiowaves.left.and.right",
            kind: .service,
            source: .autoDiscovered,
            matchers: Self.loopbackPortMatchers(port: port, group: "service-\(port)"),
            notes: "Local service port \(port) declared in \(name)/devmon.json"
        )
    }

    // MARK: - file access

    /// Reads a file only when it is a small regular file whose resolved path is
    /// still inside the owner's home. The helper is root: a symlink pointing out
    /// of the home directory is refused rather than followed.
    private func read(_ url: URL) -> Data? {
        let resolvedHome = configuration.homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard path == resolvedHome || path.hasPrefix(resolvedHome + "/") else { return nil }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= configuration.maximumFileBytes else { return nil }
        return try? Data(contentsOf: resolved)
    }

    static func expandPlaceholders(_ raw: String, home: URL) -> String {
        var value = raw
        for placeholder in ["${userHome}", "$HOME", "${env:HOME}"] {
            value = value.replacingOccurrences(of: placeholder, with: home.path)
        }
        if value.hasPrefix("~") {
            value = home.path + value.dropFirst()
        }
        return value
    }

    /// Audience names are capped at 64 characters when persisted. A repository
    /// with a very long name is truncated rather than dropped, so it still gets
    /// an audience instead of silently disappearing from the audit.
    static func boundedName(_ name: String, limit: Int = 60) -> String {
        name.count <= limit ? name : String(name.prefix(limit))
    }
}

/// Reconciles discovered audiences with what is already stored.
///
/// Discovery runs on every helper start, so it must never duplicate an audience,
/// resurrect one the user disabled, or overwrite one the user edited. Identity is
/// the audience name; a manual audience of the same name always wins.
enum AudienceSeeder {
    struct Plan: Sendable {
        var upserts: [Audience] = []
        var skipped: [String] = []
    }

    static func plan(discovered: [Audience], existing: [Audience]) -> Plan {
        var current: [String: Audience] = [:]
        for audience in existing {
            if let previous = current[audience.name], previous.source == .manual { continue }
            current[audience.name] = audience
        }

        var plan = Plan()
        for var candidate in discovered {
            guard let stored = current[candidate.name] else {
                plan.upserts.append(candidate)
                continue
            }
            guard stored.source != .manual else {
                plan.skipped.append(candidate.name)
                continue
            }
            // Keep the existing identity and the user's standing choices, and
            // refresh only what discovery is authoritative for.
            candidate.id = stored.id
            candidate.createdAt = stored.createdAt
            candidate.enabled = stored.enabled
            candidate.mode = stored.mode
            plan.upserts.append(candidate)
        }
        return plan
    }
}
