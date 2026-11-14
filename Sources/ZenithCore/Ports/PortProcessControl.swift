import Foundation
import Darwin

/// Reads and signals processes. The port manager reaches the real system only through this, so tests never signal a
/// real process.
public protocol ProcessControlling: Sendable {
    /// What the system reports about `pid` now, or `nil` when there is no such process (or it cannot be read).
    func identity(of pid: Int32) -> ProcessIdentity?
    /// Sends `signal` to `pid`. Returns 0, or the `errno` that `kill(2)` set.
    func send(_ signal: Int32, to pid: Int32) -> Int32
}

/// The real thing: `proc_pidinfo` / `proc_pidpath` from libproc and `kill(2)`.
public struct SystemProcessControl: ProcessControlling {
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        var pathBuffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path: String? = length > 0 ? String(decoding: pathBuffer.prefix(Int(length)), as: UTF8.self) : nil

        return ProcessIdentity(
            uid: info.pbi_uid,
            executablePath: path,
            startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            isZombie: info.pbi_status == UInt32(SZOMB)
        )
    }

    public func send(_ signal: Int32, to pid: Int32) -> Int32 {
        // The safety rules have already refused these; this is a last line of defence against a bug elsewhere.
        guard pid > 1 else { return EPERM }
        return kill(pid, signal) == 0 ? 0 : errno
    }
}

/// Why Zenith will not stop a process.
public enum PortStopRefusal: Sendable, Hashable {
    /// PID 0 (the kernel) or 1 (launchd).
    case launchd
    /// Zenith itself.
    case zenith
    /// A process that belongs to another user (root included).
    case otherUser
    /// A program shipped with macOS (`/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`).
    case systemProcess
    /// The process could not be read, so it cannot be checked.
    case unknownProcess
    /// The PID now belongs to a different process than the one listed.
    case processChanged

    public var message: String {
        switch self {
        case .launchd:
            return String(localized: "launchd and the kernel cannot be stopped.")
        case .zenith:
            return String(localized: "This is Zenith itself. Use Quit Zenith instead.")
        case .otherUser:
            return String(localized: "This process belongs to another user. Zenith only stops your own processes.")
        case .systemProcess:
            return String(localized: "This is part of macOS. Stopping it could break the system, so Zenith does not.")
        case .unknownProcess:
            return String(localized: "Zenith could not read this process, so it does not stop it.")
        case .processChanged:
            return String(localized: "The process changed since the list was made. Refresh and try again.")
        }
    }
}

/// The rules for which processes may be stopped. Pure, so they are tested directly.
public enum PortProcessSafety {
    /// Folders that hold programs shipped with macOS. Their processes are never stopped.
    public static let protectedPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    /// Why `pid` (described by `identity`) must not be stopped, or `nil` when it may be.
    public static func refusal(pid: Int32, identity: ProcessIdentity?, currentUID: UInt32, ownPID: Int32) -> PortStopRefusal? {
        if pid <= 1 { return .launchd }
        if pid == ownPID { return .zenith }
        guard let identity else { return .unknownProcess }
        if identity.uid != currentUID { return .otherUser }
        guard let path = identity.executablePath, path.hasPrefix("/") else { return .unknownProcess }
        let resolved = (path as NSString).standardizingPath
        if protectedPathPrefixes.contains(where: { resolved.hasPrefix($0) || path.hasPrefix($0) }) {
            return .systemProcess
        }
        return nil
    }
}

/// Lists listening sockets with `lsof` and adds each process's identity.
public enum PortLister {
    public static let lsofPath = "/usr/sbin/lsof"

    public enum Failure: Error, Sendable, Equatable {
        /// `lsof` could not be started.
        case couldNotRun
        /// `lsof` reported an error and printed nothing.
        case failed(String)
    }

    public static func list(
        includeUDP: Bool,
        runner: SystemCommandRunner,
        control: ProcessControlling
    ) -> Result<[ListeningPort], Failure> {
        guard let result = runner(lsofPath, LsofPortParser.arguments(includeUDP: includeUDP)) else {
            return .failure(.couldNotRun)
        }
        // lsof exits 1 both when nothing matches and on errors; only output (or error text) tells them apart.
        let output = result.output
        if result.status != 0, output.isEmpty {
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return .failure(.failed(message)) }
        }

        var identities: [Int32: ProcessIdentity?] = [:]
        let ports = LsofPortParser.parse(output).map { entry -> ListeningPort in
            var entry = entry
            if identities[entry.pid] == nil {
                identities[entry.pid] = .some(control.identity(of: entry.pid))
            }
            entry.identity = identities[entry.pid] ?? nil
            return entry
        }
        return .success(ports)
    }
}
