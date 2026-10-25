import Testing
import Foundation
@testable import ZenithCore

@Suite("Privacy Shield Architecture & DPI Bypass Test Suite")
struct PrivacyShieldTests {

    // MARK: - 1. DoH Provider & Endpoint Tests

    @Test("PS-01: DoHProvider enumeration covers Cloudflare, AdGuard, Google, Quad9 with valid endpoints")
    func testDoHProviderEndpoints() {
        for provider in DoHProvider.allCases {
            #expect(!provider.displayName.isEmpty)
            #expect(!provider.subtitle.isEmpty)
            #expect(provider.endpointURL.scheme == "https")
            #expect(!provider.directIP.isEmpty)
        }

        #expect(DoHProvider.cloudflare.directIP == "1.1.1.1")
        #expect(DoHProvider.google.directIP == "8.8.8.8")
        #expect(DoHProvider.quad9.directIP == "9.9.9.9")
    }

    // MARK: - 2. TLS ClientHello Chunker Tests

    @Test("PS-02: Non-TLS or truncated data is recognized and passed through without mangling")
    func testNonTLSDataPassthrough() {
        // Plain HTTP GET
        let httpData = "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n".data(using: .utf8)!
        let result = TLSClientHelloChunker.chunkPayload(httpData)
        #expect(result.isTLSClientHello == false)
        #expect(result.firstChunk == httpData)
        #expect(result.secondChunk == nil)

        // Truncated data (< 6 bytes)
        let shortData = Data([0x16, 0x03])
        let shortResult = TLSClientHelloChunker.chunkPayload(shortData)
        #expect(shortResult.isTLSClientHello == false)
        #expect(shortResult.firstChunk == shortData)
        #expect(shortResult.secondChunk == nil)
    }

    @Test("PS-03: Valid TLS ClientHello handshake is accurately detected and fragmented")
    func testValidTLSClientHelloChunking() {
        // Synthetic TLS 1.2 / 1.3 ClientHello packet
        // Byte 0: 0x16 (Handshake)
        // Byte 1: 0x03, Byte 2: 0x01 (Legacy TLS 1.0)
        // Byte 3-4: Length (0x00, 0x20)
        // Byte 5: 0x01 (ClientHello)
        var clientHello = Data([0x16, 0x03, 0x01, 0x00, 0x20, 0x01])
        // Append 32 dummy bytes simulating SNI extension & cipher suites
        clientHello.append(contentsOf: [UInt8](repeating: 0xAA, count: 32))

        #expect(TLSClientHelloChunker.isTLSClientHello(clientHello) == true)

        // Default chunk size = 2
        let result = TLSClientHelloChunker.chunkPayload(clientHello, chunkSize: 2)
        #expect(result.isTLSClientHello == true)
        #expect(result.firstChunk.count == 2)
        #expect(result.secondChunk != nil)
        #expect(result.secondChunk!.count == clientHello.count - 2)

        // Verify reassembly fidelity (TCP stream equivalence)
        var reassembled = Data()
        reassembled.append(result.firstChunk)
        reassembled.append(result.secondChunk!)
        #expect(reassembled == clientHello)
    }

    @Test("PS-04: Variable chunk size parameter boundary clamping")
    func testVariableChunkSizeClamping() {
        let clientHello = Data([0x16, 0x03, 0x03, 0x00, 0x10, 0x01, 0x02, 0x03, 0x04])

        // Clamped minimum (1 byte)
        let r1 = TLSClientHelloChunker.chunkPayload(clientHello, chunkSize: 0)
        #expect(r1.firstChunk.count == 1)

        // 5 bytes
        let r5 = TLSClientHelloChunker.chunkPayload(clientHello, chunkSize: 5)
        #expect(r5.firstChunk.count == 5)
        #expect(r5.firstChunk + r5.secondChunk! == clientHello)
    }

    // MARK: - 3. DoH Resolver IP Detection & Cache Tests

    @Test("PS-05: DoHResolver correctly identifies literal IP addresses without DNS query")
    func testLiteralIPResolution() async throws {
        let resolver = DoHResolver()

        #expect(resolver.isIPv4Address("127.0.0.1") == true)
        #expect(resolver.isIPv4Address("104.18.2.1") == true)
        #expect(resolver.isIPv4Address("not.an.ip") == false)

        #expect(resolver.isIPAddress("2606:4700::6812:201") == true)

        // Resolving literal IP directly returns itself
        let directIPv4 = try await resolver.resolve(domain: "1.1.1.1")
        #expect(directIPv4 == "1.1.1.1")
    }

