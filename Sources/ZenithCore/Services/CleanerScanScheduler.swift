import Foundation
import Combine
import AppKit

// Scheduled scan for the Cleaner: while Zenith is running, look for cleanable files once a day, week or month and
// tell the user when a lot has piled up. It only ever SCANS. Nothing here deletes, trashes or changes a file: removing
// stays behind the user's click on Clean and the confirmation that lists what goes.

// MARK: - Settings

/// How often a scheduled scan runs.
public enum CleanerScanInterval: String, CaseIterable, Sendable, Codable, Identifiable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    /// A fixed length, not a calendar unit: "a month" is 30 days.
    public var seconds: TimeInterval {
        switch self {
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .daily: return String(localized: "Every day")
        case .weekly: return String(localized: "Every week")
        case .monthly: return String(localized: "Every month")
        }
    }
}

/// What the last scheduled scan found.
public struct ScheduledCleanerScanResult: Codable, Sendable, Equatable {
    public let date: Date
    /// What Clean would remove with the scan's default selection (the Trash and Mail attachments are not ticked).
    public let reclaimableBytes: Int64
    public let itemCount: Int

    public init(date: Date, reclaimableBytes: Int64, itemCount: Int) {
        self.date = date
        self.reclaimableBytes = reclaimableBytes
        self.itemCount = itemCount
    }
}

/// The scheduled-scan switch, its interval and what the last scheduled scan found. Saved in `UserDefaults`.
@MainActor
public final class CleanerScanScheduleSettings: ObservableObject {
    public static let shared = CleanerScanScheduleSettings()

    public enum Keys {
        public static let isEnabled = "zenith_cleaner_schedule_enabled"
        public static let interval = "zenith_cleaner_schedule_interval"
        public static let lastResult = "zenith_cleaner_schedule_last_result"
        public static let lastNotifiedBytes = "zenith_cleaner_schedule_last_notified_bytes"
    }

    public static let defaultInterval: CleanerScanInterval = .weekly

    /// Off by default: scanning walks the disk, so the user asks for it.
    @Published public var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published public var interval: CleanerScanInterval {
        didSet { userDefaults.set(interval.rawValue, forKey: Keys.interval) }
    }

    @Published public internal(set) var lastResult: ScheduledCleanerScanResult? {
        didSet {
            if let lastResult, let data = try? JSONEncoder().encode(lastResult) {
                userDefaults.set(data, forKey: Keys.lastResult)
            } else {
                userDefaults.removeObject(forKey: Keys.lastResult)
            }
        }
    }

    /// The size the last notice was about (or the lowest seen since), so the same pile is not announced again.
    @Published public internal(set) var lastNotifiedBytes: Int64? {
        didSet {
            if let lastNotifiedBytes {
                userDefaults.set(lastNotifiedBytes, forKey: Keys.lastNotifiedBytes)
            } else {
                userDefaults.removeObject(forKey: Keys.lastNotifiedBytes)
            }
        }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.interval = (userDefaults.string(forKey: Keys.interval)).flatMap(CleanerScanInterval.init(rawValue:))
            ?? Self.defaultInterval
        self.lastResult = userDefaults.data(forKey: Keys.lastResult)
            .flatMap { try? JSONDecoder().decode(ScheduledCleanerScanResult.self, from: $0) }
        self.lastNotifiedBytes = (userDefaults.object(forKey: Keys.lastNotifiedBytes) as? NSNumber)?.int64Value
    }

    /// Puts the switch and the interval back; what earlier scans found is kept.
    public func resetToDefaults() {
        isEnabled = false
        interval = Self.defaultInterval
    }

    /// When the next scheduled scan is due, or nil when it is off or has never run (it then runs shortly).
    public var nextDueDate: Date? {
        guard isEnabled, let lastResult else { return nil }
        return lastResult.date.addingTimeInterval(interval.seconds)
    }

    // MARK: Text for the Settings tab

    /// "Last scan: yesterday. About 3.20 GB can be cleaned." / "No scheduled scan yet."
    public func lastScanDescription(now: Date) -> String {
        guard let lastResult else { return String(localized: "No scheduled scan yet.") }
        let when = Self.relative(lastResult.date, now: now)
        if lastResult.reclaimableBytes <= 0 {
            return String(localized: "Last scan: \(when). Nothing to clean.")
        }
        let size = SystemCleanerService.formatBytes(lastResult.reclaimableBytes)
        return String(localized: "Last scan: \(when). About \(size) can be cleaned.")
    }

