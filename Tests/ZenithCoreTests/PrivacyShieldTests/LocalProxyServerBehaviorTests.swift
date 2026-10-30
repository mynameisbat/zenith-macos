import Testing
import Foundation
import Darwin
@testable import ZenithCore

/// Minimal blocking BSD-socket helpers so the proxy can be driven by a real client and a real local origin
/// without any traffic leaving the machine.
enum Sock {
    static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// A listening socket on a free loopback port.
    static func listen() -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = address(port: 0)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        _ = Darwin.listen(fd, 16)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    static func freePort() -> UInt16 {
        let (fd, port) = listen()
        close(fd)
        return port
    }

    static func connect(to port: UInt16, timeout: TimeInterval = 20) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = address(port: port)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return fd
    }

    static func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    static func send(_ fd: Int32, _ text: String) {
        send(fd, Data(text.utf8))
    }

    /// Reads until the peer closes (`sawEOF`, which includes a connection reset) or the receive timeout expires.
    static func receiveAll(_ fd: Int32) -> (data: Data, sawEOF: Bool) {
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                collected.append(contentsOf: chunk[0..<count])
            } else {
                return (collected, count == 0 || errno == ECONNRESET)
            }
        }
    }

    /// Reads until `marker` has been seen or the connection ends / times out.
    static func receive(_ fd: Int32, until marker: Data) -> Data {
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while collected.range(of: marker) == nil {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            collected.append(contentsOf: chunk[0..<count])
        }
        return collected
    }
}

/// Runs blocking socket work on a dispatch thread. Test bodies are `async`, so blocking inside them would hold one
/// of the few cooperative-pool threads that the proxy's own `Task`s (DoH lookup, upstream connect) also need,
/// and with enough tests running at once the proxy would starve and time out.
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}

/// A local TCP server whose per-connection behaviour is supplied by the test.
final class TestOrigin: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var _received = Data()

    var received: Data { lock.withLock { _received } }

    init(handler: @escaping @Sendable (Int32, TestOrigin) -> Void) {
        let (fd, port) = Sock.listen()
        self.listenFD = fd
        self.port = port
        DispatchQueue.global().async { [self] in
            while !lock.withLock({ stopped }) {
                var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 100) > 0 else { continue }
                let client = accept(listenFD, nil, nil)
                if client < 0 { continue }
                var tv = timeval(tv_sec: 20, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                DispatchQueue.global().async {
                    handler(client, self)
                    close(client)
                }
            }
            close(listenFD)
        }
    }

    func record(_ data: Data) {
        lock.withLock { _received.append(data) }
    }

    func stop() {
        lock.withLock { stopped = true }
    }
}

@Suite("Local Proxy Server Behaviour Suite")
struct LocalProxyServerBehaviorTests {

    private func startProxy(configure: (LocalProxyServer) -> Void = { _ in }) async throws -> (LocalProxyServer, UInt16) {
        let server = LocalProxyServer()
        configure(server)
        let port = Sock.freePort()
        try await server.startAndAwaitReady(port: port, provider: .cloudflare)
        return (server, port)
    }

    private let connectEstablished = "HTTP/1.1 200 Connection Established\r\n\r\n"

    // MARK: - Request rewriting

    @Test("LP-01: A proxy-form request becomes an origin-form request with hop-by-hop headers removed")
    func testRewriteProxyFormRequest() throws {
        let head = "POST http://example.com:8081/submit?x=1 HTTP/1.1\r\nHost: example.com:8081\r\n"
            + "Proxy-Connection: keep-alive\r\nProxy-Authorization: Basic abc\r\nKeep-Alive: 300\r\nConnection: keep-alive\r\n"
            + "Content-Length: 3"
        let body = Data([0xFF, 0xFE, 0x00])

        let rewritten = try #require(LocalProxyServer.rewritePlainHttpRequest(headString: head, leftover: body))
        #expect(rewritten.host == "example.com")
        #expect(rewritten.port == 8081)

        let text = String(data: rewritten.payload, encoding: .isoLatin1) ?? ""
        #expect(text.hasPrefix("POST /submit?x=1 HTTP/1.1\r\n"))
        #expect(text.contains("Host: example.com:8081\r\n"))
        #expect(text.contains("Content-Length: 3\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(!text.lowercased().contains("proxy-"))
        #expect(!text.contains("keep-alive"))
        #expect(rewritten.payload.suffix(3) == body)
    }

