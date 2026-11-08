import Testing
import Foundation
import Combine
@testable import ZenithCore

@Suite("Tracker blocklist: matching, list parsing, and what the proxy does with it")
struct TrackerBlocklistTests {

    // MARK: Matching

    @Test("TB-01: A listed domain blocks itself and its subdomains, not unrelated or look-alike names")
    func testMatching() {
        let list = TrackerBlocklist(blocked: ["doubleclick.net", "ads.example.com"])
        #expect(list.isBlocked(host: "doubleclick.net"))
        #expect(list.isBlocked(host: "stats.g.doubleclick.net"))
        #expect(list.isBlocked(host: "DoubleClick.NET"))
        #expect(list.isBlocked(host: "doubleclick.net."))
        #expect(list.isBlocked(host: "ads.example.com"))
        #expect(list.isBlocked(host: "x.ads.example.com"))

        #expect(!list.isBlocked(host: "example.com"))
        #expect(!list.isBlocked(host: "www.example.com"))
        #expect(!list.isBlocked(host: "notdoubleclick.net"))
    }

    @Test("TB-02: A name that merely ends with a listed one, or contains it, is not blocked")
    func testNoSubstringMatches() {
        let list = TrackerBlocklist(blocked: ["doubleclick.net"])
        #expect(!list.isBlocked(host: "mydoubleclick.net"))
        #expect(!list.isBlocked(host: "doubleclick.net.evil.org"))
        #expect(!list.isBlocked(host: "doubleclick.network"))
        #expect(!list.isBlocked(host: "net"))
    }

    @Test("TB-03: Never-block wins, for the name itself and for what is under it")
    func testAllowList() {
        let list = TrackerBlocklist(blocked: ["tracker.example", "ads.shop.com", "shop.com"], allowed: ["shop.com"])
        #expect(!list.isBlocked(host: "shop.com"))
        #expect(!list.isBlocked(host: "ads.shop.com"))
        #expect(!list.isBlocked(host: "cdn.shop.com"))

        // A narrower exception leaves the rest blocked.
        let narrow = TrackerBlocklist(blocked: ["shop.com"], allowed: ["pay.shop.com"])
        #expect(narrow.isBlocked(host: "ads.shop.com"))
        #expect(!narrow.isBlocked(host: "pay.shop.com"))
        #expect(!narrow.isBlocked(host: "api.pay.shop.com"))
    }

    @Test("TB-04: Addresses, one-word names and an empty list are never blocked")
    func testNeverBlocksAddressesOrLocalNames() {
        let list = TrackerBlocklist(blocked: ["doubleclick.net", "1.2.3.4", "localhost"])
        #expect(!list.isBlocked(host: "1.2.3.4"))
        #expect(!list.isBlocked(host: "127.0.0.1"))
        #expect(!list.isBlocked(host: "::1"))
        #expect(!list.isBlocked(host: "[2001:db8::1]"))
        #expect(!list.isBlocked(host: "localhost"))
        #expect(!list.isBlocked(host: "printer"))
        #expect(!list.isBlocked(host: ""))
        #expect(!TrackerBlocklist().isBlocked(host: "doubleclick.net"))
    }

    @Test("TB-05: Update swaps both lists at once")
    func testUpdate() {
        let list = TrackerBlocklist(blocked: ["a.example"], allowed: [])
        #expect(list.isBlocked(host: "a.example") && list.blockedCount == 1)
        list.update(blocked: ["b.example", "c.example", "not a domain"], allowed: [])
        #expect(!list.isBlocked(host: "a.example"))
        #expect(list.isBlocked(host: "c.example"))
        #expect(list.blockedCount == 2)
    }

    // MARK: Normalising

