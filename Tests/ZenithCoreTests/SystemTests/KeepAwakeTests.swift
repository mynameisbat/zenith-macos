import Testing
import Foundation
@testable import ZenithCore

/// A clock the tests move by hand.
private final class KeepAwakeClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private struct Harness {
    let clock = KeepAwakeClock()
    let settings: KeepAwakeSettings
    let assertions = RecordingPowerAssertionProvider()
    let apps = FakeRunningApplications()
    let power = FakePowerSource(isOnACPower: false)
    let island = ZenithIslandState()
    let service: KeepAwakeService

    init() {
        settings = KeepAwakeSettings(userDefaults: TestDefaults.make("KeepAwakeTests_\(UUID().uuidString)")!)
        let clock = self.clock
        service = KeepAwakeService(
            settings: settings,
            assertions: assertions,
            apps: apps,
            power: power,
            now: { clock.date },
            island: island,
            autoTick: false
        )
    }
}

private let xcode = KeepAwakeApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
private let handbrake = KeepAwakeApp(bundleIdentifier: "fr.handbrake.HandBrake", name: "HandBrake")

@Suite("Keep awake: modes, timer end, app and power triggers, island, shortcut")
@MainActor
struct KeepAwakeTests {

    // MARK: Policy

    @Test("KA-01: The policy holds the assertion only while the mode's condition is true")
    func testPolicy() {
        let now = Date(timeIntervalSince1970: 1_000)
        func hold(_ mode: KeepAwakeMode?, end: Date? = nil, running: Set<String> = [], watched: Set<String> = [], ac: Bool = false) -> Bool {
            KeepAwakePolicy.shouldHoldAssertion(mode: mode, endDate: end, now: now, runningBundleIdentifiers: running,
                                                watchedBundleIdentifiers: watched, isOnACPower: ac)
        }
        #expect(!hold(nil))
        #expect(hold(.indefinite))
        #expect(hold(.duration(60), end: now.addingTimeInterval(1)))
        #expect(!hold(.duration(60), end: now))
        #expect(!hold(.whileAppsRunning, running: ["a"], watched: []))
        #expect(!hold(.whileAppsRunning, running: ["a"], watched: ["b"]))
        #expect(hold(.whileAppsRunning, running: ["a", "b"], watched: ["b"]))
        #expect(hold(.whileOnACPower, ac: true))
        #expect(!hold(.whileOnACPower, ac: false))
        #expect(KeepAwakePolicy.assertionKind(keepsDisplayOn: false) == .preventIdleSystemSleep)
        #expect(KeepAwakePolicy.assertionKind(keepsDisplayOn: true) == .preventIdleDisplaySleep)
    }

    @Test("KA-02: Duration titles read as minutes and hours")
    func testDurationTitles() {
        #expect(KeepAwakeMode.durationTitle(15 * 60) == "15 min")
        #expect(KeepAwakeMode.durationTitle(3_600) == "1 h")
        #expect(KeepAwakeMode.durationTitle(5 * 3_600) == "5 h")
        #expect(KeepAwakeMode.durationTitle(90 * 60) == "1 h 30 min")
        #expect(KeepAwakeMode.presetDurations == [900, 3_600, 7_200, 18_000])
    }

    // MARK: Timed mode

    @Test("KA-03: A timed mode holds one assertion, counts down, and releases it the moment it ends")
    func testDurationEnds() {
        let h = Harness()
        h.service.start(.duration(3_600))
        #expect(h.service.isActive)
        #expect(h.service.isHoldingAssertion)
        #expect(h.assertions.activeKinds == [.preventIdleSystemSleep])
        #expect(h.assertions.lastReason == "Zenith: Keep Awake")
        #expect(h.service.snapshot?.remaining == 3_600)
        #expect(h.service.snapshot?.remainingText == "1:00:00")

        h.clock.advance(1_800)
        h.service.tick()
        #expect(h.service.snapshot?.remaining == 1_800)
        #expect(h.assertions.createdCount == 1)   // ticking never takes a second assertion

        h.clock.advance(1_800)
        h.service.tick()
        #expect(!h.service.isActive)
        #expect(!h.service.isHoldingAssertion)
        #expect(h.assertions.active.isEmpty)
        #expect(h.service.snapshot == nil)
        #expect(h.island.keepAwake == nil)
    }

