import Testing
import Foundation
@testable import ZenithCore

@Suite("System Cleaning History Tracker Suite")
struct SystemCleaningHistoryTrackerTests {

    @Test("HIST-01: Records cleaning operations and computes cumulative metrics accurately")
    func testRecordingAndCumulativeMetrics() {
        let testDefaults = UserDefaults(suiteName: "Zenith_Test_History_\(UUID().uuidString)")!
        let tracker = SystemCleaningHistoryTracker(defaults: testDefaults)

        #expect(tracker.totalBytesFreed == 0)
        #expect(tracker.totalSessions == 0)

        // Record operation 1
        tracker.record(operationName: "Developer Package Caches", bytesFreed: 1_000_000_000, itemCount: 5)
        #expect(tracker.totalBytesFreed == 1_000_000_000)
        #expect(tracker.totalSessions == 1)
        #expect(tracker.recentRecords.count == 1)
        #expect(tracker.recentRecords.first?.operationName == "Developer Package Caches")

        // Record operation 2
        tracker.record(operationName: "App Leftovers", bytesFreed: 500_000_000, itemCount: 8)
        #expect(tracker.totalBytesFreed == 1_500_000_000)
        #expect(tracker.totalSessions == 2)
        #expect(tracker.recentRecords.count == 2)
        #expect(tracker.recentRecords.first?.operationName == "App Leftovers")

        // Formatters
        #expect(!tracker.formattedTotalFreed.isEmpty)
        #expect(tracker.summaryHeadline.contains("2 sessions"))
    }

    @Test("HIST-02: Zero byte operations are ignored safely")
    func testZeroByteOperationsIgnored() {
        let testDefaults = UserDefaults(suiteName: "Zenith_Test_History_\(UUID().uuidString)")!
        let tracker = SystemCleaningHistoryTracker(defaults: testDefaults)

        tracker.record(operationName: "No-op", bytesFreed: 0, itemCount: 0)
        #expect(tracker.totalBytesFreed == 0)
        #expect(tracker.totalSessions == 0)
        #expect(tracker.recentRecords.isEmpty)
    }
}