    @Test("TB-06: Entries are cleaned up, and dangerous or invalid ones are refused")
    func testNormalize() {
        #expect(TrackerBlocklist.normalize("  Ads.Example.COM ") == "ads.example.com")
        #expect(TrackerBlocklist.normalize("*.example.com") == "example.com")
        #expect(TrackerBlocklist.normalize(".example.com.") == "example.com")
        #expect(TrackerBlocklist.normalize("my_host.example.com") == "my_host.example.com")

        // One word would block a whole top-level domain; a public suffix would block every site under it.
        for bad in ["com", "localhost", "co.uk", "com.vn", "net.au", "org.uk", "gov.vn", "ac.jp"] {
            #expect(TrackerBlocklist.normalize(bad) == nil, "\(bad)")
        }
        // But a real domain that merely looks similar is fine.
        #expect(TrackerBlocklist.normalize("example.co") == "example.co")
        #expect(TrackerBlocklist.normalize("vn.example.com") == "vn.example.com")

        for bad in ["", " ", "a..b.com", "-a.com", "a-.com", "exa mple.com", "http://example.com", "example.com/path",
                    "1.2.3.4", "::1", "ex\u{00E9}ample.com", String(repeating: "a", count: 64) + ".com"] {
            #expect(TrackerBlocklist.normalize(bad) == nil, "\(bad)")
        }
    }

    // MARK: Lists

