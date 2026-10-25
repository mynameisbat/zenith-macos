import Testing
import Foundation
@testable import ZenithCore

@Suite("LocalProxyServer Security, Loopback Guard & SSRF Protection Suite")
struct LocalProxyServerSecurityTests {

    // MARK: - 1. Loopback Port Collisions & Self-Referential DoS Guards

    @Test("PS-SEC-01: Rejects loopback connections pointing to the proxy's own port")
    func testLoopbackSelfPortRejection() {
        let proxyPort: UInt16 = 8080

        // Explicit IPv4 loopback
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "127.0.0.1", targetPort: 8080, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "127.0.0.2", targetPort: 8080, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "127.255.255.254", targetPort: 8080, proxyPort: proxyPort) == false)

        // IPv6 loopback
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "::1", targetPort: 8080, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "[::1]", targetPort: 8080, proxyPort: proxyPort) == false)

        // Wildcard / unspecified addresses that bind or route to local machine
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "0.0.0.0", targetPort: 8080, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "::", targetPort: 8080, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "[::]", targetPort: 8080, proxyPort: proxyPort) == false)

        // Localhost hostname string
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "localhost", targetPort: 8080, proxyPort: proxyPort) == false)

        // IPv4-mapped IPv6 loopback
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "::ffff:127.0.0.1", targetPort: 8080, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "[::ffff:127.0.0.1]", targetPort: 8080, proxyPort: proxyPort) == false)
    }

    @Test("PS-SEC-02: Permits local development services when target port differs from proxy port")
    func testPermitLocalServicesOnDifferentPort() {
        let proxyPort: UInt16 = 8080

        // Local development servers (e.g. Node/Vite/Python on 3000, 8000, 5000)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "127.0.0.1", targetPort: 3000, proxyPort: proxyPort) == true)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "127.0.0.1", targetPort: 8000, proxyPort: proxyPort) == true)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "::1", targetPort: 443, proxyPort: proxyPort) == true)
    }

    // MARK: - 2. Cloud Metadata & SSRF Attack Mitigations

    @Test("PS-SEC-03: Blocks AWS / GCP / Azure IMDS and container metadata endpoints")
    func testBlockCloudMetadataSSRF() {
        let proxyPort: UInt16 = 8080

        // Standard cloud IMDS (169.254.169.254)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "169.254.169.254", targetPort: 80, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "169.254.169.254", targetPort: 443, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "[169.254.169.254]", targetPort: 80, proxyPort: proxyPort) == false)

        // AWS ECS Task Metadata Endpoint (169.254.170.2)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "169.254.170.2", targetPort: 80, proxyPort: proxyPort) == false)

        // General IPv4 Link-Local (169.254.0.0/16)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "169.254.1.1", targetPort: 80, proxyPort: proxyPort) == false)

        // IPv4-mapped IPv6 link-local
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "::ffff:169.254.169.254", targetPort: 80, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "[::ffff:169.254.169.254]", targetPort: 80, proxyPort: proxyPort) == false)

        // AWS IPv6 IMDSv2 (fd00:ec2::254)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "fd00:ec2::254", targetPort: 80, proxyPort: proxyPort) == false)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "[fd00:ec2::254]", targetPort: 80, proxyPort: proxyPort) == false)
    }

    // MARK: - 3. Legitimate Public Internet Traffic

    @Test("PS-SEC-04: Permits standard external public internet endpoints")
    func testPermitLegitimatePublicEndpoints() {
        let proxyPort: UInt16 = 8080

        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "1.1.1.1", targetPort: 443, proxyPort: proxyPort) == true)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "8.8.8.8", targetPort: 53, proxyPort: proxyPort) == true)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "93.184.216.34", targetPort: 80, proxyPort: proxyPort) == true)
        #expect(LocalProxyServer.isPermittedTarget(resolvedIP: "2606:4700::6812:201", targetPort: 443, proxyPort: proxyPort) == true)
    }

    // MARK: - 4. Concurrency & Thread-Safety

    @Test("PS-SEC-05: Concurrent state reads and stop calls remain thread-safe without race conditions")
    func testConcurrentStateThreadSafety() async {
        let server = LocalProxyServer()
        let taskCount = 50

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    _ = server.isRunning
                    _ = server.port
                    _ = server.provider
                    if i % 5 == 0 {
                        server.stop()
                    }
                    if i % 3 == 0 {
                        server.port = UInt16(8080 + (i % 10))
                        server.provider = (i % 2 == 0) ? .cloudflare : .google
                    }
                    _ = server.isRunning
                }
            }
        }

        #expect(!server.isRunning)
    }
}