    // MARK: - 4. Statistics & Live Monitor Tests

    @Test("PS-06: PrivacyShieldStatistics records telemetry and formats bytes accurately")
    @MainActor
    func testStatisticsTelemetry() {
        let stats = PrivacyShieldStatistics()
        stats.reset()

        #expect(stats.totalRequestsProtected == 0)
        #expect(stats.totalBytesShielded == 0)
        #expect(stats.lastProtectedDomain == nil)

        stats.recordProtectedRequest(domain: "store.steampowered.com", bytes: 512, chunkSize: 2)
        #expect(stats.totalRequestsProtected == 1)
        #expect(stats.totalBytesShielded == 512)
        #expect(stats.lastProtectedDomain == "store.steampowered.com")
        #expect(stats.lastChunkSize == 2)
        #expect(stats.formattedShieldedBytes == "512 B")

        stats.recordProtectedRequest(domain: "bbc.com", bytes: 2048, chunkSize: 2)
        #expect(stats.totalRequestsProtected == 2)
        #expect(stats.totalBytesShielded == 2560)
        #expect(stats.formattedShieldedBytes == "2.5 KB")

        stats.updateLatency(12)
        #expect(stats.dohLatencyMs == 12)

        stats.markVerified()
        #expect(stats.lastVerifiedAt != nil)

        stats.reset()
        #expect(stats.totalRequestsProtected == 0)
        #expect(stats.dohLatencyMs == 0)
    }

    // MARK: - 5. LocalProxyServer Lifecycle Test

    @Test("PS-07: LocalProxyServer starts and stops cleanly on high port")
    func testLocalProxyServerLifecycle() throws {
        let server = LocalProxyServer()
        #expect(server.isRunning == false)

        let testPort: UInt16 = 19443
        try server.start(port: testPort, provider: .cloudflare)
        #expect(server.isRunning == true)

        server.stop()
        #expect(server.isRunning == false)
    }

    // MARK: - 6. Live Traffic Request Log & Ring Buffer Tests

    @Test("PS-08: PrivacyShieldStatistics records recent request log records, bounds capacity to 100, and supports pause/clear")
    @MainActor
    func testRequestLogRingBufferAndControls() {
        let stats = PrivacyShieldStatistics()
        stats.reset()

        #expect(stats.recentRequests.isEmpty)
        #expect(stats.isRecordingEnabled == true)

        // 1. Record a shielded request
        stats.recordProtectedRequest(
            domain: "one.one.one.one",
            bytes: 1420,
            chunkSize: 2,
            port: 443,
            protocolType: "HTTPS",
            resolvedIP: "1.1.1.1",
            status: .shielded
        )

        #expect(stats.recentRequests.count == 1)
        let first = stats.recentRequests.first!
        #expect(first.domain == "one.one.one.one")
        #expect(first.port == 443)
        #expect(first.protocolType == "HTTPS")
        #expect(first.resolvedIP == "1.1.1.1")
        #expect(first.status == .shielded)
        #expect(first.chunkSize == 2)
        #expect(first.bytes == 1420)
        #expect(first.formattedBytes == "1.4 KB")
        #expect(!first.formattedTime.isEmpty)

        // 2. Record a failed request
        stats.recordFailedRequest(domain: "invalid.domain.xyz", port: 443, protocolType: "HTTPS")
        #expect(stats.recentRequests.count == 2)
        #expect(stats.recentRequests.first?.status == .failed)
        #expect(stats.recentRequests.first?.domain == "invalid.domain.xyz")

        // 3. Pause recording
        stats.toggleRecording()
        #expect(stats.isRecordingEnabled == false)

        stats.recordProtectedRequest(domain: "ignored.com", bytes: 100, chunkSize: 2)
        #expect(stats.recentRequests.count == 2) // Should not record when paused

        // 4. Resume recording and test 100 item capacity bounding
        stats.toggleRecording()
        #expect(stats.isRecordingEnabled == true)

        for i in 1...120 {
            stats.recordProtectedRequest(domain: "test\(i).com", bytes: Int64(i * 10), chunkSize: 2)
        }

        #expect(stats.recentRequests.count == PrivacyShieldStatistics.maxRecentRequestsCapacity)
        #expect(stats.recentRequests.first?.domain == "test120.com")

        // 5. Clear recent requests
        stats.clearRecentRequests()
        #expect(stats.recentRequests.isEmpty)
    }
}
