import Testing
import Foundation
import Network
import AppKit
@testable import ZenithCore

@Suite("Privacy Shield End-to-End System Proxy Suite")
struct PrivacyShieldE2ETest {

    /// Switches the real macOS system proxy on and off and sends traffic to the internet, so it only runs on request:
    /// `ZENITH_E2E_SYSTEM=1 swift test --filter PrivacyShieldE2ETest`.
    @Test(
        "E2E-01: Full system proxy enabling, native URLSession request, and safe cleanup",
        .enabled(if: ProcessInfo.processInfo.environment["ZENITH_E2E_SYSTEM"] == "1", "Changes the machine's real system proxy; set ZENITH_E2E_SYSTEM=1 to run")
    )
    func testE2ESystemProxy() async throws {
        let server = LocalProxyServer.shared
        try server.start(port: 8080, provider: .cloudflare)
        defer {
            _ = SystemProxyManager.shared.disableProxySynchronously()
            server.stop()
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        let service = SystemProxyManager.shared.discoverPrimaryService()
        #expect(service != nil)

        let enabled = await SystemProxyManager.shared.enableProxy(port: 8080)
        #expect(enabled == true)

        // Give macOS time to apply system configuration
        try await Task.sleep(nanoseconds: 500_000_000)

        // Test 1: plain HTTP curl through proxy
        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p1.arguments = ["-v", "-L", "-x", "http://127.0.0.1:8080", "http://1.1.1.1", "--max-time", "6"]
        let pipe1 = Pipe()
        p1.standardError = pipe1
        try p1.run()
        p1.waitUntilExit()
        let err1 = String(data: pipe1.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("=== E2E curl http://1.1.1.1 STDERR: ===\n\(err1)")
        #expect(p1.terminationStatus == 0)

        // Test 2: HTTPS curl through proxy
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p2.arguments = ["-v", "-L", "-k", "-x", "http://127.0.0.1:8080", "https://1.1.1.1", "--max-time", "6"]
        let pipe2 = Pipe()
        p2.standardError = pipe2
        try p2.run()
        p2.waitUntilExit()
        let err2 = String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("=== E2E curl https://1.1.1.1 STDERR: ===\n\(err2)")
        #expect(p2.terminationStatus == 0)

        // Test 3: Disable proxy cleanly
        let disabled = await SystemProxyManager.shared.disableProxy()
        #expect(disabled == true)
        #expect(SystemProxyManager.shared.isProxyEnabled() == false)
    }

    private func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Everything about the proxy settings of `service` that the shield changes.
    private func proxySnapshot(_ service: String) -> String {
        ["-getwebproxy", "-getsecurewebproxy", "-getproxybypassdomains"]
            .map { run("/usr/sbin/networksetup", [$0, service]) }
            .joined(separator: "--\n")
    }

    /// Does what the app's "Protect" switch does (listener first, then the system proxy), then loads a page the way
    /// Safari or any app does, through the system proxy, with providers that need a host name looked up.
    @Test(
        "E2E-02: Shield switched on for real: a page loads through the system proxy with each DoH provider, and settings are restored",
        .enabled(if: ProcessInfo.processInfo.environment["ZENITH_E2E_SYSTEM"] == "1", "Changes the machine's real system proxy; set ZENITH_E2E_SYSTEM=1 to run")
    )
    func testShieldOnForRealWithNamedProviders() async throws {
        let manager = SystemProxyManager.shared
        let server = LocalProxyServer.shared
        let service = try #require(manager.discoverPrimaryService())
        let before = proxySnapshot(service)
        defer {
            _ = manager.disableProxySynchronously()
            server.stop()
        }

        let port: UInt16 = 18_095
        for provider in [DoHProvider.google, .quad9, .adguard] {
            await DoHResolver.shared.clearCache()
            try await server.startAndAwaitReady(port: port, provider: provider)
            let enabled = await manager.enableProxy(port: port)
            #expect(enabled, "enabling the system proxy failed for \(provider.displayName)")
            #expect(manager.isProxyEnabled())

            let scutil = run("/usr/sbin/scutil", ["--proxy"])
            #expect(scutil.contains("HTTPSPort : \(port)"), "system configuration does not point at the shield")

            // CFNetwork notices a proxy change a moment after it is made.
            try await Task.sleep(nanoseconds: 1_500_000_000)

            var request = URLRequest(url: URL(string: "https://example.com/")!)
            request.timeoutInterval = 12
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let seenByShield = await MainActor.run { PrivacyShieldStatistics.shared.lastProtectedDomain ?? "" }
            print("E2E-02 \(provider.displayName): HTTP \(status), \(data.count) bytes, shield saw '\(seenByShield)'")
            #expect(status == 200)
            #expect(seenByShield.contains("example.com"), "the request did not go through the shield")

            let disabled = await manager.disableProxy()
            server.stop()
            #expect(disabled)
            #expect(!manager.isProxyEnabled())
        }

        #expect(proxySnapshot(service) == before, "the proxy settings were not put back exactly as they were")
    }
}
