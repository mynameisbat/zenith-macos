import Testing
import Foundation
@testable import ZenithCore

/// Checks found by reading the cleaner against a throwaway home directory.
@Suite("Cleaner audit: sizes inside bundles, read-only trees, what a clean really removes")
struct CleanerAuditTests {
    private func makeHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_Audit_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func relax(_ url: URL) {
        // Put write permission back everywhere so the temp folder can be removed.
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in walker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path) }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test("AUD-01: The size of a folder counts what is inside an .app, .framework or .dSYM")
    func testSizeIncludesPackageContents() throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Build/Products/Debug/Demo.app/Contents/MacOS/Demo"), bytes: 3_000_000)
        try write(root.appendingPathComponent("Build/Products/Debug/Lib.framework/Versions/A/Lib"), bytes: 2_000_000)
        try write(root.appendingPathComponent("Build/Products/Debug/Demo.app.dSYM/Contents/Resources/DWARF/Demo"), bytes: 1_000_000)
        try write(root.appendingPathComponent("Build/plain.o"), bytes: 500_000)

        let size = SystemCleanerService.calculateSize(of: root.path, fileManager: .default)
        #expect(size >= 6_500_000, "size \(size) should include the 6 MB inside the bundles")
    }

    @Test("AUD-02: A read-only tree (Go's module cache) is removed completely and counted as freed")
    @MainActor
    func testReadOnlyTreeIsRemoved() async throws {
        let home = try makeHome()
        defer { relax(home); try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("go/pkg/mod/cache")
        try write(cache.appendingPathComponent("download/example.com/mod/@v/v1.0.0.zip"), bytes: 3_000_000)
        try write(cache.appendingPathComponent("download/example.com/mod/@v/v1.0.0.mod"), bytes: 2_000)
        // `go` makes what it downloads read-only.
        for path in ["download/example.com/mod/@v/v1.0.0.zip", "download/example.com/mod/@v/v1.0.0.mod"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: cache.appendingPathComponent(path).path)
        }
        for path in ["download/example.com/mod/@v", "download/example.com/mod", "download/example.com", "download"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache.appendingPathComponent(path).path)
        }

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()
        let item = try #require(service.categories.flatMap(\.items).first { $0.name == "Go Module Cache" })
        #expect(item.size >= 3_000_000)

        let freed = await service.cleanSelected()
        #expect(freed >= 3_000_000, "freed \(freed)")
        #expect(!FileManager.default.fileExists(atPath: cache.path), "the cache folder should be gone")
    }

    // MARK: Project build folders

    private func gitRunner() -> SystemCommandRunner { { _, _ in SystemCommandResult(status: 1, output: "") } }

    private func setDate(_ url: URL, daysAgo: Int) throws {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
    }

    /// An old project: everything in it, and its node_modules, last changed 90 days ago.
    private func makeOldProject(in home: URL) throws -> URL {
        let project = home.appendingPathComponent("Projects/app")
        try write(project.appendingPathComponent("package.json"), bytes: 100)
        try write(project.appendingPathComponent("src/deep/index.js"), bytes: 100)
        try write(project.appendingPathComponent("node_modules/dep/index.js"), bytes: 5_000)
        for relative in ["node_modules/dep/index.js", "node_modules/dep", "node_modules", "src/deep/index.js", "src/deep", "src", "package.json", ""] {
            try setDate(relative.isEmpty ? project : project.appendingPathComponent(relative), daysAgo: 90)
        }
        return project
    }

    @Test("AUD-03: A project edited today is not 'untouched' just because its node_modules is old")
    func testProjectActivityCounts() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = try makeOldProject(in: home)
        let service = ProjectPurgeService(homeDirectory: home.path, runner: gitRunner())
        let roots = [home.appendingPathComponent("Projects").path]

        let idle = try #require(service.scan(customSearchRoots: roots, minAgeDays: 0).artifacts.first)
        #expect(idle.daysSinceModified >= 89, "nothing touched for 90 days: \(idle.daysSinceModified)")

        // The author saves a file in src/deep. An editor writes a new file and renames it over the old one, which
        // changes the folder's date too; an in-place write deeper than two levels is not seen (documented limit).
        try setDate(project.appendingPathComponent("src/deep/index.js"), daysAgo: 0)
        try setDate(project.appendingPathComponent("src/deep"), daysAgo: 0)
        let busy = try #require(service.scan(customSearchRoots: roots, minAgeDays: 0).artifacts.first)
        #expect(busy.daysSinceModified == 0, "edited today, but reported untouched for \(busy.daysSinceModified) days")
    }

    @Test("AUD-04: A node_modules that keeps its packages in hidden folders (pnpm) is measured in full")
    func testHiddenFoldersAreMeasured() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Projects/app")
        try write(project.appendingPathComponent("package.json"), bytes: 100)
        try write(project.appendingPathComponent("node_modules/.pnpm/dep@1.0.0/node_modules/dep/blob.bin"), bytes: 4_000_000)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("node_modules/dep"),
            withDestinationURL: project.appendingPathComponent("node_modules/.pnpm/dep@1.0.0/node_modules/dep")
        )

        let service = ProjectPurgeService(homeDirectory: home.path, runner: gitRunner())
        let item = try #require(service.scan(customSearchRoots: [home.appendingPathComponent("Projects").path], minAgeDays: 0).artifacts.first)
        #expect(item.sizeBytes >= 4_000_000, "measured \(item.sizeBytes)")
    }

    // MARK: Leftovers

    @Test("AUD-05: Recent activity inside a bundle-like folder keeps a leftover from being offered")
    func testRecentChangeInsideBundleIsSeen() async throws {
        let library = try makeHome()
        defer { try? FileManager.default.removeItem(at: library) }
        let item = library.appendingPathComponent("com.gone.tool")
        try write(item.appendingPathComponent("old.db"), bytes: 4_096)
        try write(item.appendingPathComponent("Data.app/inner/recent.db"), bytes: 4_096)
        for relative in ["old.db", "Data.app/inner", "Data.app", ""] {
            try setDate(relative.isEmpty ? item : item.appendingPathComponent(relative), daysAgo: 90)
        }
        // The file itself was written today; the folders around it were not touched.
        let service = OrphanedAppLeftoversService(
            locations: [(library, "Test")], applicationRoots: [], isBundleIdentifierInUse: { _ in false }, minIdleDays: 30
        )
        #expect(await service.scan().isEmpty, "used today, yet offered as a leftover")
    }

    @Test("AUD-06: An item that cannot be removed is reported by name, the rest still goes, and nothing false is counted")
    @MainActor
    func testFailuresAreReported() async throws {
        let home = try makeHome()
        let locked = home.appendingPathComponent(".npm/_cacache/content/locked.blob")
        defer {
            _ = chflags(locked.path, 0)
            relax(home)
            try? FileManager.default.removeItem(at: home)
        }
        try write(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Demo-abc/Build/blob"), bytes: 2_000_000)
        try write(home.appendingPathComponent(".npm/_cacache/content/other.blob"), bytes: 2_000, )
        try write(locked, bytes: 2_000_000)
        // An immutable file (what a tool or an administrator can set) refuses removal whatever the permissions.
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()
        let freed = await service.cleanSelected()

        #expect(service.lastFailedItemNames == ["npm Cache"])
        #expect(freed >= 2_000_000 && freed < 3_000_000, "DerivedData's 2 MB went, npm's locked 2 MB did not: \(freed)")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Demo-abc").path))
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }

    @Test("AUD-08: When only an empty folder is left behind, the space counts as freed and nothing is reported")
    @MainActor
    func testEmptyLeftoverFolderIsNotAFailure() async throws {
        let home = try makeHome()
        defer { relax(home); try? FileManager.default.removeItem(at: home) }
        try write(home.appendingPathComponent(".npm/_cacache/content/blob"), bytes: 2_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.appendingPathComponent(".npm").path)

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()
        let freed = await service.cleanSelected()

        #expect(freed >= 2_000_000)
        #expect(service.lastFailedItemNames.isEmpty)
    }

    @Test("AUD-07: Making a tree writable never follows a link out of it")
    func testWritableHelperStaysInside() throws {
        let home = try makeHome()
        defer { relax(home); try? FileManager.default.removeItem(at: home) }
        let outside = home.appendingPathComponent("outside")
        try write(outside.appendingPathComponent("keep.txt"), bytes: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outside.path)

        let tree = home.appendingPathComponent("tree")
        try write(tree.appendingPathComponent("sub/file"), bytes: 10)
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("sub/link"), withDestinationURL: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tree.appendingPathComponent("sub").path)

        try SystemCleanerService.removeItemMakingWritable(atPath: tree.path)

        #expect(!FileManager.default.fileExists(atPath: tree.path))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
        let mode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int
        #expect(mode == 0o555, "the link's target must not be changed")
    }

    @Test("AUD-09: Pods is offered only where Git ignores it; a project that commits its Pods is left alone")
    func testPodsNeedGitToIgnoreThem() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["ignores", "commits"] {
            let project = home.appendingPathComponent("Projects/\(name)")
            try write(project.appendingPathComponent("Podfile"), bytes: 50)
            try write(project.appendingPathComponent("Pods/Alamofire/Source.swift"), bytes: 5_000)
        }
        let runner: SystemCommandRunner = { _, arguments in
            // `git -C <project> check-ignore -q -- Pods`: ignored in one project, tracked in the other.
            let ignored = arguments.contains { $0.hasSuffix("/Projects/ignores") }
            return SystemCommandResult(status: ignored ? 0 : 1, output: "")
        }
        let service = ProjectPurgeService(homeDirectory: home.path, runner: runner)
        let offered = service.scan(customSearchRoots: [home.appendingPathComponent("Projects").path], minAgeDays: 0).artifacts
        #expect(offered.map(\.projectName) == ["ignores"])
    }

    @Test("AUD-10: Everything the scan offers on a fully stocked Mac passes the deletion gate, and nothing else is let through")
    @MainActor
    func testEveryOfferedItemPassesTheGate() async throws {
        let home = try makeHome()
        defer { relax(home); try? FileManager.default.removeItem(at: home) }
        let big = 2_000_000, small = 4_000
        func file(_ relative: String, _ bytes: Int) throws { try write(home.appendingPathComponent(relative), bytes: bytes) }

        // One of everything the scan looks for.
        for browser in ["Google/Chrome", "company.thebrowser.Browser", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Firefox", "org.mozilla.firefox"] {
            try file("Library/Caches/\(browser)/blob", small)
        }
        try file("Library/Developer/Xcode/DerivedData/App-abc/Build/blob", small)
        try file("Library/Developer/CoreSimulator/Caches/dyld/blob", small)
        try file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A)/blob", small)
        try file("Library/Caches/com.acme.helper/blob", big)
        for dev in ["Library/Caches/CocoaPods", ".gradle/caches", ".cargo/registry/cache", ".cargo/git/db", "Library/Caches/Homebrew",
                    "Library/Caches/org.swift.swiftpm", ".npm/_cacache", "Library/pnpm/store", ".pnpm-store", "Library/Caches/Yarn",
                    ".bun/install/cache", "Library/Caches/go-build", "go/pkg/mod/cache", "Library/Caches/pip", ".cache/uv",
                    "Library/Caches/pypoetry", ".android/cache", "Library/Caches/JetBrains", "Library/Application Support/Cursor/Cache",
                    "Library/Caches/com.anthropic.claudedesktop"] {
            try file("\(dev)/blob", small)
        }
        try file("Library/Saved Application State/com.acme.app.savedState/blob", big)
        try file("Downloads/movie.mp4.crdownload", small)
        try setDate(home.appendingPathComponent("Downloads/movie.mp4.crdownload"), daysAgo: 3)
        try file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/ABC/contract.docx", small)
        try file("Library/iTunes/iPhone Software Updates/iPhone.ipsw", big)
        try file("Library/Logs/Acme/app.log", small)
        try file(".Trash/old.txt", small)

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()
        let offered = service.categories.flatMap(\.items)
        #expect(offered.count >= 25, "only \(offered.count) items were offered")
        for item in offered {
            #expect(SystemCleanerService.isPathSafeForDeletion(item.path, home: home.path), "offered but refused: \(item.name) at \(item.path)")
        }

        // And the gate refuses what the scan never offers, even in the same tool folders. (A home that is not inside the
        // temporary folder, which is itself a place cleaning may go.)
        let realisticHome = "/Users/audit"
        for notCache in [".cargo/bin/cargo", ".android/avd/x.avd", ".gradle/wrapper/dists/g", ".cache/huggingface/m", "Documents/thesis.docx",
                         "Library/Developer/CoreSimulator/Devices/ABC", "Library/Application Support/Cursor/User/settings.json"] {
            #expect(!SystemCleanerService.isPathSafeForDeletion("\(realisticHome)/\(notCache)", home: realisticHome), "\(notCache)")
        }
    }
}

