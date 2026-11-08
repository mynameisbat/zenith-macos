import Testing
import Foundation
import Darwin
@testable import ZenithCore

@Suite("Proxy watchdog: gets the user online when the app dies, and only then")
struct ProxyWatchdogTests {
    /// A folder with a stand-in `networksetup` that logs its calls and prints the proxy settings kept in two files.
    private struct Fixture {
        let dir: URL
        var log: URL { dir.appendingPathComponent("calls.log") }

        init(web: String, secure: String) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-watchdog-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try web.write(to: dir.appendingPathComponent("web.txt"), atomically: true, encoding: .utf8)
            try secure.write(to: dir.appendingPathComponent("secure.txt"), atomically: true, encoding: .utf8)
            let script = """
            #!/bin/sh
            printf '%s|%s|%s\\n' "$1" "$2" "$3" >> "\(dir.path)/calls.log"
            case "$1" in
              -getwebproxy) cat "\(dir.path)/web.txt" ;;
              -getsecurewebproxy) cat "\(dir.path)/secure.txt" ;;
            esac
            """
            let url = dir.appendingPathComponent("networksetup")
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        var environment: [String: String] {
            ["NETWORKSETUP": dir.appendingPathComponent("networksetup").path, "CHECK_SECONDS": "0.1", "SETTLE_SECONDS": "0.1"]
        }

        /// The `-set…` calls the watchdog made.
        var changes: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("-set") }
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    private static func proxyOutput(enabled: Bool, server: String = "127.0.0.1", port: UInt16) -> String {
        "Enabled: \(enabled ? "Yes" : "No")\nServer: \(server)\nPort: \(port)\nAuthenticated Proxy Enabled: 0\n"
    }