    @Test("LP-02: Missing path, missing Host header, userinfo and upgrade requests are handled")
    func testRewriteEdgeCases() throws {
        let noPath = try #require(LocalProxyServer.rewritePlainHttpRequest(headString: "GET http://user:pw@example.com HTTP/1.1", leftover: Data()))
        let noPathText = String(data: noPath.payload, encoding: .isoLatin1) ?? ""
        #expect(noPath.host == "example.com" && noPath.port == 80)
        #expect(noPathText.hasPrefix("GET / HTTP/1.1\r\nHost: example.com\r\n"))

        let originForm = try #require(LocalProxyServer.rewritePlainHttpRequest(headString: "GET /a HTTP/1.1\r\nHost: [::1]:9000", leftover: Data()))
        #expect(originForm.host == "::1" && originForm.port == 9000)

        #expect(LocalProxyServer.rewritePlainHttpRequest(headString: "GET /a HTTP/1.1\r\nAccept: */*", leftover: Data()) == nil)

        let upgrade = try #require(LocalProxyServer.rewritePlainHttpRequest(
            headString: "GET http://example.com/ws HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade\r\nUpgrade: websocket",
            leftover: Data()
        ))
        let upgradeText = String(data: upgrade.payload, encoding: .isoLatin1) ?? ""
        #expect(upgradeText.contains("Connection: Upgrade\r\n") && upgradeText.contains("Upgrade: websocket\r\n"))
        #expect(!upgradeText.contains("Connection: close"))
    }

    @Test("LP-03: Header bytes outside ASCII survive the rewrite unchanged")
    func testRewritePreservesNonASCIIHeaderBytes() throws {
        let latin1 = try #require(String(data: Data([0x43, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x3A, 0x20, 0xE9]), encoding: .isoLatin1))
        let head = "GET http://example.com/ HTTP/1.1\r\n" + latin1
        let rewritten = try #require(LocalProxyServer.rewritePlainHttpRequest(headString: head, leftover: Data()))
        #expect(rewritten.payload.range(of: Data([0x43, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x3A, 0x20, 0xE9, 0x0D, 0x0A])) != nil)
    }

    // MARK: - Plain HTTP through the live proxy

    @Test("LP-04: Plain HTTP with a non-UTF-8 body reaches the origin intact, in origin-form")
    func testPlainHttpWithBinaryBody() async throws {
        let origin = TestOrigin { fd, origin in
            let request = Sock.receive(fd, until: Data([0xFF, 0xFE, 0xFD]))
            origin.record(request)
            Sock.send(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        }
        defer { origin.stop() }
        let (server, proxyPort) = try await startProxy()
        defer { server.stop() }
        let originPort = origin.port

        let response = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            var request = Data("POST http://127.0.0.1:\(originPort)/upload HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nProxy-Connection: keep-alive\r\nContent-Length: 3\r\n\r\n".utf8)
            request.append(contentsOf: [0xFF, 0xFE, 0xFD])
            Sock.send(client, request)
            return Sock.receiveAll(client)
        }
        #expect(String(data: response.data, encoding: .utf8)?.hasPrefix("HTTP/1.1 200 OK") == true)

        let seen = origin.received
        let seenText = String(data: seen, encoding: .isoLatin1) ?? ""
        #expect(seenText.hasPrefix("POST /upload HTTP/1.1\r\n"))
        #expect(seenText.contains("Connection: close"))
        #expect(!seenText.contains("Proxy-Connection"))
        #expect(seen.suffix(3) == Data([0xFF, 0xFE, 0xFD]))
    }

    @Test("LP-05: The upstream connection ends with the response, so a reused client connection is never misrouted")
    func testUpstreamIsDedicatedToOneRequest() async throws {
        let origin = TestOrigin { fd, _ in
            _ = Sock.receive(fd, until: Data("\r\n\r\n".utf8))
            Sock.send(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        }
        defer { origin.stop() }
        let (server, proxyPort) = try await startProxy()
        defer { server.stop() }
        let originPort = origin.port

        let response = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            Sock.send(client, "GET http://127.0.0.1:\(originPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nConnection: keep-alive\r\n\r\n")
            return Sock.receiveAll(client)
        }
        #expect(String(data: response.data, encoding: .utf8)?.hasSuffix("OK") == true)
        #expect(response.sawEOF)
    }

    // MARK: - CONNECT tunnels

    @Test("LP-06: Bytes sent right behind CONNECT are forwarded instead of dropped")
    func testConnectWithPipelinedPayload() async throws {
        let origin = TestOrigin { fd, origin in
            let data = Sock.receive(fd, until: Data("HELLO-PAYLOAD".utf8))
            origin.record(data)
            Sock.send(fd, data)
        }
        defer { origin.stop() }
        let (server, proxyPort) = try await startProxy()
        defer { server.stop() }
        let originPort = origin.port

        let reply = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            Sock.send(client, "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\nHELLO-PAYLOAD")
            return Sock.receive(client, until: Data("HELLO-PAYLOAD".utf8))
        }
        #expect(String(data: reply, encoding: .utf8) == connectEstablished + "HELLO-PAYLOAD")
        #expect(String(data: origin.received, encoding: .utf8) == "HELLO-PAYLOAD")
    }

    @Test("LP-07: A client that finishes sending still receives the rest of the response (half-close)")
    func testHalfCloseKeepsResponseFlowing() async throws {
        let origin = TestOrigin { fd, _ in
            _ = Sock.receiveAll(fd)             // waits for the client's end-of-stream
            Sock.send(fd, "FINAL-REPLY")
        }
        defer { origin.stop() }
        let (server, proxyPort) = try await startProxy()
        defer { server.stop() }
        let originPort = origin.port

        let reply = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            Sock.send(client, "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: x\r\n\r\n")
            _ = Sock.receive(client, until: Data("\r\n\r\n".utf8))
            Sock.send(client, "ping")
            shutdown(client, SHUT_WR)
            return Sock.receiveAll(client)
        }
        let text = String(data: reply.data, encoding: .utf8)
        #expect(text == "FINAL-REPLY", "reply: \(String(describing: text)), origin saw: \(origin.received.count) bytes")
        #expect(reply.sawEOF)
    }

    @Test("LP-07b: A request sent together with the client's end-of-stream still gets its response")
    func testRequestAndEndOfStreamArriveTogether() async throws {
        let origin = TestOrigin { fd, _ in
            _ = Sock.receive(fd, until: Data("\r\n\r\n".utf8))
            Sock.send(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        }
        defer { origin.stop() }
        let (server, proxyPort) = try await startProxy()
        defer { server.stop() }
        let originPort = origin.port

        let replies = await offPool { () -> [(plain: Data, tunnel: Data)] in
            (0..<5).map { _ in
                // Plain HTTP: request, then FIN immediately (what `printf … | nc` or an HTTP/1.0 client does).
                let plain = Sock.connect(to: proxyPort)
                Sock.send(plain, "GET http://127.0.0.1:\(originPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n")
                shutdown(plain, SHUT_WR)
                let plainReply = Sock.receiveAll(plain).data
                close(plain)

                // CONNECT with the first payload and the FIN right behind it.
                let tunnel = Sock.connect(to: proxyPort)
                Sock.send(tunnel, "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n")
                shutdown(tunnel, SHUT_WR)
                let tunnelReply = Sock.receiveAll(tunnel).data
                close(tunnel)
                return (plainReply, tunnelReply)
            }
        }
        for reply in replies {
            #expect(String(data: reply.plain, encoding: .utf8)?.hasSuffix("OK") == true, "plain reply: \(reply.plain.count) bytes")
            #expect(String(data: reply.tunnel, encoding: .utf8)?.hasSuffix("OK") == true, "tunnel reply: \(reply.tunnel.count) bytes")
        }
    }

    // MARK: - Limits

    @Test("LP-08: A client that never finishes its request is dropped after the header timeout")
    func testRequestHeaderTimeout() async throws {
        let (server, proxyPort) = try await startProxy { $0.requestHeaderTimeout = 0.3 }
        defer { server.stop() }

        let result = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            Sock.send(client, "GET http://127.0.0.1:1/ HTTP/1.1\r\nHost: slow")  // never sends the blank line
            return Sock.receiveAll(client)
        }
        #expect(result.sawEOF)
    }

    @Test("LP-09: An oversized request head is rejected with 431")
    func testOversizedRequestHead() async throws {
        let (server, proxyPort) = try await startProxy()
        defer { server.stop() }

        let result = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            Sock.send(client, "GET / HTTP/1.1\r\nX-Padding: " + String(repeating: "a", count: 20_000))
            return Sock.receiveAll(client)
        }
        #expect(String(data: result.data, encoding: .utf8)?.hasPrefix("HTTP/1.1 431") == true)
    }

    @Test("LP-10: Connections beyond the limit are refused")
    func testConnectionLimit() async throws {
        let (server, proxyPort) = try await startProxy { $0.maxConnections = 2 }
        defer { server.stop() }

        let held = await offPool { [Sock.connect(to: proxyPort), Sock.connect(to: proxyPort)] }
        defer { held.forEach { close($0) } }
        try await Task.sleep(nanoseconds: 300_000_000) // let the proxy register both

        let result = await offPool {
            let third = Sock.connect(to: proxyPort)
            defer { close(third) }
            Sock.send(third, "GET / HTTP/1.1\r\n\r\n")
            return Sock.receiveAll(third)
        }
        #expect(result.data.isEmpty)
    }

    @Test("LP-11: A tunnel with no traffic in either direction is closed after the idle timeout")
    func testIdleTimeout() async throws {
        let origin = TestOrigin { fd, _ in
            _ = Sock.receiveAll(fd)             // stays silent
        }
        defer { origin.stop() }
        let (server, proxyPort) = try await startProxy { $0.idleTimeout = 0.4 }
        defer { server.stop() }
        let originPort = origin.port

        let result = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            Sock.send(client, "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: x\r\n\r\n")
            _ = Sock.receive(client, until: Data("\r\n\r\n".utf8))
            return Sock.receiveAll(client)
        }
        #expect(result.sawEOF)
    }
}

