import Testing
import Foundation
@testable import ZenithCore

@Suite("Installer Purge and Orphaned Leftovers Safety Suite")
struct LeftoverServicesSafetyTests {

    private let fm = FileManager.default

    private func makeTempDirectory(_ label: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("zenith_\(label)_\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func age(_ url: URL, days: Int) throws {
        let old = Date().addingTimeInterval(-Double(days) * 86_400)
        try fm.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: url.path)
    }

    /// Writes `bytes` of data and back-dates the file and the folders created for it, so it counts as an old file.
    @discardableResult
    private func writeOld(_ url: URL, bytes: Int = 4096, days: Int = 90) throws -> URL {
        let temp = fm.temporaryDirectory.resolvingSymlinksInPath().path
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        var current = url
        while current.resolvingSymlinksInPath().path != temp, current.path.count > temp.count {
            try age(current, days: days)
            current = current.deletingLastPathComponent()
        }
        return url
    }

    private func makeApp(named name: String, bundleID: String, in root: URL) throws {
        let contents = root.appendingPathComponent("\(name).app/Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func orphanService(
        library: URL,
        apps: [URL] = [],
        inUse: @escaping @Sendable (String) -> Bool = { _ in false },
        minIdleDays: Int = 30
    ) -> OrphanedAppLeftoversService {
        OrphanedAppLeftoversService(
            locations: [(library, "Test")],
            applicationRoots: apps,
            isBundleIdentifierInUse: inUse,
            minIdleDays: minIdleDays
        )
    }

    // MARK: - Orphaned app leftovers

    @Test("ORPH-01: Only bundle-identifier folders are offered; vendor and plain-name folders never are")
    func testOnlyBundleIdentifiersAreOffered() async throws {
        let library = try makeTempDirectory("orph_names")
        defer { try? fm.removeItem(at: library) }

        try writeOld(library.appendingPathComponent("Google/Chrome/Default/Login Data"))
        try writeOld(library.appendingPathComponent("JetBrains/Rider2025.1/options/ide.xml"))
        try writeOld(library.appendingPathComponent("SomeOldApp/data.db"))
        try writeOld(library.appendingPathComponent("com.defunct.app/data.db"))

        let orphans = await orphanService(library: library).scan()
        #expect(orphans.map(\.bundleId) == ["com.defunct.app"])
    }

    @Test("ORPH-02: Apple's, Docker's and the same vendor's other apps are never offered")
    func testProtectedAndSameVendorEntriesAreSkipped() async throws {
        let library = try makeTempDirectory("orph_vendor")
        let apps = try makeTempDirectory("orph_apps")
        defer { try? fm.removeItem(at: library); try? fm.removeItem(at: apps) }

        try makeApp(named: "Chrome", bundleID: "com.google.Chrome", in: apps.appendingPathComponent("Utilities/Browsers"))

        try writeOld(library.appendingPathComponent("com.apple.Safari/Cache.db"))
        try writeOld(library.appendingPathComponent("com.docker.docker/Data/vms/0/data/Docker.raw"))
        try writeOld(library.appendingPathComponent("com.google.Chrome/Cache.db"))               // the app itself
        try writeOld(library.appendingPathComponent("com.google.Chrome.helper/Cache.db"))        // its helper
        try writeOld(library.appendingPathComponent("com.google.Keystone/Cache.db"))             // same vendor
        try writeOld(library.appendingPathComponent("com.acme.gone/Cache.db"))                   // a real leftover

        let orphans = await orphanService(library: library, apps: [apps]).scan()
        #expect(orphans.map(\.bundleId) == ["com.acme.gone"])
    }

    @Test("ORPH-03: An app the system still knows or has running is not an orphan, even if it is not in /Applications")
    func testAppKnownToTheSystemIsKept() async throws {
        let library = try makeTempDirectory("orph_inuse")
        defer { try? fm.removeItem(at: library) }

        try writeOld(library.appendingPathComponent("com.external.player/state.db"))
        try writeOld(library.appendingPathComponent("com.acme.gone/state.db"))

        let orphans = await orphanService(library: library, inUse: { $0 == "com.external.player" }).scan()
        #expect(orphans.map(\.bundleId) == ["com.acme.gone"])
    }

    @Test("ORPH-04: Anything modified recently is left alone, and so is a symlink")
    func testRecentAndSymlinkedEntriesAreSkipped() async throws {
        let library = try makeTempDirectory("orph_recent")
        let elsewhere = try makeTempDirectory("orph_target")
        defer { try? fm.removeItem(at: library); try? fm.removeItem(at: elsewhere) }

        try writeOld(library.appendingPathComponent("com.acme.busy/old.db"))
        try Data(repeating: 1, count: 4096).write(to: library.appendingPathComponent("com.acme.busy/fresh.db"))
        try writeOld(library.appendingPathComponent("com.acme.quiet/old.db"))
        try writeOld(elsewhere.appendingPathComponent("payload.db"))
        try fm.createSymbolicLink(at: library.appendingPathComponent("com.acme.linked"), withDestinationURL: elsewhere)

        let orphans = await orphanService(library: library).scan()
        #expect(orphans.map(\.bundleId) == ["com.acme.quiet"])
    }

    @Test("ORPH-05: Purge re-checks every item: wrong folder, returned app and fresh files are skipped")
    func testOrphanPurgeRevalidates() async throws {
        let library = try makeTempDirectory("orph_purge")
        let apps = try makeTempDirectory("orph_purge_apps")
        let stranger = try makeTempDirectory("orph_stranger")
        defer { try? fm.removeItem(at: library); try? fm.removeItem(at: apps); try? fm.removeItem(at: stranger) }

        try writeOld(library.appendingPathComponent("com.defunct.gone/data.db"))
        try writeOld(library.appendingPathComponent("com.acme.back/data.db"))
        try writeOld(stranger.appendingPathComponent("com.acme.elsewhere/data.db"))

        let service = orphanService(library: library, apps: [apps])
        var items = await service.scan()
        #expect(Set(items.compactMap(\.bundleId)) == ["com.defunct.gone", "com.acme.back"])

        // The app comes back after the scan; a forged item points outside the scanned folder.
        try makeApp(named: "Back", bundleID: "com.acme.back", in: apps)
        items.append(OrphanedAppItem(
            appName: "Elsewhere", bundleId: "com.acme.elsewhere",
            path: stranger.appendingPathComponent("com.acme.elsewhere").path, byteSize: 4096, fileCount: 1
        ))

        let freed = try await service.purge(items: items, moveToTrash: false)
        #expect(freed == 4096)
        #expect(!fm.fileExists(atPath: library.appendingPathComponent("com.defunct.gone").path))
        #expect(fm.fileExists(atPath: library.appendingPathComponent("com.acme.back").path))
        #expect(fm.fileExists(atPath: stranger.appendingPathComponent("com.acme.elsewhere").path))
    }

    @Test("ORPH-06: Entry names are recognised as bundle identifiers only when they look like one")
    func testBundleIdentifierParsing() {
        #expect(OrphanedAppLeftoversService.bundleIdentifier(fromEntryName: "com.acme.app") == "com.acme.app")
        #expect(OrphanedAppLeftoversService.bundleIdentifier(fromEntryName: "com.acme.app.savedState") == "com.acme.app")
        #expect(OrphanedAppLeftoversService.bundleIdentifier(fromEntryName: "Google") == nil)
        #expect(OrphanedAppLeftoversService.bundleIdentifier(fromEntryName: "node.js") == nil)
        #expect(OrphanedAppLeftoversService.bundleIdentifier(fromEntryName: "my notes.v2.backup") == nil)
        #expect(OrphanedAppLeftoversService.bundleIdentifier(fromEntryName: "com..app") == nil)
    }

    // MARK: - Installer purge

    /// By default the clock runs 90 days ahead, so files written a moment ago count as long untouched.
    private func installerService(
        mountedImages: [String] = [],
        zipMin: Int64 = 100,
        now: @escaping @Sendable () -> Date = { Date().addingTimeInterval(90 * 86_400) }
    ) -> InstallerPurgeService {
        let images = mountedImages.map { ["image-path": $0] }
        let data = (try? PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)) ?? Data()
        let output = String(decoding: data, as: UTF8.self)
        return InstallerPurgeService(
            runCommand: { _, _ in SystemCommandResult(status: 0, output: output) },
            zipMinSizeBytes: zipMin,
            now: now
        )
    }

