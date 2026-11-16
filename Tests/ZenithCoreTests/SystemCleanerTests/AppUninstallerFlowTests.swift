import Testing
import Foundation
@testable import ZenithCore

/// The uninstaller end to end, on a throwaway home: listing apps, tying files to an app, and the removal itself.
/// Nothing here touches the real Applications folder, the real Library or the real Trash: "the Trash" is a folder in
/// the sandbox, `launchctl` is a recorder, and "is it running" is a fake.
@Suite("App Uninstaller Flow Suite")
struct AppUninstallerFlowTests {

    // MARK: Fixtures

    /// A pretend app that can be open, and that quits (or not) when asked.
    final class FakeRunningApps: @unchecked Sendable {
        private let lock = NSLock()
        private var _running: Bool
        private var _quitRequests = 0
        private let quitsWhenAsked: Bool

        init(running: Bool, quitsWhenAsked: Bool) {
            _running = running
            self.quitsWhenAsked = quitsWhenAsked
        }

        var quitRequests: Int { lock.withLock { _quitRequests } }

        var control: RunningAppControl {
            RunningAppControl(
                isRunning: { [self] _, _ in lock.withLock { _running } },
                requestQuit: { [self] _, _ in
                    lock.withLock {
                        _quitRequests += 1
                        if quitsWhenAsked { _running = false }
                    }
                }
            )
        }
    }

