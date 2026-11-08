import Testing
import Foundation
import Darwin
@testable import ZenithCore

/// Checks found by reading Privacy Shield: values a user can type, limits of the process, load on the proxy.
@Suite("Privacy Shield audit: typed ports and resolvers, open-file limit, many tunnels at once")
struct PrivacyShieldAuditTests {

    @Test("PSA-01: A typed port is usable only inside 1024...65535; anything else is refused instead of trapping")
    func testPortValidation() {
        #expect(PrivacyShieldStatistics.validPort(8080) == 8080)
        #expect(PrivacyShieldStatistics.validPort(1024) == 1024)
        #expect(PrivacyShieldStatistics.validPort(65_535) == 65_535)
        for bad in [0, 1, 80, 443, 1023, 65_536, 70_000, -1, -8080, Int.max, Int.min] {
            #expect(PrivacyShieldStatistics.validPort(bad) == nil, "\(bad)")
        }
    }

    @Test("PSA-02: A custom resolver must be https with a host, and a bootstrap address must be an IP")
    func testCustomProviderValidation() {
        let ok = DoHProvider.custom(urlString: " https://dns.example.com/dns-query ", bootstrapIP: " 9.9.9.9 ")
        #expect(ok == .custom(url: URL(string: "https://dns.example.com/dns-query")!, bootstrapIP: "9.9.9.9"))
        #expect(DoHProvider.custom(urlString: "https://dns.example.com/dns-query", bootstrapIP: "") ==
                .custom(url: URL(string: "https://dns.example.com/dns-query")!, bootstrapIP: nil))
        #expect(DoHProvider.custom(urlString: "https://dns.example.com/q", bootstrapIP: "2620:fe::fe") != nil)

