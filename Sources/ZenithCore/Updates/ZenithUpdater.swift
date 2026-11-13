import Foundation
import Combine
import AppKit

// Checking for a new Zenith and installing it. Checking is automatic (once a day while Zenith runs, on by default)
// or manual; installing only ever starts from the user's click and a confirmation, and never relaunches by itself:
// the app does that after `install` returns (see `UpdateController` in the app target).

// MARK: - Settings

/// The automatic-check switch, when the last check succeeded, and the last version the user was told about.
@MainActor
public final class UpdateSettings: ObservableObject {
    public static let shared = UpdateSettings()

    public enum Keys {
        public static let checksAutomatically = "zenith_updates_check_automatically"
        public static let lastCheckDate = "zenith_updates_last_check"
        public static let lastNotifiedVersion = "zenith_updates_last_notified_version"
    }

    /// On by default: the owner decided a daily check is what users expect.
    @Published public var checksAutomatically: Bool {
        didSet { userDefaults.set(checksAutomatically, forKey: Keys.checksAutomatically) }
    }

    @Published public internal(set) var lastCheckDate: Date? {
        didSet { userDefaults.set(lastCheckDate, forKey: Keys.lastCheckDate) }
    }

    /// The newest version a notice was shown for, so the same version is announced once.
    @Published public internal(set) var lastNotifiedVersion: String? {
        didSet { userDefaults.set(lastNotifiedVersion, forKey: Keys.lastNotifiedVersion) }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.checksAutomatically = userDefaults.object(forKey: Keys.checksAutomatically) as? Bool ?? true
        self.lastCheckDate = userDefaults.object(forKey: Keys.lastCheckDate) as? Date
        self.lastNotifiedVersion = userDefaults.string(forKey: Keys.lastNotifiedVersion)
    }

    public func resetToDefaults() {
        checksAutomatically = true
    }
}

// MARK: - Decisions (pure)

public struct UpdateCheckDecision: Equatable, Sendable {
    public let checkNow: Bool
    /// When to evaluate again; nil means not at all (automatic checks are off).
    public let nextCheck: Date?

    public init(checkNow: Bool, nextCheck: Date?) {
        self.checkNow = checkNow
        self.nextCheck = nextCheck
    }
}

public enum UpdateCheckSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60
    /// A failed automatic check (offline, rate limited) is tried again this much later, not a day later.
    public static let failureRetryDelay: TimeInterval = 60 * 60
    public static let launchDelay: TimeInterval = 3 * 60
    public static let wakeDelay: TimeInterval = 2 * 60
    /// A last-check date this far in the future means the clock went back; it is not trusted.
    public static let clockSkewTolerance: TimeInterval = 5 * 60

    public static func decide(isEnabled: Bool, lastSuccessfulCheck: Date?, lastFailedAttempt: Date?, now: Date) -> UpdateCheckDecision {
        guard isEnabled else { return UpdateCheckDecision(checkNow: false, nextCheck: nil) }
        let tolerance = now.addingTimeInterval(clockSkewTolerance)
        var due = now
        if let last = lastSuccessfulCheck, last <= tolerance {
            due = last.addingTimeInterval(interval)
        }
        if let failed = lastFailedAttempt, failed <= tolerance {
            due = max(due, failed.addingTimeInterval(failureRetryDelay))
        }
        guard now >= due else { return UpdateCheckDecision(checkNow: false, nextCheck: due) }
        return UpdateCheckDecision(checkNow: true, nextCheck: now.addingTimeInterval(interval))
    }

    /// One notice per version: only for a version newer than the running one and newer than the last one announced.
    public static func shouldNotify(about version: AppVersion, running: AppVersion, lastNotified: String?) -> Bool {
        guard version > running else { return false }
        guard let lastNotified, let previous = AppVersion(lastNotified) else { return true }
        return version > previous
    }

    public static func noticeText(for version: AppVersion) -> (title: String, subtitle: String) {
        (
            String(localized: "Zenith \(version.description) is available"),
            String(localized: "Open Settings › General to install it")
        )
    }
}

// MARK: - Updater

