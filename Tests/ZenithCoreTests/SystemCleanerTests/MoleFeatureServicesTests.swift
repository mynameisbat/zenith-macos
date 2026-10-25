import Testing
import Foundation
@testable import ZenithCore

@Suite("Mole-Inspired System Services Suite")
struct MoleFeatureServicesTests {

    // MARK: - Cleaner Whitelist Service Tests

    @Test("MOLE-01: Whitelist service manages custom paths and statutory protections")
    func testCleanerWhitelistService() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_whitelist_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let whitelist = CleanerWhitelistService(storageURL: tempURL)

        #expect(whitelist.allPaths.isEmpty)

        // Adding paths
        whitelist.addPath("/Users/bat/Projects/secret")
        #expect(whitelist.isWhitelisted(path: "/Users/bat/Projects/secret"))
        #expect(whitelist.isWhitelisted(path: "/Users/bat/Projects/secret/node_modules"))
        #expect(!whitelist.isWhitelisted(path: "/Users/bat/Projects/public"))

        // Statutory protections
        #expect(whitelist.isWhitelisted(path: "/Users/bat/Library/Caches/com.apple.e5rt.e5bundlecache/model.bin"))
        #expect(whitelist.isWhitelisted(path: "/Users/bat/Library/Application Support/Steam/steamapps/common/Game"))
        #expect(whitelist.isWhitelisted(path: "/Users/bat/Library/Application Support/Epic Games/Fortnite"))

        // Removing path
        whitelist.removePath("/Users/bat/Projects/secret")
        #expect(!whitelist.isWhitelisted(path: "/Users/bat/Projects/secret"))
    }

    // MARK: - Installer Purge Service Tests

    @Test("MOLE-02: Installer purge service detects stale installers and respects exclusions")
    func testInstallerPurgeService() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("zenith_test_installers_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dmgFile = tempDir.appendingPathComponent("TestApp.dmg")
        let pkgFile = tempDir.appendingPathComponent("Package.pkg")
        let docFile = tempDir.appendingPathComponent("Notes.txt")

        // Create dummy files with 1KB
        let dummyData = Data(repeating: 0x41, count: 1024)
        try dummyData.write(to: dmgFile)
        try dummyData.write(to: pkgFile)
        try dummyData.write(to: docFile)

        let service = InstallerPurgeService()
        let items = await service.scan(directories: [tempDir], minAgeDays: 0, minSizeBytes: 100)

        #expect(items.count == 2)
        #expect(items.contains(where: { $0.url.lastPathComponent == "TestApp.dmg" }))
        #expect(items.contains(where: { $0.url.lastPathComponent == "Package.pkg" }))
        #expect(!items.contains(where: { $0.url.lastPathComponent == "Notes.txt" }))

        // Purge files directly
        let freed = try await service.purge(items: items, moveToTrash: false)
        #expect(freed >= 2048)
        #expect(!FileManager.default.fileExists(atPath: dmgFile.path))
        #expect(!FileManager.default.fileExists(atPath: pkgFile.path))
        #expect(FileManager.default.fileExists(atPath: docFile.path))
    }

    // MARK: - External Drive Sanitizer Tests

    @Test("MOLE-03: External drive sanitizer removes phantom macOS files and protects user files")
    func testExternalDriveSanitizer() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("zenith_test_extdrive_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dsStore = tempDir.appendingPathComponent(".DS_Store")
        let appleDouble = tempDir.appendingPathComponent("._Vacation.jpg")
        let userPhoto = tempDir.appendingPathComponent("Vacation.jpg")

        let dummyData = Data(repeating: 0x20, count: 512)
        try dummyData.write(to: dsStore)
        try dummyData.write(to: appleDouble)
        try dummyData.write(to: userPhoto)

        let service = ExternalDriveSanitizerService()
        let scanResult = await service.scanVolume(url: tempDir)

        #expect(scanResult.fileCount == 2)
        #expect(scanResult.byteSize == 1024)

        let sanitizeResult = try await service.sanitize(volumeURL: tempDir)
        #expect(sanitizeResult.removedCount == 2)
        #expect(sanitizeResult.freedBytes == 1024)

        #expect(!FileManager.default.fileExists(atPath: dsStore.path))
        #expect(!FileManager.default.fileExists(atPath: appleDouble.path))
        #expect(FileManager.default.fileExists(atPath: userPhoto.path))
    }

    // MARK: - Heavy Storage Insight Service Tests

    @Test("MOLE-04: Heavy storage insight service enumerates system target categories")
    func testHeavyStorageInsightService() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("zenith_test_heavy_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleBackup = tempDir.appendingPathComponent("Snapshot1")
        try FileManager.default.createDirectory(at: sampleBackup, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 4096).write(to: sampleBackup.appendingPathComponent("data.bin"))

        let service = HeavyStorageInsightService()
        let customCategories = await service.scan(
            customTargets: [
                (id: "ios_backups", name: "iOS Device Backups", icon: "iphone.gen3", url: tempDir, subtitle: "Local backups")
            ],
            minSizeBytes: 100
        )

        #expect(customCategories.count == 1)
        #expect(customCategories.first?.id == "ios_backups")
        #expect(customCategories.first?.byteSize == 4096)
        #expect(customCategories.first?.itemCount == 1)

        // Default scan runs without errors
        let defaultCategories = await service.scan()
        #expect(defaultCategories.count >= 0)
    }

    // MARK: - Orphaned App Leftovers Tests

    @Test("MOLE-05: Orphaned app leftovers service detects stranded support folders")
    func testOrphanedAppLeftoversService() async throws {
        let tempParent = FileManager.default.temporaryDirectory.appendingPathComponent("zenith_test_orphans_\(UUID().uuidString)")
        let leftoverDir = tempParent.appendingPathComponent("com.defunct.nonexistentapp")
        try FileManager.default.createDirectory(at: leftoverDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempParent) }

        let sampleFile = leftoverDir.appendingPathComponent("cache.db")
        try Data(repeating: 0x55, count: 2048).write(to: sampleFile)

        let service = OrphanedAppLeftoversService()
        let orphans = await service.scan(locations: [(tempParent, "Test Category")])

        #expect(orphans.count == 1)
        #expect(orphans.first?.appName.lowercased() == "nonexistentapp")
        #expect(orphans.first?.byteSize == 2048)

        let freed = try await service.purge(items: orphans, moveToTrash: false)
        #expect(freed == 2048)
        #expect(!FileManager.default.fileExists(atPath: leftoverDir.path))
    }

    // MARK: - System Optimizer Mole Features Tests

    @Test("MOLE-06: System optimizer zombie cleanup and launch services execute cleanly")
    func testSystemOptimizerZombieAndLaunchServices() async throws {
        let optimizer = SystemOptimizerService()

        // Zombie process cleanup
        let zombieFreed = try optimizer.execute(taskId: .zombieProcessCleanup)
        #expect(zombieFreed >= 0)

        // Launch services rebuild
        let lsFreed = try optimizer.execute(taskId: .launchServicesRebuild)
        #expect(lsFreed >= 0)
    }
}
