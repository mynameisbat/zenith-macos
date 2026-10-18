import Testing
import Foundation
import Network
import AppKit
@testable import GoldenGateCore

@Suite("Privacy Shield End-to-End System Proxy Suite")
struct PrivacyShieldE2ETest {

    @Test("E2E-01: Full system proxy enabling, native URLSession request, and safe cleanup")
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
}
