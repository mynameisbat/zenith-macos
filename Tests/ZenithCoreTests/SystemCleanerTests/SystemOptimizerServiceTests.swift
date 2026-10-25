import Testing
import Foundation
@testable import ZenithCore

@Suite("System Optimizer & Maintenance Service Suite")
struct SystemOptimizerServiceTests {

    @Test("OPT-01: Scan returns complete set of optimization tasks")
    func testScanReturnsAllCategories() {
        let service = SystemOptimizerService()
        let tasks = service.scan()

        #expect(tasks.count >= 6)
        #expect(tasks.contains(where: { $0.id == .apfsSnapshots }))
        #expect(tasks.contains(where: { $0.id == .orphanLaunchAgents }))
        #expect(tasks.contains(where: { $0.id == .quarantineDatabase }))
        #expect(tasks.contains(where: { $0.id == .preventNetworkDsStore }))
        #expect(tasks.contains(where: { $0.id == .quickLookCacheRefresh }))
        #expect(tasks.contains(where: { $0.id == .dnsCacheFlush }))
    }

    @Test("OPT-02: Orphan LaunchAgent detection correctly flags missing binaries")
    func testOrphanLaunchAgentDetection() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_OrphanAgent_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let service = SystemOptimizerService()

        // 1. Agent pointing to a non-existent binary -> ORPHAN
        let orphanPlist = tempDir.appendingPathComponent("com.test.orphan.plist")
        let orphanDict: [String: Any] = [
            "Label": "com.test.orphan",
            "Program": "/Applications/NonExistentApp.app/Contents/MacOS/Helper"
        ]
        let orphanData = try PropertyListSerialization.data(fromPropertyList: orphanDict, format: .xml, options: 0)
        try orphanData.write(to: orphanPlist)

        #expect(service.isLaunchAgentOrphan(atPath: orphanPlist.path) == true)

        // 2. Agent pointing to a valid binary (e.g. /bin/sh or existing file) -> NOT ORPHAN
        let validPlist = tempDir.appendingPathComponent("com.test.valid.plist")
        let validDict: [String: Any] = [
            "Label": "com.test.valid",
            "Program": "/bin/sh"
        ]
        let validData = try PropertyListSerialization.data(fromPropertyList: validDict, format: .xml, options: 0)
        try validData.write(to: validPlist)

        #expect(service.isLaunchAgentOrphan(atPath: validPlist.path) == false)
    }

    @Test("OPT-03: Quarantine database size inspection returns accurate metrics")
    func testQuarantineDbInspection() throws {
        let fm = FileManager.default
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_Quarantine_Home_\(UUID().uuidString)")
        let prefDir = tempHome.appendingPathComponent("Library/Preferences")
        try fm.createDirectory(at: prefDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let dbPath = prefDir.appendingPathComponent("com.apple.LaunchServices.QuarantineEventsV2")
        let dummyData = Data(repeating: 0x42, count: 4096)
        try dummyData.write(to: dbPath)

        let service = SystemOptimizerService()
        let item = service.scanQuarantineDatabase(home: tempHome.path)

        #expect(item.id == .quarantineDatabase)
        #expect(item.reclaimableBytes == 4096)
        #expect(item.itemCount == 1)
        #expect(item.status == .ready)
    }
}
