import Foundation
import AppKit
import Darwin

/// One proxy protocol's configuration as reported by `networksetup -get…proxy`.
public struct SystemProxyConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var server: String
    public var port: Int
    public var isAuthenticated: Bool

    public init(isEnabled: Bool, server: String, port: Int, isAuthenticated: Bool = false) {
        self.isEnabled = isEnabled
        self.server = server
        self.port = port
        self.isAuthenticated = isAuthenticated
    }
}

/// Proxy settings of one network service captured before Privacy Shield takes over, so they can be put back.
public struct SystemProxySnapshot: Codable, Equatable, Sendable {
    public let service: String
    public let shieldPort: UInt16
    public let web: SystemProxyConfiguration
    public let secureWeb: SystemProxyConfiguration
    public let bypassDomains: [String]
}

/// Manages macOS system network proxy settings via /usr/sbin/networksetup.
///
/// Before pointing the system at Zenith's local proxy it records what was configured (and persists that record),
/// and it only ever undoes settings that still point at Zenith, so a user's own proxy is never discarded.
public final class SystemProxyManager: @unchecked Sendable {
    public static let shared = SystemProxyManager()

    private enum ProxyKind {
        case web
        case secureWeb

        var getCommand: String { self == .web ? "-getwebproxy" : "-getsecurewebproxy" }
        var setCommand: String { self == .web ? "-setwebproxy" : "-setsecurewebproxy" }
        var stateCommand: String { self == .web ? "-setwebproxystate" : "-setsecurewebproxystate" }
    }

    private static let networksetupPath = "/usr/sbin/networksetup"
    private static let snapshotDefaultsKey = "com.zenith.privacyshield.proxySnapshot"
    private static let requiredBypassDomains = ["127.0.0.1", "localhost", "*.local", "169.254/16"]

    private let runner: SystemCommandRunner
    private let defaults: UserDefaults
    private let portProbe: @Sendable (UInt16) -> Bool

    private let lock = NSLock()
    private var activeSnapshot: SystemProxySnapshot?
    private var failureReason: String?
    private var signalSources: [DispatchSourceSignal] = []

    public init(
        runner: @escaping SystemCommandRunner = SystemProxyManager.processRunner,
        defaults: UserDefaults = .standard,
        portProbe: @escaping @Sendable (UInt16) -> Bool = SystemProxyManager.isLoopbackPortListening,
        installExitHooks: Bool = true
    ) {
        self.runner = runner
        self.defaults = defaults
        self.portProbe = portProbe
        if installExitHooks {
            self.installExitHooks()
        }
    }

