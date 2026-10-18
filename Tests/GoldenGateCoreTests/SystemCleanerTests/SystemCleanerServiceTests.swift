import Testing
import Foundation
import AppKit
@testable import GoldenGateCore

@Suite("System Cleaner Service & Models Test Suite")
struct SystemCleanerServiceTests {

    // MARK: - Byte Formatting Tests

    @Test("CLN-01: formatBytes formats various scales correctly")
    func testFormatBytes() {
        #expect(SystemCleanerService.formatBytes(0) == "0 B")
        #expect(SystemCleanerService.formatBytes(512) == "512 B")
        #expect(SystemCleanerService.formatBytes(1023) == "1023 B")
        #expect(SystemCleanerService.formatBytes(1024) == "1.0 KB")
        #expect(SystemCleanerService.formatBytes(1536) == "1.5 KB")
        #expect(SystemCleanerService.formatBytes(1024 * 1024) == "1.0 MB")
        #expect(SystemCleanerService.formatBytes(1024 * 1024 * 50) == "50.0 MB")
        #expect(SystemCleanerService.formatBytes(1024 * 1024 * 1024) == "1.00 GB")
        #expect(SystemCleanerService.formatBytes(Int64(3.45 * 1024 * 1024 * 1024)) == "3.45 GB")
    }

    // MARK: - JunkItem Model Tests

    @Test("CLN-02: JunkItem properties and formatted size")
    func testJunkItem() {
        let item = JunkItem(name: "DerivedData_App1", path: "/tmp/DerivedData_App1", size: 1024 * 1024 * 12)
        #expect(item.name == "DerivedData_App1")
        #expect(item.path == "/tmp/DerivedData_App1")
        #expect(item.size == 1024 * 1024 * 12)
        #expect(item.isSelected == true)
        #expect(item.formattedSize == "12.0 MB")
    }

    // MARK: - JunkCategory Model Tests

    @Test("CLN-03: JunkCategory calculations and selection aggregation")
    func testJunkCategory() {
        let item1 = JunkItem(name: "Item1", path: "/tmp/i1", size: 1024 * 1024 * 10, isSelected: true)
        let item2 = JunkItem(name: "Item2", path: "/tmp/i2", size: 1024 * 1024 * 20, isSelected: false)
        let item3 = JunkItem(name: "Item3", path: "/tmp/i3", size: 1024 * 1024 * 30, isSelected: true)

        let category = JunkCategory(
            id: "cat_test",
            title: "Test Category",
            description: "Test description",
            icon: "trash",
            items: [item1, item2, item3],
            isSelected: true,
            isExpanded: false
        )

        #expect(category.totalSize == 1024 * 1024 * 60)
        #expect(category.selectedSize == 1024 * 1024 * 40)
        #expect(category.formattedTotalSize == "60.0 MB")
        #expect(category.formattedSelectedSize == "40.0 MB")
    }

    // MARK: - DiskSpaceInfo Telemetry Tests

    @Test("CLN-04: DiskSpaceInfo calculation and percentage")
    func testDiskSpaceInfo() {
        let total: Int64 = 500 * 1024 * 1024 * 1024 // 500 GB
        let free: Int64 = 200 * 1024 * 1024 * 1024  // 200 GB
        let used = total - free                     // 300 GB

        let disk = DiskSpaceInfo(totalBytes: total, freeBytes: free, usedBytes: used)
        #expect(disk.usedPercentage == 0.6)
        #expect(disk.formattedTotal == "500.00 GB")
        #expect(disk.formattedFree == "200.00 GB")
        #expect(disk.formattedUsed == "300.00 GB")
    }

    // MARK: - Service State Management & Toggles

