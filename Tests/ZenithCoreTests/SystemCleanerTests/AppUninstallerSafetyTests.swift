import Testing
import Foundation
@testable import ZenithCore

@Suite("App Uninstaller Matching Safety Suite")
struct AppUninstallerSafetyTests {

    private let home = (NSHomeDirectory() as NSString).standardizingPath

    @Test("UNINST-04: Leftover paths must be inside ~/Library proper and never macOS's own data")
    func testLeftoverPathBoundaries() {
        let service = AppUninstallerService()

        // A sibling whose name merely starts with "Library" is not inside ~/Library.
        #expect(service.isSafeLeftoverPath("\(home)/LibraryBackup/old-app") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library-archive/old-app") == false)

        // Apple's own data folders, whatever app triggered the lookup.
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support/Mail") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support/AddressBook/Sources") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Caches/com.apple.Safari") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Containers/com.apple.mail") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Group Containers/group.com.apple.notes") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Preferences/com.apple.finder.plist") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Keychains/login.keychain-db") == false)

        // A third-party app's own folders stay deletable, even when a nested folder is called "Mail".
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support/AcmeApp") == true)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support/AcmeApp/Mail/cache.db") == true)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Caches/com.acme.app") == true)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Preferences/com.acme.app.plist") == true)
    }

    @Test("UNINST-05: Shared containers and launch agents are matched by bundle identifier, never by a common app name")
    func testSharedContainersAndAgentsNeedBundleIdentifier() throws {
        let fm = FileManager.default
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_UninstSafety_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempHome) }
        let library = tempHome.appendingPathComponent("Library")

        // Belonging to some other product that merely has "Notes" in its name…
        let strangerGroup = library.appendingPathComponent("Group Containers/ABCDE12345.notes-sync")
        let strangerAgent = library.appendingPathComponent("LaunchAgents/com.other.notesync.plist")
        // …and genuinely belonging to com.acme.notes.
        let ownGroup = library.appendingPathComponent("Group Containers/group.com.acme.notes")
        let ownAgent = library.appendingPathComponent("LaunchAgents/com.acme.notes.helper.plist")

        for url in [strangerGroup, ownGroup] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: library.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
        for url in [strangerAgent, ownAgent] {
            try "plist".write(to: url, atomically: true, encoding: .utf8)
        }

        let app = InstalledAppInfo(
            bundlePath: "/Applications/Notes.app",
            bundleIdentifier: "com.acme.notes",
            displayName: "Notes",
            version: "1.0",
            appSizeBytes: 1_000
        )
        let leftovers = AppUninstallerService().scanLeftovers(for: app, home: tempHome.path)
        let paths = Set(leftovers.map(\.path))

        #expect(paths.contains(ownGroup.path))
        #expect(paths.contains(ownAgent.path))
        #expect(!paths.contains(strangerGroup.path))
        #expect(!paths.contains(strangerAgent.path))
    }
}