        for url in ["http://dns.example.com/dns-query", "ftp://dns.example.com", "dns.example.com", "https://", "https:///path",
                    "", "  ", "javascript:alert(1)", "file:///etc/hosts"] {
            #expect(DoHProvider.custom(urlString: url, bootstrapIP: "") == nil, "\(url)")
        }
        for ip in ["dns.example.com", "999.1.1.1", "1.1.1", "9.9.9.9/24", "not an ip"] {
            #expect(DoHProvider.custom(urlString: "https://dns.example.com/dns-query", bootstrapIP: ip) == nil, "\(ip)")
        }
    }

    @Test("PSA-03: Typing the start of an address never yields a provider, so a half-typed URL cannot become the resolver")
    func testHalfTypedAddressesAreRefused() {
        let target = "https://dns.example.com/dns-query"
        for length in 0..<"https://".count {
            #expect(DoHProvider.custom(urlString: String(target.prefix(length)), bootstrapIP: "") == nil)
        }
    }

    @Test("PSA-04: A NextDNS profile ID is letters and numbers only; empty means the generic endpoint")
    func testNextDNSValidation() {
        #expect(DoHProvider.nextDNS(profileID: " 2b489c ") == .nextdns(profileID: "2b489c"))
        #expect(DoHProvider.nextDNS(profileID: "") == .nextdns(profileID: ""))
        for bad in ["../evil", "a/b", "id?x=1", "a b", "id#frag", "é", "a%2fb"] {
            #expect(DoHProvider.nextDNS(profileID: bad) == nil, "\(bad)")
        }
    }

    @Test("PSA-05: The open-file limit is raised to what is allowed and never lowered")
    func testFileDescriptorTarget() {
        // A Finder-launched app starts at 256.
        #expect(FileDescriptorLimit.targetSoftLimit(current: 256, hard: .max, perProcessMaximum: 122_880) == 10_240)
        // The hard limit or the system maximum may allow less.
        #expect(FileDescriptorLimit.targetSoftLimit(current: 256, hard: 4_096, perProcessMaximum: 122_880) == 4_096)
        #expect(FileDescriptorLimit.targetSoftLimit(current: 256, hard: .max, perProcessMaximum: 2_048) == 2_048)
        // Already higher: left alone.
        #expect(FileDescriptorLimit.targetSoftLimit(current: 50_000, hard: .max, perProcessMaximum: 122_880) == 50_000)
        #expect(FileDescriptorLimit.targetSoftLimit(current: 8_192, hard: 1_024, perProcessMaximum: 1_024) == 8_192)
    }

    @Test("PSA-06: Raising the limit in this process leaves it at least where it was and, if it was low, at the target")
    func testRaiseInThisProcess() {
        var before = rlimit()
        getrlimit(RLIMIT_NOFILE, &before)
        let after = FileDescriptorLimit.raiseSoftLimit()
        var now = rlimit()
        getrlimit(RLIMIT_NOFILE, &now)
        #expect(UInt64(now.rlim_cur) >= UInt64(before.rlim_cur))
        #expect(after == UInt64(now.rlim_cur))
        #expect(UInt64(now.rlim_cur) >= FileDescriptorLimit.desired)
    }

    @Test("PSA-07: Starting the proxy raises the limit")
    func testStartingTheProxyRaisesTheLimit() async throws {
        let server = LocalProxyServer()
        let port = Sock.freePort()
        try await server.startAndAwaitReady(port: port, provider: .cloudflare)
        defer { server.stop() }
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        #expect(UInt64(limit.rlim_cur) >= FileDescriptorLimit.desired)
    }

    @Test("PSA-09: An app inside /Volumes (a mounted DMG or drive) is recognised; one in Applications is not")
    func testMountedVolumeDetection() {
        #expect(AppLocation.isOnMountedVolume("/Volumes/Zenith 2.3.1/Zenith.app"))
        #expect(AppLocation.isOnMountedVolume("/Volumes/Samsung SSD/Apps/Zenith.app"))
        #expect(!AppLocation.isOnMountedVolume("/Applications/Zenith.app"))
        #expect(!AppLocation.isOnMountedVolume("/Users/someone/Applications/Zenith.app"))
        #expect(!AppLocation.isOnMountedVolume("/Volumes"))
        // The boot volume appears under /Volumes as a link to "/", which is not a volume that goes away.
        let boot = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in boot where (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/\(name)")) == "/" {
            #expect(!AppLocation.isOnMountedVolume("/Volumes/\(name)/Applications"), "\(name)")
        }
    }

    @Test("PSA-10: Only a path on the volume being unmounted matches it, not a look-alike name")
    func testPathOnVolume() {
        #expect(AppLocation.isPath("/Volumes/Zenith/Zenith.app", onVolumeMountedAt: "/Volumes/Zenith"))
        #expect(AppLocation.isPath("/Volumes/Zenith/Zenith.app", onVolumeMountedAt: "/Volumes/Zenith/"))
        #expect(AppLocation.isPath("/Volumes/Zenith", onVolumeMountedAt: "/Volumes/Zenith"))
        #expect(!AppLocation.isPath("/Volumes/Zenith 2/Zenith.app", onVolumeMountedAt: "/Volumes/Zenith"))
        #expect(!AppLocation.isPath("/Applications/Zenith.app", onVolumeMountedAt: "/Volumes/Zenith"))
        #expect(!AppLocation.isPath("/Applications/Zenith.app", onVolumeMountedAt: "/"))
        #expect(!AppLocation.isPath("/Volumes/Zenith/Zenith.app", onVolumeMountedAt: "/"))
    }

    @Test("PSA-08: Two hundred tunnels open at once each carry their own data back unmixed")
    func testManyTunnelsAtOnce() async throws {
        let count = 200
        let origin = PollingEchoOrigin()
        defer { origin.stop() }
        let server = LocalProxyServer()
        let proxyPort = Sock.freePort()
        try await server.startAndAwaitReady(port: proxyPort, provider: .cloudflare)
        defer { server.stop() }
        let originPort = origin.port

        // One thread drives every client, so the test itself never starves the threads the proxy needs.
        let failures: [String] = await offPool {
            var problems: [String] = []
            var clients: [Int32] = []
            defer { clients.forEach { close($0) } }

            // 200 tunnels open at once, but arriving the way a busy browser makes them (a few dozen at a time). All 200
            // connecting within a few milliseconds overflows the kernel's accept queue (`kern.ipc.somaxconn`, 128 by
            // default) and macOS resets the overflow, whatever the server does.
            for index in 0..<count {
                let client = Sock.connect(to: proxyPort, timeout: 20)
                clients.append(client)
                Sock.send(client, "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n")
                if index % 25 == 24 { usleep(40_000) }
            }
            for (index, client) in clients.enumerated() {
                let head = Sock.receive(client, until: Data("\r\n\r\n".utf8))
                if String(data: head, encoding: .utf8)?.hasPrefix("HTTP/1.1 200") != true {
                    problems.append("tunnel \(index) not established, got \(head.count) bytes: \(String(decoding: head.prefix(60), as: UTF8.self).debugDescription) errno \(errno)")
                }
            }
            for (index, client) in clients.enumerated() { Sock.send(client, "request-\(index)\n") }
            for (index, client) in clients.enumerated() {
                let reply = String(data: Sock.receive(client, until: Data("\n".utf8)), encoding: .utf8)
                if reply != "echo:request-\(index)\n" { problems.append("tunnel \(index) got \(String(describing: reply))") }
            }
            return problems
        }
        #expect(failures.isEmpty, "\(failures.count) of \(count) tunnels failed, first: \(failures.first ?? "")")
    }
}

/// A local server that echoes each line back with a prefix, serving every client from one thread with `poll`.
final class PollingEchoOrigin: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false

    init() {
        let (fd, port) = Sock.listen()
        listenFD = fd
        self.port = port
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)   // accept must never wait: one thread serves everyone
        // Sock.listen asks for a queue of 16; 200 clients arriving together would overflow it, macOS would drop the
        // overflow, and TCP would retry only after a second or more.
        _ = Darwin.listen(fd, 512)
        Thread.detachNewThread { [self] in run() }
    }

    func stop() { lock.withLock { stopped = true } }

    private func run() {
        var clients: [Int32: Data] = [:]
        while !lock.withLock({ stopped }) {
            var descriptors = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
            descriptors += clients.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&descriptors, nfds_t(descriptors.count), 100) > 0 else { continue }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                while true {
                    let client = accept(listenFD, nil, nil)
                    if client < 0 { break }
                    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
                    clients[client] = Data()
                }
            }
            for descriptor in descriptors.dropFirst() where descriptor.revents != 0 {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let received = recv(descriptor.fd, &chunk, chunk.count, 0)
                if received > 0 {
                    clients[descriptor.fd, default: Data()].append(contentsOf: chunk[0..<received])
                    if let line = clients[descriptor.fd], line.contains(0x0A) {
                        Sock.send(descriptor.fd, Data("echo:".utf8) + line)
                        close(descriptor.fd)
                        clients.removeValue(forKey: descriptor.fd)
                    }
                } else if received == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    close(descriptor.fd)
                    clients.removeValue(forKey: descriptor.fd)
                }
            }
        }
        clients.keys.forEach { close($0) }
        close(listenFD)
    }
}
