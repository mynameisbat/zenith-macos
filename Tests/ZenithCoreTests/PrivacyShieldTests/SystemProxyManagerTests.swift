import Testing
import Foundation
import Darwin
@testable import ZenithCore

/// In-memory stand-in for `networksetup`, `route` and the network service database,
/// so proxy handling can be exercised without touching the machine's real network settings.
final class FakeNetworkSetup: @unchecked Sendable {
    struct Proxy: Equatable {
        var enabled = false
        var server = ""
        var port = 0
        var authenticated = false
    }

    private let lock = NSLock()
    private var _web = Proxy()
    private var _secure = Proxy()
    private var _bypass: [String] = []
    private var _failing: Set<String> = []
    private var _commands: [[String]] = []

    var web: Proxy {
        get { lock.withLock { _web } }
        set { lock.withLock { _web = newValue } }
    }
    var secure: Proxy {
        get { lock.withLock { _secure } }
        set { lock.withLock { _secure = newValue } }
    }
    var bypass: [String] {
        get { lock.withLock { _bypass } }
        set { lock.withLock { _bypass = newValue } }
    }
    /// networksetup subcommands (e.g. "-setsecurewebproxy") that should exit non-zero.
    var failing: Set<String> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    var commands: [[String]] { lock.withLock { _commands } }
    var mutatingCommands: [[String]] { commands.filter { $0.first?.hasPrefix("-set") == true } }

    var runner: SystemCommandRunner {
        { [self] executable, arguments in run(executable, arguments) }
    }

    private func run(_ executable: String, _ arguments: [String]) -> SystemCommandResult? {
        lock.lock()
        defer { lock.unlock() }

        if executable == "/sbin/route" {
            return SystemCommandResult(status: 0, output: "   route to: default\n  interface: en0\n")
        }
        guard executable == "/usr/sbin/networksetup", let command = arguments.first else { return nil }
        _commands.append(arguments)
        if _failing.contains(command) {
            return SystemCommandResult(status: 1, output: "")
        }

        switch command {
        case "-listallhardwareports":
            return ok("Hardware Port: Wi-Fi\nDevice: en0\nEthernet Address: aa:bb:cc:dd:ee:ff\n")
        case "-listallnetworkservices":
            return ok("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n")
        case "-getwebproxy":
            return ok(describe(_web))
        case "-getsecurewebproxy":
            return ok(describe(_secure))
        case "-getproxybypassdomains":
            return ok(_bypass.isEmpty ? "There aren't any bypass domains set on Wi-Fi.\n" : _bypass.joined(separator: "\n") + "\n")
        case "-setwebproxy":
            _web = Proxy(enabled: true, server: arguments[2], port: Int(arguments[3]) ?? 0, authenticated: false)
        case "-setsecurewebproxy":
            _secure = Proxy(enabled: true, server: arguments[2], port: Int(arguments[3]) ?? 0, authenticated: false)
        case "-setwebproxystate":
            _web.enabled = arguments[2] == "on"
        case "-setsecurewebproxystate":
            _secure.enabled = arguments[2] == "on"
        case "-setproxybypassdomains":
            let domains = Array(arguments.dropFirst(2))
            _bypass = domains == ["Empty"] ? [] : domains
        default:
            return SystemCommandResult(status: 1, output: "")
        }
        return ok("")
    }

    private func ok(_ output: String) -> SystemCommandResult {
        SystemCommandResult(status: 0, output: output)
    }

    private func describe(_ proxy: Proxy) -> String {
        "Enabled: \(proxy.enabled ? "Yes" : "No")\nServer: \(proxy.server)\nPort: \(proxy.port)\n"
            + "Authenticated Proxy Enabled: \(proxy.authenticated ? 1 : 0)\n"
    }
}

