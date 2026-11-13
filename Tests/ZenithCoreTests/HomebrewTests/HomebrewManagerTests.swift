import Testing
import Foundation
@testable import ZenithCore

/// Stands in for `brew`: answers the read-only commands with canned output and "runs" the changing ones by streaming
/// scripted chunks. Never starts a process.
final class FakeBrew: @unchecked Sendable {
    static let path = "/opt/homebrew/bin/brew"

    struct Script {
        var chunks: [String] = []
        var status: Int32 = 0
        /// Keeps "running" until cancelled, then exits like a process killed by SIGTERM.
        var waitsForCancel = false
    }

    private let lock = NSLock()
    private var _reads: [[String]] = []
    private var _streams: [[String]] = []
    private var _replies: [String: SystemCommandResult] = [:]
    private var _scripts: [String: Script] = [:]
    private var _running = 0
    private var _maxRunning = 0
    private var _environmentOK = true

    /// brew's arguments (after the brew path) of every read-only command, in order.
    var reads: [[String]] { lock.withLock { _reads } }
    /// brew's arguments of every command run through the queue, in order.
    var streams: [[String]] { lock.withLock { _streams } }
    var maxConcurrentRuns: Int { lock.withLock { _maxRunning } }
    /// Every command went through `/usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 … brew`.
    var everyCommandHadEnvironment: Bool { lock.withLock { _environmentOK } }

    func reply(_ arguments: String, _ output: String, status: Int32 = 0) {
        lock.withLock { _replies[arguments] = SystemCommandResult(status: status, output: output) }
    }

    func script(_ arguments: String, _ script: Script) {
        lock.withLock { _scripts[arguments] = script }
    }

    /// Splits `/usr/bin/env VAR=1 … /path/brew args…` into brew's arguments, checking the environment on the way.
    private func brewArguments(_ executable: String, _ arguments: [String]) -> [String] {
        let ok = executable == "/usr/bin/env"
            && arguments.starts(with: HomebrewCommand.environment)
            && arguments.contains("HOMEBREW_NO_AUTO_UPDATE=1")
            && arguments.dropFirst(HomebrewCommand.environment.count).first == Self.path
        if !ok { _environmentOK = false }
        return Array(arguments.dropFirst(HomebrewCommand.environment.count + 1))
    }

    var readRunner: SystemCommandRunner {
        { [self] executable, arguments in
            lock.withLock {
                let brew = brewArguments(executable, arguments)
                _reads.append(brew)
                let key = brew.joined(separator: " ")
                if let reply = _replies[key] { return reply }
                if key.hasPrefix("info") || key.hasPrefix("outdated") {
                    return SystemCommandResult(status: 0, output: #"{"formulae":[],"casks":[]}"#)
                }
                return SystemCommandResult(status: 1, output: "", errorOutput: "Error: No formulae or casks found for \"x\".")
            }
        }
    }

    var streamRunner: StreamingCommandRunner {
        { [self] executable, arguments, cancellation, onOutput in
            let script: Script = lock.withLock {
                let brew = brewArguments(executable, arguments)
                _streams.append(brew)
                _running += 1
                _maxRunning = max(_maxRunning, _running)
                return _scripts[brew.joined(separator: " ")] ?? Script()
            }
            defer { lock.withLock { _running -= 1 } }
            var output = ""
            for chunk in script.chunks {
                onOutput(chunk)
                output += chunk
                await Task.yield()
            }
            if script.waitsForCancel {
                while !cancellation.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return SystemCommandResult(status: 143, output: output)
            }
            return SystemCommandResult(status: script.status, output: output)
        }
    }
}

@Suite("Homebrew Manager Suite")
struct HomebrewManagerTests {

    private static let prefix = "/opt/homebrew"