@MainActor
public final class ZenithUpdater: ObservableObject {
    public static let shared = ZenithUpdater()

    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double?)
        case verifying
        case installing
        /// The new version is in place; the app is about to quit and reopen.
        case installed
        /// Saved for the user to install by hand.
        case downloaded(URL)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var availableRelease: UpdateRelease?
    /// Why Zenith will not replace itself for `availableRelease` (then the Download button is offered).
    @Published public private(set) var installRefusal: UpdateInstallRefusal?
    /// The last failure of something the user asked for; automatic checks fail silently.
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var nextCheckDate: Date?

    public let settings: UpdateSettings
    public let runningVersion: AppVersion
    /// Set by the app to route a notice through the island or the toast.
    public var notifier: (@MainActor (_ title: String, _ subtitle: String) -> Void)?

    private let feed: UpdateFeed
    private let installer: UpdateInstalling
    private let now: @MainActor () -> Date
    private let autoSchedule: Bool
    private var lastFailedAttempt: Date?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var settingsObservation: AnyCancellable?
    private var isStarted = false

    /// - Parameter autoSchedule: false in tests and for screenshots: no timer, no wake observer.
    public init(
        settings: UpdateSettings? = nil,
        feed: UpdateFeed = GitHubUpdateFeed(),
        installer: UpdateInstalling = UpdateInstaller(),
        runningVersion: AppVersion = .running,
        now: @escaping @MainActor () -> Date = { Date() },
        autoSchedule: Bool = true
    ) {
        self.settings = settings ?? .shared
        self.feed = feed
        self.installer = installer
        self.runningVersion = runningVersion
        self.now = now
        self.autoSchedule = autoSchedule
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing, .installed: return true
        default: return false
        }
    }

    // MARK: Scheduling

    /// A first check `launchDelay` after launch, one after each wake, and one when the switch is turned on. No polling.
    public func start(launchDelay: TimeInterval = UpdateCheckSchedule.launchDelay) {
        guard !isStarted else { return }
        isStarted = true
        if autoSchedule {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
        }
        settingsObservation = settings.$checksAutomatically
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.evaluate() }
                }
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
        guard settings.checksAutomatically else { return }
        let soon = now().addingTimeInterval(UpdateCheckSchedule.wakeDelay)
        if let next = nextCheckDate, next <= soon { return }
        scheduleCheck(at: soon)
    }

    /// The automatic check: runs only when due, says nothing when it fails, and tells the user once per version.
    @discardableResult
    public func evaluate() async -> Bool {
        let decision = UpdateCheckSchedule.decide(
            isEnabled: settings.checksAutomatically,
            lastSuccessfulCheck: settings.lastCheckDate,
            lastFailedAttempt: lastFailedAttempt,
            now: now()
        )
        guard decision.checkNow, !isBusy else {
            scheduleCheck(at: decision.checkNow ? now().addingTimeInterval(UpdateCheckSchedule.failureRetryDelay) : decision.nextCheck)
            return false
        }
        timer?.invalidate()
        timer = nil
        let found = await performCheck(reportingErrors: false)
        if found, let release = availableRelease,
           UpdateCheckSchedule.shouldNotify(about: release.version, running: runningVersion, lastNotified: settings.lastNotifiedVersion) {
            settings.lastNotifiedVersion = release.version.description
            let text = UpdateCheckSchedule.noticeText(for: release.version)
            notifier?(text.title, text.subtitle)
        }
        let next = UpdateCheckSchedule.decide(
            isEnabled: settings.checksAutomatically,
            lastSuccessfulCheck: settings.lastCheckDate,
            lastFailedAttempt: lastFailedAttempt,
            now: now()
        )
        scheduleCheck(at: next.nextCheck)
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
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Checking

    /// "Check for Updates": always asks GitHub, and shows the result or the error.
    public func checkNow() async {
        guard !isBusy else { return }
        _ = await performCheck(reportingErrors: true)
    }

    /// Returns whether a newer version was found.
    private func performCheck(reportingErrors: Bool) async -> Bool {
        let previousPhase = phase
        phase = .checking
        if reportingErrors { errorMessage = nil }
        do {
            let latest = try await feed.latestRelease()
            settings.lastCheckDate = now()
            lastFailedAttempt = nil
            if let latest, latest.version > runningVersion {
                if availableRelease != latest { availableRelease = latest }
                installRefusal = installer.automaticInstallRefusal()
                phase = .available
                return true
            }
            availableRelease = nil
            installRefusal = nil
            phase = .upToDate
            return false
        } catch {
            lastFailedAttempt = now()
            if reportingErrors {
                errorMessage = error.localizedDescription
                phase = availableRelease == nil ? .idle : .available
            } else {
                phase = previousPhase == .checking ? .idle : previousPhase
            }
            return false
        }
    }

    // MARK: Installing

    /// Installs `availableRelease` after `confirm` says yes. Returns where the new app is, for the caller to relaunch;
    /// nil when it was declined, refused or failed (the reason is in `errorMessage` / `installRefusal`).
    public func install(confirm: @MainActor (UpdateRelease) -> Bool) async -> URL? {
        guard !isBusy, let release = availableRelease else { return nil }
        errorMessage = nil
        if let refusal = installer.automaticInstallRefusal() {
            installRefusal = refusal
            return nil
        }
        guard confirm(release) else { return nil }
        phase = .downloading(nil)
        let installer = self.installer
        let report = progressReporter()
        do {
            let installed = try await Task.detached(priority: .userInitiated) {
                try await installer.install(release, progress: report)
            }.value
            phase = .installed
            return installed
        } catch {
            errorMessage = error.localizedDescription
            if case UpdateInstallError.refused(let refusal) = error { installRefusal = refusal }
            phase = .available
            return nil
        }
    }

    /// The fallback when Zenith will not replace itself: saves the DMG in Downloads. Returns it for the app to open.
    public func downloadForManualInstall() async -> URL? {
        guard !isBusy, let release = availableRelease else { return nil }
        errorMessage = nil
        phase = .downloading(nil)
        let installer = self.installer
        let report = progressReporter()
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try await installer.downloadForManualInstall(release) { report(.downloading($0)) }
            }.value
            phase = .downloaded(file)
            return file
        } catch {
            errorMessage = error.localizedDescription
            phase = .available
            return nil
        }
    }

    /// Progress arrives on the installer's threads and is applied on the main actor.
    private func progressReporter() -> @Sendable (UpdateInstallProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
    }

    private func apply(_ progress: UpdateInstallProgress) {
        switch (progress, phase) {
        case (.downloading(let fraction), .downloading):
            phase = .downloading(fraction)
        case (.verifying, _):
            phase = .verifying
        case (.installing, _):
            phase = .installing
        default:
            break
        }
    }

    /// For `--render-screenshots`: show `release` as found, without asking GitHub or reading this Mac.
    /// Writes `checkedAt` into this updater's settings, so pass one backed by a throwaway store.
    public func presentForScreenshot(release: UpdateRelease, refusal: UpdateInstallRefusal?, checkedAt: Date) {
        settings.lastCheckDate = checkedAt
        availableRelease = release
        installRefusal = refusal
        errorMessage = nil
        phase = .available
    }

    // MARK: Text

    /// "Last checked 5 minutes ago." / "Not checked yet."
    public func lastCheckedDescription(at date: Date) -> String {
        guard let last = settings.lastCheckDate else { return String(localized: "Not checked yet.") }
        return String(localized: "Last checked \(CleanerScanScheduleSettings.relative(last, now: date)).")
    }

    /// One line describing where things stand, in the user's language. Versions are digits and dots, never grouped.
    public func statusDescription(at date: Date) -> String {
        let version = availableRelease?.version.description ?? ""
        switch phase {
        case .idle:
            return lastCheckedDescription(at: date)
        case .checking:
            return String(localized: "Checking for updates…")
        case .upToDate:
            return String(localized: "Zenith is up to date.")
        case .available:
            return String(localized: "Zenith \(version) is available.")
        case .downloading(let fraction):
            if let fraction {
                let percent = String(Int((min(max(fraction, 0), 1) * 100).rounded()))
                return String(localized: "Downloading Zenith \(version)… \(percent)%")
            }
            return String(localized: "Downloading Zenith \(version)…")
        case .verifying:
            return String(localized: "Checking the signature of Zenith \(version)…")
        case .installing:
            return String(localized: "Installing Zenith \(version)…")
        case .installed:
            return String(localized: "Zenith \(version) is installed. Reopening…")
        case .downloaded:
            return String(localized: "Zenith \(version) is in your Downloads folder. Drag it to Applications to install it.")
        }
    }
}