    /// The PID of a process that has already ended.
    private static func deadPID() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func runToCompletion(_ watchdog: ProxyWatchdog, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while watchdog.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test("WD-01: App gone, proxy still on Zenith's port, nothing listening: both proxies are switched off")
    func testSwitchesOffAfterTheAppDies() async throws {
        let port = Sock.freePort()
        let fixture = try Fixture(web: Self.proxyOutput(enabled: true, port: port), secure: Self.proxyOutput(enabled: true, port: port))
        defer { fixture.remove() }
        let watchdog = ProxyWatchdog()
        #expect(watchdog.start(port: port, service: "Wi-Fi", appPID: Self.deadPID(), environment: fixture.environment))
        await runToCompletion(watchdog)
        #expect(fixture.changes == ["-setwebproxystate|Wi-Fi|off", "-setsecurewebproxystate|Wi-Fi|off"])
    }

    @Test("WD-02: A Zenith that is listening on the port again owns the proxy: nothing is touched")
    func testLeavesAnotherLiveZenithAlone() async throws {
        let (listener, port) = Sock.listen()
        defer { close(listener) }
        let fixture = try Fixture(web: Self.proxyOutput(enabled: true, port: port), secure: Self.proxyOutput(enabled: true, port: port))
        defer { fixture.remove() }
        let watchdog = ProxyWatchdog()
        watchdog.start(port: port, service: "Wi-Fi", appPID: Self.deadPID(), environment: fixture.environment)
        await runToCompletion(watchdog)
        #expect(fixture.changes.isEmpty)
    }

    @Test("WD-03: A proxy that is not Zenith's (another port or server, or already off) is never changed")
    func testLeavesOtherProxiesAlone() async throws {
        let port = Sock.freePort()
        let cases: [(String, String)] = [
            (Self.proxyOutput(enabled: true, port: port &+ 1), Self.proxyOutput(enabled: true, port: port &+ 1)),          // other port
            (Self.proxyOutput(enabled: true, server: "proxy.corp.example", port: port), Self.proxyOutput(enabled: true, server: "10.0.0.1", port: port)),
            (Self.proxyOutput(enabled: false, port: port), Self.proxyOutput(enabled: false, port: port))                    // already off
        ]
        for (web, secure) in cases {
            let fixture = try Fixture(web: web, secure: secure)
            defer { fixture.remove() }
            let watchdog = ProxyWatchdog()
            watchdog.start(port: port, service: "Wi-Fi", appPID: Self.deadPID(), environment: fixture.environment)
            await runToCompletion(watchdog)
            #expect(fixture.changes.isEmpty, "changed: \(fixture.changes) for \(web)")
        }
    }

    @Test("WD-04: Only the protocol that points at Zenith is switched off")
    func testChangesOnlyWhatIsZeniths() async throws {
        let port = Sock.freePort()
        let fixture = try Fixture(web: Self.proxyOutput(enabled: true, port: port), secure: Self.proxyOutput(enabled: true, server: "10.1.1.1", port: 3128))
        defer { fixture.remove() }
        let watchdog = ProxyWatchdog()
        watchdog.start(port: port, service: "Wi-Fi", appPID: Self.deadPID(), environment: fixture.environment)
        await runToCompletion(watchdog)
        #expect(fixture.changes == ["-setwebproxystate|Wi-Fi|off"])
    }

    @Test("WD-05: While the app is alive nothing happens; when it is killed, the proxy is switched off")
    func testWaitsForTheApp() async throws {
        let port = Sock.freePort()
        let fixture = try Fixture(web: Self.proxyOutput(enabled: true, port: port), secure: Self.proxyOutput(enabled: true, port: port))
        defer { fixture.remove() }
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["60"]
        try app.run()
        defer { if app.isRunning { app.terminate() } }

        let watchdog = ProxyWatchdog()
        watchdog.start(port: port, service: "Wi-Fi", appPID: app.processIdentifier, environment: fixture.environment)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(watchdog.isRunning)
        #expect(fixture.changes.isEmpty, "acted while the app was still running")

        kill(app.processIdentifier, SIGKILL)   // the app is killed, not quit
        await runToCompletion(watchdog)
        #expect(fixture.changes.count == 2)
    }

    @Test("WD-06: Stopping it (a normal restore) ends the process without touching anything")
    func testStop() async throws {
        let port = Sock.freePort()
        let fixture = try Fixture(web: Self.proxyOutput(enabled: true, port: port), secure: Self.proxyOutput(enabled: true, port: port))
        defer { fixture.remove() }
        let watchdog = ProxyWatchdog()
        watchdog.start(port: port, service: "Wi-Fi", environment: fixture.environment)   // watches this test process
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(watchdog.isRunning)
        watchdog.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(!watchdog.isRunning)
        #expect(fixture.changes.isEmpty)
    }

    @Test("WD-07: A service name with spaces, quotes and shell characters reaches networksetup intact")
    func testOddServiceName() async throws {
        let port = Sock.freePort()
        let name = "Wi-Fi \"Home\" $(touch /tmp/zenith-watchdog-pwned) ; & `x`"
        let fixture = try Fixture(web: Self.proxyOutput(enabled: true, port: port), secure: Self.proxyOutput(enabled: false, port: port))
        defer { fixture.remove() }
        try? FileManager.default.removeItem(atPath: "/tmp/zenith-watchdog-pwned")
        let watchdog = ProxyWatchdog()
        watchdog.start(port: port, service: name, appPID: Self.deadPID(), environment: fixture.environment)
        await runToCompletion(watchdog)
        #expect(fixture.changes == ["-setwebproxystate|\(name)|off"])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/zenith-watchdog-pwned"), "the name was run as a command")
    }

    @Test("WD-08: SystemProxyManager starts the watchdog when it enables the proxy and ends it when it restores")
    func testManagerStartsAndStopsIt() throws {
        let fake = FakeNetworkSetup()
        let watchdog = ProxyWatchdog()
        defer { watchdog.stop() }
        // The manager only creates its own watchdog when it is the real instance, so one is handed in here.
        let manager = SystemProxyManager(
            runner: fake.runner,
            defaults: TestDefaults.make("zenith.tests.watchdog.\(UUID().uuidString)")!,
            portProbe: { _ in false },
            installExitHooks: false,
            watchdog: watchdog
        )
        #expect(!watchdog.isRunning)
        #expect(manager.enableProxySynchronously(port: 18080))
        #expect(watchdog.isRunning)
        #expect(manager.disableProxySynchronously())
        #expect(!watchdog.isRunning)
    }

    @Test("WD-09: A manager made for tests (no exit hooks) never starts a process of its own")
    func testTestManagerHasNoWatchdog() throws {
        let fake = FakeNetworkSetup()
        let manager = SystemProxyManager(
            runner: fake.runner,
            defaults: TestDefaults.make("zenith.tests.watchdog.\(UUID().uuidString)")!,
            portProbe: { _ in false },
            installExitHooks: false
        )
        #expect(manager.enableProxySynchronously(port: 18081))
        #expect(manager.disableProxySynchronously())
    }
}