    @MainActor
    private func makeModel(_ brew: FakeBrew, brewInstalled: Bool = true, sizes: [String: Int64] = [:]) -> HomebrewManagerModel {
        HomebrewManagerModel(
            locator: HomebrewLocator(isExecutable: { path in brewInstalled && path == FakeBrew.path }),
            readRunner: brew.readRunner,
            streamRunner: brew.streamRunner,
            sizeOf: { sizes[$0] }
        )
    }

    private func names(_ packages: [HomebrewPackage]) -> [String] { packages.map(\.name) }

    // MARK: - Parsing brew's JSON

    @Test("HB-01: The recorded `brew info --installed` of a real Mac reads as one installed formula")
    func testRecordedInstalled() throws {
        let packages = try HomebrewJSON.packages(from: Data(HomebrewFixtures.recordedInstalledGh.utf8), prefix: Self.prefix)
        #expect(packages.count == 1)
        let gh = try #require(packages.first)
        #expect(gh.name == "gh")
        #expect(gh.kind == .formula)
        #expect(gh.version == "2.104.0")
        #expect(gh.summary == "GitHub command-line tool")
        #expect(gh.homepage == "https://cli.github.com/")
        #expect(gh.isInstalled)
        #expect(gh.isInstalledOnRequest)
        #expect(gh.isOutdated == false)
        #expect(gh.sizePath == "/opt/homebrew/Cellar/gh")
    }

    @Test("HB-02: Formulae, dependencies, other taps and installed casks are told apart")
    func testInstalledMix() throws {
        let packages = try HomebrewJSON.packages(from: Data(HomebrewFixtures.installed.utf8), prefix: Self.prefix)
        #expect(names(packages) == ["gh", "openssl@3", "someone/tap/tool", "firefox"])

        let openssl = try #require(packages.first { $0.name == "openssl@3" })
        #expect(openssl.isInstalledOnRequest == false)
        #expect(openssl.version == "3.6.0")
        #expect(openssl.latestVersion == "3.6.1")
        #expect(openssl.isOutdated)

        let tool = try #require(packages.first { $0.name == "someone/tap/tool" })
        #expect(tool.displayName == "tool")
        #expect(tool.isPinned)
        #expect(tool.summary == nil)
        #expect(tool.sizePath == "/opt/homebrew/Cellar/tool")

        let firefox = try #require(packages.first { $0.kind == .cask })
        #expect(firefox.name == "firefox")
        #expect(firefox.displayName == "Mozilla Firefox")
        #expect(firefox.version == "159.0")
        #expect(firefox.latestVersion == "160.0")
        #expect(firefox.isInstalled)
        #expect(firefox.isOutdated)
        #expect(firefox.sizePath == "/Applications/Firefox.app")
    }

    @Test("HB-03: The recorded cask that is not installed shows the latest version and no size")
    func testRecordedCaskNotInstalled() throws {
        let packages = try HomebrewJSON.packages(from: Data(HomebrewFixtures.recordedFirefoxCask.utf8))
        let firefox = try #require(packages.first)
        #expect(packages.count == 1)
        #expect(firefox.kind == .cask)
        #expect(firefox.isInstalled == false)
        #expect(firefox.version == "160.0")
        #expect(firefox.summary == "Web browser")
        #expect(firefox.sizePath == nil)
    }

    @Test("HB-04: `brew outdated --json=v2` reads with versions and pins; garbage is an error, not an empty list")
    func testOutdated() throws {
        let entries = try HomebrewJSON.outdated(from: Data(HomebrewFixtures.outdatedSample.utf8))
        #expect(entries.map(\.id) == ["formula:openssl@3", "formula:node", "cask:firefox"])
        let node = try #require(entries.first { $0.name == "node" })
        #expect(node.installedVersion == "23.0.0")
        #expect(node.currentVersion == "25.2.1")
        #expect(node.isPinned)
        #expect(try HomebrewJSON.outdated(from: Data(HomebrewFixtures.recordedOutdatedEmpty.utf8)).isEmpty)
        #expect(throws: HomebrewJSONError.unreadable) { try HomebrewJSON.outdated(from: Data("Error: oops".utf8)) }
        #expect(throws: HomebrewJSONError.unreadable) { try HomebrewJSON.packages(from: Data()) }
    }

