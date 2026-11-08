import Testing
import Foundation
@testable import ZenithCore

/// Checks against this Mac and the internet, read-only: nothing is deleted and no system setting is changed.
/// Opt in with `ZENITH_AUDIT_REAL=1`. It makes small web requests (the speed test downloads about 8 MB and throws it away).
private let auditEnabled = ProcessInfo.processInfo.environment["ZENITH_AUDIT_REAL"] == "1"

private func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    guard (try? process.run()) != nil else { return (-1, "", "could not launch") }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { process.terminate() }
    let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, o, e)
}

@Suite("Real machine audit (opt-in, read-only)", .enabled(if: auditEnabled), .serialized)
struct RealMachineAuditTests {

    // MARK: Network speed

    @Test("RM-01: The measured download speed matches what curl itself reports")
    @MainActor
    func testNetworkSpeedAgainstCurl() async throws {
        let before = try #require(NetworkInterfaceReader.readCounters())
        print("RM-01 interfaces counted: \(before.keys.sorted())")

        let monitor = NetworkSpeedMonitor(autoTick: false)
        monitor.acquire()
        var peak = 0.0
        var samples: [Double] = []

        let done = NSLock()
        nonisolated(unsafe) var finished = false
        let curl = Task.detached { () -> (status: Int32, out: String, err: String) in
            let result = run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{speed_download} %{size_download}",
                                               "https://speed.cloudflare.com/__down?bytes=8000000"])
            done.withLock { finished = true }
            return result
        }
        // Sample twice a second until the download is over.
        while samples.count < 120, !done.withLock({ finished }) {
            try await Task.sleep(nanoseconds: 500_000_000)
            monitor.sample()
            samples.append(monitor.speed.downloadBytesPerSecond)
            peak = max(peak, monitor.speed.downloadBytesPerSecond)
        }
        let result = await curl.value
        monitor.release()
        let after = try #require(NetworkInterfaceReader.readCounters())

        let fields = result.out.split(separator: " ")
        let curlSpeed = Double(fields.first ?? "") ?? 0
        let curlBytes = Double(fields.last ?? "") ?? 0
        // Interface by interface (a dictionary has no order); an interface that appeared in between counts for nothing.
        let received = after.reduce(0.0) { total, entry in
            guard let earlier = before[entry.key], entry.value.receivedBytes >= earlier.receivedBytes else { return total }
            return total + Double(entry.value.receivedBytes - earlier.receivedBytes)
        }
        print("RM-01 curl: \(curlBytes) bytes at \(curlSpeed) B/s; counters rose by \(received); monitor peak \(peak) B/s; samples \(samples.map { Int($0) })")

        try #require(curlBytes >= 7_000_000, "curl did not download the test file (offline?): \(result.err)")
        #expect(received >= curlBytes && received < curlBytes * 1.5 + 5_000_000, "counters rose by \(received) for \(curlBytes) bytes")
        #expect(peak >= curlSpeed * 0.5 && peak <= curlSpeed * 3, "monitor peak \(peak) vs curl \(curlSpeed)")
    }

    // MARK: Tracker blocking through the real proxy

    private func startProxy(blocking: [String]) async throws -> (LocalProxyServer, UInt16) {
        let server = LocalProxyServer()
        server.blocklist = TrackerBlocklist(blocked: blocking)
        let port = Sock.freePort()
        try await server.startAndAwaitReady(port: port, provider: .cloudflare)
        return (server, port)
    }

    @Test("RM-02: curl through the proxy: blocked HTTPS and HTTP get 403, other sites load")
    func testCurlThroughProxy() async throws {
        let (server, port) = try await startProxy(blocking: ["doubleclick.net", "scorecardresearch.com"])
        defer { server.stop() }
        let proxy = "http://127.0.0.1:\(port)"

        let https = await offPool { run("/usr/bin/curl", ["-sS", "-m", "20", "-o", "/dev/null", "-x", proxy, "https://stats.g.doubleclick.net/"]) }
        print("RM-02 blocked https: status \(https.status) err: \(https.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(https.status != 0)
        #expect(https.err.contains("403"), "curl should report the proxy's 403: \(https.err)")

        let http = await offPool { run("/usr/bin/curl", ["-sS", "-m", "20", "-o", "/dev/null", "-w", "%{http_code}", "-x", proxy, "http://b.scorecardresearch.com/beacon.js"]) }
        print("RM-02 blocked http: code \(http.out)")
        #expect(http.out == "403")

        let ok = await offPool { run("/usr/bin/curl", ["-sS", "-m", "30", "-o", "/dev/null", "-w", "%{http_code}", "-x", proxy, "https://example.com/"]) }
        print("RM-02 allowed https: code \(ok.out) err: \(ok.err)")
        try #require(ok.status == 0, "example.com should load through the proxy (DoH + TLS split): \(ok.err)")
        #expect(ok.out == "200")
    }

    @Test("RM-03: Headless Chrome through the proxy loads the page and has its tracker requests refused")
    @MainActor
    func testChromeThroughProxy() async throws {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        try #require(FileManager.default.isExecutableFile(atPath: chrome), "Chrome is not installed")
        let (server, port) = try await startProxy(blocking: ["doubleclick.net", "scorecardresearch.com"])
        defer { server.stop() }
        PrivacyShieldStatistics.shared.reset()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("page.html")
        try """
        <html><body><h1 id="ok">page loaded</h1>
        <img src="https://ad.doubleclick.net/pixel.gif">
        <script src="https://sb.scorecardresearch.com/beacon.js"></script>
        <img src="http://stats.doubleclick.net/p.gif">
        </body></html>
        """.write(to: page, atomically: true, encoding: .utf8)

        let result = await offPool {
            run(chrome, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                         "--user-data-dir=\(dir.appendingPathComponent("profile").path)",
                         "--proxy-server=http://127.0.0.1:\(port)", "--virtual-time-budget=8000",
                         "--dump-dom", page.absoluteString], timeout: 45)
        }
        try await Task.sleep(nanoseconds: 500_000_000)   // the statistics are updated on the main actor
        let blocked = PrivacyShieldStatistics.shared.totalRequestsBlocked
        let domains = PrivacyShieldStatistics.shared.recentRequests.filter { $0.status == .blocked }.map(\.domain)
        print("RM-03 chrome status \(result.status), page has marker: \(result.out.contains("page loaded")), blocked \(blocked): \(domains)")
        #expect(result.out.contains("page loaded"))
        #expect(blocked >= 2, "Chrome should have asked for the tracker URLs through the proxy: \(domains)")
        #expect(domains.allSatisfy { $0.hasSuffix("doubleclick.net") || $0.hasSuffix("scorecardresearch.com") })
    }

    // MARK: Cleaner on this Mac (scan only)

    @Test("RM-04: Sizes the cleaner reports on this Mac agree with du, and the old way read low")
    @MainActor
    func testCleanerSizesAgainstDu() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let service = SystemCleanerService(homeDirectory: home)
        await service.scan()   // read-only: nothing is cleaned
        var checked = 0
        for category in service.categories {
            for item in category.items.prefix(6) where item.size > 5_000_000 {
                let du = run("/usr/bin/du", ["-sk", item.path])
                let duBytes = (Double(du.out.split(separator: "\t").first ?? "") ?? 0) * 1024
                let ratio = duBytes > 0 ? Double(item.size) / duBytes : 0
                print("RM-04 \(category.id) / \(item.name): zenith \(item.size) du \(Int(duBytes)) ratio \(String(format: "%.2f", ratio))")
                #expect(ratio > 0.85 && ratio < 1.15, "\(item.name) ratio \(ratio)")
                checked += 1
            }
        }
        print("RM-04 compared \(checked) real folders")
    }

    @Test("RM-05: Project build folders on this Mac: sizes agree with du; show how many days untouched")
    func testProjectScanAgainstDu() async throws {
        let service = ProjectPurgeService()
        let summary = service.scan(minAgeDays: 0)
        print("RM-05 projects found \(summary.totalProjectsFound), build folders \(summary.artifacts.count)")
        for item in summary.artifacts.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(8) {
            let du = run("/usr/bin/du", ["-sk", item.artifactPath])
            let duBytes = (Double(du.out.split(separator: "\t").first ?? "") ?? 0) * 1024
            let ratio = duBytes > 0 ? Double(item.sizeBytes) / duBytes : 0
            print("RM-05 \(item.projectName)/\(item.artifactName): zenith \(item.sizeBytes) du \(Int(duBytes)) ratio \(String(format: "%.2f", ratio)) untouched \(item.daysSinceModified) d")
            #expect(ratio > 0.85 && ratio < 1.15, "\(item.artifactPath) ratio \(ratio)")
        }
    }

    // MARK: System proxy, read-only

    @Test("RM-06: This Mac's real networksetup output is understood (read-only; nothing is changed)")
    func testSystemProxyParsing() throws {
        let manager = SystemProxyManager(installExitHooks: false)
        let service = try #require(manager.discoverPrimaryService(), "no primary network service")
        print("RM-06 primary service: \(service)")
        for command in ["-getwebproxy", "-getsecurewebproxy"] {
            let raw = run("/usr/sbin/networksetup", [command, service])
            let parsed = SystemProxyManager.parseProxyConfiguration(raw.out)
            print("RM-06 \(command): raw \(raw.out.replacingOccurrences(of: "\n", with: " | ")) -> \(String(describing: parsed))")
            let config = try #require(parsed, "could not parse: \(raw.out)")
            let enabledInRaw = raw.out.contains("Enabled: Yes")
            #expect(config.isEnabled == enabledInRaw)
        }
        let bypass = run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])
        print("RM-06 bypass: \(SystemProxyManager.parseBypassDomains(bypass.out))")
        print("RM-06 Zenith proxy active right now: \(manager.isZenithProxyActive(port: 8080))")
    }
}