    @Test("INST-01: A disk image that is mounted is flagged by its image path and never purged")
    func testMountedImageIsKept() async throws {
        let dir = try makeTempDirectory("inst_mounted")
        defer { try? fm.removeItem(at: dir) }
        let mounted = try writeOld(dir.appendingPathComponent("Foo-1.2.dmg"))
        let idle = try writeOld(dir.appendingPathComponent("Bar-3.0.dmg"))

        let service = installerService(mountedImages: [mounted.path])
        let items = await service.scan(directories: [dir], minAgeDays: 3, minSizeBytes: 100)
        #expect(items.first { $0.url.lastPathComponent == "Foo-1.2.dmg" }?.isMounted == true)

        // Mounted between the scan and the purge: the stale flag must not matter.
        let unflagged = items.map { StaleInstallerItem(name: $0.name, url: $0.url, byteSize: $0.byteSize, fileExtension: $0.fileExtension, modifiedAt: $0.modifiedAt) }
        _ = try await service.purge(items: unflagged, moveToTrash: false)
        #expect(fm.fileExists(atPath: mounted.path))
        #expect(!fm.fileExists(atPath: idle.path))
    }

    @Test("INST-02: A .zip is an installer only if it is large and named like one")
    func testZipRules() async throws {
        let dir = try makeTempDirectory("inst_zip")
        defer { try? fm.removeItem(at: dir) }
        try writeOld(dir.appendingPathComponent("mac-backup.zip"))
        try writeOld(dir.appendingPathComponent("app-assets.zip"))
        try writeOld(dir.appendingPathComponent("Foo-installer.zip"))
        try writeOld(dir.appendingPathComponent("Tiny-setup.zip"), bytes: 10)

        let items = await installerService(zipMin: 1000).scan(directories: [dir], minAgeDays: 3, minSizeBytes: 1)
        #expect(items.map(\.name) == ["Foo-installer.zip"])
    }