    final class HistoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [(name: String, bytes: Int64, items: Int)] = []
        var entries: [(name: String, bytes: Int64, items: Int)] { lock.withLock { _entries } }
        func record(_ name: String, _ bytes: Int64, _ items: Int) { lock.withLock { _entries.append((name, bytes, items)) } }
    }

    /// A home, an Applications folder and a "Trash", all under one temporary folder.
    struct Sandbox {
        let root: URL
        let home: URL
        let applications: URL
        let trash: URL
        let commands = RecordingCommandRunner()
        let history = HistoryRecorder()

        init() throws {
            let fm = FileManager.default
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_UninstFlow_\(UUID().uuidString)")
            home = root.appendingPathComponent("home")
            applications = root.appendingPathComponent("Applications")
            trash = root.appendingPathComponent("Trash")
            for url in [home.appendingPathComponent("Library"), applications, trash] {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        var library: URL { home.appendingPathComponent("Library") }

        /// A bundle with an Info.plist and a payload file. `bundleID: nil` leaves the Info.plist out.
        @discardableResult
        func makeApp(
            _ fileName: String,
            bundleID: String?,
            displayName: String? = nil,
            in directory: URL? = nil,
            payloadBytes: Int = 8_192
        ) throws -> URL {
            let fm = FileManager.default
            let app = (directory ?? applications).appendingPathComponent(fileName)
            let macOS = app.appendingPathComponent("Contents/MacOS")
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data(count: payloadBytes).write(to: macOS.appendingPathComponent("binary"))
            if let bundleID {
                var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "2.1"]
                if let displayName { plist["CFBundleName"] = displayName }
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
            return app
        }

        /// A file or (with a trailing slash) a folder holding one file, under ~/Library.
        @discardableResult
        func makeLibraryEntry(_ relativePath: String, bytes: Int = 2_048) throws -> URL {
            let fm = FileManager.default
            if relativePath.hasSuffix("/") {
                let folder = library.appendingPathComponent(String(relativePath.dropLast()))
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(count: bytes).write(to: folder.appendingPathComponent("data.bin"))
                return folder
            }
            let file = library.appendingPathComponent(relativePath)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: file)
            return file
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        var trashedNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [])
                .map { String($0.dropFirst(37)) }   // "<uuid>-<name>"
                .sorted()
        }

        func service(
            running: RunningAppControl? = nil,
            refusingToTrash: Set<String> = [],
            ownBundleIdentifier: String? = "dev.zenith.self"
        ) -> AppUninstallerService {
            let trash = self.trash
            let history = self.history
            let mover = TrashMover(
                trashDirectly: { url in
                    // Not a permission error, so `TrashMover` does not go on to ask Finder.
                    if refusingToTrash.contains(url.lastPathComponent) { throw CocoaError(.fileWriteUnknown) }
                    try FileManager.default.moveItem(
                        at: url,
                        to: trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                    )
                },
                runCommand: commands.runner
            )
            return AppUninstallerService(
                homeDirectory: home.path,
                applicationDirectories: [applications.path],
                ownBundleIdentifier: ownBundleIdentifier,
                ownBundlePath: nil,
                trashMover: mover,
                runCommand: commands.runner,
                runningApps: running ?? RunningAppControl(isRunning: { _, _ in false }, requestQuit: { _, _ in }),
                quitTimeout: 0.2,
                recordHistory: { name, bytes, items in history.record(name, bytes, items) }
            )
        }
    }

    // MARK: Listing

    @Test("UNINST-10: The app list holds what can be uninstalled, by name, and measures nothing")
    func testListInstalledApps() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let fm = FileManager.default

        try box.makeApp("Zeta.app", bundleID: "com.zeta.app", displayName: "Zeta")
        let acme = try box.makeApp("Acme.app", bundleID: "com.acme.app", displayName: "Acme")
        let folder = box.applications.appendingPathComponent("Suite")
        try box.makeApp("Nested.app", bundleID: "com.nested.tool", displayName: "Nested", in: folder)
        // None of these may be offered:
        try box.makeApp("Deep.app", bundleID: "com.deep.app", in: folder.appendingPathComponent("More"))
        try box.makeApp("Preview.app", bundleID: "com.apple.Preview")
        try box.makeApp("NoPlist.app", bundleID: nil)
        try box.makeApp("OneWord.app", bundleID: "oneword")
        try box.makeApp("Zenith.app", bundleID: "dev.zenith.self")
        try box.makeApp(".Hidden.app", bundleID: "com.hidden.app")
        try fm.createSymbolicLink(at: box.applications.appendingPathComponent("Link.app"), withDestinationURL: acme)

        let apps = box.service().listInstalledApps()
        #expect(apps.map(\.displayName) == ["Acme", "Nested", "Zeta"])
        #expect(apps.allSatisfy { $0.appSizeBytes == 0 })
        #expect(apps.first?.bundlePath == acme.path)
        #expect(apps.first?.version == "2.1")
    }

    @Test("UNINST-11: An app that must not be uninstalled is refused with the reason")
    func testEligibility() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let service = box.service()

        let acme = try box.makeApp("Acme.app", bundleID: "com.acme.app", payloadBytes: 20_000)
        // A hidden file is part of what a removal takes, so it is part of the size.
        try Data(count: 30_000).write(to: acme.appendingPathComponent("Contents/.hidden-cache"))
        guard case .success(let info) = service.eligibility(ofAppAt: acme.path) else {
            Issue.record("Acme.app should be accepted")
            return
        }
        #expect(info.bundleIdentifier == "com.acme.app")
        #expect(info.appSizeBytes >= 50_000)

        let plainFolder = box.applications.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        #expect(service.eligibility(ofAppAt: plainFolder.path) == .failure(.notAnApp))
        #expect(service.eligibility(ofAppAt: box.applications.appendingPathComponent("Gone.app").path) == .failure(.notAnApp))

        let apple = try box.makeApp("Notes.app", bundleID: "com.apple.Notes")
        #expect(service.eligibility(ofAppAt: apple.path) == .failure(.partOfMacOS))
        #expect(service.eligibility(ofAppAt: "/System/Applications/Calculator.app") == .failure(.partOfMacOS))

        let own = try box.makeApp("Zenith.app", bundleID: "dev.zenith.self")
        #expect(service.eligibility(ofAppAt: own.path) == .failure(.isZenith))

        let helper = try box.makeApp("Helper.app", bundleID: "com.acme.app.helper", in: acme.appendingPathComponent("Contents/Library/LoginItems"))
        #expect(service.eligibility(ofAppAt: helper.path) == .failure(.insideAnotherApp))

        let noPlist = try box.makeApp("NoPlist.app", bundleID: nil)
        #expect(service.eligibility(ofAppAt: noPlist.path) == .failure(.unreadable))
        let hostile = try box.makeApp("Hostile.app", bundleID: "../../Documents")
        #expect(service.eligibility(ofAppAt: hostile.path) == .failure(.unreadable))
    }

    // MARK: Tying files to an app

    @Test("UNINST-12: A name from an Info.plist cannot walk out of the folder it is looked up in")
    func testHostileNamesFindNothing() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.makeLibraryEntry("Fonts/")
        try box.makeLibraryEntry("Application Support/Other/")
        try box.makeLibraryEntry("Preferences/com.other.app.plist")

        let service = box.service()
        for (name, identifier) in [
            ("../Fonts", "com.evil.app"),
            ("..", "com.evil.app"),
            ("Other/../Other", "com.evil.app"),
            ("Evil", "../Preferences/com.other.app"),
            ("Evil", "../Application Support/Other"),
            (".", "")
        ] {
            let app = InstalledAppInfo(bundlePath: "/Applications/Evil.app", bundleIdentifier: identifier, displayName: name, version: "1", appSizeBytes: 1)
            #expect(service.scanLeftovers(for: app).isEmpty, "name \(name), identifier \(identifier)")
        }
    }

    @Test("UNINST-13: An identifier matches whole components only, and a name match is flagged")
    func testIdentifierBoundariesAndNameMatches() throws {
        let box = try Sandbox()
        defer { box.cleanup() }

        let own = try [
            "LaunchAgents/com.acme.app.plist",
            "LaunchAgents/com.acme.app.helper.plist",
            "Preferences/com.acme.app.plist",
            "Preferences/ByHost/com.acme.app.ABCDEF.plist",
            "Group Containers/TEAM123.com.acme.app/",
            "Group Containers/group.com.acme.app.shared/",
            "Caches/com.acme.app/",
            "Application Support/Acme/"
        ].map { try box.makeLibraryEntry($0).path }
        let strangers = try [
            "LaunchAgents/com.acme.apple.plist",
            "LaunchAgents/com.acme.app.helper.txt",
            "Preferences/com.acme.application.plist",
            "Preferences/ByHost/com.acme.appstore.ABCDEF.plist",
            "Group Containers/group.com.acme.appstore/",
            "Group Containers/Acme/",
            "Caches/com.acme.app2/",
            "Application Support/Acme Pro/",
            // Apple's, whatever the app calls itself:
            "Caches/com.apple.acme/"
        ].map { try box.makeLibraryEntry($0).path }

        let app = InstalledAppInfo(bundlePath: "/Applications/Acme.app", bundleIdentifier: "com.acme.app", displayName: "Acme", version: "1", appSizeBytes: 1)
        let leftovers = box.service().scanLeftovers(for: app)
        let paths = Set(leftovers.map(\.path))

        for path in own { #expect(paths.contains(path), "missing \(path)") }
        for path in strangers { #expect(!paths.contains(path), "wrongly claimed \(path)") }
        #expect(leftovers.filter(\.matchedByName).map(\.name) == ["Acme"])
        #expect(leftovers.allSatisfy { $0.sizeBytes > 0 })
    }

    // MARK: Removal

    /// Acme.app with a cache, a preference file, a launch agent and a name-matched support folder.
    private func installAcme(in box: Sandbox) throws -> (plan: AppUninstallPlan, app: URL, cache: URL, prefs: URL, agent: URL, support: URL) {
        let app = try box.makeApp("Acme.app", bundleID: "com.acme.app", displayName: "Acme")
        let cache = try box.makeLibraryEntry("Caches/com.acme.app/")
        let prefs = try box.makeLibraryEntry("Preferences/com.acme.app.plist")
        let agent = try box.makeLibraryEntry("LaunchAgents/com.acme.app.agent.plist")
        let support = try box.makeLibraryEntry("Application Support/Acme/")
        let plan = try #require(box.service().analyzeApp(atPath: app.path))
        return (plan, app, cache, prefs, agent, support)
    }

    @Test("UNINST-14: The app and the chosen files go to the Trash; anything else stays, even if a list names it")
    func testUninstallMovesOnlyWhatWasChosen() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)
        let other = try box.makeLibraryEntry("Application Support/OtherApp/")
        #expect(acme.plan.leftovers.count == 4)

        let chosen = acme.plan.leftovers.filter { !$0.matchedByName }
            // A hand-made entry for another app's folder: inside ~/Library, but not this app's.
            + [AppLeftoverItem(name: "OtherApp", path: other.path, kind: .appSupport, sizeBytes: 999)]
        let freed = try box.service().uninstall(plan: acme.plan, selectedLeftovers: chosen)

        #expect(box.trashedNames == ["Acme.app", "com.acme.app", "com.acme.app.agent.plist", "com.acme.app.plist"])
        #expect(!box.exists(acme.app) && !box.exists(acme.cache) && !box.exists(acme.prefs) && !box.exists(acme.agent))
        #expect(box.exists(acme.support), "a file that was not chosen stays")
        #expect(box.exists(other), "another app's folder stays")
        #expect(freed == acme.plan.totalReclaimableBytes - (acme.plan.leftovers.first { $0.matchedByName }?.sizeBytes ?? 0))

        #expect(box.commands.didRun("launchctl", containing: acme.agent.path))
        #expect(box.commands.commands.filter { $0.first == "launchctl" }.count == 1)
        #expect(box.history.entries.count == 1)
        #expect(box.history.entries.first?.items == 4)
    }

    @Test("UNINST-15: Leftovers alone can go while the app stays")
    func testUninstallLeftoversOnly() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)

        try box.service().uninstall(plan: acme.plan, selectedLeftovers: [acme.plan.leftovers.first { $0.kind == .caches }!], includeApp: false)
        #expect(box.trashedNames == ["com.acme.app"])
        #expect(box.exists(acme.app) && box.exists(acme.prefs))
    }

    @Test("UNINST-16: An open app is asked to quit; if it stays open nothing is removed")
    func testRunningAppMustQuitFirst() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)

        let stubborn = FakeRunningApps(running: true, quitsWhenAsked: false)
        #expect(throws: UninstallError.appStillRunning("Acme")) {
            try box.service(running: stubborn.control).uninstall(plan: acme.plan)
        }
        #expect(stubborn.quitRequests == 1)
        #expect(box.trashedNames.isEmpty)
        #expect(box.exists(acme.app) && box.exists(acme.cache))
        #expect(box.commands.commands.isEmpty)

        let polite = FakeRunningApps(running: true, quitsWhenAsked: true)
        let service = box.service(running: polite.control)
        #expect(service.isAppRunning(acme.plan.app))
        try service.uninstall(plan: acme.plan)
        #expect(polite.quitRequests == 1)
        #expect(!box.exists(acme.app))
    }

    @Test("UNINST-17: If the app cannot be moved, its files are left where they are")
    func testAppThatCannotBeTrashedStopsEverything() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)

        #expect(throws: (any Error).self) {
            try box.service(refusingToTrash: ["Acme.app"]).uninstall(plan: acme.plan)
        }
        #expect(box.trashedNames.isEmpty)
        #expect(box.exists(acme.app) && box.exists(acme.cache) && box.exists(acme.prefs) && box.exists(acme.agent))
        #expect(box.commands.commands.isEmpty, "the launch agent is not unloaded for an app that stays")
        #expect(box.history.entries.isEmpty)
    }

    @Test("UNINST-18: A file that cannot be moved is named; the rest still goes")
    func testLeftoverFailureIsReported() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)

        do {
            try box.service(refusingToTrash: ["com.acme.app.plist"]).uninstall(plan: acme.plan)
            Issue.record("the failure should be thrown")
        } catch let UninstallError.someFailed(names, _) {
            #expect(names == ["com.acme.app.plist"])
        }
        #expect(box.exists(acme.prefs))
        #expect(box.trashedNames == ["Acme", "Acme.app", "com.acme.app", "com.acme.app.agent.plist"])
        #expect(box.history.entries.count == 1)
    }

    @Test("UNINST-19: Apple's apps and Zenith are refused even with a hand-made plan")
    func testProtectedAppsAreRefusedAtRemoval() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let service = box.service()

        let apple = try box.makeApp("Notes.app", bundleID: "com.apple.Notes")
        let applePlan = AppUninstallPlan(
            app: InstalledAppInfo(bundlePath: apple.path, bundleIdentifier: "com.apple.Notes", displayName: "Notes", version: "1", appSizeBytes: 1),
            leftovers: []
        )
        #expect(throws: UninstallError.protectedSystemApplication) { try service.uninstall(plan: applePlan) }

        let own = try box.makeApp("Zenith.app", bundleID: "dev.zenith.self")
        let ownPlan = AppUninstallPlan(
            app: InstalledAppInfo(bundlePath: own.path, bundleIdentifier: "dev.zenith.self", displayName: "Zenith", version: "1", appSizeBytes: 1),
            leftovers: []
        )
        #expect(throws: UninstallError.cannotUninstallZenith) { try service.uninstall(plan: ownPlan) }
        #expect(box.exists(apple) && box.exists(own))
        #expect(box.trashedNames.isEmpty)
    }

    // MARK: The list the Settings page shows

    @Test("UNINST-20: The list puts the app first, leaves name matches unticked, and removes nothing when declined")
    @MainActor
    func testUninstallerToolModel() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)
        let service = box.service()
        let listed = try #require(service.listInstalledApps().first)

        let model = CleanupToolModel.uninstaller(app: listed, service: service)
        #expect(model.kind == .uninstaller)
        #expect(model.movesToTrash)
        await model.scan()

        let appID = CleanupToolModel.uninstallerAppCandidateID(for: listed)
        #expect(model.candidates.first?.id == appID)
        #expect(model.candidates.first?.bytes ?? 0 > 0, "the app is measured once it is picked")
        #expect(model.candidates.count == 5)
        #expect(model.candidates.filter { !$0.isSelected }.map(\.id) == [acme.support.path])

        let question = model.confirmation()
        #expect(question.title == "Uninstall Acme?")
        #expect(question.message.contains("• Acme — "))
        #expect(question.message.contains("com.acme.app.plist"))
        #expect(!question.message.contains("is open"))
        #expect(question.actionTitle == "Move to Trash")

        let declined = await model.cleanSelected { _ in false }
        #expect(declined == 0)
        #expect(box.trashedNames.isEmpty)
        #expect(box.exists(acme.app))

        let freed = await model.cleanSelected { _ in true }
        #expect(freed > 0)
        #expect(!box.exists(acme.app) && !box.exists(acme.cache) && !box.exists(acme.prefs) && !box.exists(acme.agent))
        // What was not ticked is still listed (and still unticked) once the app is gone.
        #expect(model.candidates.map(\.id) == [acme.support.path])
        #expect(model.selectedCandidates.isEmpty)

        // Without the app in the selection it is an ordinary "move to the Trash" question.
        model.selectAll(true)
        #expect(model.confirmation().title == "Move 1 item to the Trash?")
    }

    @Test("UNINST-21: The confirmation says so when the app is open, and a stubborn app leaves everything in place")
    @MainActor
    func testToolModelWithRunningApp() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)
        let running = FakeRunningApps(running: true, quitsWhenAsked: false)
        let service = box.service(running: running.control)
        let listed = try #require(service.listInstalledApps().first)

        let model = CleanupToolModel.uninstaller(app: listed, service: service)
        await model.scan()
        #expect(model.confirmation().message.contains("Acme is open and will be asked to quit first."))

        let freed = await model.cleanSelected { _ in true }
        #expect(freed == 0)
        #expect(model.status?.contains("still open") == true)
        #expect(box.exists(acme.app) && box.exists(acme.cache))
        #expect(box.trashedNames.isEmpty)
    }

    @Test("UNINST-22: The page lists and filters apps, refuses what it must, and returns to the list after an uninstall")
    @MainActor
    func testAppUninstallerModel() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let acme = try installAcme(in: box)
        try box.makeApp("Cafe.app", bundleID: "org.example.coffee", displayName: "Café")
        let apple = try box.makeApp("Notes.app", bundleID: "com.apple.Notes")

        let model = AppUninstallerModel(service: box.service())
        #expect(!model.hasLoaded)
        await model.loadApps()
        #expect(model.hasLoaded)
        #expect(model.apps.map(\.displayName) == ["Acme", "Café"])

        model.searchText = "cafe"
        #expect(model.filteredApps.map(\.displayName) == ["Café"])
        model.searchText = "COM.ACME"
        #expect(model.filteredApps.map(\.displayName) == ["Acme"])
        model.searchText = "  "
        #expect(model.filteredApps.count == 2)

        let accepted = await model.choose(appAtPath: apple.path)
        #expect(!accepted)
        #expect(model.tool == nil)
        #expect(model.notice?.contains("Notes") == true)

        await model.select(model.apps[0])
        #expect(model.notice == nil)
        #expect(model.selectedApp?.bundlePath == acme.app.path)
        let tool = try #require(model.tool)
        #expect(tool.hasScanned)

        // Something is left (the unticked support folder), so the page stays on the app.
        _ = await tool.cleanSelected { _ in true }
        await model.afterCleaning()
        #expect(model.tool != nil)

        tool.selectAll(true)
        _ = await tool.cleanSelected { _ in true }
        await model.afterCleaning()
        #expect(model.tool == nil && model.selectedApp == nil)
        #expect(model.apps.map(\.displayName) == ["Café"])
        #expect(model.notice?.contains("Acme") == true)
        #expect(!box.exists(acme.support))

        model.back()
        let viaPath = await model.choose(appAtPath: box.applications.appendingPathComponent("Cafe.app").path)
        #expect(viaPath)
        #expect(model.selectedApp?.displayName == "Café")
    }
}
