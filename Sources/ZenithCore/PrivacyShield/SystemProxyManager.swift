import Foundation
import AppKit

/// Manages macOS system network proxy settings via /usr/sbin/networksetup with automatic crash-safe cleanup.
public final class SystemProxyManager: @unchecked Sendable {
    public static let shared = SystemProxyManager()

    private var activeService: String?
    private let lock = NSLock()
    private var isHookInstalled = false
    private var signalSources: [DispatchSourceSignal] = []

    public init() {
        installExitHooks()
    }

    /// Discovers the active network service name (e.g. "Wi-Fi", "Ethernet") by checking the default route interface.
    public func discoverPrimaryService() -> String? {
        // 1. Try to find active service via current default route interface
        if let activeInterface = getActiveDefaultRouteInterface(),
           let serviceName = getServiceName(forDevice: activeInterface) {
            return serviceName
        }

        // 2. Fallback to listing all network services
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let lines = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.contains("*") } // Exclude disabled services marked with asterisk

            // Prefer Wi-Fi if available, otherwise first valid service
            if let wifi = lines.first(where: { $0.lowercased().contains("wi-fi") || $0.lowercased().contains("airport") }) {
                return wifi
            }
            return lines.first
        } catch {
            NSLog("[SystemProxyManager] Failed to list network services: \(error)")
            return nil
        }
    }

    private func getActiveDefaultRouteInterface() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("interface:") {
                    return trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func getServiceName(forDevice targetDevice: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let blocks = output.components(separatedBy: "\n\n")
            for block in blocks {
                let lines = block.components(separatedBy: .newlines)
                var currentPort: String?
                var currentDevice: String?
                for line in lines {
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
        } catch {
            return nil
        }
        return nil
    }

    /// Enables HTTP & HTTPS proxy synchronously on the active macOS network service pointing to 127.0.0.1:<port>.
    @discardableResult
    public func enableProxySynchronously(port: UInt16 = 8080) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let service = discoverPrimaryService() else {
            NSLog("[SystemProxyManager] No active network service discovered")
            return false
        }
        self.activeService = service

        let portStr = String(port)
        // Ensure local and loopback addresses are never routed through the proxy
        _ = runNetworkSetup(["-setproxybypassdomains", service, "127.0.0.1", "localhost", "*.local", "169.254/16"])

        let successHTTP = runNetworkSetup(["-setwebproxy", service, "127.0.0.1", portStr]) &&
                          runNetworkSetup(["-setwebproxystate", service, "on"])
        let successHTTPS = runNetworkSetup(["-setsecurewebproxy", service, "127.0.0.1", portStr]) &&
                           runNetworkSetup(["-setsecurewebproxystate", service, "on"])

        return successHTTP && successHTTPS
    }

    /// Enables HTTP & HTTPS proxy on the active macOS network service asynchronously.
    @discardableResult
    public func enableProxy(port: UInt16 = 8080) async -> Bool {
        await Task.detached(priority: .userInitiated) { [weak self] () -> Bool in
            guard let self = self else { return false }
            return self.enableProxySynchronously(port: port)
        }.value
    }

    /// Disables HTTP & HTTPS proxy synchronously on the active macOS network service.
    @discardableResult
    public func disableProxySynchronously() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let service = activeService ?? discoverPrimaryService() else {
            return false
        }

        let offHTTP = runNetworkSetup(["-setwebproxystate", service, "off"])
        let offHTTPS = runNetworkSetup(["-setsecurewebproxystate", service, "off"])
        self.activeService = nil

        return offHTTP && offHTTPS
    }

    /// Disables HTTP & HTTPS proxy on the active macOS network service asynchronously.
    @discardableResult
    public func disableProxy() async -> Bool {
        await Task.detached(priority: .userInitiated) { [weak self] () -> Bool in
            guard let self = self else { return false }
            return self.disableProxySynchronously()
        }.value
    }

    /// Queries whether secure web proxy is enabled on the primary service.
    public func isProxyEnabled() -> Bool {
        guard let service = discoverPrimaryService() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getsecurewebproxy", service]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return false }
            return output.contains("Enabled: Yes")
        } catch {
            return false
        }
    }

    private func runNetworkSetup(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[SystemProxyManager] Execution failed for args \(arguments): \(error)")
            return false
        }
    }

    // MARK: - Fail-Safe Cleanup Hooks

    private func installExitHooks() {
        guard !isHookInstalled else { return }
        isHookInstalled = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            _ = self?.disableProxySynchronously()
        }

        // Safe GCD signal sources executed on .main queue calling disableProxySynchronously()
        for sig in [SIGINT, SIGTERM] {
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
