import Testing
import Foundation
@testable import GoldenGateCore

@Suite("App Uninstaller & Leftover Discovery Suite")
struct AppUninstallerServiceTests {

    @Test("UNINST-01: App parsing extracts metadata and detects system apps")
    func testAppInfoParsing() throws {
        let service = AppUninstallerService()

        // 1. System app detection
        #expect(service.isSystemPath("/System/Applications/Finder.app") == true)
        #expect(service.isSystemPath("/usr/bin/some_binary") == true)
        #expect(service.isSystemPath("/Applications/Slack.app") == false)

        // 2. Apple bundle protection
        #expect(service.isProtectedAppleBundle("com.apple.Safari") == true)
        #expect(service.isProtectedAppleBundle("com.apple.finder") == true)
        #expect(service.isProtectedAppleBundle("com.tinyspeck.slackmacgap") == false)
        #expect(service.isProtectedAppleBundle("com.google.Chrome") == false)
    }

    @Test("UNINST-02: Leftovers discovery identifies Application Support, Caches, Containers, and Preferences")
    func testLeftoversDiscovery() throws {
        let fm = FileManager.default
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_Uninst_Home_\(UUID().uuidString)")
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let homePath = tempHome.path

        // Construct mock ~/Library structure
        let appSupportDir = "\(homePath)/Library/Application Support/AcmeApp"
        let cachesDir = "\(homePath)/Library/Caches/com.acme.app"
        let containerDir = "\(homePath)/Library/Containers/com.acme.app"
        let prefFile = "\(homePath)/Library/Preferences/com.acme.app.plist"
        let stateDir = "\(homePath)/Library/Saved Application State/com.acme.app.savedState"
        let agentFile = "\(homePath)/Library/LaunchAgents/com.acme.app.helper.plist"

        try fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cachesDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: containerDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(homePath)/Library/Preferences", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(homePath)/Library/LaunchAgents", withIntermediateDirectories: true)

        try "data".write(toFile: "\(appSupportDir)/db.sqlite", atomically: true, encoding: .utf8)
        try "pref".write(toFile: prefFile, atomically: true, encoding: .utf8)
        try "launchd".write(toFile: agentFile, atomically: true, encoding: .utf8)

        let mockApp = InstalledAppInfo(
            bundlePath: "/Applications/AcmeApp.app",
            bundleIdentifier: "com.acme.app",
            displayName: "AcmeApp",
            version: "2.1.0",
            appSizeBytes: 50_000_000
        )

        let service = AppUninstallerService()
        let leftovers = service.scanLeftovers(for: mockApp, home: homePath)

        #expect(leftovers.count >= 6)
        #expect(leftovers.contains(where: { $0.kind == .appSupport && $0.path == appSupportDir }))
        #expect(leftovers.contains(where: { $0.kind == .caches && $0.path == cachesDir }))
        #expect(leftovers.contains(where: { $0.kind == .sandboxContainers && $0.path == containerDir }))
        #expect(leftovers.contains(where: { $0.kind == .preferences && $0.path == prefFile }))
        #expect(leftovers.contains(where: { $0.kind == .savedState && $0.path == stateDir }))
        #expect(leftovers.contains(where: { $0.kind == .launchAgents && $0.path == agentFile }))
    }

    @Test("UNINST-03: Safety invariants prevent deleting root user directories or protected apps")
    func testSafetyInvariants() {
        let service = AppUninstallerService()
        let home = NSHomeDirectory()

        // Critical user Library directories must be blocked from deletion
        #expect(service.isSafeLeftoverPath("\(home)/Library") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Preferences") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Caches") == false)

        // Valid sub-directories for specific app are allowed
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support/Discord") == true)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Caches/com.tinyspeck.slackmacgap") == true)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Preferences/com.spotify.client.plist") == true)

        // Apple Neural Engine and Steam/Epic game libraries must be protected
        #expect(service.isSafeLeftoverPath("\(home)/Library/Caches/com.apple.e5rt.e5bundlecache") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support/Steam/steamapps/common/Game") == false)
        #expect(service.isSafeLeftoverPath("\(home)/Library/Application Support/Epic Games/Game") == false)

        // Attempting to uninstall a protected system app throws error
        let systemPlan = AppUninstallPlan(
            app: InstalledAppInfo(
                bundlePath: "/System/Applications/Safari.app",
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari",
                version: "18.0",
                appSizeBytes: 10_000_000,
                isSystemApp: true
            ),
            leftovers: []
        )
        #expect(throws: UninstallError.protectedSystemApplication) {
            try service.uninstall(plan: systemPlan)
        }
    }
}
