import Testing
import Foundation
@testable import ZenithCore

@Suite("Cleaner Overlap and Defaults Suite")
struct CleanerOverlapAndDefaultsTests {

    private func makeHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_Overlap_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int = 8_192) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test("OVL-01: The same files offered twice are counted once, in the total, the summary and the deletion")
    @MainActor
    func testOverlapIsCountedOnce() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Chrome's cache is a "Browser Cache" and also part of Caches/Google, an "Application Cache".
        try write(home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache/data_0"), bytes: 2_000_000)

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()

        let titles = service.categories.map(\.title)
        #expect(titles.contains("Browser Caches") && titles.contains("Application Caches"))
        let listed = service.categories.flatMap(\.items).reduce(0) { $0 + $1.size }
        #expect(listed >= 2 * 2_000_000)                                      // both categories list it ...
        #expect(service.selectedJunkSize <= listed / 2 + 8_192)               // ... but it is one folder's worth
        #expect(service.effectiveSelectedItems.count == 1)
        #expect(service.selectedItemCount == 1)
        #expect(service.selectionSummary.components(separatedBy: "\n").count == 1)

        let freed = await service.cleanSelected()
        #expect(freed == service.lastFreedBytes)
        #expect(freed <= listed / 2 + 8_192)                                  // not the double-counted figure
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/Google/Chrome").path))
    }

    @Test("OVL-02: Overlap removal keeps the outer folder, and drops repeats and nested items only")
    func testWithoutOverlaps() {
        func item(_ path: String) -> JunkItem { JunkItem(name: path, path: path, size: 10) }
        let kept = SystemCleanerService.withoutOverlaps([
            item("/h/Library/Caches/Google/Chrome"),
            item("/h/Library/Caches/Google"),
            item("/h/Library/Caches/Googlefoo"),           // a sibling whose name only starts the same
            item("/h/Library/Caches/Homebrew"),
            item("/h/Library/Caches/Homebrew/")            // the same folder written with a slash
        ])
        #expect(kept.map(\.path) == ["/h/Library/Caches/Google", "/h/Library/Caches/Googlefoo", "/h/Library/Caches/Homebrew"])
    }

    @Test("OVL-03: Mail attachments you opened are listed but not ticked")
    @MainActor
    func testMailDownloadsAreNotTicked() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/ABC/contract.docx"))

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()

        let mail = service.categories.first { $0.id == "mail_downloads" }
        #expect(mail != nil)
        #expect(mail?.isSelected == false)
        #expect(mail?.items.allSatisfy { !$0.isSelected } == true)
        #expect(service.selectedJunkSize == 0)
    }

    @Test("OVL-04: A project worked on this week is not ticked; an idle one is")
    @MainActor
    func testRecentProjectIsNotTicked() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        func makeProject(_ name: String, modifiedDaysAgo days: Int) throws {
            let project = home.appendingPathComponent("Projects/\(name)")
            let modules = project.appendingPathComponent("node_modules")
            try write(modules.appendingPathComponent("lib.js"))
            try "{}".write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            let when = Date().addingTimeInterval(-Double(days) * 86_400)
            for path in [modules.appendingPathComponent("lib.js").path, modules.path] {
                try fm.setAttributes([.modificationDate: when], ofItemAtPath: path)
            }
        }
        try makeProject("active", modifiedDaysAgo: 0)
        try makeProject("idle", modifiedDaysAgo: 40)

        let service = ProjectPurgeService(homeDirectory: home.path, runner: { _, _ in nil })
        let root = home.appendingPathComponent("Projects").path
        let model = CleanupToolModel.projects(service: service, roots: { [root] })
        await model.scan()

        let byTitle = Dictionary(uniqueKeysWithValues: model.candidates.map { ($0.title, $0.isSelected) })
        #expect(byTitle["active / node_modules"] == false)
        #expect(byTitle["idle / node_modules"] == true)
    }

    @Test("OVL-05: An iPhone app run through PlayCover is installed, so its container is not a leftover")
    func testPlayCoverAppsAreNotLeftovers() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("zenith_pc_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let old = Date().addingTimeInterval(-120 * 86_400)

        // The app, as PlayCover keeps it: a bundle with an Info.plist under its own container.
        let appRoot = home.appendingPathComponent("Library/Containers/io.playcover.PlayCover/Applications")
        let bundle = appRoot.appendingPathComponent("Some Game.app/Contents")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "jp.example.somegame", "CFBundlePackageType": "APPL"]
        try (plist as NSDictionary).write(to: bundle.appendingPathComponent("Info.plist"))

        // Its saved data, and the data of a game that really is gone.
        for name in ["jp.example.somegame", "jp.other.gonegame"] {
            let folder = home.appendingPathComponent("Library/Containers/\(name)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("save.dat")
            try Data(count: 4096).write(to: file)
            for path in [file.path, folder.path] { try fm.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: path) }
        }

        // Default application roots under this home, as the app uses them.
        let service = OrphanedAppLeftoversService(homeDirectory: home, isBundleIdentifierInUse: { _ in false }, minIdleDays: 0)
        let offered = await service.scan().compactMap(\.bundleId)

        #expect(offered.contains("jp.other.gonegame"))
        #expect(!offered.contains("jp.example.somegame"))
    }
}