    @Test("CLN-05: SystemCleanerService toggles and selection actions")
    @MainActor
    func testServiceSelectionAndToggles() {
        let service = SystemCleanerService()

        let item1 = JunkItem(name: "FileA", path: "/tmp/FileA", size: 1000, isSelected: true)
        let item2 = JunkItem(name: "FileB", path: "/tmp/FileB", size: 2000, isSelected: true)
        let item3 = JunkItem(name: "FileC", path: "/tmp/FileC", size: 3000, isSelected: true)

        let cat1 = JunkCategory(
            id: "cat1",
            title: "Cat 1",
            description: "Desc 1",
            icon: "folder",
            items: [item1, item2],
            isSelected: true,
            isExpanded: false
        )
        let cat2 = JunkCategory(
            id: "cat2",
            title: "Cat 2",
            description: "Desc 2",
            icon: "doc",
            items: [item3],
            isSelected: true,
            isExpanded: false
        )

        service.categories = [cat1, cat2]

        #expect(service.totalJunkSize == 6000)
        #expect(service.selectedJunkSize == 6000)
        #expect(service.totalItemCount == 3)
        #expect(service.selectedItemCount == 3)

        // Toggle single item
        service.toggleItem(categoryId: "cat1", itemId: item1.id)
        #expect(service.selectedJunkSize == 5000)
        #expect(service.selectedItemCount == 2)
        #expect(service.categories[0].isSelected == true) // still has item2

        // Toggle category expansion
        #expect(service.categories[0].isExpanded == false)
        service.toggleCategoryExpansion(id: "cat1")
        #expect(service.categories[0].isExpanded == true)

        // Toggle category selection off
        service.toggleCategory(id: "cat1")
        #expect(service.categories[0].isSelected == false)
        #expect(service.categories[0].items.allSatisfy { !$0.isSelected })
        #expect(service.selectedJunkSize == 3000)

        // Select All false
        service.selectAll(false)
        #expect(service.selectedJunkSize == 0)
        #expect(service.selectedItemCount == 0)
        #expect(service.categories.allSatisfy { !$0.isSelected })

        // Select All true
        service.selectAll(true)
        #expect(service.selectedJunkSize == 6000)
        #expect(service.selectedItemCount == 3)
        #expect(service.categories.allSatisfy { $0.isSelected })
    }

    // MARK: - Directory Size Calculation Tests

