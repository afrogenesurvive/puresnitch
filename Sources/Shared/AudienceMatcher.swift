import Foundation

/// Derives the git repository a working directory belongs to.
///
/// A repository root is the only honest way to attribute a bare `node` or
/// `python` process to one of the user's agent projects: the executable path is
/// a shared runtime, the bundle identifier is absent or generic, and the working
/// directory is where the agent was actually started.
public final class RepoLocator: @unchecked Sendable {
    /// How far up from a working directory to look for `.git`. Bounded so a
    /// process whose cwd is `/` cannot walk the whole filesystem on every poll.
    public static let defaultMaxDepth = 8

    private let maxDepth: Int
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init(maxDepth: Int = RepoLocator.defaultMaxDepth) {
        self.maxDepth = maxDepth
    }

    /// Walks up from `cwd` looking for a `.git` entry: a directory in a normal
    /// clone, a file in a worktree or submodule. Results are cached because the
    /// monitor asks once per connection per poll.
    public func repoRoot(forCwd cwd: String) -> String? {
        let key = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.hasPrefix("/") else { return nil }

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Self.walkUp(from: key, maxDepth: maxDepth)

        lock.lock()
        cache[key] = resolved
        lock.unlock()
        return resolved
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private static func walkUp(from cwd: String, maxDepth: Int) -> String? {
        let fileManager = FileManager.default
        var current = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        for _ in 0...maxDepth {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }
}

/// Attributes connections to audiences.
///
/// Precedence is deliberate and total: a manual audience beats a discovered one,
/// then the longest matching pattern wins, then the audience name breaks ties so
/// a snapshot always resolves the same way. Same "first decisive match wins"
/// shape as `RuleMatcher`, without relying on dictionary ordering.
public struct AudienceResolver: Sendable {
    public let audiences: [Audience]

    public init(audiences: [Audience]) {
        self.audiences = audiences.filter { $0.enabled }
    }

    /// Length of the longest pattern that matched, or nil when no group matched.
    ///
    /// Matchers are partitioned by `group`; ungrouped matchers each form their
    /// own group. A group counts as a match only when every matcher inside it
    /// matches, and the audience matches when any group matches.
    public func matchScore(audience: Audience, connection: Connection) -> Int? {
        var groups: [[AudienceMatcher]] = []
        var grouped: [String: Int] = [:]
        for matcher in audience.matchers {
            guard let name = matcher.group else {
                groups.append([matcher])
                continue
            }
            if let existing = grouped[name] {
                groups[existing].append(matcher)
            } else {
                grouped[name] = groups.count
                groups.append([matcher])
            }
        }

        var best: Int?
        for group in groups where group.allSatisfy({ matches(matcher: $0, connection: connection) }) {
            let score = group.map(\.pattern.count).max() ?? 0
            if best.map({ score > $0 }) ?? true { best = score }
        }
        return best
    }

    public func resolve(_ connection: Connection) -> Audience? {
        var winner: Audience?
        var winnerScore = 0
        for audience in audiences {
            guard let score = matchScore(audience: audience, connection: connection) else { continue }
            guard let current = winner else {
                winner = audience
                winnerScore = score
                continue
            }
            if beats(audience, score: score, current: current, currentScore: winnerScore) {
                winner = audience
                winnerScore = score
            }
        }
        return winner
    }

    public func matches(matcher: AudienceMatcher, connection: Connection) -> Bool {
        switch matcher.kind {
        case .processPathPrefix:
            return !connection.processPath.isEmpty && connection.processPath.hasPrefix(matcher.pattern)
        case .processBundleId:
            guard let bundleId = connection.processBundleId else { return false }
            return bundleId == matcher.pattern
        case .cwdPrefix:
            guard let cwd = connection.processCwd, !cwd.isEmpty else { return false }
            return cwd.hasPrefix(matcher.pattern)
        case .commandLineContains:
            guard let commandLine = connection.processCommandLine, !commandLine.isEmpty else { return false }
            return commandLine.contains(matcher.pattern)
        case .remoteHost:
            let engine = RuleMatcher()
            if !connection.remoteHost.isEmpty,
               engine.hostMatches(pattern: matcher.pattern, host: connection.remoteHost) {
                return true
            }
            if !connection.remoteIP.isEmpty,
               engine.hostMatches(pattern: matcher.pattern, host: connection.remoteIP) {
                return true
            }
            if !connection.remoteIP.isEmpty,
               engine.ipMatches(pattern: matcher.pattern, ip: connection.remoteIP) {
                return true
            }
            return false
        case .remotePort:
            guard let port = Int(matcher.pattern) else { return false }
            return connection.remotePort == port
        }
    }

    /// Tag every connection with the audience and repository it belongs to.
    ///
    /// One pure pass over the snapshot, so the rows persisted by the helper and
    /// the rows pushed to the UI can never disagree about attribution.
    public func annotate(_ connections: [Connection], repoLocator: RepoLocator? = nil) -> [Connection] {
        connections.map { connection in
            var annotated = connection
            if let audience = resolve(connection) {
                annotated.audienceId = audience.id
                annotated.audienceName = audience.name
            } else {
                annotated.audienceId = nil
                annotated.audienceName = nil
            }
            if annotated.repoRoot == nil, let locator = repoLocator, let cwd = annotated.processCwd {
                annotated.repoRoot = locator.repoRoot(forCwd: cwd)
            }
            return annotated
        }
    }

    private func beats(_ candidate: Audience, score: Int, current: Audience, currentScore: Int) -> Bool {
        let candidateIsManual = candidate.source == .manual
        let currentIsManual = current.source == .manual
        if candidateIsManual != currentIsManual { return candidateIsManual }
        if score != currentScore { return score > currentScore }
        return candidate.name < current.name
    }
}
