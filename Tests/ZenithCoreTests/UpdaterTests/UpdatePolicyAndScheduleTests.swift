import Testing
import Foundation
@testable import ZenithCore

/// The pure decisions: may Zenith replace itself, is a candidate acceptable, is a check due, is a notice due.
@Suite("Updater: install policy and check schedule")
@MainActor
struct UpdatePolicyAndScheduleTests {
    private let stable = RunningAppSigning.stable(requirement: "identifier \"com.zenith.workspace\" and certificate leaf = H\"00\"")
    private let day: TimeInterval = 24 * 60 * 60
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func v(_ text: String) -> AppVersion { AppVersion(text)! }

    // MARK: - May Zenith replace itself

    @Test("UPD-P01: Ad hoc, unsigned or unreadable signature refuses, wherever the app is")
    func testSigningRefusals() {
        for (signing, expected) in [
            (RunningAppSigning.adHoc, UpdateInstallRefusal.notSignedWithStableIdentity),
            (.unsigned, .notSignedWithStableIdentity),
            (.unreadable("x"), .signatureUnreadable)
        ] {
            let refusal = UpdateInstallPolicy.automaticInstallRefusal(
                signing: signing, appPath: "/Applications/Zenith.app", isAppBundle: true, isOnReadOnlyVolume: false, isLocationWritable: true
            )
            #expect(refusal == expected)
        }
        #expect(UpdateInstallRefusal.notSignedWithStableIdentity.message.contains("not signed with a stable identity"))
    }

    @Test("UPD-P02: Not a bundle, translocated, on a mounted or read-only volume, or not writable refuses")
    func testLocationRefusals() {
        func refusal(_ path: String, bundle: Bool = true, readOnly: Bool = false, writable: Bool = true) -> UpdateInstallRefusal? {
            UpdateInstallPolicy.automaticInstallRefusal(
                signing: stable, appPath: path, isAppBundle: bundle, isOnReadOnlyVolume: readOnly, isLocationWritable: writable
            )
        }
        #expect(refusal("/Applications/Zenith.app") == nil)
        #expect(refusal("/Users/me/Applications/Zenith.app") == nil)
        #expect(refusal("/Users/me/Project/.build/debug", bundle: false) == .notAnAppBundle)
        #expect(refusal("/private/var/folders/ab/cd/T/AppTranslocation/1234-ABCD/d/Zenith.app") == .translocated)
        #expect(refusal("/Volumes/Zenith/Zenith.app") == .onMountedVolume)
        #expect(refusal("/Applications/Zenith.app", readOnly: true) == .onMountedVolume)
        #expect(refusal("/Applications/Zenith.app", writable: false) == .notWritable)
    }