    @Test("KA-04: A mode that ran out while the Mac slept ends at the next check, without a tick")
    func testExpiredOnReevaluate() {
        let h = Harness()
        h.service.start(minutes: 15)
        h.clock.advance(2 * 3_600)
        h.service.reevaluate()
        #expect(!h.service.isActive)
        #expect(h.assertions.active.isEmpty)
    }

    @Test("KA-05: Zero or negative durations are ignored; start(minutes:) uses at least one minute")
    func testInvalidDurations() {
        let h = Harness()
        h.service.start(.duration(0))
        h.service.start(.duration(-5))
        #expect(!h.service.isActive)
        #expect(h.assertions.createdCount == 0)
        h.service.start(minutes: 0)
        #expect(h.service.remaining == 60)
    }

    // MARK: Off, toggle, replace

    @Test("KA-06: Turning it off releases the assertion at once; toggle switches 'until turned off' on and off")
    func testStopAndToggle() {
        let h = Harness()
        h.service.toggle()
        #expect(h.service.mode == .indefinite)
        #expect(h.assertions.active.count == 1)
        #expect(h.service.snapshot?.remaining == nil)

        h.service.toggle()
        #expect(h.service.mode == nil)
        #expect(h.assertions.active.isEmpty)

        h.service.start(.duration(600))
        h.service.stop()
        #expect(h.assertions.active.isEmpty)
        #expect(h.service.remaining == nil)
    }

    @Test("KA-07: Choosing another mode keeps the same assertion when its kind does not change")
    func testReplaceMode() {
        let h = Harness()
        h.service.start(.duration(600))
        h.service.start(.indefinite)
        #expect(h.assertions.createdCount == 1)
        #expect(h.assertions.active.count == 1)
        #expect(h.service.remaining == nil)
    }

    @Test("KA-08: 'Keep the display on' swaps the assertion's kind while active, never leaving a gap or a leftover")
    func testDisplaySettingSwapsAssertion() {
        let h = Harness()
        h.service.start(.indefinite)
        h.settings.keepsDisplayOn = true
        #expect(h.assertions.activeKinds == [.preventIdleDisplaySleep])
        #expect(h.service.snapshot?.keepsDisplayOn == true)
        h.settings.keepsDisplayOn = false
        #expect(h.assertions.activeKinds == [.preventIdleSystemSleep])
        #expect(h.assertions.createdCount == 3)
    }

    @Test("KA-09: A refused assertion is reported and nothing is counted as held")
    func testRefusedAssertion() {
        let h = Harness()
        h.assertions.refuses = true
        h.service.start(.indefinite)
        #expect(h.service.isActive)
        #expect(!h.service.isHoldingAssertion)
        #expect(h.service.assertionFailed)
        #expect(h.island.keepAwake == nil)

        h.assertions.refuses = false
        h.service.reevaluate()
        #expect(h.service.isHoldingAssertion)
        #expect(!h.service.assertionFailed)
    }

    // MARK: App trigger

