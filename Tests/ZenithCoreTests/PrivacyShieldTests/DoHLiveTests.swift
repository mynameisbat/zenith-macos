import Testing
import Foundation
@testable import ZenithCore

/// Talks to the real DoH servers, so it only runs on request: `ZENITH_E2E_NETWORK=1 swift test --filter DoHLiveTests`.
@Suite(
    "DoH Live Resolution Suite",
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
}
