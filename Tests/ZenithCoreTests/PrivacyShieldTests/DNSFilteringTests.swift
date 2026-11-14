import Testing
import Foundation
import Darwin
@testable import ZenithCore

/// A resolver that answers from a table and remembers which provider each name was asked of. No network.
private final class FakeResolver: DoHResolverProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: @Sendable (String, DoHProvider) -> String
    private var _asked: [(host: String, providerID: String)] = []

    init(answer: @escaping @Sendable (String, DoHProvider) -> String) {
        self.answer = answer
    }

    var asked: [(host: String, providerID: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _asked
    }

    func resolve(domain: String, provider: DoHProvider) async throws -> String {
        lock.withLock { _asked.append((domain, provider.id)) }
        return answer(domain, provider)
    }
}

@Suite("DNS filtering: a resolver's blocking answers, and Never Block over a filtering resolver")
struct DNSFilteringTests {

    @Test("DNSF-01: 0.0.0.0 and :: (in any spelling) are blocking answers; real and loopback addresses are not")
    func testBlockingAnswer() {
        for blocked in ["0.0.0.0", "::", "0:0:0:0:0:0:0:0", "[::]", " 0.0.0.0 "] {
            #expect(DoHResolver.isBlockingAnswer(blocked), "\(blocked)")
        }
        for address in ["127.0.0.1", "1.1.1.1", "::1", "2606:4700::1111", "0.0.0.1", "", "not an address"] {
            #expect(!DoHResolver.isBlockingAnswer(address), "\(address)")
        }
    }

    @Test("DNSF-02: Which resolvers filter ads themselves, and which one a never-blocked name is asked of")
    func testProviderFiltering() {
        #expect(DoHProvider.adguard.blocksAdsItself)
        #expect(DoHProvider.nextdns(profileID: "abc123").blocksAdsItself)
        #expect(!DoHProvider.nextdns(profileID: "").blocksAdsItself)
        #expect(!DoHProvider.cloudflare.blocksAdsItself)
        #expect(!DoHProvider.google.blocksAdsItself)
        #expect(!DoHProvider.quad9.blocksAdsItself)

        // Unfiltered resolvers are asked as they are.
        #expect(DoHProvider.cloudflare.neverBlockResolver == .cloudflare)
        #expect(DoHProvider.google.neverBlockResolver == .google)
        #expect(DoHProvider.quad9.neverBlockResolver == .quad9)
        // AdGuard has an unfiltered twin; NextDNS and a custom resolver fall back to Cloudflare.
        let unfiltered = DoHProvider.adguard.neverBlockResolver
        #expect(unfiltered.endpointURL.host == "unfiltered.adguard-dns.com")
        #expect(!unfiltered.blocksAdsItself)
        #expect(DoHProvider.nextdns(profileID: "abc123").neverBlockResolver == .cloudflare)
        let custom = DoHProvider.custom(url: URL(string: "https://dns.example.net/dns-query")!, bootstrapIP: nil)
        #expect(custom.neverBlockResolver == .cloudflare)
    }

    @Test("DNSF-03: isNeverBlocked covers the listed domain and its subdomains, nothing else")
    func testNeverBlocked() {
        let list = TrackerBlocklist(blocked: [], allowed: ["shop.example"])
        #expect(list.isNeverBlocked(host: "shop.example"))
        #expect(list.isNeverBlocked(host: "pay.shop.example"))
        #expect(list.isNeverBlocked(host: "PAY.Shop.Example."))
        #expect(!list.isNeverBlocked(host: "myshop.example"))
        #expect(!list.isNeverBlocked(host: "example"))
        #expect(!list.isNeverBlocked(host: "127.0.0.1"))
        #expect(!TrackerBlocklist().isNeverBlocked(host: "shop.example"))
    }