    @Test("KA-10: 'While chosen apps run' holds the assertion only while one runs, and follows launches and quits")
    func testAppTrigger() {
        let h = Harness()
        h.settings.addWatchedApp(xcode)
        h.settings.addWatchedApp(handbrake)
        h.settings.addWatchedApp(xcode)   // no duplicates
        #expect(h.settings.watchedApps == [xcode, handbrake])

        h.service.start(.whileAppsRunning)
        #expect(h.apps.isObserving)
        #expect(h.service.isActive)
        #expect(!h.service.isHoldingAssertion)
        #expect(h.service.snapshot?.statusText == "Waiting for a chosen app")

        h.apps.launch(handbrake)
        #expect(h.service.isHoldingAssertion)
        h.apps.launch(xcode)
        #expect(h.assertions.createdCount == 1)

        h.apps.quit(handbrake.bundleIdentifier)
        #expect(h.service.isHoldingAssertion)
        h.apps.quit(xcode.bundleIdentifier)
        #expect(!h.service.isHoldingAssertion)
        #expect(h.assertions.active.isEmpty)
        #expect(h.service.isActive)   // still armed

        h.service.stop()
        #expect(!h.apps.isObserving)
    }

    @Test("KA-11: Removing the running app from the list releases the assertion")
    func testRemovingWatchedApp() {
        let h = Harness()
        h.apps.apps = [xcode]
        h.settings.addWatchedApp(xcode)
        h.service.start(.whileAppsRunning)
        #expect(h.service.isHoldingAssertion)
        h.settings.removeWatchedApp(bundleIdentifier: xcode.bundleIdentifier)
        #expect(!h.service.isHoldingAssertion)
        #expect(h.assertions.active.isEmpty)
    }

    // MARK: Power trigger

    @Test("KA-12: 'While on power adapter' follows plugging in and unplugging")
    func testPowerTrigger() {
        let h = Harness()
        h.service.start(.whileOnACPower)
        #expect(h.power.isObserving)
        #expect(!h.service.isHoldingAssertion)
        #expect(h.service.snapshot?.statusText == "Waiting for the power adapter")

        h.power.isOnACPower = true
        #expect(h.service.isHoldingAssertion)
        #expect(h.service.snapshot?.statusText == "On the power adapter")

        h.power.isOnACPower = false
        #expect(!h.service.isHoldingAssertion)
        #expect(h.assertions.active.isEmpty)

        h.service.start(.indefinite)
        #expect(!h.power.isObserving)
        h.power.isOnACPower = true
        h.power.isOnACPower = false
        #expect(h.service.isHoldingAssertion)   // no longer follows the adapter
    }

    // MARK: Island

    @Test("KA-13: The island shows keep awake only while it holds the Mac awake and the setting allows it")
    func testIslandIndicator() {
        let h = Harness()
        h.service.start(.duration(600))
        #expect(h.island.keepAwake?.remaining == 600)
        #expect(h.island.hasCompactActivity)
        #expect(h.island.compactActivity == .keepAwake)
        #expect(h.island.compactActivityUsesWideWings)
        #expect(h.island.keepAwake?.accessibilityDescription == "Keeping the Mac awake, 10:00 left")

        h.settings.showsOnIsland = false
        #expect(h.island.keepAwake == nil)
        #expect(!h.island.hasCompactActivity)
        h.settings.showsOnIsland = true

        h.service.start(.indefinite)
        #expect(h.island.keepAwake != nil)
        #expect(!h.island.compactActivityUsesWideWings)   // no time to fit

        h.service.start(.whileOnACPower)   // armed, waiting: nothing on the island
        #expect(h.island.keepAwake == nil)
    }

    @Test("KA-14: A focus timer and playing media come before keep awake beside the notch")
    func testCompactPriority() {
        let island = ZenithIslandState()
        island.keepAwake = KeepAwakeSnapshot(mode: .indefinite, isHoldingAssertion: true, keepsDisplayOn: false, remaining: nil)
        #expect(island.compactActivity == .keepAwake)
        island.nowPlayingTrack = NowPlayingTrack(app: .spotify, title: "Song", artist: "Artist", isPlaying: true)
        #expect(island.compactActivity == .nowPlaying)
        island.focusTimer = FocusTimerSnapshot(mode: .focus, isPaused: false, duration: 60, remaining: 60)
        #expect(island.compactActivity == .focusTimer)
        #expect(island.compactActivityUsesWideWings)
    }

