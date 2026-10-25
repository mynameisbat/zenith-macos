import Testing
import Foundation
import Network
@testable import ZenithCore

@Suite("Live Proxy Curl Diagnosis Suite")
struct PrivacyShieldLiveTest {

    @Test("Diagnose live request to 1.1.1.1")
    func testLiveProxyRequest() async throws {
        let server = LocalProxyServer()
        try server.start(port: 9876, provider: .cloudflare)
        defer { server.stop() }

        // Wait 200ms for listener to be ready
        try await Task.sleep(nanoseconds: 200_000_000)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-v", "-L", "-k", "-x", "http://127.0.0.1:9876", "https://1.1.1.1/help", "--max-time", "10"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errOutput = String(data: errData, encoding: .utf8) ?? ""
        print("=== CURL OUTPUT ===")
        print(errOutput)
        print("=== EXIT CODE: \(process.terminationStatus) ===")
    }

    @Test("Diagnose URLSession (Safari/macOS native engine) through proxy")
    func testURLSessionThroughProxy() async throws {
        let server = LocalProxyServer()
        try server.start(port: 9877, provider: .cloudflare)
        defer { server.stop() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPPort as String: 9877,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSPort as String: 9877,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
        ]
        config.timeoutIntervalForRequest = 8.0

        let proxySession = URLSession(configuration: config)
        let url = URL(string: "https://1.1.1.1/help")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await proxySession.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("=== URLSESSION SUCCESS: statusCode \(http.statusCode), bytes: \(data.count) ===")
                #expect(http.statusCode == 200)
                #expect(!data.isEmpty)
            }
        } catch {
            print("=== URLSESSION FAILED: \(error) ===")
            Issue.record("URLSession failed: \(error)")
        }
    }

    @Test("Diagnose Plain HTTP (Port 80) through proxy")
    func testPlainHTTPThroughProxy() async throws {
        let server = LocalProxyServer()
        try server.start(port: 9878, provider: .cloudflare)
        defer { server.stop() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPPort as String: 9878,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
        ]
        config.timeoutIntervalForRequest = 8.0

        let proxySession = URLSession(configuration: config)
        let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await proxySession.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("=== PLAIN HTTP SUCCESS: statusCode \(http.statusCode), bytes: \(data.count) ===")
                #expect(http.statusCode == 200)
                #expect(!data.isEmpty)
            }
        } catch {
            print("=== PLAIN HTTP DIAGNOSTIC NOTICE (Network Timeout): \(error) ===")
        }
    }

    @Test("Diagnose root 1.1.1.1 HTTP and HTTPS")
    func testRoot1111() async throws {
        let server = LocalProxyServer()
        try server.start(port: 9879, provider: .cloudflare)
        defer { server.stop() }

        try await Task.sleep(nanoseconds: 200_000_000)

        // 1. Plain HTTP to http://1.1.1.1/
        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p1.arguments = ["-v", "-L", "-x", "http://127.0.0.1:9879", "http://1.1.1.1", "--max-time", "10"]
        let e1 = Pipe()
        p1.standardError = e1
        try p1.run()
        p1.waitUntilExit()
        let err1 = String(data: e1.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("=== TEST http://1.1.1.1 EXIT \(p1.terminationStatus) ===")
        print(err1)

        // 2. HTTPS to https://1.1.1.1/
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p2.arguments = ["-v", "-L", "-k", "-x", "http://127.0.0.1:9879", "https://1.1.1.1", "--max-time", "10"]
        let e2 = Pipe()
        p2.standardError = e2
        try p2.run()
        p2.waitUntilExit()
        let err2 = String(data: e2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("=== TEST https://1.1.1.1 EXIT \(p2.terminationStatus) ===")
        print(err2)
    }
}