    /// Why the last `enableProxySynchronously` call failed, for user-facing messages.
    public var lastFailureReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return failureReason
    }

    /// True while Zenith has changed the system proxy and has not yet put the previous settings back.
    public var hasPendingRestore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSnapshot != nil || loadPersistedSnapshot() != nil
    }

    // MARK: - Service Discovery

    /// Discovers the active network service name (e.g. "Wi-Fi", "Ethernet") by checking the default route interface.
    public func discoverPrimaryService() -> String? {
        // 1. Try to find active service via current default route interface
        if let activeInterface = activeDefaultRouteInterface(),
           let serviceName = serviceName(forDevice: activeInterface) {
            return serviceName
        }

        // 2. Fallback to listing all network services
        guard let output = networksetup(["-listallnetworkservices"])?.output else {
            NSLog("[SystemProxyManager] Failed to list network services")
            return nil
        }

        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("*") } // Exclude disabled services marked with asterisk

        // Prefer Wi-Fi if available, otherwise first valid service
        if let wifi = lines.first(where: { $0.lowercased().contains("wi-fi") || $0.lowercased().contains("airport") }) {
            return wifi
        }
        return lines.first
    }

    private func activeDefaultRouteInterface() -> String? {
        guard let output = runner("/sbin/route", ["-n", "get", "default"])?.output else { return nil }
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func serviceName(forDevice targetDevice: String) -> String? {
        guard let output = networksetup(["-listallhardwareports"])?.output else { return nil }
        for block in output.components(separatedBy: "\n\n") {
            var currentPort: String?
            var currentDevice: String?
            for line in block.components(separatedBy: .newlines) {
                if line.hasPrefix("Hardware Port:") {
                    currentPort = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("Device:") {
                    currentDevice = line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
            if let dev = currentDevice, dev == targetDevice, let port = currentPort {
                return port
            }
        }
        return nil
    }

    // MARK: - Enable

    /// Points the HTTP & HTTPS proxy of the active macOS network service at 127.0.0.1:<port>,
    /// after recording the settings it replaces.
    @discardableResult
    public func enableProxySynchronously(port: UInt16 = 8080) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        failureReason = nil

        guard let service = discoverPrimaryService() else {
            return failEnable("No active network service discovered")
        }

        // A snapshot for this service means Privacy Shield is already active: keep the original settings.
        let snapshot: SystemProxySnapshot
        if let existing = activeSnapshot ?? loadPersistedSnapshot(), existing.service == service {
            snapshot = existing
        } else {
            guard let captured = captureSnapshot(service: service, shieldPort: port) else {
                return failEnable("Could not read the current proxy settings")
            }
            if (captured.web.isEnabled && captured.web.isAuthenticated)
                || (captured.secureWeb.isEnabled && captured.secureWeb.isAuthenticated) {
                // The stored credentials cannot be read back, so they could not be restored afterwards.
                return failEnable("An authenticated proxy is configured for \(service); Privacy Shield will not replace it")
            }
            snapshot = captured
            persist(snapshot)
        }

        let portString = String(port)
        let bypass = snapshot.bypassDomains + Self.requiredBypassDomains.filter { !snapshot.bypassDomains.contains($0) }
        let applied = succeeded(["-setproxybypassdomains", service] + bypass)
            && succeeded([ProxyKind.web.setCommand, service, "127.0.0.1", portString])
            && succeeded([ProxyKind.web.stateCommand, service, "on"])
            && succeeded([ProxyKind.secureWeb.setCommand, service, "127.0.0.1", portString])
            && succeeded([ProxyKind.secureWeb.stateCommand, service, "on"])

        guard applied else {
            _ = restoreLocked(snapshot)
            return failEnable("networksetup could not change the proxy settings for \(service)")
        }

        activeSnapshot = snapshot
        return true
    }

    /// Enables HTTP & HTTPS proxy on the active macOS network service asynchronously.
    @discardableResult
    public func enableProxy(port: UInt16 = 8080) async -> Bool {
        await Task.detached(priority: .userInitiated) { [weak self] () -> Bool in
            guard let self = self else { return false }
            return self.enableProxySynchronously(port: port)
        }.value
    }

    private func failEnable(_ reason: String) -> Bool {
        failureReason = reason
        NSLog("[SystemProxyManager] \(reason)")
        return false
    }

    private func captureSnapshot(service: String, shieldPort: UInt16) -> SystemProxySnapshot? {
        guard let web = readConfiguration(.web, service: service),
              let secureWeb = readConfiguration(.secureWeb, service: service),
              let bypass = networksetup(["-getproxybypassdomains", service]), bypass.status == 0 else {
            return nil
        }
        return SystemProxySnapshot(
            service: service,
            shieldPort: shieldPort,
            web: discardingZenithEndpoint(web, port: shieldPort),
            secureWeb: discardingZenithEndpoint(secureWeb, port: shieldPort),
            bypassDomains: Self.parseBypassDomains(bypass.output)
        )
    }

    /// A proxy already pointing at Zenith is a leftover of an earlier unclean exit, not a user setting to restore.
    private func discardingZenithEndpoint(_ config: SystemProxyConfiguration, port: UInt16) -> SystemProxyConfiguration {
        guard Self.isZenithEndpoint(config, port: port) else { return config }
        var inactive = config
        inactive.isEnabled = false
        return inactive
    }

    // MARK: - Disable / Restore

    /// Puts the proxy settings recorded by `enableProxySynchronously` back.
    /// Returns `true` when there was nothing of Zenith's to undo.
    @discardableResult
    public func disableProxySynchronously() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let snapshot = activeSnapshot ?? loadPersistedSnapshot() else {
            return true
        }
        return restoreLocked(snapshot)
    }

    /// Restores the previous HTTP & HTTPS proxy settings asynchronously.
    @discardableResult
    public func disableProxy() async -> Bool {
        await Task.detached(priority: .userInitiated) { [weak self] () -> Bool in
            guard let self = self else { return false }
            return self.disableProxySynchronously()
        }.value
    }

    /// Undoes a system proxy left behind by a previous run that exited without cleaning up.
    ///
    /// With a persisted record the original settings are restored. Without one (older versions kept none),
    /// only a loopback proxy on `legacyPort` whose listener is gone is switched off, because it would swallow all
    /// web traffic; a live local proxy such as a debugging tool is never touched.
    @discardableResult
    public func recoverFromUncleanShutdown(legacyPort: UInt16 = 8080) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let snapshot = loadPersistedSnapshot() {
            activeSnapshot = snapshot
            return restoreLocked(snapshot)
        }

        guard let service = discoverPrimaryService(), !portProbe(legacyPort) else { return false }

        var switchedOff = false
        for kind in [ProxyKind.web, .secureWeb] {
            guard let config = readConfiguration(kind, service: service),
                  config.isEnabled, config.port == Int(legacyPort), Self.isLoopback(config.server) else { continue }
            switchedOff = succeeded([kind.stateCommand, service, "off"]) || switchedOff
        }
        return switchedOff
    }

    /// Restores each protocol only if it still points at Zenith, so settings the user changed in the meantime survive.
    private func restoreLocked(_ snapshot: SystemProxySnapshot) -> Bool {
        let service = snapshot.service
        var success = true

        for (kind, original) in [(ProxyKind.web, snapshot.web), (ProxyKind.secureWeb, snapshot.secureWeb)] {
            guard let current = readConfiguration(kind, service: service) else {
                success = false
                continue
            }
            guard current.server == "127.0.0.1", current.port == Int(snapshot.shieldPort) else { continue }
            if !original.server.isEmpty, original.port > 0 {
                success = succeeded([kind.setCommand, service, original.server, String(original.port)]) && success
            }
            success = succeeded([kind.stateCommand, service, original.isEnabled ? "on" : "off"]) && success
        }

        if let current = networksetup(["-getproxybypassdomains", service]), current.status == 0 {
            let expected = snapshot.bypassDomains
                + Self.requiredBypassDomains.filter { !snapshot.bypassDomains.contains($0) }
            if Self.parseBypassDomains(current.output) == expected {
                let restored = snapshot.bypassDomains.isEmpty ? ["Empty"] : snapshot.bypassDomains
                success = succeeded(["-setproxybypassdomains", service] + restored) && success
            }
        } else {
            success = false
        }

        // Keep the record after a partial failure so the next launch can retry.
        if success {
            activeSnapshot = nil
            clearPersistedSnapshot()
        }
        return success
    }

    // MARK: - Queries

    /// Queries whether the secure web proxy is enabled on the primary service (whoever configured it).
    public func isProxyEnabled() -> Bool {
        guard let service = discoverPrimaryService() else { return false }
        return readConfiguration(.secureWeb, service: service)?.isEnabled ?? false
    }

    /// Queries whether the primary service's proxy currently points at Zenith's local endpoint.
    public func isZenithProxyActive(port: UInt16) -> Bool {
        guard let service = discoverPrimaryService() else { return false }
        return [ProxyKind.web, .secureWeb].contains { kind in
            readConfiguration(kind, service: service).map { Self.isZenithEndpoint($0, port: port) } ?? false
        }
    }

    // MARK: - Parsing

    static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1"
    }

    static func isZenithEndpoint(_ config: SystemProxyConfiguration, port: UInt16) -> Bool {
        config.isEnabled && isLoopback(config.server) && config.port == Int(port)
    }

    /// Parses `networksetup -getwebproxy` / `-getsecurewebproxy` output; `nil` when it is not recognisable.
    static func parseProxyConfiguration(_ output: String) -> SystemProxyConfiguration? {
        var isEnabled = false
        var server = ""
        var port = 0
        var isAuthenticated = false
        var sawEnabledField = false

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Enabled":
                isEnabled = value.lowercased() == "yes"
                sawEnabledField = true
            case "Server":
                server = value
            case "Port":
                port = Int(value) ?? 0
            case "Authenticated Proxy Enabled":
                isAuthenticated = value != "0" && value.lowercased() != "no"
            default:
                break
            }
        }
        guard sawEnabledField else { return nil }
        return SystemProxyConfiguration(isEnabled: isEnabled, server: server, port: port, isAuthenticated: isAuthenticated)
    }

    /// Parses `networksetup -getproxybypassdomains` output (one domain per line, or a sentence when none are set).
    /// A bypass entry never contains whitespace, so that is what tells the "none set" sentence apart from entries.
    static func parseBypassDomains(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }
    }

    // MARK: - Command Helpers

    private func networksetup(_ arguments: [String]) -> SystemCommandResult? {
        runner(Self.networksetupPath, arguments)
    }

    private func succeeded(_ arguments: [String]) -> Bool {
        guard let result = networksetup(arguments) else { return false }
        if result.status != 0 {
            NSLog("[SystemProxyManager] networksetup %@ exited with status %d", arguments.first ?? "", result.status)
        }
        return result.status == 0
    }

    private func readConfiguration(_ kind: ProxyKind, service: String) -> SystemProxyConfiguration? {
        guard let result = networksetup([kind.getCommand, service]), result.status == 0 else { return nil }
        return Self.parseProxyConfiguration(result.output)
    }

    /// Runs a real process (see `SystemCommand.processRunner`).
    public static let processRunner: SystemCommandRunner = SystemCommand.processRunner

    /// True when something accepts TCP connections on 127.0.0.1:<port>.
    public static let isLoopbackPortListening: @Sendable (UInt16) -> Bool = { port in
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - Persistence

    private func persist(_ snapshot: SystemProxySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.snapshotDefaultsKey)
    }

    private func loadPersistedSnapshot() -> SystemProxySnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SystemProxySnapshot.self, from: data)
    }

    private func clearPersistedSnapshot() {
        defaults.removeObject(forKey: Self.snapshotDefaultsKey)
    }

    // MARK: - Fail-Safe Cleanup Hooks

    private func installExitHooks() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            _ = self?.disableProxySynchronously()
        }

        // Safe GCD signal sources executed on .main queue calling disableProxySynchronously()
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN) // Ignore default POSIX disposition
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                NSLog("[SystemProxyManager] Caught signal %d, safely restoring system proxy...", sig)
                _ = self?.disableProxySynchronously()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