    @Test("UPD-P03: The file-system variant: a writable temporary bundle passes, a plain folder is not a bundle")
    func testFileSystemVariant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-updater-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Zenith.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(UpdateInstallPolicy.automaticInstallRefusal(signing: stable, appURL: app) == nil)
        #expect(UpdateInstallPolicy.automaticInstallRefusal(signing: .adHoc, appURL: app) == .notSignedWithStableIdentity)
        #expect(UpdateInstallPolicy.automaticInstallRefusal(signing: stable, appURL: root) == .notAnAppBundle)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        #expect(UpdateInstallPolicy.automaticInstallRefusal(signing: stable, appURL: app) == .notWritable)
    }

    // MARK: - Is the candidate acceptable

    private func rejection(
        id: String? = "com.zenith.workspace",
        version: String? = "2.5.0",
        claimed: String = "2.5.0",
        running: String = "2.4.0",
        signature: CandidateSignatureCheck = .satisfiesRunningRequirement
    ) -> UpdateCandidateRejection? {
        UpdateInstallPolicy.candidateRejection(
            bundleIdentifier: id, shortVersion: version, claimed: v(claimed), running: v(running), signature: signature
        )
    }

    @Test("UPD-P04: All good proceeds")
    func testCandidateGood() {
        #expect(rejection() == nil)
        #expect(rejection(version: "2.5", claimed: "2.5.0") == nil)
    }

    @Test("UPD-P05: Wrong identifier, unreadable Info.plist refuse")
    func testCandidateIdentifier() {
        #expect(rejection(id: "com.example.other") == .wrongIdentifier)
        #expect(rejection(id: "com.zenith.workspace.evil") == .wrongIdentifier)
        #expect(rejection(id: nil) == .unreadableInfo)
        #expect(rejection(version: nil) == .unreadableInfo)
    }

    @Test("UPD-P06: Claimed version must equal the bundle's, and be strictly newer than the running one")
    func testCandidateVersions() {
        #expect(rejection(version: "2.6.0", claimed: "2.5.0") == .versionMismatch(claimed: "2.5.0", found: "2.6.0"))
        #expect(rejection(version: "2.5.0-beta", claimed: "2.5.0") == .versionMismatch(claimed: "2.5.0", found: "2.5.0-beta"))
        #expect(rejection(version: "2.4.0", claimed: "2.4.0") == .notNewer(found: "2.4.0", running: "2.4.0"))
        #expect(rejection(version: "2.3.9", claimed: "2.3.9") == .notNewer(found: "2.3.9", running: "2.4.0"))
    }

    @Test("UPD-P07: A failed signature check refuses even when everything else is right")
    func testCandidateSignature() {
        #expect(rejection(signature: .rejected("different certificate")) == .signature("different certificate"))
    }

    // MARK: - Check schedule

    @Test("UPD-S01: Off never checks and schedules nothing")
    func testScheduleOff() {
        for last in [nil, t0, t0.addingTimeInterval(-400 * day)] as [Date?] {
            #expect(UpdateCheckSchedule.decide(isEnabled: false, lastSuccessfulCheck: last, lastFailedAttempt: nil, now: t0)
                    == UpdateCheckDecision(checkNow: false, nextCheck: nil))
        }
    }

    @Test("UPD-S02: Never checked checks now; just checked waits a day; overdue checks once")
    func testScheduleDue() {
        #expect(UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: nil, lastFailedAttempt: nil, now: t0)
                == UpdateCheckDecision(checkNow: true, nextCheck: t0.addingTimeInterval(day)))
        let last = t0.addingTimeInterval(-60)
        #expect(UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: last, lastFailedAttempt: nil, now: t0)
                == UpdateCheckDecision(checkNow: false, nextCheck: last.addingTimeInterval(day)))
        #expect(UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: t0.addingTimeInterval(-30 * day), lastFailedAttempt: nil, now: t0)
                == UpdateCheckDecision(checkNow: true, nextCheck: t0.addingTimeInterval(day)))
        #expect(UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: t0.addingTimeInterval(-day), lastFailedAttempt: nil, now: t0).checkNow)
    }

    @Test("UPD-S03: A failed attempt is retried an hour later, not at once and not a day later")
    func testScheduleFailure() {
        let failed = t0.addingTimeInterval(-10 * 60)
        #expect(UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: nil, lastFailedAttempt: failed, now: t0)
                == UpdateCheckDecision(checkNow: false, nextCheck: failed.addingTimeInterval(UpdateCheckSchedule.failureRetryDelay)))
        let later = failed.addingTimeInterval(UpdateCheckSchedule.failureRetryDelay)
        #expect(UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: nil, lastFailedAttempt: failed, now: later).checkNow)
    }

    @Test("UPD-S04: A last-check date in the future (clock moved back) is not trusted")
    func testScheduleClockSkew() {
        #expect(UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: t0.addingTimeInterval(10 * day), lastFailedAttempt: nil, now: t0).checkNow)
        // Within the tolerance it still counts.
        #expect(!UpdateCheckSchedule.decide(isEnabled: true, lastSuccessfulCheck: t0.addingTimeInterval(60), lastFailedAttempt: nil, now: t0).checkNow)
    }

    @Test("UPD-S05: One notice per version, none for the running or an older one")
    func testNotifyOnce() {
        let running = v("2.4.0")
        #expect(UpdateCheckSchedule.shouldNotify(about: v("2.5.0"), running: running, lastNotified: nil))
        #expect(!UpdateCheckSchedule.shouldNotify(about: v("2.5.0"), running: running, lastNotified: "2.5.0"))
        #expect(!UpdateCheckSchedule.shouldNotify(about: v("2.5.0"), running: running, lastNotified: "2.5"))
        #expect(UpdateCheckSchedule.shouldNotify(about: v("2.6.0"), running: running, lastNotified: "2.5.0"))
        #expect(!UpdateCheckSchedule.shouldNotify(about: v("2.4.0"), running: running, lastNotified: nil))
        #expect(!UpdateCheckSchedule.shouldNotify(about: v("2.3.0"), running: running, lastNotified: nil))
        #expect(UpdateCheckSchedule.shouldNotify(about: v("2.5.0"), running: running, lastNotified: "garbage"))
        let text = UpdateCheckSchedule.noticeText(for: v("2.10.0"))
        #expect(text.title == "Zenith 2.10.0 is available")
    }

    // MARK: - The updater with a stubbed feed

    private final class StubFeed: UpdateFeed, @unchecked Sendable {
        var result: Result<UpdateRelease?, Error>
        var calls = 0
        init(_ result: Result<UpdateRelease?, Error>) { self.result = result }
        func latestRelease() async throws -> UpdateRelease? {
            calls += 1
            return try result.get()
        }
    }

    private final class StubInstaller: UpdateInstalling, @unchecked Sendable {
        var refusal: UpdateInstallRefusal?
        var installs = 0
        func install(_ release: UpdateRelease, progress: @escaping @Sendable (UpdateInstallProgress) -> Void) async throws -> URL {
            installs += 1
            return URL(fileURLWithPath: "/tmp/Zenith.app")
        }
        func downloadForManualInstall(_ release: UpdateRelease, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
            URL(fileURLWithPath: "/tmp/Zenith-2.5.0.dmg")
        }
        func automaticInstallRefusal() -> UpdateInstallRefusal? { refusal }
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    static func release(_ version: String) -> UpdateRelease {
        UpdateRelease(
            version: AppVersion(version)!, tag: "v\(version)", assetName: "Zenith-\(version).dmg",
            downloadURL: URL(string: "https://github.com/mynameisbat/zenith-macos/releases/download/v\(version)/Zenith-\(version).dmg")!,
            assetSize: 1_000, sha256: nil
        )
    }

    private func makeUpdater(feed: StubFeed, installer: StubInstaller = StubInstaller(), clock: Clock) throws -> (ZenithUpdater, UpdateSettings) {
        let defaults = try #require(TestDefaults.make("updates.\(UUID().uuidString)"))
        let settings = UpdateSettings(userDefaults: defaults)
        let updater = ZenithUpdater(
            settings: settings, feed: feed, installer: installer, runningVersion: v("2.4.0"),
            now: { clock.now }, autoSchedule: false
        )
        return (updater, settings)
    }

    @Test("UPD-S06: Automatic checks are on by default; the switch persists")
    func testSettingsDefault() throws {
        let defaults = try #require(TestDefaults.make("updates.\(UUID().uuidString)"))
        let settings = UpdateSettings(userDefaults: defaults)
        #expect(settings.checksAutomatically)
        settings.checksAutomatically = false
        #expect(!UpdateSettings(userDefaults: defaults).checksAutomatically)
        settings.resetToDefaults()
        #expect(UpdateSettings(userDefaults: defaults).checksAutomatically)
    }

    @Test("UPD-S07: The daily check tells the user once per version, and not again the next day")
    func testAutomaticNoticeOnce() async throws {
        let clock = Clock(t0)
        let feed = StubFeed(.success(Self.release("2.5.0")))
        let (updater, settings) = try makeUpdater(feed: feed, clock: clock)
        var notices: [String] = []
        updater.notifier = { title, _ in notices.append(title) }

        #expect(await updater.evaluate())
        #expect(notices == ["Zenith 2.5.0 is available"])
        #expect(updater.phase == .available)
        #expect(settings.lastNotifiedVersion == "2.5.0")
        #expect(updater.nextCheckDate == t0.addingTimeInterval(day))

        // Not due yet: no request at all.
        #expect(!(await updater.evaluate()))
        #expect(feed.calls == 1)

        clock.now = t0.addingTimeInterval(day + 1)
        #expect(await updater.evaluate())
        #expect(notices.count == 1)

        feed.result = .success(Self.release("2.6.0"))
        clock.now = t0.addingTimeInterval(2 * day + 2)
        #expect(await updater.evaluate())
        #expect(notices == ["Zenith 2.5.0 is available", "Zenith 2.6.0 is available"])
    }

    @Test("UPD-S08: Automatic failures are silent; manual failures are shown")
    func testErrorsSilentOrShown() async throws {
        let clock = Clock(t0)
        let feed = StubFeed(.failure(UpdateFeedError.offline))
        let (updater, settings) = try makeUpdater(feed: feed, clock: clock)
        var notices = 0
        updater.notifier = { _, _ in notices += 1 }

        await updater.evaluate()
        #expect(updater.errorMessage == nil)
        #expect(notices == 0)
        #expect(settings.lastCheckDate == nil)
        #expect(updater.nextCheckDate == t0.addingTimeInterval(UpdateCheckSchedule.failureRetryDelay))

        feed.result = .failure(UpdateFeedError.rateLimited)
        await updater.checkNow()
        #expect(updater.errorMessage == UpdateFeedError.rateLimited.errorDescription)
        #expect(updater.phase == .idle)
        #expect(feed.calls == 2)
    }

    @Test("UPD-S09: Manual check always asks; up to date and the same version are not offered")
    func testManualCheck() async throws {
        let clock = Clock(t0)
        let feed = StubFeed(.success(Self.release("2.4.0")))
        let (updater, settings) = try makeUpdater(feed: feed, clock: clock)
        settings.lastCheckDate = t0
        await updater.checkNow()
        #expect(feed.calls == 1)
        #expect(updater.phase == .upToDate)
        #expect(updater.availableRelease == nil)
        #expect(updater.statusDescription(at: t0) == "Zenith is up to date.")

        feed.result = .success(Self.release("2.10.0"))
        await updater.checkNow()
        #expect(updater.phase == .available)
        #expect(updater.statusDescription(at: t0) == "Zenith 2.10.0 is available.")
    }

    @Test("UPD-S10: Install needs the confirmation; a refusal never reaches the installer")
    func testInstallNeedsConfirmation() async throws {
        let clock = Clock(t0)
        let installer = StubInstaller()
        let (updater, _) = try makeUpdater(feed: StubFeed(.success(Self.release("2.5.0"))), installer: installer, clock: clock)
        await updater.checkNow()

        var asked = 0
        #expect(await updater.install(confirm: { _ in asked += 1; return false }) == nil)
        #expect(asked == 1)
        #expect(installer.installs == 0)

        installer.refusal = .notSignedWithStableIdentity
        #expect(await updater.install(confirm: { _ in asked += 1; return true }) == nil)
        #expect(asked == 1)
        #expect(installer.installs == 0)
        #expect(updater.installRefusal == .notSignedWithStableIdentity)

        installer.refusal = nil
        #expect(await updater.install(confirm: { _ in true }) != nil)
        #expect(installer.installs == 1)
        #expect(updater.phase == .installed)
    }
}
