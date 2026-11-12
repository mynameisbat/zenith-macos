import Testing
import Foundation
@testable import ZenithCore

/// The Cleaner's scheduled scan: when it runs, what it records, when it speaks up, and that it never deletes.
@Suite("Cleaner Scheduled Scan")
@MainActor
struct CleanerScanSchedulerTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let gb: Int64 = 1024 * 1024 * 1024
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A clock tests move by hand.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// Mutable test state read by the scheduler's (sendable, main-actor) closures.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeSettings(_ name: String = UUID().uuidString) throws -> (CleanerScanScheduleSettings, UserDefaults) {
        let defaults = try #require(TestDefaults.make("cleaner.schedule.\(name)"))
        return (CleanerScanScheduleSettings(userDefaults: defaults), defaults)
    }

    // MARK: - Due / not due

    @Test("SCH-01: Off never scans and schedules nothing, whatever the dates")
    func testDecisionOff() {
        for last in [nil, t0, t0.addingTimeInterval(-400 * day)] as [Date?] {
            let decision = CleanerScanSchedule.decide(isEnabled: false, interval: .daily, lastScan: last, now: t0, isBusy: false)
            #expect(decision == CleanerScanDecision(scanNow: false, nextCheck: nil))
        }
    }

    @Test("SCH-02: Never scanned scans now; the next check is one interval on")
    func testDecisionNeverScanned() {
        for interval in CleanerScanInterval.allCases {
            let decision = CleanerScanSchedule.decide(isEnabled: true, interval: interval, lastScan: nil, now: t0, isBusy: false)
            #expect(decision == CleanerScanDecision(scanNow: true, nextCheck: t0.addingTimeInterval(interval.seconds)))
        }
    }

    @Test("SCH-03: Just scanned waits until last scan + interval, for each interval")
    func testDecisionJustScanned() {
        for interval in CleanerScanInterval.allCases {
            let last = t0.addingTimeInterval(-60)
            let decision = CleanerScanSchedule.decide(isEnabled: true, interval: interval, lastScan: last, now: t0, isBusy: false)
            #expect(decision == CleanerScanDecision(scanNow: false, nextCheck: last.addingTimeInterval(interval.seconds)))
            // One second before it is due: still waiting.
            let almost = last.addingTimeInterval(interval.seconds - 1)
            #expect(!CleanerScanSchedule.decide(isEnabled: true, interval: interval, lastScan: last, now: almost, isBusy: false).scanNow)
        }
    }

    @Test("SCH-04: Due exactly, or overdue (a Mac asleep for weeks), scans once now")
    func testDecisionOverdue() {
        for interval in CleanerScanInterval.allCases {
            let exactlyDue = CleanerScanSchedule.decide(
                isEnabled: true, interval: interval, lastScan: t0.addingTimeInterval(-interval.seconds), now: t0, isBusy: false
            )
            #expect(exactlyDue == CleanerScanDecision(scanNow: true, nextCheck: t0.addingTimeInterval(interval.seconds)))
            let longOverdue = CleanerScanSchedule.decide(
                isEnabled: true, interval: interval, lastScan: t0.addingTimeInterval(-10 * interval.seconds), now: t0, isBusy: false
            )
            #expect(longOverdue == CleanerScanDecision(scanNow: true, nextCheck: t0.addingTimeInterval(interval.seconds)))
        }
    }

    @Test("SCH-05: Clock moved back past the last scan: the date is not trusted and it scans now")
    func testDecisionClockMovedBack() {
        let future = t0.addingTimeInterval(3 * day)
        let decision = CleanerScanSchedule.decide(isEnabled: true, interval: .weekly, lastScan: future, now: t0, isBusy: false)
        #expect(decision == CleanerScanDecision(scanNow: true, nextCheck: t0.addingTimeInterval(CleanerScanInterval.weekly.seconds)))
        // A last scan a minute "ahead" (clock drift) is within tolerance: not due.
        let drift = t0.addingTimeInterval(60)
        #expect(!CleanerScanSchedule.decide(isEnabled: true, interval: .daily, lastScan: drift, now: t0, isBusy: false).scanNow)
    }

    @Test("SCH-06: Due while busy waits a few minutes instead of scanning")
    func testDecisionBusy() {
        let decision = CleanerScanSchedule.decide(isEnabled: true, interval: .daily, lastScan: nil, now: t0, isBusy: true)
        #expect(decision == CleanerScanDecision(scanNow: false, nextCheck: t0.addingTimeInterval(CleanerScanSchedule.busyRetryDelay)))
        // Not due and busy: the due date wins.
        let last = t0.addingTimeInterval(-60)
        let notDue = CleanerScanSchedule.decide(isEnabled: true, interval: .daily, lastScan: last, now: t0, isBusy: true)
        #expect(notDue == CleanerScanDecision(scanNow: false, nextCheck: last.addingTimeInterval(day)))
    }

    @Test("SCH-07: Intervals are a day, a week and 30 days")
    func testIntervals() {
        #expect(CleanerScanInterval.daily.seconds == day)
        #expect(CleanerScanInterval.weekly.seconds == 7 * day)
        #expect(CleanerScanInterval.monthly.seconds == 30 * day)
    }

    // MARK: - Scheduler

    @Test("SCH-08: The scheduler scans when due, records it, and does not scan again within the interval")
    func testSchedulerScansOncePerInterval() async throws {
        let (settings, _) = try makeSettings()
        settings.isEnabled = true
        settings.interval = .daily
        let clock = Clock(t0)
        var scans = 0
        let scheduler = CleanerScanScheduler(
            settings: settings,
            scanner: { scans += 1; return .init(reclaimableBytes: 5 * self.gb, itemCount: 3) },
            isBusy: { false },
            now: { clock.now },
            autoSchedule: false
        )

        #expect(await scheduler.evaluate())
        #expect(scans == 1)
        #expect(settings.lastResult == ScheduledCleanerScanResult(date: t0, reclaimableBytes: 5 * gb, itemCount: 3))
        #expect(scheduler.nextCheckDate == t0.addingTimeInterval(day))

        clock.now = t0.addingTimeInterval(day - 60)
        #expect(await scheduler.evaluate() == false)
        #expect(scans == 1)

        clock.now = t0.addingTimeInterval(day + 1)
        #expect(await scheduler.evaluate())
        #expect(scans == 2)
    }

    @Test("SCH-09: No scheduled scan while a manual scan or a clean is in progress, nor while off")
    func testSchedulerSkipsWhileBusy() async throws {
        let (settings, _) = try makeSettings()
        settings.isEnabled = true
        let busy = Box(true)
        var scans = 0
        let scheduler = CleanerScanScheduler(
            settings: settings,
            scanner: { scans += 1; return .init(reclaimableBytes: 0, itemCount: 0) },
            isBusy: { busy.value },
            now: { self.t0 },
            autoSchedule: false
        )
        #expect(await scheduler.evaluate() == false)
        #expect(scans == 0)
        #expect(scheduler.nextCheckDate == t0.addingTimeInterval(CleanerScanSchedule.busyRetryDelay))

        settings.isEnabled = false
        busy.value = false
        #expect(await scheduler.evaluate() == false)
        #expect(scans == 0)
        #expect(scheduler.nextCheckDate == nil)
    }

    @Test("SCH-10: A clean that starts during the scheduled scan makes its figures stale: they are dropped")
    func testSchedulerDropsResultWhenCleanStartedMeanwhile() async throws {
        let (settings, _) = try makeSettings()
        settings.isEnabled = true
        var busy = false
        var notices = 0
        let scheduler = CleanerScanScheduler(
            settings: settings,
            scanner: { busy = true; return .init(reclaimableBytes: 9 * self.gb, itemCount: 1) },
            isBusy: { busy },
            now: { self.t0 },
            autoSchedule: false
        )
        scheduler.notifier = { _, _ in notices += 1 }
        #expect(await scheduler.evaluate() == false)
        #expect(settings.lastResult == nil)
        #expect(notices == 0)
    }

    @Test("SCH-11: At most one notice per scan, none below the threshold, none for the same pile twice")
    func testSchedulerNotices() async throws {
        let (settings, _) = try makeSettings()
        settings.isEnabled = true
        settings.interval = .daily
        let clock = Clock(t0)
        let found = Box<Int64>(3 * gb)
        var notices: [(String, String)] = []
        let scheduler = CleanerScanScheduler(
            settings: settings,
            scanner: { .init(reclaimableBytes: found.value, itemCount: 4) },
            isBusy: { false },
            now: { clock.now },
            autoSchedule: false
        )
        scheduler.notifier = { notices.append(($0, $1)) }

        // 1. 3 GB: one notice naming the size and where to act.
        #expect(await scheduler.evaluate())
        #expect(notices.count == 1)
        #expect(notices.first?.0.contains(SystemCleanerService.formatBytes(3 * gb)) == true)
        #expect(notices.first?.1.contains("Cleaner") == true)

        // 2. Same pile a day later (and evaluating twice without a new scan): no new notice.
        clock.now = clock.now.addingTimeInterval(day)
        #expect(await scheduler.evaluate())
        #expect(await scheduler.evaluate() == false)
        #expect(notices.count == 1)

        // 3. Grew by less than the threshold: still quiet.
        found.value = 3 * gb + gb / 2
        clock.now = clock.now.addingTimeInterval(day)
        #expect(await scheduler.evaluate())
        #expect(notices.count == 1)

        // 4. Grew by another threshold: told again, once.
        found.value = 4 * gb + 1
        clock.now = clock.now.addingTimeInterval(day)
        #expect(await scheduler.evaluate())
        #expect(notices.count == 2)

        // 5. Cleaned below the threshold: no notice, and the memory is reset...
        found.value = 200 * 1024 * 1024
        clock.now = clock.now.addingTimeInterval(day)
        #expect(await scheduler.evaluate())
        #expect(notices.count == 2)
        #expect(settings.lastNotifiedBytes == nil)

        // 6. ...so a new pile above it is announced.
        found.value = 2 * gb
        clock.now = clock.now.addingTimeInterval(day)
        #expect(await scheduler.evaluate())
        #expect(notices.count == 3)
    }

    @Test("SCH-12: Notice rule as a table")
    func testNoticeRule() {
        let t = CleanerScanSchedule.noticeThresholdBytes
        #expect(t == gb)
        #expect(CleanerScanSchedule.notice(reclaimableBytes: t - 1, previouslyNotifiedBytes: nil) == .init(notify: false, notifiedBytes: nil))
        #expect(CleanerScanSchedule.notice(reclaimableBytes: t, previouslyNotifiedBytes: nil) == .init(notify: true, notifiedBytes: t))
        #expect(CleanerScanSchedule.notice(reclaimableBytes: 0, previouslyNotifiedBytes: 5 * t) == .init(notify: false, notifiedBytes: nil))
        // Partly cleaned (5 → 2): quiet, and growth now counts from 2.
        #expect(CleanerScanSchedule.notice(reclaimableBytes: 2 * t, previouslyNotifiedBytes: 5 * t) == .init(notify: false, notifiedBytes: 2 * t))
        #expect(CleanerScanSchedule.notice(reclaimableBytes: 3 * t, previouslyNotifiedBytes: 2 * t) == .init(notify: true, notifiedBytes: 3 * t))
    }

    // MARK: - Persistence

    @Test("SCH-13: Switch, interval, last result and notice memory survive a reload; defaults are off and weekly")
    func testPersistence() throws {
        let name = UUID().uuidString
        let (settings, defaults) = try makeSettings(name)
        #expect(settings.isEnabled == false)
        #expect(settings.interval == .weekly)
        #expect(settings.lastResult == nil)

        settings.isEnabled = true
        settings.interval = .monthly
        let result = ScheduledCleanerScanResult(date: t0, reclaimableBytes: 7 * gb, itemCount: 12)
        settings.lastResult = result
        settings.lastNotifiedBytes = 7 * gb

        let reloaded = CleanerScanScheduleSettings(userDefaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.interval == .monthly)
        #expect(reloaded.lastResult == result)
        #expect(reloaded.lastNotifiedBytes == 7 * gb)
        #expect(reloaded.nextDueDate == t0.addingTimeInterval(30 * day))

        reloaded.resetToDefaults()
        let again = CleanerScanScheduleSettings(userDefaults: defaults)
        #expect(again.isEnabled == false)
        #expect(again.interval == .weekly)
        #expect(again.lastResult == result, "resetting the switch keeps what earlier scans found")
    }

    @Test("SCH-14: Settings text names the size with formatBytes and says when the next scan is due")
    func testDescriptions() throws {
        let (settings, _) = try makeSettings()
        #expect(settings.nextScanDescription(now: t0, isScanning: false) == nil)
        #expect(!settings.lastScanDescription(now: t0).isEmpty)

        settings.isEnabled = true
        #expect(settings.nextScanDescription(now: t0, isScanning: false) != nil)
        settings.lastResult = ScheduledCleanerScanResult(date: t0, reclaimableBytes: 3 * gb + gb / 5, itemCount: 2)
        #expect(settings.lastScanDescription(now: t0.addingTimeInterval(60)).contains(SystemCleanerService.formatBytes(3 * gb + gb / 5)))
        let next = try #require(settings.nextScanDescription(now: t0, isScanning: false))
        #expect(next != settings.nextScanDescription(now: t0, isScanning: true))
    }

    // MARK: - Read-only proof

    @Test("SCH-15: A scheduled scan with the real Cleaner scan on a throwaway home finds the junk and deletes nothing")
    func testScheduledScanIsReadOnly() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_ScheduledScan_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let files = [
            "Library/Caches/com.example.app/blob",
            "Library/Developer/Xcode/DerivedData/App-abc/Build/out.o",
            "Library/Logs/Example/app.log",
            ".npm/_cacache/content/blob",
            ".Trash/old.txt",
            "Downloads/movie.mp4.crdownload",
            "Documents/keep.txt"
        ]
        var before: [String: Data] = [:]
        for (index, path) in files.enumerated() {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(repeating: UInt8(65 + index), count: 300_000)
            try data.write(to: url)
            before[path] = data
        }
        // An abandoned download, old enough to be offered.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * day)],
            ofItemAtPath: home.appendingPathComponent("Downloads/movie.mp4.crdownload").path
        )
        let snapshotBefore = try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted()

        let (settings, _) = try makeSettings()
        settings.isEnabled = true
        var notices = 0
        let scheduler = CleanerScanScheduler(
            settings: settings,
            scanner: CleanerScanScheduler.liveScanner(homeDirectory: home.path),
            isBusy: { false },
            autoSchedule: false
        )
        scheduler.notifier = { _, _ in notices += 1 }
        #expect(await scheduler.evaluate())

        let result = try #require(settings.lastResult)
        #expect(result.reclaimableBytes >= 4 * 300_000, "found \(result.reclaimableBytes)")
        #expect(result.itemCount >= 4)
        #expect(notices == 0, "well below the 1 GB threshold")

        // Every file and folder is still there, unchanged.
        #expect(try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted() == snapshotBefore)
        for (path, data) in before {
            #expect(try Data(contentsOf: home.appendingPathComponent(path)) == data, "\(path) changed")
        }
    }
}