    @Test("TB-07: Hosts files, plain lists and ad-blocker rules are read; the rest is skipped")
    func testParseList() {
        let text = """
        # Title: some list
        ! another comment style
        [Adblock Plus 2.0]
        127.0.0.1 localhost
        127.0.0.1\tlocalhost.localdomain
        ::1 ip6-localhost
        255.255.255.255 broadcasthost
        0.0.0.0 ads.example.com
        0.0.0.0 tracker.example.net   # trailing comment
        127.0.0.1 one.example.org two.example.org
        plain.example.com
        ||adblock.example.com^
        ||third.example.com^$third-party
        ||path.example.com/banner
        ||scripts.example.com^$script
        ##.ad-banner
        @@||allowed.example.com^
        0.0.0.0 ADS.example.com
        0.0.0.0 com
        some random text with spaces
        """
        let domains = TrackerBlocklist.parseList(text)
        #expect(domains == [
            "ads.example.com", "tracker.example.net", "one.example.org", "two.example.org", "plain.example.com",
            "adblock.example.com", "third.example.com"
        ])
    }

    @Test("TB-08: An empty or binary file gives no domains and no crash")
    func testParseGarbage() {
        #expect(TrackerBlocklist.parseList("").isEmpty)
        #expect(TrackerBlocklist.parseList("\n\n   \n").isEmpty)
        #expect(TrackerBlocklist.parseList(String(decoding: Data((0..<2_000).map { UInt8($0 % 256) }), as: UTF8.self)).isEmpty)
    }

    @Test("TB-09: A big list is read and searched quickly")
    func testBigList() {
        let lines = (0..<200_000).map { "0.0.0.0 host\($0).tracker\($0 % 500).example" }.joined(separator: "\n")
        let started = Date()
        let domains = TrackerBlocklist.parseList(lines)
        let list = TrackerBlocklist(blocked: domains)
        for index in 0..<1_000 { _ = list.isBlocked(host: "www.news\(index).example.com") }
        #expect(domains.count == 200_000)
        #expect(list.isBlocked(host: "x.host42.tracker42.example"))
        #expect(!list.isBlocked(host: "x.host42.tracker43.example"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: Built-in list

    @Test("TB-10: Every built-in entry is a valid domain, with no duplicates, and common sites are not on it")
    func testBuiltInList() {
        let builtIn = TrackerBlocklist.builtInDomains
        #expect(builtIn.count > 50)
        for domain in builtIn {
            #expect(TrackerBlocklist.normalize(domain) == domain, "\(domain)")
        }
        #expect(Set(builtIn).count == builtIn.count)

        let list = TrackerBlocklist(blocked: builtIn)
        #expect(list.isBlocked(host: "securepubads.g.doubleclick.net"))
        #expect(list.isBlocked(host: "www.google-analytics.com"))
        // Things sites need to work must not be here.
        for host in ["google.com", "www.google.com", "accounts.google.com", "gstatic.com", "fonts.googleapis.com",
                     "apple.com", "icloud.com", "github.com", "cloudflare.com", "cdnjs.cloudflare.com", "stripe.com",
                     "paypal.com", "facebook.com", "twitter.com", "linkedin.com", "youtube.com", "ytimg.com",
                     "googletagmanager.com", "amazon.com", "microsoft.com", "bing.com", "yahoo.com", "pinterest.com"] {
            #expect(!list.isBlocked(host: host), "\(host)")
        }
    }

    // MARK: The proxy

    private func startProxy(blocklist: TrackerBlocklist?) async throws -> (LocalProxyServer, UInt16) {
        let server = LocalProxyServer()
        server.blocklist = blocklist
        let port = Sock.freePort()
        try await server.startAndAwaitReady(port: port, provider: .cloudflare)
        return (server, port)
    }

    @Test("TB-11: A CONNECT to a blocked domain is refused with 403, before any DoH lookup")
    func testConnectIsRefused() async throws {
        let (server, port) = try await startProxy(blocklist: TrackerBlocklist(blocked: ["ads.test-tracker.example"]))
        defer { server.stop() }

        let response = await offPool {
            let client = Sock.connect(to: port)
            defer { close(client) }
            Sock.send(client, "CONNECT stats.ads.test-tracker.example:443 HTTP/1.1\r\nHost: stats.ads.test-tracker.example:443\r\n\r\n")
            return Sock.receiveAll(client)
        }
        let text = String(data: response.data, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(response.sawEOF)
    }

    @Test("TB-12: A plain HTTP request to a blocked domain is refused with 403")
    func testPlainHttpIsRefused() async throws {
        let (server, port) = try await startProxy(blocklist: TrackerBlocklist(blocked: ["ads.test-tracker.example"]))
        defer { server.stop() }

        let response = await offPool {
            let client = Sock.connect(to: port)
            defer { close(client) }
            Sock.send(client, "GET http://ads.test-tracker.example/pixel.gif HTTP/1.1\r\nHost: ads.test-tracker.example\r\n\r\n")
            return Sock.receiveAll(client)
        }
        #expect((String(data: response.data, encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 403 Forbidden"))
    }

    @Test("TB-13: With a blocklist set, a request to anything else still goes through")
    func testOtherTrafficUnaffected() async throws {
        let origin = TestOrigin { fd, _ in
            _ = Sock.receive(fd, until: Data("\r\n\r\n".utf8))
            Sock.send(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        }
        defer { origin.stop() }
        let (server, proxyPort) = try await startProxy(blocklist: TrackerBlocklist(blocked: TrackerBlocklist.builtInDomains))
        defer { server.stop() }
        let originPort = origin.port

        let response = await offPool {
            let client = Sock.connect(to: proxyPort)
            defer { close(client) }
            Sock.send(client, "GET http://127.0.0.1:\(originPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n")
            return Sock.receiveAll(client)
        }
        #expect((String(data: response.data, encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test("TB-14: Changing the list while the proxy runs takes effect on the next request")
    func testLiveUpdate() async throws {
        let list = TrackerBlocklist(blocked: ["first.test-tracker.example"])
        let (server, port) = try await startProxy(blocklist: list)
        defer { server.stop() }

        func connectStatus(to host: String) async -> String {
            await offPool {
                let client = Sock.connect(to: port)
                defer { close(client) }
                Sock.send(client, "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n")
                return String(data: Sock.receiveAll(client).data, encoding: .utf8) ?? ""
            }
        }

        #expect((await connectStatus(to: "first.test-tracker.example")).hasPrefix("HTTP/1.1 403 Forbidden"))
        // Only blocked names are tried here: an unlisted one would be looked up over the internet.
        list.update(blocked: ["second.test-tracker.example"], allowed: [])
        #expect((await connectStatus(to: "second.test-tracker.example")).hasPrefix("HTTP/1.1 403 Forbidden"))
    }
}

@Suite("Tracker blocking settings: switch, user lists, imported file")
@MainActor
struct TrackerBlockingSettingsTests {
    private func makeSettings(suite: String, directory: URL? = nil) throws -> (TrackerBlockingSettings, UserDefaults, URL) {
        let defaults = try #require(TestDefaults.make(suite))
        defaults.removePersistentDomain(forName: TestDefaults.prefix + suite)
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("zenith-tracker-tests-\(UUID().uuidString)", isDirectory: true)
        return (TrackerBlockingSettings(userDefaults: defaults, storageDirectory: dir), defaults, dir)
    }

    private func writeList(_ text: String, named name: String = "list.txt") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-tracker-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("TS-01: Blocking is off until the user turns it on, and the list is empty while it is off")
    func testOffByDefault() throws {
        let (settings, _, _) = try makeSettings(suite: "ts01")
        #expect(!settings.isEnabled)
        #expect(settings.activeDomainCount == 0)
        #expect(!settings.blocklist.isBlocked(host: "ads.doubleclick.net"))

        settings.isEnabled = true
        #expect(settings.activeDomainCount == settings.builtInDomainCount)
        #expect(settings.blocklist.isBlocked(host: "ads.doubleclick.net"))

        settings.isEnabled = false
        #expect(!settings.blocklist.isBlocked(host: "ads.doubleclick.net"))
    }

    @Test("TS-02: Added domains are cleaned up, kept in order, and refused when invalid or repeated")
    func testCustomDomains() throws {
        let (settings, _, _) = try makeSettings(suite: "ts02")
        settings.isEnabled = true
        #expect(settings.addCustomDomain(" Annoying.Example.org ") == .added("annoying.example.org"))
        #expect(settings.addCustomDomain("annoying.example.org") == .alreadyListed("annoying.example.org"))
        #expect(settings.addCustomDomain("com") == .invalid)
        #expect(settings.addCustomDomain("not a domain") == .invalid)
        #expect(settings.addCustomDomain("two.example.org") == .added("two.example.org"))
        #expect(settings.customDomains == ["annoying.example.org", "two.example.org"])
        #expect(settings.blocklist.isBlocked(host: "img.annoying.example.org"))

        settings.removeCustomDomain("annoying.example.org")
        #expect(settings.customDomains == ["two.example.org"])
        #expect(!settings.blocklist.isBlocked(host: "img.annoying.example.org"))
    }

    @Test("TS-03: A never-block domain frees a built-in entry")
    func testAllowedDomains() throws {
        let (settings, _, _) = try makeSettings(suite: "ts03")
        settings.isEnabled = true
        #expect(settings.blocklist.isBlocked(host: "bat.bing.com"))
        #expect(settings.addAllowedDomain("bat.bing.com") == .added("bat.bing.com"))
        #expect(!settings.blocklist.isBlocked(host: "bat.bing.com"))
        settings.removeAllowedDomain("bat.bing.com")
        #expect(settings.blocklist.isBlocked(host: "bat.bing.com"))
    }

    @Test("TS-04: Everything is remembered across launches")
    func testPersistence() throws {
        let (first, defaults, dir) = try makeSettings(suite: "ts04")
        first.isEnabled = true
        first.addCustomDomain("custom.example.org")
        first.addAllowedDomain("fine.example.org")
        try first.importList(from: writeList("0.0.0.0 imported.example.net\n", named: "my-hosts.txt"))

        let second = TrackerBlockingSettings(userDefaults: defaults, storageDirectory: dir)
        #expect(second.isEnabled)
        #expect(second.customDomains == ["custom.example.org"])
        #expect(second.allowedDomains == ["fine.example.org"])
        #expect(second.importedListName == "my-hosts.txt")
        #expect(second.importedDomainCount == 1)
        #expect(second.blocklist.isBlocked(host: "imported.example.net"))
        #expect(second.blocklist.isBlocked(host: "custom.example.org"))
        #expect(!second.blocklist.isBlocked(host: "fine.example.org"))
    }

    @Test("TS-05: Importing a list reports how many domains it has and replaces the one before")
    func testImport() throws {
        let (settings, _, dir) = try makeSettings(suite: "ts05")
        settings.isEnabled = true
        let count = try settings.importList(from: writeList("# hosts\n0.0.0.0 a.example.net\n0.0.0.0 b.example.net\n"))
        #expect(count == 2)
        #expect(settings.blocklist.isBlocked(host: "a.example.net"))

        try settings.importList(from: writeList("c.example.net\n", named: "second.txt"))
        #expect(settings.importedListName == "second.txt")
        #expect(settings.importedDomainCount == 1)
        #expect(!settings.blocklist.isBlocked(host: "a.example.net"))
        #expect(settings.blocklist.isBlocked(host: "c.example.net"))

        settings.removeImportedList()
        #expect(settings.importedListName == nil && settings.importedDomainCount == 0)
        #expect(!settings.blocklist.isBlocked(host: "c.example.net"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(TrackerBlockingSettings.importedFileName).path))
    }

    @Test("TS-06: A file with no domains, or one that is missing, is refused and changes nothing")
    func testBadImports() throws {
        let (settings, _, _) = try makeSettings(suite: "ts06")
        settings.isEnabled = true
        try settings.importList(from: writeList("keep.example.net\n", named: "good.txt"))

        #expect(throws: TrackerListImportError.noDomains) {
            try settings.importList(from: writeList("# nothing here\nlocalhost\n"))
        }
        #expect(throws: TrackerListImportError.unreadable) {
            try settings.importList(from: URL(fileURLWithPath: "/nonexistent/zenith-test-list.txt"))
        }
        #expect(settings.importedListName == "good.txt")
        #expect(settings.blocklist.isBlocked(host: "keep.example.net"))
    }

    @Test("TS-07: Each setting tells SwiftUI it is about to change")
    func testPublishesChanges() throws {
        let (settings, _, _) = try makeSettings(suite: "ts07")
        var changes = 0
        let cancellable = settings.objectWillChange.sink { changes += 1 }
        defer { cancellable.cancel() }

        settings.isEnabled = true
        let afterSwitch = changes
        #expect(afterSwitch > 0)
        settings.addCustomDomain("one.example.org")
        #expect(changes > afterSwitch)
        let afterCustom = changes
        settings.addAllowedDomain("two.example.org")
        #expect(changes > afterCustom)
        let afterAllowed = changes
        try settings.importList(from: writeList("three.example.org\n"))
        #expect(changes > afterAllowed)
    }

    @Test("TS-08: Stored names that are not valid domains are dropped when loading")
    func testDirtyStoredValues() throws {
        let defaults = try #require(TestDefaults.make("ts08"))
        defaults.removePersistentDomain(forName: TestDefaults.prefix + "ts08")
        defaults.set(["good.example.org", "com", "GOOD.example.org", "bad domain"], forKey: TrackerBlockingSettings.Keys.customDomains)
        let settings = TrackerBlockingSettings(
            userDefaults: defaults,
            storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("zenith-tracker-tests-\(UUID().uuidString)")
        )
        #expect(settings.customDomains == ["good.example.org"])
    }

    @Test("TS-09: With a big imported list, adding a domain or a never-block entry by hand does not rebuild the list")
    func testBigListStaysResponsive() throws {
        let (settings, _, _) = try makeSettings(suite: "ts09")
        settings.isEnabled = true
        let lines = (0..<200_000).map { "0.0.0.0 h\($0).t\($0 % 400).example" }.joined(separator: "\n")
        try settings.importList(from: writeList(lines, named: "big.txt"))
        #expect(settings.importedDomainCount == 200_000)
        #expect(settings.blocklist.isBlocked(host: "x.h77.t77.example"))

        let started = Date()
        for index in 0..<50 {
            settings.addCustomDomain("hand\(index).example.org")
            settings.addAllowedDomain("fine\(index).example.net")
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 0.5, "100 small additions took \(elapsed) s")
        #expect(settings.blocklist.isBlocked(host: "x.hand7.example.org"))
        #expect(settings.blocklist.isBlocked(host: "x.h77.t77.example"))

        // The result is the same as rebuilding: a removal (which does rebuild) agrees with what was added.
        settings.removeCustomDomain("hand7.example.org")
        #expect(!settings.blocklist.isBlocked(host: "x.hand7.example.org"))
        #expect(settings.blocklist.isBlocked(host: "x.hand8.example.org"))
        #expect(settings.blocklist.isBlocked(host: "x.h77.t77.example"))
        settings.addAllowedDomain("t77.example")
        #expect(!settings.blocklist.isBlocked(host: "x.h77.t77.example"))
    }
}