    @Test("HB-05: Search output becomes names; headers, blank lines and anything that is not a name are dropped")
    func testSearchNames() {
        let recorded = HomebrewJSON.searchNames(from: HomebrewFixtures.recordedCaskSearch)
        #expect(recorded.count == 17)
        #expect(recorded.contains("firefox@developer-edition"))
        let messy = HomebrewJSON.searchNames(from: "==> Formulae\nwget\n\nwget2\n-rf\nwget\nhas space\r\nhomebrew/core/curl\n")
        #expect(messy == ["wget", "wget2", "homebrew/core/curl"])
    }

    // MARK: - Finding brew and building commands

    @Test("HB-06: brew is looked for in /opt/homebrew, then /usr/local; nothing found means missing")
    func testLocator() {
        #expect(HomebrewLocator(isExecutable: { _ in true }).locate() == "/opt/homebrew/bin/brew")
        #expect(HomebrewLocator(isExecutable: { $0.hasPrefix("/usr/local") }).locate() == "/usr/local/bin/brew")
        #expect(HomebrewLocator(isExecutable: { _ in false }).locate() == nil)
        #expect(HomebrewLocator.prefix(forBrewAt: "/usr/local/bin/brew") == "/usr/local")
    }

    @Test("HB-07: Commands run through env with auto-update and hints off, and name kind and package exactly")
    func testCommandBuilding() {
        let invocation = HomebrewCommand.invocation(brew: FakeBrew.path, arguments: ["install", "--cask", "firefox"])
        #expect(invocation.executable == "/usr/bin/env")
        #expect(invocation.arguments == ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_COLOR=1",
                                         FakeBrew.path, "install", "--cask", "firefox"])

        #expect(HomebrewOperation.install(name: "wget", kind: .formula).arguments == ["install", "--formula", "wget"])
        #expect(HomebrewOperation.uninstall(name: "firefox", kind: .cask).arguments == ["uninstall", "--cask", "firefox"])
        #expect(HomebrewOperation.upgrade(names: ["a", "b"], kind: .formula).arguments == ["upgrade", "--formula", "a", "b"])
        #expect(HomebrewOperation.update.arguments == ["update"])