    // MARK: Settings

    @Test("KA-15: Settings persist, the custom duration is clamped, and defaults come back")
    func testSettingsPersist() {
        let defaults = TestDefaults.make("KeepAwakeSettings_\(UUID().uuidString)")!
        let settings = KeepAwakeSettings(userDefaults: defaults)
        #expect(settings.keepsDisplayOn == false)
        #expect(settings.showsOnIsland == true)
        #expect(settings.customMinutes == KeepAwakeSettings.defaultCustomMinutes)
        #expect(settings.hotKeyEnabled == false)

        settings.keepsDisplayOn = true
        settings.customMinutes = 100_000
        settings.addWatchedApp(xcode)
        settings.hotKeyEnabled = true
        #expect(settings.customMinutes == 1_440)

        let reloaded = KeepAwakeSettings(userDefaults: defaults)
        #expect(reloaded.keepsDisplayOn)
        #expect(reloaded.customMinutes == 1_440)
        #expect(reloaded.watchedApps == [xcode])
        #expect(reloaded.hotKeyEnabled)

        reloaded.customMinutes = 1
        #expect(reloaded.customMinutes == 5)
        reloaded.resetToDefaults()
        #expect(!reloaded.keepsDisplayOn && reloaded.watchedApps.isEmpty && !reloaded.hotKeyEnabled)
        #expect(reloaded.customMinutes == KeepAwakeSettings.defaultCustomMinutes)
    }

    // MARK: Shortcut

    @Test("KA-16: The shortcut is registered only while switched on, toggles keep awake, and can be changed")
    func testHotKey() async {
        let h = Harness()
        let store = SettingsStore(userDefaults: TestDefaults.make("KeepAwakeHotKey_\(UUID().uuidString)")!)
        let manager = HotKeyManager(backend: SimulatedCarbonBackend())
        let service = h.service
        let controller = KeepAwakeHotKeyController(settings: h.settings, store: store, manager: manager) { service.toggle() }

        controller.apply()
        #expect(!controller.isRegistered)

        #expect(controller.setEnabled(true))
        #expect(controller.isRegistered)
        #expect(manager.registeredHotKeys[HotKeyDefinition.keepAwakeToggleId] == .defaultKeepAwake)

        manager.simulateHotKeyTrigger(id: HotKeyDefinition.keepAwakeToggleId)
        for _ in 0..<20 where !service.isActive { await Task.yield() }
        #expect(service.mode == .indefinite)

        // A key combination another Zenith shortcut uses is refused and not saved.
        manager.registerHotKey(HotKeyDefinition.defaultClipboard) {}
        let clash = HotKeyDefinition(id: "x", name: "x", keyCode: 9, carbonModifiers: HotKeyDefinition.defaultClipboard.carbonModifiers, keyEquivalent: "⌘⇧V")
        #expect(controller.change(clash) == .conflict(with: HotKeyDefinition.defaultClipboard.name))
        #expect(controller.definition == .defaultKeepAwake)

        let other = HotKeyDefinition(id: "x", name: "x", keyCode: 0, carbonModifiers: CarbonModifierFlags.control.rawValue | CarbonModifierFlags.option.rawValue, keyEquivalent: "⌃⌥A")
        #expect(controller.change(other) == .applied)
        #expect(controller.definition.keyCode == 0)
        #expect(controller.definition.id == HotKeyDefinition.keepAwakeToggleId)
        #expect(manager.registeredHotKeys[HotKeyDefinition.keepAwakeToggleId]?.keyCode == 0)

        controller.setEnabled(false)
        #expect(!controller.isRegistered)
        // Changing it while off only saves it.
        #expect(controller.resetToDefault() == .applied)
        #expect(!controller.isRegistered)
        #expect(controller.definition.keyCode == HotKeyDefinition.defaultKeepAwake.keyCode)
    }
}