    @Test("INST-03: A recent download is kept even when its modification date is old")
    func testRecentCreationDateCounts() async throws {
        let dir = try makeTempDirectory("inst_recent")
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Fresh.dmg")
        try Data(repeating: 1, count: 4096).write(to: url)
        // Keeps the server's old Last-Modified, but was downloaded just now.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)], ofItemAtPath: url.path)

        let items = await installerService(now: { Date() }).scan(directories: [dir], minAgeDays: 3, minSizeBytes: 100)
        #expect(items.isEmpty)
    }

    @Test("INST-04: Symlinks and folders named like installers are not offered")
    func testSymlinksAndFoldersAreSkipped() async throws {
        let dir = try makeTempDirectory("inst_links")
        let elsewhere = try makeTempDirectory("inst_target")
        defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: elsewhere) }
        let target = try writeOld(elsewhere.appendingPathComponent("Real.dmg"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Link.dmg"), withDestinationURL: target)
        try fm.createDirectory(at: dir.appendingPathComponent("Folder.pkg"), withIntermediateDirectories: true)
        try writeOld(dir.appendingPathComponent("Folder.pkg/payload.bin"))

        let items = await installerService().scan(directories: [dir], minAgeDays: 3, minSizeBytes: 100)
        #expect(items.isEmpty)
    }

    @Test("INST-05: Purge skips a file replaced after the scan and anything that is not an installer")
    func testInstallerPurgeRevalidates() async throws {
        let dir = try makeTempDirectory("inst_purge")
        defer { try? fm.removeItem(at: dir) }
        let replaced = try writeOld(dir.appendingPathComponent("Replaced.dmg"))
        let untouched = try writeOld(dir.appendingPathComponent("Untouched.pkg"))
        let notes = try writeOld(dir.appendingPathComponent("Thesis.docx"))

        let service = installerService()
        var items = await service.scan(directories: [dir], minAgeDays: 3, minSizeBytes: 100)
        #expect(items.count == 2)

        // Re-downloaded under the same name after the scan.
        try Data(repeating: 9, count: 8192).write(to: replaced)
        items.append(StaleInstallerItem(name: "Thesis.docx", url: notes, byteSize: 4096, fileExtension: "docx", modifiedAt: Date.distantPast))

        let freed = try await service.purge(items: items, moveToTrash: false)
        #expect(freed == 4096)
        #expect(fm.fileExists(atPath: replaced.path))
        #expect(!fm.fileExists(atPath: untouched.path))
        #expect(fm.fileExists(atPath: notes.path))
    }
}
