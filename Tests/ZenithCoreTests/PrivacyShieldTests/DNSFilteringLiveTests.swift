import Testing
import Foundation
import Darwin
@testable import ZenithCore

/// Runs a real proxy (on a free port, never the system proxy) against the real AdGuard DNS, so it only runs on request:
/// `ZENITH_E2E_NETWORK=1 swift test --filter DNSFilteringLiveTests`.
@Suite(
    "DNS filtering through the real proxy and AdGuard DNS",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ZENITH_E2E_NETWORK"] == "1", "Needs internet access; set ZENITH_E2E_NETWORK=1 to run")
)
struct DNSFilteringLiveTests {

    private func startProxy(provider: DoHProvider, blocklist: TrackerBlocklist) async throws -> (LocalProxyServer, UInt16) {
        let server = LocalProxyServer()
        server.blocklist = blocklist
        server.resolver = DoHResolver()   // a fresh cache, not the app's
        var lastError: Error?
        for _ in 0..<5 {
            let port = Sock.freePort()
            do {
                try await server.startAndAwaitReady(port: port, provider: provider)
                return (server, port)
            } catch {
                lastError = error
                server.stop()
            }
        }
        throw lastError!
    }

    /// The proxy's first response line to a CONNECT.
    private func connectStatus(port: UInt16, host: String) async -> String {
        await offPool {
            let client = Sock.connect(to: port)
            defer { close(client) }
            Sock.send(client, "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n")
            let head = Sock.receive(client, until: Data("\r\n".utf8))
            return String(data: head, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    @Test("DNSF-L1: Through AdGuard DNS, an ordinary site connects and an ad domain gets 403 (CONNECT and plain HTTP)")
    func testAdGuardBlocks() async throws {
        let (server, port) = try await startProxy(provider: .adguard, blocklist: TrackerBlocklist())
        defer { server.stop() }

        let site = await connectStatus(port: port, host: "example.com")
        print("LIVE example.com -> \(site)")
        #expect(site.hasPrefix("HTTP/1.1 200"))

        // All three were answered 0.0.0.0 by AdGuard when this was written (2026-11); its list is AdGuard's choice.
        for ad in ["doubleclick.net", "googleadservices.com", "google-analytics.com"] {
            let status = await connectStatus(port: port, host: ad)
            print("LIVE \(ad) -> \(status)")
            #expect(status.hasPrefix("HTTP/1.1 403"), "\(ad): \(status)")
        }

        let plain = await offPool {
            let client = Sock.connect(to: port)
            defer { close(client) }
            Sock.send(client, "GET http://doubleclick.net/ HTTP/1.1\r\nHost: doubleclick.net\r\n\r\n")
            return String(data: Sock.receive(client, until: Data("\r\n".utf8)), encoding: .utf8) ?? ""
        }
        print("LIVE http://doubleclick.net -> \(plain.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(plain.hasPrefix("HTTP/1.1 403"))
    }

    @Test("DNSF-L2: A Never Block name gets through AdGuard DNS (asked of AdGuard's unfiltered resolver)")
    func testNeverBlockOverridesAdGuard() async throws {
        let (server, port) = try await startProxy(
            provider: .adguard,
            blocklist: TrackerBlocklist(blocked: [], allowed: ["doubleclick.net"])
        )
        defer { server.stop() }

        let status = await connectStatus(port: port, host: "doubleclick.net")
        print("LIVE never-blocked doubleclick.net -> \(status)")
        #expect(status.hasPrefix("HTTP/1.1 200"))
        // Its sibling is still blocked.
        #expect(await connectStatus(port: port, host: "googleadservices.com").hasPrefix("HTTP/1.1 403"))
    }

    @Test("DNSF-L3: With Cloudflare (no filtering) an ad domain is connected, unless the user's list has it")
    func testUnfilteredResolver() async throws {
        let (server, port) = try await startProxy(
            provider: .cloudflare,
            blocklist: TrackerBlocklist(blocked: ["googleadservices.com"])
        )
        defer { server.stop() }

        #expect(await connectStatus(port: port, host: "doubleclick.net").hasPrefix("HTTP/1.1 200"))
        #expect(await connectStatus(port: port, host: "googleadservices.com").hasPrefix("HTTP/1.1 403"))
    }
}