    @Test("CLN-06: calculateSize computes recursive directory size accurately")
    func testCalculateDirectorySize() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GG_CleanerTest_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDir)
        }

        let file1 = tempDir.appendingPathComponent("file1.bin")
        let file2 = tempDir.appendingPathComponent("subdir").appendingPathComponent("file2.bin")
        try fm.createDirectory(at: file2.deletingLastPathComponent(), withIntermediateDirectories: true)

        let data1 = Data(repeating: 0xAA, count: 5000)
        let data2 = Data(repeating: 0xBB, count: 3500)
        try data1.write(to: file1)
        try data2.write(to: file2)

        let calculatedSize = SystemCleanerService.calculateSize(of: tempDir.path, fileManager: fm)
        // Calculated size should be at least total uncompressed bytes
        #expect(calculatedSize >= 8500)
    }

    // MARK: - Symlink and Path Safety Tests (CRIT-02, CRIT-03, HIGH-10)

    @Test("CLN-07: calculateSize skips symbolic links and prevents symlink recursion")
    func testCalculateSizeSkipsSymbolicLinks() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GG_CleanerSymlinkTest_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDir)
        }

        // Real target file outside or inside
        let targetFile = tempDir.appendingPathComponent("target.bin")
        let data = Data(repeating: 0x55, count: 10_000)
        try data.write(to: targetFile)

        // Subdirectory containing symlink to targetFile
        let subDir = tempDir.appendingPathComponent("scanned_folder")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

        let symlinkPath = subDir.appendingPathComponent("link_to_target.bin")
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: targetFile)

        // Subdirectory size must be 0 because the only item is a symlink (which must be skipped)
        let subDirSize = SystemCleanerService.calculateSize(of: subDir.path, fileManager: fm)
        #expect(subDirSize == 0)

        // Also if path itself is a symlink to targetFile, calculateSize returns 0
        let directSymlinkSize = SystemCleanerService.calculateSize(of: symlinkPath.path, fileManager: fm)
        #expect(directSymlinkSize == 0)
    }

    @Test("CLN-08: isPathSafeForDeletion strictly validates boundaries and blocks traversal (CRIT-02, CRIT-03)")
    func testIsPathSafeForDeletionBoundariesAndTraversal() {
        let home = "/Users/testuser"

        // Safe junk paths inside approved directories
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.example.app/Cache.db", home: home) == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Developer/Xcode/DerivedData/MyApp-abcd/Build", home: home) == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Developer/Xcode/iOS DeviceSupport/17.0/Symbols", home: home) == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Logs/DiagnosticReports/crash.ips", home: home) == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/.Trash/old_file.txt", home: home) == true)

        // Candidate EQUAL to safe root itself must be BLOCKED
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/.Trash", home: home) == false)

        // Protected system roots must be BLOCKED
        #expect(SystemCleanerService.isPathSafeForDeletion(home, home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Documents", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Desktop", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Downloads", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("/", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("/System", home: home) == false)

        // Traversal attempts with relative segments (..) resolving outside must be BLOCKED
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/../../Documents/Secret.txt", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/../..", home: home) == false)
    }

    @Test("CLN-09: Protected system bundles are blacklisted from cache deletion (HIGH-10)")
    func testProtectedBundleBlacklisting() {
        let home = "/Users/testuser"

        // Safari browser sessions, sub-bundles, and caches
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "com.apple.Safari") == true)
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "COM.APPLE.SAFARI") == true)
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "com.apple.Safari.SafeBrowsing") == true)
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "\(home)/Library/Caches/com.apple.Safari.SafeBrowsing") == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.Safari", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.Safari/Cache.db", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.Safari.SafeBrowsing", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.Safari.SafeBrowsing/Cache.db", home: home) == false)

        // CloudKit & Apple ID accounts
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "com.apple.CloudKit") == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.CloudKit", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.CloudKit.metadata", home: home) == false)
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "com.apple.akd") == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.akd", home: home) == false)

        // Spotlight & HomeKit
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "com.apple.Spotlight") == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.Spotlight", home: home) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.apple.HomeKit", home: home) == false)

        // Standard 3rd party apps must NOT be blocked
        #expect(SystemCleanerService.isProtectedBundle(nameOrPath: "com.google.Chrome") == false)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/com.google.Chrome/data", home: home) == true)
    }

    @Test("CLN-10: SensitivePasteboardMarker extended UTI and case-insensitive matching (HIGH-07)")
    func testSensitivePasteboardMarkerExtendedAndCaseInsensitive() {
        // Extended password manager types
        #expect(SensitivePasteboardMarker.containsSensitiveType(in: [NSPasteboard.PasteboardType("de.keepassxc.keepassxc")]) == true)
        #expect(SensitivePasteboardMarker.containsSensitiveType(in: [NSPasteboard.PasteboardType("com.bitwarden.desktop")]) == true)
        #expect(SensitivePasteboardMarker.containsSensitiveType(in: [NSPasteboard.PasteboardType("org.keepassxc.keepassxc")]) == true)
        #expect(SensitivePasteboardMarker.isSensitive(type: "com.bitwarden.clipmarker") == true)
        #expect(SensitivePasteboardMarker.isSensitive(type: "org.macpassapp.macpass") == true)
        #expect(SensitivePasteboardMarker.isSensitive(type: "in.sinew.enpass-desktop") == true)
        #expect(SensitivePasteboardMarker.isSensitive(type: "application/x-nspasteboard-concealed-type") == true)

        // Case-insensitive and whitespace-tolerant normalization
        #expect(SensitivePasteboardMarker.containsSensitiveType(in: [NSPasteboard.PasteboardType("ORG.NSPASTEBOARD.CONCEALEDTYPE")]) == true)
        #expect(SensitivePasteboardMarker.containsSensitiveType(in: [NSPasteboard.PasteboardType("COM.BITWARDEN.DESKTOP")]) == true)
        #expect(SensitivePasteboardMarker.containsSensitiveType(in: [NSPasteboard.PasteboardType("De.KeePassXC.keepassxc")]) == true)
        #expect(SensitivePasteboardMarker.isSensitive(type: "  COM.BITWARDEN.CLIPMARKER  ") == true)

        // String overload
        #expect(SensitivePasteboardMarker.isSensitive(types: ["org.nspasteboard.transienttype"]) == true)
        #expect(SensitivePasteboardMarker.isSensitive(types: ["public.utf8-plain-text"]) == false)

        // Backward compatibility invariant: sensitiveTypes is [String] and strictly count == 10
        let origTypes: [String] = SensitivePasteboardMarker.sensitiveTypes
        #expect(origTypes.count == 10)
        #expect(SensitivePasteboardMarker.allMarkers.count == 10)
    }
}
