import Foundation
import SwiftUI
import GoldenGateCore

/// Main-actor orchestrator connecting LocalProxyServer, SystemProxyManager, and user interface.
@MainActor
public final class PrivacyShieldController: ObservableObject {
    public static let shared = PrivacyShieldController()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var isDiagnosticRunning: Bool = false
    @Published public private(set) var diagnosticMessage: String? = nil

    public var statistics: PrivacyShieldStatistics {
        PrivacyShieldStatistics.shared
    }

    private init() {
        // Guarantee clean state on launch:
        // If system proxy was left on from an earlier crash or unexpected termination,
        // cleanly reset it so user internet is never stuck in a broken state.
        if SystemProxyManager.shared.isProxyEnabled() {
            _ = SystemProxyManager.shared.disableProxySynchronously()
        }
        self.isRunning = false
        PrivacyShieldStatistics.shared.isActive = false
        let savedProvider = SettingsStore.shared.dohProvider
        LocalProxyServer.shared.provider = savedProvider
        PrivacyShieldStatistics.shared.selectedProvider = savedProvider
    }

    @Published public private(set) var isTransitioning: Bool = false

    /// Toggles the Privacy Shield on or off with re-entrancy protection.
    public func toggle() {
        guard !isTransitioning else { return }
        isTransitioning = true

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.isTransitioning = false }

            if self.isRunning {
                await self.stop()
            } else {
                await self.start()
            }
        }
    }

    /// Activates local proxy engine and system-wide macOS proxy settings asynchronously.
    public func start() async {
        guard !isRunning else { return }

        let port = UInt16(statistics.port)
        let provider = statistics.selectedProvider

        do {
            try LocalProxyServer.shared.start(port: port, provider: provider)
            let enabled = await SystemProxyManager.shared.enableProxy(port: port)
            guard enabled else {
                NSLog("[PrivacyShieldController] Failed to enable system proxy via SystemProxyManager")
                LocalProxyServer.shared.stop()
                self.isRunning = false
                statistics.isActive = false
                ToastHUDController.shared.show(
                    message: "Failed to enable system proxy",
                    icon: "exclamationmark.triangle"
                )
                return
            }
            self.isRunning = true
            statistics.isActive = true

            ToastHUDController.shared.show(
                message: "Privacy Shield: Protected",
                icon: "shield.checkered"
            )
        } catch {
            NSLog("[PrivacyShieldController] Failed to start: \(error)")
            ToastHUDController.shared.show(
                message: "Failed to start Privacy Shield: \(error.localizedDescription)",
                icon: "exclamationmark.triangle"
            )
        }
    }

    /// Deactivates proxy engine and cleanly restores macOS network settings asynchronously.
    public func stop() async {
        LocalProxyServer.shared.stop()
        _ = await SystemProxyManager.shared.disableProxy()
        self.isRunning = false
        statistics.isActive = false

        ToastHUDController.shared.show(
            message: "Privacy Shield: Inactive",
            icon: "shield.slash"
        )
    }

    /// Dynamically switches the active DoH provider, updates proxy server and statistics, and flushes DNS cache.
    public func updateProvider(_ newProvider: DoHProvider) {
        LocalProxyServer.shared.provider = newProvider
        statistics.selectedProvider = newProvider
        SettingsStore.shared.dohProvider = newProvider
        Task {
            await DoHResolver.shared.clearCache()
        }
    }

    /// Performs an asynchronous diagnostic test verifying DoH encrypted resolution and connectivity.
    public func runDiagnosticTest() async {
        guard !isDiagnosticRunning else { return }
        isDiagnosticRunning = true
        diagnosticMessage = "Testing encrypted probe..."

        let startTime = Date()
        do {
            // 1. Test resolving domain via DoH
            let testDomain = "one.one.one.one"
            let resolvedIP = try await DoHResolver.shared.resolve(domain: testDomain, provider: statistics.selectedProvider)
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

            statistics.updateLatency(elapsedMs)
            statistics.markVerified()

            // 2. If proxy is currently active, verify proxy tunnel end-to-end
            if isRunning {
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: 1,
                    kCFNetworkProxiesHTTPPort as String: statistics.port,
                    kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                    kCFNetworkProxiesHTTPSEnable as String: 1,
                    kCFNetworkProxiesHTTPSPort as String: statistics.port,
                    kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                ]
                config.timeoutIntervalForRequest = 4.0
                guard let probeURL = URL(string: "https://1.1.1.1/") else { return }
                let session = URLSession(configuration: config)
                let (_, response) = try await session.data(from: probeURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 301 else {
                    throw NSError(domain: "PrivacyShield", code: -1, userInfo: [NSLocalizedDescriptionKey: "Proxy tunnel failed"])
                }
            }

            diagnosticMessage = "✔ Probe passed: DoH \(resolvedIP) • Proxy Active (\(elapsedMs)ms)"
            ToastHUDController.shared.show(
                message: "Privacy Shield probe passed (\(elapsedMs)ms)",
                icon: "checkmark.shield.fill"
            )
        } catch {
            diagnosticMessage = "❌ Probe failed: \(error.localizedDescription)"
            ToastHUDController.shared.show(
                message: "Probe failed: \(error.localizedDescription)",
                icon: "xmark.shield"
            )
        }

        isDiagnosticRunning = false
    }
}