// MARK: - DoH IPv6 fallback

/// Answers DoH JSON queries from memory so resolution can be tested without the network.
final class StubDoHProtocol: URLProtocol {
    static let log = QueryLog()

    final class QueryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ entry: String) { lock.withLock { entries.append(entry) } }
        func queries(for name: String) -> [String] { lock.withLock { entries.filter { $0.hasPrefix(name + "|") } } }
    }

    static func body(name: String, type: String) -> String {
        switch (name, type) {
        case ("v6only.test", "AAAA"):
            return #"{"Status":0,"Answer":[{"name":"v6only.test","type":28,"TTL":60,"data":"2606:4700::6810:84e5"}]}"#
        case ("dual.test", "A"):
            return #"{"Status":0,"Answer":[{"name":"dual.test","type":1,"TTL":60,"data":"93.184.216.34"}]}"#
        default:
            return #"{"Status":0}"#
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let name = items.first { $0.name == "name" }?.value ?? ""
        let type = items.first { $0.name == "type" }?.value ?? ""
        Self.log.record("\(name)|\(type)")

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body(name: name, type: type).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("DoH Resolver IPv6 Fallback Suite")
struct DoHResolverIPv6Tests {

    private func makeResolver() -> DoHResolver {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubDoHProtocol.self]
        return DoHResolver(session: URLSession(configuration: config))
    }

    @Test("DOH-01: A host with only AAAA records resolves to its IPv6 address")
    func testIPv6OnlyHostResolves() async throws {
        let resolver = makeResolver()
        let address = try await resolver.resolve(domain: "v6only.test", provider: .cloudflare)
        #expect(address == "2606:4700::6810:84e5")
        #expect(resolver.isIPv6Address(address))
        #expect(StubDoHProtocol.log.queries(for: "v6only.test") == ["v6only.test|A", "v6only.test|AAAA"])
    }

    @Test("DOH-02: A host with an A record never triggers the AAAA query")
    func testIPv4PreferredWithoutExtraQuery() async throws {
        let resolver = makeResolver()
        let address = try await resolver.resolve(domain: "dual.test", provider: .cloudflare)
        #expect(address == "93.184.216.34")
        #expect(StubDoHProtocol.log.queries(for: "dual.test") == ["dual.test|A"])
    }

    @Test("DOH-03: A host with no address records still fails with a clear error")
    func testNoRecordsStillFails() async throws {
        let resolver = makeResolver()
        await #expect(throws: (any Error).self) {
            _ = try await resolver.resolve(domain: "nothing.test", provider: .cloudflare)
        }
    }

    @Test("DOH-04: The DNS cache stays within its size limit and keeps the longest-lived entries")
    func testDNSCacheIsBounded() async {
        let cache = DNSCache(maxEntries: 3)
        await cache.set(domain: "bootstrap.test", ip: "1.1.1.1", ttl: 86_400)
        for index in 0..<10 {
            await cache.set(domain: "site\(index).test", ip: "10.0.0.\(index)", ttl: 300 + TimeInterval(index))
        }
        #expect(await cache.count <= 3)
        #expect(await cache.get(domain: "bootstrap.test") == "1.1.1.1")     // longest TTL survives
        #expect(await cache.get(domain: "site9.test") == "10.0.0.9")        // as does the most recent
        #expect(await cache.get(domain: "site0.test") == nil)
    }
}