    /// "Next scan: in 6 days." / "Next scan: soon." / "Scanning now…", or nil while scheduled scans are off.
    public func nextScanDescription(now: Date, isScanning: Bool) -> String? {
        guard isEnabled else { return nil }
        if isScanning { return String(localized: "Scanning now…") }
        guard let due = nextDueDate, due > now else { return String(localized: "Next scan: soon.") }
        return String(localized: "Next scan: \(Self.relative(due, now: now)).")
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Decisions (pure)

/// Whether to scan now and when to look again.
public struct CleanerScanDecision: Equatable, Sendable {
    public let scanNow: Bool
    /// When to evaluate again; nil means not at all (scheduled scans are off).
    public let nextCheck: Date?

    public init(scanNow: Bool, nextCheck: Date?) {
        self.scanNow = scanNow
        self.nextCheck = nextCheck
    }
}

/// Whether a finished scan is worth a notice.
public struct CleanerScanNoticeDecision: Equatable, Sendable {
    public let notify: Bool
    /// What to remember as the size already announced (nil once the pile is below the threshold again).
    public let notifiedBytes: Int64?

    public init(notify: Bool, notifiedBytes: Int64?) {
        self.notify = notify
        self.notifiedBytes = notifiedBytes
    }
}

public enum CleanerScanSchedule {
    /// A manual scan, a clean or its confirmation is on screen: look again this much later.
    public static let busyRetryDelay: TimeInterval = 5 * 60
    /// A last-scan date this far in the future means the clock was moved back; the date is not trusted.
    public static let clockSkewTolerance: TimeInterval = 5 * 60
    /// The first check after launch waits this long, so the scan does not compete with startup.
    public static let launchDelay: TimeInterval = 2 * 60
    /// After the Mac wakes, the check waits this long (disks and network settle first).
    public static let wakeDelay: TimeInterval = 60
    /// Below this (1 GB as `formatBytes` counts, 1024³ bytes) a notice is not worth the interruption: caches regrow
    /// by a few hundred MB a week on a normal Mac, and the Settings tab still shows the figure.
    public static let noticeThresholdBytes: Int64 = 1024 * 1024 * 1024

    public static func decide(
        isEnabled: Bool,
        interval: CleanerScanInterval,
        lastScan: Date?,
        now: Date,
        isBusy: Bool
    ) -> CleanerScanDecision {
        guard isEnabled else { return CleanerScanDecision(scanNow: false, nextCheck: nil) }
        let due: Date
        if let lastScan, lastScan <= now.addingTimeInterval(clockSkewTolerance) {
            due = lastScan.addingTimeInterval(interval.seconds)
        } else {
            // Never scanned, or the clock went back past the last scan: scan now and start counting from here.
            due = now
        }
        guard now >= due else { return CleanerScanDecision(scanNow: false, nextCheck: due) }
        if isBusy { return CleanerScanDecision(scanNow: false, nextCheck: now.addingTimeInterval(busyRetryDelay)) }
        return CleanerScanDecision(scanNow: true, nextCheck: now.addingTimeInterval(interval.seconds))
    }

    /// At most one notice per scan, none below the threshold, and none for a pile already announced: a new notice
    /// needs the size to have grown by another threshold since the last one (or to have dropped below it in between).
    public static func notice(
        reclaimableBytes: Int64,
        previouslyNotifiedBytes: Int64?,
        threshold: Int64 = noticeThresholdBytes
    ) -> CleanerScanNoticeDecision {
        guard reclaimableBytes >= threshold else { return CleanerScanNoticeDecision(notify: false, notifiedBytes: nil) }
        guard let previous = previouslyNotifiedBytes else {
            return CleanerScanNoticeDecision(notify: true, notifiedBytes: reclaimableBytes)
        }
        if reclaimableBytes >= previous + threshold {
            return CleanerScanNoticeDecision(notify: true, notifiedBytes: reclaimableBytes)
        }
        // Part of it was cleaned: measure growth from the smaller pile.
        return CleanerScanNoticeDecision(notify: false, notifiedBytes: min(previous, reclaimableBytes))
    }

    /// The notice's title ("About 3.20 GB can be cleaned") and where to act.
    public static func noticeText(reclaimableBytes: Int64) -> (title: String, subtitle: String) {
        let size = SystemCleanerService.formatBytes(reclaimableBytes)
        return (
            String(localized: "About \(size) can be cleaned"),
            String(localized: "Review it in Settings › Cleaner")
        )
    }
}

// MARK: - Scheduler

/// Runs the scheduled scan. One timer for the next due time, plus a check after launch and after wake; never a
/// polling loop. The scan is the Cleaner's own (`SystemCleanerService.scan`) on a separate instance, so the list the
/// user ticks and confirms in Settings or the Command Hub is never replaced behind their back.
@MainActor
public final class CleanerScanScheduler: ObservableObject {
    public static let shared = CleanerScanScheduler()

    /// What a scan found. A scanner only reads the disk.
    public struct Findings: Sendable, Equatable {
        public let reclaimableBytes: Int64
        public let itemCount: Int

        public init(reclaimableBytes: Int64, itemCount: Int) {
            self.reclaimableBytes = reclaimableBytes
            self.itemCount = itemCount
        }
    }

    public typealias Scanner = @MainActor () async -> Findings
    /// Shows a notice: a title and where to act.
    public typealias Notifier = @MainActor (_ title: String, _ subtitle: String) -> Void

    @Published public private(set) var isRunningScheduledScan = false
    /// When the scheduler will evaluate again (nil: not scheduled).
    @Published public private(set) var nextCheckDate: Date?

    public let settings: CleanerScanScheduleSettings
    /// Set by the app to route the notice through the island or the toast.
    public var notifier: Notifier?

    private let scanner: Scanner
    private let isBusy: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let autoSchedule: Bool
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var settingsObservation: AnyCancellable?
    private var isStarted = false

    /// - Parameters:
    ///   - scanner: Reads the disk and reports; the default runs the Cleaner's scan at low priority.
    ///   - isBusy: True while a manual scan, a clean or the clean confirmation is in progress.
    ///   - autoSchedule: False in tests: no timer and no wake observer; call `evaluate()` instead.
    public init(
        settings: CleanerScanScheduleSettings? = nil,
        scanner: Scanner? = nil,
        isBusy: (@MainActor () -> Bool)? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        autoSchedule: Bool = true
    ) {
        self.settings = settings ?? .shared
        self.scanner = scanner ?? Self.liveScanner()
        self.isBusy = isBusy ?? Self.liveIsBusy
        self.now = now
        self.autoSchedule = autoSchedule
    }

    /// The Cleaner's own scan on a fresh instance, at `.utility` priority. It reads sizes and dates only.
    public static func liveScanner(homeDirectory: String? = nil) -> Scanner {
        return {
            let service = SystemCleanerService(homeDirectory: homeDirectory)
            await service.scan(priority: .utility)
            return Findings(reclaimableBytes: service.selectedJunkSize, itemCount: service.selectedItemCount)
        }
    }

    public static func liveIsBusy() -> Bool {
        let cleaner = SystemCleanerService.shared
        return cleaner.isScanning || cleaner.isCleaning || cleaner.showCleanConfirmation
    }

    /// Starts watching: a first check `launchDelay` after launch, a check after each wake, and one when the switch or
    /// the interval changes. Calling it again does nothing.
    public func start(launchDelay: TimeInterval = CleanerScanSchedule.launchDelay) {
        guard !isStarted else { return }
        isStarted = true
        if autoSchedule {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
        }
        // `@Published` sends before the value is stored, so look at the settings on the next turn of the run loop.
        settingsObservation = settings.$isEnabled.combineLatest(settings.$interval)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated { self?.settingsChanged() }
            }
        scheduleCheck(at: now().addingTimeInterval(launchDelay))
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        nextCheckDate = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        settingsObservation = nil
        isStarted = false
    }

    func handleWake() {
        guard settings.isEnabled, !isRunningScheduledScan else { return }
        let soon = now().addingTimeInterval(CleanerScanSchedule.wakeDelay)
        if let next = nextCheckDate, next <= soon { return }
        scheduleCheck(at: soon)
    }

    func settingsChanged() {
        guard !isRunningScheduledScan else { return }
        Task { await self.evaluate() }
    }

    /// Scans if one is due and nothing else is going on, records what it found, tells the user when it is worth it,
    /// and schedules the next check. Returns whether it scanned.
    @discardableResult
    public func evaluate() async -> Bool {
        guard !isRunningScheduledScan else { return false }
        let decision = CleanerScanSchedule.decide(
            isEnabled: settings.isEnabled,
            interval: settings.interval,
            lastScan: settings.lastResult?.date,
            now: now(),
            isBusy: isBusy()
        )
        guard decision.scanNow else {
            scheduleCheck(at: decision.nextCheck)
            return false
        }

        timer?.invalidate()
        timer = nil
        isRunningScheduledScan = true
        let findings = await scanner()
        isRunningScheduledScan = false

        guard settings.isEnabled else {
            scheduleCheck(at: nil)
            return false
        }
        // A clean that started meanwhile makes the figures stale: drop them and look again later.
        if isBusy() {
            scheduleCheck(at: now().addingTimeInterval(CleanerScanSchedule.busyRetryDelay))
            return false
        }

        let result = ScheduledCleanerScanResult(
            date: now(),
            reclaimableBytes: findings.reclaimableBytes,
            itemCount: findings.itemCount
        )
        settings.lastResult = result
        let notice = CleanerScanSchedule.notice(
            reclaimableBytes: result.reclaimableBytes,
            previouslyNotifiedBytes: settings.lastNotifiedBytes
        )
        settings.lastNotifiedBytes = notice.notifiedBytes
        if notice.notify {
            let text = CleanerScanSchedule.noticeText(reclaimableBytes: result.reclaimableBytes)
            notifier?(text.title, text.subtitle)
        }
        scheduleCheck(at: result.date.addingTimeInterval(settings.interval.seconds))
        return true
    }

    private func scheduleCheck(at date: Date?) {
        timer?.invalidate()
        timer = nil
        nextCheckDate = date
        guard autoSchedule, isStarted, let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        // A scheduled scan need not be punctual; let the system group the wake-up with others.
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