    @Test("DNSF-04: With blocking off, the never-block list still reaches the proxy (it also overrides a filtering resolver)")
    @MainActor
    func testNeverBlockWhileBlockingOff() throws {
        let suite = "DNSF-04-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DNSF-04-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocklist = TrackerBlocklist()
        let settings = TrackerBlockingSettings(userDefaults: defaults, storageDirectory: directory, blocklist: blocklist)

        settings.isEnabled = false
        _ = settings.addAllowedDomain("shop.example")
        #expect(blocklist.isNeverBlocked(host: "pay.shop.example"))
        #expect(!blocklist.isBlocked(host: "doubleclick.net"))
    }

    // MARK: The proxy

    private func startProxy(provider: DoHProvider, blocklist: TrackerBlocklist?, resolver: FakeResolver) async throws -> (LocalProxyServer, UInt16) {
        let server = LocalProxyServer()
        server.blocklist = blocklist
        server.resolver = resolver
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

    private func connectStatus(port: UInt16, host: String) async -> String {
        await offPool {
            let client = Sock.connect(to: port)
            defer { close(client) }
            Sock.send(client, "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n")
            return String(data: Sock.receiveAll(client).data, encoding: .utf8) ?? ""
        }
    }

    @Test("DNSF-05: A CONNECT the resolver answers with 0.0.0.0 or :: gets 403, not a connection to this Mac")
    func testConnectBlockedByResolver() async throws {
        let resolver = FakeResolver { host, _ in host.hasPrefix("v6.") ? "::" : "0.0.0.0" }
        let (server, port) = try await startProxy(provider: .adguard, blocklist: TrackerBlocklist(), resolver: resolver)
        defer { server.stop() }

        #expect(await connectStatus(port: port, host: "ads.filtered.example").hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(await connectStatus(port: port, host: "v6.ads.filtered.example").hasPrefix("HTTP/1.1 403 Forbidden"))
    }

    @Test("DNSF-06: A plain HTTP request the resolver answers with 0.0.0.0 gets 403")
    func testPlainHttpBlockedByResolver() async throws {
        let resolver = FakeResolver { _, _ in "0.0.0.0" }
        let (server, port) = try await startProxy(provider: .adguard, blocklist: nil, resolver: resolver)
        defer { server.stop() }

        let response = await offPool {
            let client = Sock.connect(to: port)
            defer { close(client) }
            Sock.send(client, "GET http://ads.filtered.example/pixel.gif HTTP/1.1\r\nHost: ads.filtered.example\r\n\r\n")
            return Sock.receiveAll(client)
        }
        #expect((String(data: response.data, encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 403 Forbidden"))
    }

    @Test("DNSF-07: A never-blocked name is asked of the unfiltered resolver; other names of the chosen one")
    func testNeverBlockedUsesUnfilteredResolver() async throws {
        let resolver = FakeResolver { _, _ in "0.0.0.0" }
        let blocklist = TrackerBlocklist(blocked: [], allowed: ["shop.example"])
        let (server, port) = try await startProxy(provider: .adguard, blocklist: blocklist, resolver: resolver)
        defer { server.stop() }

        _ = await connectStatus(port: port, host: "pay.shop.example")
        _ = await connectStatus(port: port, host: "news.example")

        let asked = resolver.asked
        #expect(asked.first { $0.host == "pay.shop.example" }?.providerID == DoHProvider.adguard.neverBlockResolver.id)
        #expect(asked.first { $0.host == "news.example" }?.providerID == DoHProvider.adguard.id)
    }

    @Test("DNSF-08: The proxy's own list still answers first: a listed name never reaches the resolver")
    func testOwnListFirst() async throws {
        let resolver = FakeResolver { _, _ in "0.0.0.0" }
        let (server, port) = try await startProxy(
            provider: .adguard,
            blocklist: TrackerBlocklist(blocked: ["ads.listed.example"]),
            resolver: resolver
        )
        defer { server.stop() }

        #expect(await connectStatus(port: port, host: "x.ads.listed.example").hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(resolver.asked.isEmpty)
    }
}
