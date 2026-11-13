import Foundation
import SwiftUI
import ZenithCore

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
        // Recovery of a proxy left behind by a crash runs at launch (see AppDelegate), not here:
        // this controller is created lazily, possibly long after the user has lost connectivity.
        self.isRunning = false
        PrivacyShieldStatistics.shared.isActive = false
        let savedProvider = SettingsStore.shared.dohProvider
        LocalProxyServer.shared.provider = savedProvider
        LocalProxyServer.shared.blocklist = TrackerBlockingSettings.shared.blocklist
        PrivacyShieldStatistics.shared.selectedProvider = savedProvider

        // If the listener dies while the shield is on, the system proxy would point at a dead port.
        LocalProxyServer.shared.onUnexpectedStop = { [weak self] in
            Task { @MainActor in
                await self?.handleListenerFailure()
            }
        }
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

        // The port is typed by the user: 70000 or -1 must be refused here, not trap in a conversion.
        guard let port = PrivacyShieldStatistics.validPort(statistics.port) else {
            ToastHUDController.shared.show(
                message: "Choose a port between 1024 and 65535",
                icon: "exclamationmark.triangle"
            )
            return
        }
        let provider = statistics.selectedProvider

        // Run from a disk image or an external drive, Zenith dies when that volume is ejected, and the proxy would be
        // left pointing at nothing. Say so before it happens rather than after.
        if AppLocation.isOnMountedVolume(Bundle.main.bundlePath) {
            let proceed = DestructiveConfirmation.confirm(
                title: "Zenith is running from a disk image or an external drive",
                message: "If that volume is ejected while Privacy Shield is on, Zenith quits and your internet may stop until you open Zenith again. Drag Zenith to your Applications folder and open it from there.",
                destructiveTitle: "Turn On Anyway"
            )
            guard proceed else { return }
        }

        // The system proxy is only pointed at the listener once it is really accepting connections;
        // otherwise a busy port would leave all web traffic aimed at nothing while the UI says "Protected".
        do {
            try await LocalProxyServer.shared.startAndAwaitReady(port: port, provider: provider)
        } catch {
            NSLog("[PrivacyShieldController] Failed to start: \(error)")
            ToastHUDController.shared.show(
                message: "Privacy Shield can't listen on port \(String(port))",
                icon: "exclamationmark.triangle",
                subtitle: error.localizedDescription
            )
            return
        }

        let enabled = await SystemProxyManager.shared.enableProxy(port: port)
        guard enabled else {
            NSLog("[PrivacyShieldController] Failed to enable system proxy via SystemProxyManager")
            LocalProxyServer.shared.stop()
            self.isRunning = false
            statistics.isActive = false
            ToastHUDController.shared.show(
                message: "Failed to enable system proxy",
                icon: "exclamationmark.triangle",
                subtitle: SystemProxyManager.shared.lastFailureReason
            )
            return
        }
        self.isRunning = true
        statistics.isActive = true

        ToastHUDController.shared.show(
            message: "Privacy Shield: Protected",
            icon: SymbolName.shieldProtected
        )
    }

    /// Deactivates proxy engine and cleanly restores macOS network settings asynchronously.
    public func stop() async {
        // Put the user's proxy settings back before the listener goes away, so traffic is never aimed at a dead port.
        let restored = await SystemProxyManager.shared.disableProxy()
        // New connections now go direct; let the tunnels other apps already hold finish instead of cutting them.
        // Quitting still closes them (applicationWillTerminate calls `stop()`, and the process ends anyway).
        LocalProxyServer.shared.stop(gracePeriod: restored ? 30 : 0)
        self.isRunning = false
        statistics.isActive = false

        if restored {
            ToastHUDController.shared.show(
                message: "Privacy Shield: Inactive",
                icon: "shield.slash"
            )
        } else {
            ToastHUDController.shared.show(
                message: "Privacy Shield stopped, but proxy settings were not restored",
                icon: "exclamationmark.triangle",
                subtitle: String(localized: "Zenith will retry on next launch")
            )
        }
    }

    /// Reacts to the local listener dying while the shield is on: restore the system proxy and show it as off.
    private func handleListenerFailure() async {
        guard isRunning, !isTransitioning else { return }
        _ = await SystemProxyManager.shared.disableProxy()
        self.isRunning = false
        statistics.isActive = false
        ToastHUDController.shared.show(
            message: "Privacy Shield stopped: local proxy failed",
            icon: "exclamationmark.triangle"
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
        diagnosticMessage = String(localized: "Testing encrypted probe...")

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

            diagnosticMessage = "✔ " + String(localized: "Probe passed: DoH \(resolvedIP) • Proxy Active (\(elapsedMs)ms)")
            ToastHUDController.shared.show(
                message: "Privacy Shield probe passed (\(elapsedMs)ms)",
                icon: "checkmark.shield.fill"
            )
        } catch {
            diagnosticMessage = "❌ " + String(localized: "Probe failed: \(error.localizedDescription)")
            ToastHUDController.shared.show(
                message: "Probe failed: \(error.localizedDescription)",
                icon: "xmark.shield"
            )
        }

        isDiagnosticRunning = false
    }
}