@Suite("System Proxy Manager Test Suite")
struct SystemProxyManagerTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zenith.tests.proxy.\(UUID().uuidString)")!
    }

    private func makeManager(
        _ fake: FakeNetworkSetup,
        defaults: UserDefaults? = nil,
        portListening: Bool = false
    ) -> SystemProxyManager {
        SystemProxyManager(
            runner: fake.runner,
            defaults: defaults ?? makeDefaults(),
            portProbe: { _ in portListening },
            installExitHooks: false
        )
    }

    // MARK: - Parsing

    @Test("SP-01: networksetup output is parsed into proxy configuration and bypass domains")
    func testParsing() {
        let enabled = SystemProxyManager.parseProxyConfiguration(
            "Enabled: Yes\nServer: proxy.corp.example\nPort: 3128\nAuthenticated Proxy Enabled: 1\n"
        )
        #expect(enabled == SystemProxyConfiguration(isEnabled: true, server: "proxy.corp.example", port: 3128, isAuthenticated: true))

        let disabled = SystemProxyManager.parseProxyConfiguration("Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n")
        #expect(disabled == SystemProxyConfiguration(isEnabled: false, server: "", port: 0, isAuthenticated: false))

        let ipv6 = SystemProxyManager.parseProxyConfiguration("Enabled: Yes\nServer: ::1\nPort: 8080\n")
        #expect(ipv6?.server == "::1")

        #expect(SystemProxyManager.parseProxyConfiguration("** Error: Unable to find item in network database.") == nil)

        #expect(SystemProxyManager.parseBypassDomains("*.local\n169.254/16\n") == ["*.local", "169.254/16"])
        #expect(SystemProxyManager.parseBypassDomains("There aren't any bypass domains set on Wi-Fi.\n") == [])
    }

    // MARK: - Enable / Disable

    @Test("SP-02: Enabling then disabling restores the user's own proxy and bypass list exactly")
    func testUserProxyRoundTrip() {
        let fake = FakeNetworkSetup()
        fake.web = .init(enabled: true, server: "proxy.corp.example", port: 3128)
        fake.secure = .init(enabled: true, server: "proxy.corp.example", port: 3129)
        fake.bypass = ["*.corp.example", "10.0.0.0/8"]
        let manager = makeManager(fake)

        #expect(manager.enableProxySynchronously(port: 8080))
        #expect(fake.web.server == "127.0.0.1" && fake.web.port == 8080 && fake.web.enabled)
        #expect(fake.secure.server == "127.0.0.1" && fake.secure.port == 8080 && fake.secure.enabled)
        #expect(manager.hasPendingRestore)

        #expect(manager.disableProxySynchronously())
        #expect(fake.web.server == "proxy.corp.example" && fake.web.port == 3128 && fake.web.enabled)
        #expect(fake.secure.server == "proxy.corp.example" && fake.secure.port == 3129 && fake.secure.enabled)
        #expect(fake.bypass == ["*.corp.example", "10.0.0.0/8"])
        #expect(!manager.hasPendingRestore)
    }

    @Test("SP-03: While active, the user's bypass domains are kept alongside the required loopback ones")
    func testBypassDomainsAreMerged() {
        let fake = FakeNetworkSetup()
        fake.bypass = ["*.corp.example", "localhost"]
        let manager = makeManager(fake)

        #expect(manager.enableProxySynchronously(port: 8080))
        #expect(fake.bypass == ["*.corp.example", "localhost", "127.0.0.1", "*.local", "169.254/16"])
    }

    @Test("SP-04: A previously disabled proxy goes back to disabled, not on")
    func testDisabledProxyStaysDisabled() {
        let fake = FakeNetworkSetup()
        let manager = makeManager(fake)

        #expect(manager.enableProxySynchronously(port: 8080))
        #expect(manager.disableProxySynchronously())
        #expect(!fake.web.enabled && !fake.secure.enabled)
        #expect(fake.bypass.isEmpty)
    }

    @Test("SP-05: An authenticated proxy is never replaced")
    func testAuthenticatedProxyIsRefused() {
        let fake = FakeNetworkSetup()
        fake.secure = .init(enabled: true, server: "proxy.corp.example", port: 3128, authenticated: true)
        let manager = makeManager(fake)

        #expect(!manager.enableProxySynchronously(port: 8080))
        #expect(manager.lastFailureReason?.contains("authenticated") == true)
        #expect(fake.mutatingCommands.isEmpty)
        #expect(fake.secure.server == "proxy.corp.example")
        #expect(!manager.hasPendingRestore)
    }

    @Test("SP-06: Disabling with nothing recorded leaves someone else's proxy alone")
    func testDisableWithoutRecordIsNoOp() {
        let fake = FakeNetworkSetup()
        fake.secure = .init(enabled: true, server: "proxy.corp.example", port: 3128)
        let manager = makeManager(fake)

        #expect(manager.disableProxySynchronously())
        #expect(fake.mutatingCommands.isEmpty)
        #expect(fake.secure.enabled)
    }

    @Test("SP-07: A failed enable rolls back and reports why")
    func testFailedEnableRollsBack() {
        let fake = FakeNetworkSetup()
        fake.web = .init(enabled: true, server: "proxy.corp.example", port: 3128)
        fake.bypass = ["*.corp.example"]
        fake.failing = ["-setsecurewebproxy"]
        let manager = makeManager(fake)

        #expect(!manager.enableProxySynchronously(port: 8080))
        #expect(manager.lastFailureReason != nil)
        #expect(fake.web == FakeNetworkSetup.Proxy(enabled: true, server: "proxy.corp.example", port: 3128))
        #expect(fake.bypass == ["*.corp.example"])
        #expect(!manager.hasPendingRestore)
    }

    @Test("SP-08: Settings the user changed while the shield was on are not overwritten on restore")
    func testRestoreSkipsSettingsChangedByUser() {
        let fake = FakeNetworkSetup()
        fake.web = .init(enabled: true, server: "old.example", port: 3128)
        let manager = makeManager(fake)

        #expect(manager.enableProxySynchronously(port: 8080))
        fake.secure = .init(enabled: true, server: "chosen-later.example", port: 9000)

        #expect(manager.disableProxySynchronously())
        #expect(fake.secure.server == "chosen-later.example" && fake.secure.enabled)
        #expect(fake.web.server == "old.example" && fake.web.enabled)
    }

    @Test("SP-09: A leftover Zenith endpoint is not mistaken for a user setting to restore")
    func testLeftoverZenithEndpointIsDiscarded() {
        let fake = FakeNetworkSetup()
        fake.web = .init(enabled: true, server: "127.0.0.1", port: 8080)
        fake.secure = .init(enabled: true, server: "127.0.0.1", port: 8080)
        let manager = makeManager(fake)

        #expect(manager.enableProxySynchronously(port: 8080))
        #expect(manager.disableProxySynchronously())
        #expect(!fake.web.enabled && !fake.secure.enabled)
    }

    // MARK: - Crash Recovery

    @Test("SP-10: A recorded session is restored after an unclean exit, even by a new process")
    func testRecoveryFromPersistedSnapshot() {
        let fake = FakeNetworkSetup()
        fake.secure = .init(enabled: true, server: "proxy.corp.example", port: 3128)
        fake.bypass = ["*.corp.example"]
        let defaults = makeDefaults()

        let crashed = makeManager(fake, defaults: defaults)
        #expect(crashed.enableProxySynchronously(port: 8080))
        // The process dies here: no disable call, only the persisted record survives.

        let relaunched = makeManager(fake, defaults: defaults)
        #expect(relaunched.hasPendingRestore)
        #expect(relaunched.recoverFromUncleanShutdown())
        #expect(fake.secure.server == "proxy.corp.example" && fake.secure.port == 3128 && fake.secure.enabled)
        #expect(fake.bypass == ["*.corp.example"])
        #expect(!relaunched.hasPendingRestore)
    }

    @Test("SP-11: Without a record, only a dead loopback proxy on the legacy port is switched off")
    func testLegacyRecoveryOnlyTouchesDeadLoopbackProxy() {
        // Dead listener: web traffic would be swallowed, so it is switched off.
        let dead = FakeNetworkSetup()
        dead.web = .init(enabled: true, server: "127.0.0.1", port: 8080)
        dead.secure = .init(enabled: true, server: "127.0.0.1", port: 8080)
        #expect(makeManager(dead, portListening: false).recoverFromUncleanShutdown(legacyPort: 8080))
        #expect(!dead.web.enabled && !dead.secure.enabled)

        // Something is listening (e.g. a debugging proxy the user runs): untouched.
        let live = FakeNetworkSetup()
        live.secure = .init(enabled: true, server: "127.0.0.1", port: 8080)
        #expect(!makeManager(live, portListening: true).recoverFromUncleanShutdown(legacyPort: 8080))
        #expect(live.secure.enabled)

        // A corporate proxy is never touched.
        let corporate = FakeNetworkSetup()
        corporate.secure = .init(enabled: true, server: "proxy.corp.example", port: 8080)
        #expect(!makeManager(corporate, portListening: false).recoverFromUncleanShutdown(legacyPort: 8080))
        #expect(corporate.secure.enabled)
    }

    @Test("SP-12: Zenith's own endpoint is told apart from other proxies")
    func testZenithEndpointDetection() {
        let fake = FakeNetworkSetup()
        fake.secure = .init(enabled: true, server: "proxy.corp.example", port: 8080)
        let manager = makeManager(fake)
        #expect(!manager.isZenithProxyActive(port: 8080))
        #expect(manager.isProxyEnabled())

        #expect(manager.enableProxySynchronously(port: 8080))
        #expect(manager.isZenithProxyActive(port: 8080))
        #expect(!manager.isZenithProxyActive(port: 9090))
    }

    @Test("SP-13: The real process runner drains output larger than the pipe buffer")
    func testProcessRunnerHandlesLargeOutput() {
        let result = SystemProxyManager.processRunner("/usr/bin/head", ["-c", "200000", "/dev/zero"])
        #expect(result?.status == 0)
        #expect(result?.output.utf8.count == 200_000)
    }

    // MARK: - Local Proxy Listener Readiness

    private func freeLoopbackPort() -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    @Test("SP-14: startAndAwaitReady returns only once the port accepts connections")
    func testListenerIsReadyWhenAwaitReturns() async throws {
        let server = LocalProxyServer()
        let port = freeLoopbackPort()

        try await server.startAndAwaitReady(port: port, provider: .cloudflare)
        #expect(server.isRunning)
        #expect(SystemProxyManager.isLoopbackPortListening(port))

        server.stop()
        #expect(!server.isRunning)
    }

    @Test("SP-15: startAndAwaitReady throws and stays stopped when the port is already taken")
    func testBusyPortIsReportedInsteadOfIgnored() async throws {
        let port = freeLoopbackPort()

        let occupant = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(occupant) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(occupant, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(occupant, 1) == 0)

        let server = LocalProxyServer()
        await #expect(throws: (any Error).self) {
            try await server.startAndAwaitReady(port: port, provider: .cloudflare, timeout: 2)
        }
        #expect(!server.isRunning)
    }
}
