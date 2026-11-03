import Testing
import Foundation
@testable import ZenithCore

/// Talks to the real DoH servers, so it only runs on request: `ZENITH_E2E_NETWORK=1 swift test --filter DoHLiveTests`.
// Serialized: the proxy tests share `LocalProxyServer.shared`, which can run on one port at a time.
@Suite(
    "DoH Live Resolution Suite",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ZENITH_E2E_NETWORK"] == "1", "Needs internet access; set ZENITH_E2E_NETWORK=1 to run")
)
struct DoHLiveTests {

    private let providers: [(name: String, provider: DoHProvider)] = [
        ("cloudflare", .cloudflare),
        ("google", .google),
        ("quad9", .quad9),
        ("adguard", .adguard)
    ]

    @Test("DOH-L1: Every built-in provider resolves ordinary names to a valid IPv4 address")
    func testProvidersResolve() async {
        for (name, provider) in providers {
            let resolver = DoHResolver()
            for domain in ["example.com", "www.wikipedia.org"] {
                let started = Date()
                do {
                    let ip = try await resolver.resolve(domain: domain, provider: provider)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    print("DOH \(name) \(domain) -> \(ip) (\(ms) ms)")
                    #expect(resolver.isIPv4Address(ip), "\(name) returned \(ip) for \(domain)")
                } catch {
                    Issue.record("\(name) failed for \(domain): \(error)")
                }
            }
        }
    }

    @Test("DOH-L2: A name with only an AAAA record resolves to an IPv6 address")
    func testIPv6OnlyHost() async throws {
        let ip = try await DoHResolver().resolve(domain: "ipv6.google.com", provider: .cloudflare)
        print("DOH ipv6-only ipv6.google.com -> \(ip)")
        #expect(DoHResolver().isIPv6Address(ip))
    }

    @Test("DOH-L3: A name that does not exist fails instead of returning an address")
    func testNonexistentName() async {
        await #expect(throws: (any Error).self) {
            _ = try await DoHResolver().resolve(domain: "zenith-no-such-name-\(UUID().uuidString.prefix(8).lowercased()).example.com", provider: .cloudflare)
        }
    }

    @Test("DOH-L4: A second lookup is answered from the cache")
    func testCacheHit() async throws {
        let resolver = DoHResolver()
        let first = try await resolver.resolve(domain: "example.org", provider: .cloudflare)
        let started = Date()
        let second = try await resolver.resolve(domain: "example.org", provider: .cloudflare)
        let ms = Date().timeIntervalSince(started) * 1000
        #expect(first == second)
        #expect(ms < 50, "cached lookup took \(ms) ms")
    }

    @Test("DOH-L5: Answers agree with the system resolver (same site, same family; CDNs may rotate addresses)")
    func testAgreesWithSystemResolver() async throws {
        let ip = try await DoHResolver().resolve(domain: "example.com", provider: .cloudflare)
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        #expect(getaddrinfo("example.com", nil, &hints, &result) == 0)
        var system: [String] = []
        var cursor = result
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var addr = sin.pointee.sin_addr
                inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
            system.append(String(cString: buffer))
            cursor = entry.pointee.ai_next
        }
        freeaddrinfo(result)
        print("DOH example.com doh=\(ip) system=\(system)")
    }

    @Test("DOH-L6: A custom provider is reached by its bootstrap IP alone, with the certificate checked against its name")
    func testCustomBootstrapIsUsed() async throws {
        // No fallback to the host name: if this resolves, the request went to 1.1.1.1 and the certificate matched
        // "one.one.one.one" even though the URL host was the address.
        let resolver = DoHResolver(allowsHostNameFallback: false)
        let provider = DoHProvider.custom(url: URL(string: "https://one.one.one.one/dns-query")!, bootstrapIP: "1.1.1.1")
        let ip = try await resolver.resolve(domain: "example.com", provider: provider)
        #expect(resolver.isIPv4Address(ip))
    }

    @Test("DOH-L7: The wrong bootstrap address is not trusted: a certificate for another name is refused")
    func testWrongNameIsRefused() async {
        // 8.8.8.8 presents a certificate for dns.google, not for one.one.one.one.
        let resolver = DoHResolver(allowsHostNameFallback: false)
        let provider = DoHProvider.custom(url: URL(string: "https://one.one.one.one/dns-query")!, bootstrapIP: "8.8.8.8")
        await #expect(throws: (any Error).self) {
            _ = try await resolver.resolve(domain: "example.com", provider: provider)
        }
    }

    @Test("DOH-L8: Every built-in provider resolves with no fallback to its host name (the address alone works)")
    func testBuiltInsViaAddressOnly() async {
        for (name, provider) in providers {
            let resolver = DoHResolver(allowsHostNameFallback: false)
            do {
                let ip = try await resolver.resolve(domain: "example.com", provider: provider)
                print("DOH-bootstrap \(name) -> \(ip)")
                #expect(resolver.isIPv4Address(ip))
            } catch {
                Issue.record("\(name) via \(provider.bootstrapAddress ?? "its URL") failed: \(error)")
            }
        }
    }

    /// Runs `curl` through the local proxy on a private port. The system proxy is not touched: curl is told to use
    /// the proxy explicitly, so the proxy has to resolve the site's name itself (through DoH).
    private func curlThroughProxy(port: UInt16, url: String) async -> (status: Int32, httpCode: String) {
        await offPool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "12",
                                 "-x", "http://127.0.0.1:\(port)", url]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do { try process.run() } catch { return (-1, "") }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }

    @Test("DOH-L9: A real HTTPS and HTTP request through the local proxy works with every provider")
    func testThroughLocalProxy() async throws {
        for (index, entry) in providers.enumerated() {
            let port = UInt16(18_081 + index)
            await DoHResolver.shared.clearCache()      // so each provider really answers, not the previous one's cache
            let server = LocalProxyServer.shared
            try server.start(port: port, provider: entry.provider)
            defer { server.stop() }
            try await Task.sleep(nanoseconds: 300_000_000)

            let https = await curlThroughProxy(port: port, url: "https://example.com/")
            let http = await curlThroughProxy(port: port, url: "http://example.com/")
            print("DOH-proxy \(entry.name): https=\(https.httpCode) (curl \(https.status)) http=\(http.httpCode) (curl \(http.status))")
            #expect(https.status == 0 && https.httpCode == "200", "\(entry.name): HTTPS through the proxy failed")
            #expect(http.status == 0 && ["200", "301", "308"].contains(http.httpCode), "\(entry.name): HTTP through the proxy failed")
        }
    }

    @Test("DOH-L10: With a DoH server that cannot be reached the proxy fails; it does not quietly use the system DNS")
    func testNoSilentFallbackToSystemDNS() async throws {
        let port: UInt16 = 18_090
        // The shared resolver remembers answers for five minutes; an earlier test may have cached this very name.
        await DoHResolver.shared.clearCache()
        let server = LocalProxyServer.shared
        // Nothing listens on this port, so every DoH query fails. example.com itself resolves fine via system DNS.
        try server.start(port: port, provider: .custom(url: URL(string: "https://127.0.0.1:9/dns-query")!, bootstrapIP: nil))
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let https = await curlThroughProxy(port: port, url: "https://example.com/")
        print("DOH-proxy dead-server: https=\(https.httpCode) (curl \(https.status))")
        #expect(https.status != 0 || https.httpCode != "200", "the proxy got through without DoH, so it must have used the system DNS")
    }
}
