import Darwin
import Foundation

/// Cached process metadata for the connection monitor.
///
/// `lsof` reports a PID and a short command name. The executable path, the
/// working directory and the enclosing bundle identifier each cost a syscall or
/// an Info.plist read. The previous implementation spawned `/bin/ps` once per
/// connection per two-second poll, which does not survive an audience spanning
/// dozens of AI processes and their MCP children.
final class ProcessResolver: @unchecked Sendable {
    struct Info: Sendable {
        var executablePath: String
        var workingDirectory: String?
        var bundleId: String?
        var commandLine: String?
    }

    /// How much of the command line is kept. Enough for an interpreter plus its
    /// script path, short of letting a pathological argument list bloat every
    /// snapshot the helper pushes.
    static let maximumCommandLineLength = 512

    static let empty = Info(executablePath: "", workingDirectory: nil, bundleId: nil, commandLine: nil)

    private let ttl: TimeInterval
    private let lock = NSLock()
    private var cache: [Int32: (commandName: String, info: Info, storedAt: Date)] = [:]

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    /// `commandName` is the short name `lsof` reported for the PID. It is part of
    /// the cache key on purpose: macOS recycles PIDs, and a recycled PID that
    /// inherited a fresh command name must not be served the previous
    /// occupant's path, working directory or bundle identifier.
    func info(forPID pid: Int32, commandName: String = "") -> Info {
        guard pid > 0 else { return Self.empty }

        lock.lock()
        let cached = cache[pid]
        lock.unlock()
        if let cached, cached.commandName == commandName,
           Date().timeIntervalSince(cached.storedAt) < ttl {
            return cached.info
        }

        // Computed outside the lock: the syscalls and the plist read are the
        // slow part, and the cache exists to amortize them rather than to
        // serialize every poller behind them.
        let resolved = Self.read(pid: pid)

        lock.lock()
        cache[pid] = (commandName, resolved, Date())
        lock.unlock()
        return resolved
    }

    /// A socket can be reused by a new process while a stale entry is still
    /// inside the TTL, so callers that see a PID whose path changed can force a
    /// refresh instead of waiting the window out.
    func invalidate(pid: Int32) {
        lock.lock()
        cache.removeValue(forKey: pid)
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - syscalls

    private static func read(pid: Int32) -> Info {
        let path = executablePath(pid: pid)
        return Info(
            executablePath: path,
            workingDirectory: workingDirectory(pid: pid),
            bundleId: bundleId(forPath: path),
            commandLine: commandLine(pid: pid)
        )
    }

    static func executablePath(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return "" }
        return String(cString: buffer)
    }

    /// `PROC_PIDVNODEPATHINFO` carries the current and root directories. It is
    /// readable for the caller's own processes and, when the caller is root as
    /// the helper is, for every process on the system.
    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard written == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// Executable plus arguments via `KERN_PROCARGS2`, truncated to
    /// `maximumCommandLineLength`.
    ///
    /// The buffer layout is `int argc`, the executable path, NUL padding, then
    /// each argument NUL-terminated. Anything unparseable yields nil rather than
    /// a half-decoded string, because a wrong command line would mis-attribute
    /// traffic to the wrong audience.
    static func commandLine(pid: Int32, maxLength: Int = ProcessResolver.maximumCommandLineLength) -> String? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<MemoryLayout<Int32>.size]))
            }
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding

        var arguments: [String] = []
        var remaining = Int(argc)
        while remaining > 0, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index > start, let argument = String(bytes: buffer[start..<index], encoding: .utf8) {
                arguments.append(argument)
            }
            remaining -= 1
            while index < size, buffer[index] == 0 { index += 1 }
        }
        guard !arguments.isEmpty else { return nil }

        let joined = arguments.joined(separator: " ")
        return String(joined.prefix(maxLength))
    }

    /// Best-effort bundle id from the innermost `.app` enclosing the executable.
    ///
    /// Deliberately unchanged from the original implementation: a stored rule may
    /// already be pinned to the identifier this returns for a helper process, so
    /// audiences match on path prefixes instead of widening this behaviour.
    static func bundleId(forPath path: String) -> String? {
        guard !path.isEmpty, let range = path.range(of: ".app/", options: .backwards) else { return nil }
        let appPath = String(path[..<range.upperBound])
        let plist = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plist)),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dictionary["CFBundleIdentifier"] as? String
    }
}