        #expect(HomebrewCommand.terminalCommand(brew: FakeBrew.path, arguments: ["install", "--cask", "firefox"])
                == "/opt/homebrew/bin/brew install --cask firefox")
        #expect(HomebrewCommand.terminalCommand(brew: "/x y/brew", arguments: ["it's"]) == #"'/x y/brew' 'it'\''s'"#)
    }

    @Test("HB-08: Only real package names pass: nothing that brew could read as an option or a path trick")
    func testNameValidation() {
        for good in ["wget", "node@20", "font-fira-code", "homebrew/cask/firefox", "c++utils", "python@3.13", "7zip"] {
            #expect(HomebrewCommand.isValidPackageName(good), "\(good)")
        }
        for bad in ["", "-rf", "--force", "a b", "../x", "a;rm", "@x", "/abs", "x\ny", String(repeating: "a", count: 201)] {
            #expect(!HomebrewCommand.isValidPackageName(bad), "\(bad)")
        }
        #expect(HomebrewOperation.upgrade(names: [], kind: .formula).hasValidNames == false)
        #expect(HomebrewCommand.normalizedQuery("  fire  ") == "fire")
        #expect(HomebrewCommand.normalizedQuery("--desc") == nil)
        #expect(HomebrewCommand.normalizedQuery("   ") == nil)
    }

    @Test("HB-09: Failures map to what the user can do: Terminal for sudo, wait, network, not found, brew's own error")
    func testFailureMapping() {
        let install = HomebrewOperation.install(name: "some-driver", kind: .cask)
        func classify(_ status: Int32?, _ output: String, cancelled: Bool = false, _ operation: HomebrewOperation = install) -> HomebrewFailure? {
            HomebrewFailure.classify(status: status, output: output, wasCancelled: cancelled, operation: operation, brew: FakeBrew.path)
        }

        #expect(classify(0, "sudo: a terminal is required to read the password") == nil)
        let sudo = classify(1, "==> Running installer for some-driver\nsudo: a terminal is required to read the password; either use the -S option\nError: Failure while executing")
        #expect(sudo == .needsPassword(terminalCommand: "/opt/homebrew/bin/brew install --cask some-driver"))
        #expect(sudo?.terminalCommand == "/opt/homebrew/bin/brew install --cask some-driver")
        #expect(classify(1, "sudo: no tty present and no askpass program specified")?.terminalCommand != nil)
        #expect(classify(1, "installer: Must be run as root to install this package.")?.terminalCommand != nil)

        #expect(classify(1, "Error: Another active Homebrew update process is already in progress.") == .busy)
        #expect(classify(1, "Error: A `brew install` process has already locked /opt/homebrew/var/homebrew/locks/x.") == .busy)
        #expect(classify(1, "Error: Cask 'nope' is unavailable: No Cask with this name exists.") == .notFound(name: "some-driver"))
        #expect(classify(1, "curl: (6) Could not resolve host: ghcr.io\nError: Failed to download resource") == .network)
        #expect(classify(143, "partial", cancelled: true) == .cancelled)
        #expect(classify(nil, "") == .couldNotStart)

        let refused = classify(1, "Error: Refusing to uninstall /opt/homebrew/Cellar/openssl@3/3.6.0\nbecause it is required by curl, which is currently installed.",
                               .uninstall(name: "openssl@3", kind: .formula))
        #expect(refused == .failed(status: 1, detail: "Refusing to uninstall /opt/homebrew/Cellar/openssl@3/3.6.0"))
        #expect(classify(2, "") == .failed(status: 2, detail: ""))
        #expect(HomebrewFailure.failed(status: 2, detail: "").message.contains("2"))
        #expect(HomebrewFailure.errorLine(in: "Warning: x\nError: These casks failed:\n  firefox") == "These casks failed: firefox")
    }

    // MARK: - The model

    @Test("HB-10: Without brew nothing runs, nothing can be queued, and the page knows brew is missing")
    @MainActor
    func testMissingBrew() async {
        let brew = FakeBrew()
        let model = makeModel(brew, brewInstalled: false)
        await model.refresh()
        await model.refreshOutdated(ifOlderThan: 0)
        model.searchQuery = "wget"
        await model.search()
        #expect(model.availability == .missing)
        #expect(model.enqueue(.update) == false)
        #expect(brew.reads.isEmpty)
        #expect(brew.streams.isEmpty)
    }

    @Test("HB-11: Refresh lists installed (sorted) and outdated packages, measures sizes, all through env")
    @MainActor
    func testRefresh() async {
        let brew = FakeBrew()
        brew.reply("info --json=v2 --installed", HomebrewFixtures.installed)
        brew.reply("outdated --json=v2", HomebrewFixtures.outdatedSample)
        let model = makeModel(brew, sizes: ["/opt/homebrew/Cellar/gh": 42_000_000, "/Applications/Firefox.app": 400_000_000])
        await model.refresh()

        #expect(model.availability == .available(brewPath: FakeBrew.path))
        #expect(model.installed.map(\.displayName) == ["gh", "Mozilla Firefox", "openssl@3", "tool"])
        #expect(model.installed.first { $0.name == "gh" }?.bytes == 42_000_000)
        #expect(model.installed.first { $0.name == "firefox" }?.bytes == 400_000_000)
        #expect(model.installed.first { $0.name == "openssl@3" }?.bytes == nil)
        #expect(model.outdated.map(\.name) == ["firefox", "node", "openssl@3"])
        #expect(model.upgradable.map(\.name) == ["firefox", "openssl@3"], "a pinned formula is not offered")
        #expect(model.refreshError == nil)
        #expect(brew.everyCommandHadEnvironment)
        #expect(brew.streams.isEmpty, "refreshing changes nothing")
    }

    @Test("HB-12: A failed read shows brew's error instead of an empty list pretending all is well")
    @MainActor
    func testRefreshError() async {
        let brew = FakeBrew()
        brew.reply("info --json=v2 --installed", "Error: Homebrew API data is broken.", status: 1)
        let model = makeModel(brew)
        await model.refresh()
        #expect(model.refreshError == "Homebrew API data is broken.")
        #expect(model.installed.isEmpty)
    }

    @Test("HB-13: Commands run one at a time, in the order queued, each followed by a fresh list")
    @MainActor
    func testQueueOrder() async {
        let brew = FakeBrew()
        brew.script("install --formula wget", .init(chunks: ["==> Fetching wget\n", "==> Pouring wget\n"]))
        let model = makeModel(brew)
        model.locate()

        #expect(model.enqueue(.install(name: "wget", kind: .formula)))
        #expect(model.enqueue(.update))
        #expect(model.enqueue(.upgrade(names: ["gh"], kind: .formula)))
        await model.waitUntilIdle()

        #expect(brew.streams == [["install", "--formula", "wget"], ["update"], ["upgrade", "--formula", "gh"]])
        #expect(brew.maxConcurrentRuns == 1)
        #expect(model.jobs.map(\.state) == [.succeeded, .succeeded, .succeeded])
        #expect(model.isBusy == false)
        #expect(brew.reads.filter { $0.first == "info" }.count == 3, "the list is read again after every command")
        #expect(model.log.text.contains("$ brew install --formula wget\n==> Fetching wget\n==> Pouring wget\n"))
        #expect(brew.everyCommandHadEnvironment)
    }

    @Test("HB-14: The same command is not queued twice, and names that are not package names are refused")
    @MainActor
    func testQueueRefusals() async {
        let brew = FakeBrew()
        brew.script("update", .init(waitsForCancel: true))
        let model = makeModel(brew)
        model.locate()
        #expect(model.enqueue(.update))
        #expect(model.enqueue(.update) == false)
        #expect(model.enqueue(.install(name: "--force", kind: .formula)) == false)
        #expect(model.enqueue(.upgrade(names: [], kind: .cask)) == false)
        for _ in 0..<200 where brew.streams.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.enqueue(.update) == false, "still refused while it runs")
        if let running = model.currentJob { model.cancel(running.id) }
        await model.waitUntilIdle()
        #expect(brew.streams == [["update"]])
    }

    @Test("HB-15: Cancel stops the running command and the queue moves on; a pending one is dropped without running")
    @MainActor
    func testCancel() async throws {
        let brew = FakeBrew()
        brew.script("install --cask big-app", .init(chunks: ["==> Downloading big-app\n"], waitsForCancel: true))
        let model = makeModel(brew)
        model.locate()
        model.enqueue(.install(name: "big-app", kind: .cask))
        model.enqueue(.install(name: "dropped", kind: .formula))
        model.enqueue(.update)

        // Wait until the first one is really running.
        for _ in 0..<200 where brew.streams.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try #require(model.pendingJobs.first { $0.operation == .install(name: "dropped", kind: .formula) })
        model.cancel(pending.id)
        let running = try #require(model.currentJob)
        model.cancel(running.id)
        await model.waitUntilIdle()

        #expect(brew.streams == [["install", "--cask", "big-app"], ["update"]])
        #expect(model.jobs.first?.failure == .cancelled)
        #expect(model.jobs.last?.state == .succeeded)
        #expect(model.log.text.contains("==> Downloading big-app"))
    }

    @Test("HB-16: Uninstall asks first and runs nothing when declined; the question names the package")
    @MainActor
    func testUninstallConfirmation() async {
        let brew = FakeBrew()
        brew.reply("info --json=v2 --installed", HomebrewFixtures.installed)
        let model = makeModel(brew)
        await model.refresh()
        let firefox = model.installed.first { $0.kind == .cask }!

        var asked: HomebrewConfirmation?
        #expect(model.uninstall(firefox) { asked = $0; return false } == false)
        await model.waitUntilIdle()
        #expect(brew.streams.isEmpty)
        #expect(asked?.title.contains("Mozilla Firefox") == true)
        #expect(asked?.message.contains("firefox") == true)

        #expect(model.uninstall(firefox) { _ in true })
        await model.waitUntilIdle()
        #expect(brew.streams == [["uninstall", "--cask", "firefox"]])
    }

    @Test("HB-17: Upgrade All lists what it upgrades, asks, then upgrades exactly those names, per kind")
    @MainActor
    func testUpgradeAll() async {
        let brew = FakeBrew()
        brew.reply("outdated --json=v2", HomebrewFixtures.outdatedSample)
        let model = makeModel(brew)
        await model.refresh()

        let confirmation = model.upgradeAllConfirmation()
        #expect(confirmation.message.contains("openssl@3 3.6.0 → 3.6.1"))
        #expect(confirmation.message.contains("firefox 159.0 → 160.0"))
        #expect(!confirmation.message.contains("node"), "pinned packages are not upgraded")

        #expect(model.upgradeAll { _ in false } == false)
        await model.waitUntilIdle()
        #expect(brew.streams.isEmpty)

        #expect(model.upgradeAll { _ in true })
        await model.waitUntilIdle()
        #expect(brew.streams == [["upgrade", "--formula", "openssl@3"], ["upgrade", "--cask", "firefox"]])
    }

    @Test("HB-18: A cask that wants the admin password fails with the command to run in Terminal")
    @MainActor
    func testSudoFailure() async {
        let brew = FakeBrew()
        brew.script("install --cask some-driver", .init(
            chunks: ["==> Installing Cask some-driver\n", "sudo: a terminal is required to read the password\n", "Error: Failure while executing\n"],
            status: 1
        ))
        let model = makeModel(brew)
        model.locate()
        model.enqueue(.install(name: "some-driver", kind: .cask))
        await model.waitUntilIdle()
        let failure = model.jobs.first?.failure
        #expect(failure?.terminalCommand == "/opt/homebrew/bin/brew install --cask some-driver")
        #expect(model.log.text.contains("sudo: a terminal is required"))
    }

    @Test("HB-19: Search asks both kinds, ranks exact matches first, describes them and marks what is installed")
    @MainActor
    func testSearch() async {
        let brew = FakeBrew()
        brew.reply("search --cask fire", HomebrewFixtures.recordedCaskSearch)
        brew.reply("search --formula fire", "firebase-cli\narrayfire\n")
        let described = HomebrewFixtures.recordedFirefoxCask
        let model = makeModel(brew)
        model.locate()
        model.searchQuery = "  fire "
        // Searching sorts the casks before asking `brew info` about them, so the reply is keyed by that order.
        let caskNames = HomebrewManagerModel.ranked(HomebrewJSON.searchNames(from: HomebrewFixtures.recordedCaskSearch), for: "fire")
        brew.reply((["info", "--json=v2", "--cask"] + caskNames).joined(separator: " "), described)
        await model.search()

        #expect(brew.reads.prefix(2).map { $0.joined(separator: " ") }.sorted() == ["search --cask fire", "search --formula fire"])
        #expect(model.searchResults.prefix(2).map(\.name) == ["firebase-cli", "arrayfire"])
        let firefox = model.searchResults.first { $0.name == "firefox" }
        #expect(firefox?.summary == "Web browser")
        #expect(firefox?.isInstalled == false)
        #expect(model.searchResults.filter { $0.kind == .cask }.count == 17)
        #expect(model.searchError == nil)

        #expect(HomebrewManagerModel.ranked(["firefoxpwa", "a-fire", "fire", "firebird"], for: "fire") == ["fire", "firebird", "firefoxpwa", "a-fire"])

        let before = brew.reads.count
        model.searchQuery = "--desc"
        await model.search()
        #expect(brew.reads.count == before, "an option is never passed as a query")
        #expect(model.searchResults.isEmpty)
        #expect(brew.streams.isEmpty)
    }

    @Test("HB-20: The Command Hub's outdated check runs `brew outdated` only, and not again while fresh")
    @MainActor
    func testOutdatedCheckThrottle() async {
        let brew = FakeBrew()
        brew.reply("outdated --json=v2", HomebrewFixtures.outdatedSample)
        let model = makeModel(brew)
        await model.refreshOutdated(ifOlderThan: 3600)
        await model.refreshOutdated(ifOlderThan: 3600)
        #expect(brew.reads == [["outdated", "--json=v2"]])
        #expect(model.outdated.count == 3)
    }

    // MARK: - The log and the real streaming runner

    @Test("HB-21: The log drops colour codes, turns progress returns into lines and keeps only its newest part")
    func testLog() {
        var log = HomebrewLog(limit: 50)
        log.append("\u{1B}[34m==>\u{1B}[0m Fetching\r\n###  10%\r###### 50%\r")
        #expect(log.text == "==> Fetching\n###  10%\n###### 50%\n")
        log.appendCommandLine("brew update")
        #expect(log.text.hasSuffix("50%\n$ brew update\n"))
        for index in 0..<20 { log.append("line \(index)\n") }
        #expect(log.text.count <= 50)
        #expect(log.text.hasSuffix("line 19\n"))
        #expect(log.text.hasPrefix("line "), "trimming starts at a whole line")
        log.clear()
        #expect(log.text.isEmpty)
    }

    @Test("HB-22: Output is cut at line ends, and never inside a UTF-8 character")
    func testChunking() {
        var pending = Data("one\ntwo".utf8)
        #expect(StreamingCommand.takeCompleteText(&pending) == "one\n")
        #expect(String(decoding: pending, as: UTF8.self) == "two")

        var long = Data(String(repeating: "é", count: 3_000).utf8)  // 6000 bytes, no line break
        let first = StreamingCommand.takeCompleteText(&long) ?? ""
        #expect(!first.contains("\u{FFFD}"))
        #expect(first.count + String(decoding: long, as: UTF8.self).count == 3_000)
    }

    @Test("HB-23: The real runner streams a child's output and exit code, and Cancel ends its whole process group")
    func testRealStreamingRunner() async throws {
        final class Chunks: @unchecked Sendable {
            let lock = NSLock()
            var text = ""
        }
        let chunks = Chunks()
        let result = await StreamingCommand.processRunner("/bin/sh", ["-c", "echo one; echo two >&2; read x; echo \"[$x]\"; exit 3"], CommandCancellation()) { chunk in
            chunks.lock.withLock { chunks.text += chunk }
        }
        #expect(result?.status == 3)
        #expect(result?.output == "one\ntwo\n[]\n", "stdin is /dev/null, so `read` gets nothing at once")
        #expect(chunks.lock.withLock { chunks.text } == result?.output)

        // A child that starts its own long sleeper: cancelling must not wait for the sleeper.
        let cancellation = CommandCancellation()
        let started = Date()
        async let cancelled = StreamingCommand.processRunner("/bin/sh", ["-c", "echo ready; sleep 30 & wait"], cancellation) { _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        cancellation.cancel()
        let outcome = await cancelled
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(outcome?.status == 128 + SIGTERM)
        #expect(outcome?.output == "ready\n")

        #expect(await StreamingCommand.processRunner("/nonexistent/brew", [], CommandCancellation()) { _ in } == nil)
    }
}
