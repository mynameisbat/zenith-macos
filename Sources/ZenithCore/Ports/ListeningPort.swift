import Foundation

/// The transport a socket uses.
public enum PortProtocol: String, Sendable, Hashable, CaseIterable {
    case tcp = "TCP"
    case udp = "UDP"
}

/// Who can reach a listening socket, judged from the address it is bound to.
public enum PortReach: Sendable, Hashable {
    /// 127.0.0.1, ::1 and the rest of the loopback range: only this Mac.
    case thisMacOnly
    /// `*`, 0.0.0.0 or `::`: every network interface, so other machines on the network too.
    case allInterfaces
    /// One particular address (a LAN or VPN address).
    case specificAddress

    public static func of(address: String) -> PortReach {
        let host = address.lowercased()
        if host == "*" || host == "0.0.0.0" || host == "::" || host == "[::]" {
            return .allInterfaces
        }
        if host == "::1" || host.hasPrefix("127.") || host == "localhost" {
            return .thisMacOnly
        }
        return .specificAddress
    }
}

/// What the system says about a process right now. Read again before a signal is sent, so a PID that was reused by
/// another program in the meantime is never signalled.
public struct ProcessIdentity: Sendable, Hashable {
    public let uid: UInt32
    public let executablePath: String?
    /// Start time in microseconds since 1970; together with the PID it names one process run.
    public let startTime: UInt64
    /// A zombie has exited and only waits for its parent; it no longer holds any socket.
    public let isZombie: Bool

    public init(uid: UInt32, executablePath: String?, startTime: UInt64, isZombie: Bool = false) {
        self.uid = uid
        self.executablePath = executablePath
        self.startTime = startTime
        self.isZombie = isZombie
    }

    /// Whether `other` is the same run of the same program (the zombie flag aside).
    public func isSameProcess(as other: ProcessIdentity) -> Bool {
        uid == other.uid && startTime == other.startTime && executablePath == other.executablePath
    }
}

/// One socket a process listens on (TCP) or is bound to without a peer (UDP).
public struct ListeningPort: Sendable, Hashable, Identifiable {
    public let pid: Int32
    public let processName: String
    public let uid: UInt32?
    public let user: String?
    public let proto: PortProtocol
    /// The bound address as `lsof` prints it, without brackets: `*`, `127.0.0.1`, `::1`, `fe80::1%lo0`.
    public let address: String
    public let port: UInt16
    /// Filled in by `PortLister` after parsing; `nil` when the process could not be read.
    public var identity: ProcessIdentity?

    public init(
        pid: Int32,
        processName: String,
        uid: UInt32?,
        user: String?,
        proto: PortProtocol,
        address: String,
        port: UInt16,
        identity: ProcessIdentity? = nil
    ) {
        self.pid = pid
        self.processName = processName
        self.uid = uid
        self.user = user
        self.proto = proto
        self.address = address
        self.port = port
        self.identity = identity
    }

    public var id: String { "\(pid)|\(proto.rawValue)|\(address)|\(port)" }

    public var reach: PortReach { PortReach.of(address: address) }

    /// The address in words: "All interfaces", "This Mac only", or the address itself.
    public var addressDescription: String {
        switch reach {
        case .allInterfaces: return String(localized: "All interfaces")
        case .thisMacOnly: return String(localized: "This Mac only (\(address))")
        case .specificAddress: return address
        }
    }

    /// The `.app` bundle the executable lives in (the outermost one, so a helper shows its app), if any.
    public var appBundlePath: String? {
        guard let path = identity?.executablePath, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.upperBound].dropLast())
    }
}

/// Parses the field output of `lsof -F pcuLftPnT` (one field per line, the first character naming it).
public enum LsofPortParser {
    /// The arguments `PortLister` passes to `/usr/sbin/lsof`: numeric addresses and ports (no DNS lookups), full
    /// command names, listening TCP sockets and, when asked, every UDP socket (connected ones are dropped here).
    public static func arguments(includeUDP: Bool) -> [String] {
        var arguments = ["-nP", "-w", "+c", "0", "-iTCP", "-sTCP:LISTEN"]
        if includeUDP { arguments.append("-iUDP") }
        arguments += ["-F", "pcuLftPnT"]
        return arguments
    }

    /// Every distinct listening socket in `output`, sorted by port, then protocol, then PID. The same socket shared
    /// by several descriptors, and an IPv4 and IPv6 wildcard pair on one port, become one entry.
    public static func parse(_ output: String) -> [ListeningPort] {
        var results: [ListeningPort] = []
        var seen = Set<String>()

        var pid: Int32?
        var command = ""
        var uid: UInt32?
        var login: String?

        var fileProto: PortProtocol?
        var fileName: String?
        var fileState: String?

        func flushFile() {
            defer {
                fileProto = nil
                fileName = nil
                fileState = nil
            }
            guard let pid, let proto = fileProto, let name = fileName else { return }
            // lsof was asked for listening TCP only, but say so here too, so the parser stands on its own.
            if proto == .tcp, let state = fileState, state != "LISTEN" { return }
            guard let (address, port) = splitEndpoint(name) else { return }
            let entry = ListeningPort(
                pid: pid,
                processName: command.isEmpty ? String(pid) : command,
                uid: uid,
                user: login,
                proto: proto,
                address: address,
                port: port
            )
            if seen.insert(entry.id).inserted {
                results.append(entry)
            }
        }

        for rawLine in output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = Substring(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flushFile()
                pid = Int32(value)
                command = ""
                uid = nil
                login = nil
            case "c":
                command = value
            case "u":
                uid = UInt32(value)
            case "L":
                login = value
            case "f":
                flushFile()
            case "P":
                fileProto = PortProtocol(rawValue: value.uppercased())
            case "n":
                fileName = value
            case "T":
                if value.hasPrefix("ST=") { fileState = String(value.dropFirst(3)) }
            default:
                continue // t (IPv4/IPv6) and anything newer lsof adds
            }
        }
        flushFile()

        return results.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.proto != $1.proto { return $0.proto == .tcp }
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.address < $1.address
        }
    }

    /// Splits `host:port` (`[v6]:port` for IPv6). `nil` for a connected socket (`a->b`), a port of `*`, or anything
    /// that is not a port number.
    static func splitEndpoint(_ name: String) -> (address: String, port: UInt16)? {
        guard !name.contains("->"), let colon = name.lastIndex(of: ":") else { return nil }
        var host = String(name[..<colon])
        let portText = name[name.index(after: colon)...]
        guard let port = UInt16(portText), port > 0 else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        if host == "0.0.0.0" || host == "::" { host = "*" }
        return (host, port)
    }
}
