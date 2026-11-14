import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

/// Cleaning Mode's state machine, time limit, exit gesture and tap-disabled handling, fed with synthetic events.
/// No test here creates a real event tap or a window: the tap, timer and windows are the mocks in `Mocks/`.
@MainActor
@Suite("Cleaning Mode")
struct CleaningModeTests {
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private struct Harness {
        let controller: CleaningModeController
        let settings: CleaningModeSettings
        let permissions: MockPermissionsService
        let tap: MockCleaningModeEventTap
        let ticker: ManualCleaningModeTicker
        let presenter: RecordingCleaningModePresenter
        let clock: Clock
        let announcements: Box
    }

    private final class Box { var messages: [String] = [] }

    private func makeHarness(accessibility: Bool = true, duration: Int? = nil, name: String = #function) -> Harness {
        let defaults = TestDefaults.make("cleaningMode.\(name)")!
        defaults.removePersistentDomain(forName: "zenith.tests.cleaningMode.\(name)")
        let settings = CleaningModeSettings(userDefaults: defaults)
        if let duration { settings.durationSeconds = duration }
        let permissions = MockPermissionsService(accessibilityGranted: accessibility)
        let tap = MockCleaningModeEventTap()
        let ticker = ManualCleaningModeTicker()
        let presenter = RecordingCleaningModePresenter()
        let clock = Clock()
        let box = Box()
        let controller = CleaningModeController(
            settings: settings,
            permissions: permissions,
            tap: tap,
            ticker: ticker,
            now: { clock.now },
            announce: { box.messages.append($0) }
        )
        controller.presenter = presenter
        return Harness(controller: controller, settings: settings, permissions: permissions, tap: tap,
                       ticker: ticker, presenter: presenter, clock: clock, announcements: box)
    }

    private let exitKeys = CleaningModeInputEvent.modifiersChanged([.control, .option, .command])

    // MARK: Settings

    @Test("CLN-01: settings default to 60 s, black, shortcut off; the limit is clamped to 15 s – 5 min and persisted")
    func settingsDefaultsAndClamp() {
        let defaults = TestDefaults.make("cleaningMode.settings")!
        defaults.removePersistentDomain(forName: "zenith.tests.cleaningMode.settings")
        let settings = CleaningModeSettings(userDefaults: defaults)
        #expect(settings.durationSeconds == 60)
        #expect(settings.appearance == .black)
        #expect(settings.hotKeyEnabled == false)

        settings.durationSeconds = 5
        #expect(settings.durationSeconds == 15)
        settings.durationSeconds = 10_000
        #expect(settings.durationSeconds == 300)
        settings.durationSeconds = 90
        settings.appearance = .dimmed
        settings.hotKeyEnabled = true

        let reloaded = CleaningModeSettings(userDefaults: defaults)
        #expect(reloaded.durationSeconds == 90)
        #expect(reloaded.appearance == .dimmed)
        #expect(reloaded.hotKeyEnabled)

        // A value written by something else is clamped when read back.
        defaults.set(-4, forKey: CleaningModeSettings.Keys.duration)
        #expect(CleaningModeSettings(userDefaults: defaults).durationSeconds == 15)
        #expect(CleaningModeSettings.durationChoices.allSatisfy { (15...300).contains($0) })
        #expect(CleaningModeSettings.countdownText(65) == "1:05")
        #expect(CleaningModeSettings.countdownText(-3) == "0:00")
    }

    @Test("CLN-02: every setter tells observers")
    func settingsNotify() {
        let defaults = TestDefaults.make("cleaningMode.notify")!
        let settings = CleaningModeSettings(userDefaults: defaults)
        var count = 0
        let token = settings.objectWillChange.sink { count += 1 }
        settings.durationSeconds = 30
        settings.appearance = .dimmed
        settings.hotKeyEnabled = true
        #expect(count == 3)
        token.cancel()
    }

    // MARK: Starting

    @Test("CLN-03: without Accessibility nothing is blocked: no tap, no windows, no timer")
    func needsAccessibility() {
        let h = makeHarness(accessibility: false)
        #expect(h.controller.start() == .needsAccessibility)
        #expect(!h.controller.isActive)
        #expect(h.tap.installCount == 0)
        #expect(h.presenter.presented.isEmpty)
        #expect(!h.ticker.isRunning)
        #expect(h.tap.send(.keyDown(keyCode: 0)) == false)
        #expect(h.permissions.requestAccessibilityCallCount == 0, "Cleaning Mode never prompts by itself")
    }

    @Test("CLN-04: start blocks every kind of input, shows the windows, ticks and announces")
    func startBlocks() {
        let h = makeHarness(duration: 45)
        h.settings.appearance = .dimmed
        #expect(h.controller.start() == .started)
        #expect(h.controller.isActive)
        #expect(h.controller.remainingSeconds == 45)
        #expect(h.controller.endsAt == h.clock.now.addingTimeInterval(45))
        #expect(h.tap.isInstalled)
        #expect(h.presenter.presented == [.dimmed])
        #expect(h.ticker.isRunning)
        #expect(h.ticker.interval == CleaningModeController.tickInterval)
        #expect(h.announcements.messages.count == 1)

        let events: [CleaningModeInputEvent] = [
            .keyDown(keyCode: 0), .keyUp(keyCode: 0), .modifiersChanged([.shift]), .pointer, .scroll,
            .systemDefined, .gesture
        ]
        for event in events {
            #expect(h.tap.send(event), "\(event) should be swallowed")
        }
        #expect(h.controller.swallowedEventCount == events.count)
    }

    @Test("CLN-05: a second start while on changes nothing; ending while off does nothing")
    func idempotent() {
        let h = makeHarness()
        h.controller.end(.stopped)
        #expect(h.controller.lastEndReason == nil)
        #expect(h.announcements.messages.isEmpty)
        #expect(h.controller.start() == .started)
        #expect(h.controller.start() == .alreadyActive)
        #expect(h.tap.installCount == 1)
        #expect(h.presenter.presented.count == 1)
    }

    @Test("CLN-06: when the tap cannot be created nothing stays half-started")
    func tapUnavailable() {
        let h = makeHarness()
        h.tap.failsToInstall = true
        #expect(h.controller.start() == .tapUnavailable)
        #expect(!h.controller.isActive)
        #expect(h.presenter.presented.isEmpty)
        #expect(!h.ticker.isRunning)
        #expect(h.announcements.messages.isEmpty)
    }

    // MARK: Time limit

    @Test("CLN-07: the countdown moves and input comes back when the time is up")
    func timeLimit() {
        let h = makeHarness(duration: 15)
        h.controller.start()
        h.clock.advance(4.3)
        h.ticker.fire()
        #expect(h.controller.remainingSeconds == 11)
        h.clock.advance(10.7)
        h.ticker.fire()
        #expect(!h.controller.isActive)
        #expect(h.controller.lastEndReason == .timeLimit)
        #expect(!h.tap.isInstalled)
        #expect(h.tap.removeCount == 1)
        #expect(!h.presenter.isShowing)
        #expect(!h.ticker.isRunning)
        #expect(h.announcements.messages.count == 2)
        #expect(h.announcements.messages.last == CleaningModeController.endMessage(for: .timeLimit))
    }

    @Test("CLN-08: a stalled timer cannot keep input blocked: the first event after the limit passes through and ends it")
    func timeLimitWithoutTimer() {
        let h = makeHarness(duration: 15)
        h.controller.start()
        h.clock.advance(15)
        #expect(h.tap.send(.keyDown(keyCode: 3)) == false)
        #expect(!h.controller.isActive)
        #expect(h.controller.lastEndReason == .timeLimit)
    }

    @Test("CLN-09: the limit can never exceed five minutes, even with a bad stored value")
    func limitCeiling() {
        let defaults = TestDefaults.make("cleaningMode.ceiling")!
        defaults.set(86_400, forKey: CleaningModeSettings.Keys.duration)
        let settings = CleaningModeSettings(userDefaults: defaults)
        let clock = Clock()
        let controller = CleaningModeController(
            settings: settings, permissions: MockPermissionsService(accessibilityGranted: true),
            tap: MockCleaningModeEventTap(), ticker: ManualCleaningModeTicker(),
            now: { clock.now }, announce: { _ in }
        )
        controller.start()
        #expect(controller.endsAt == clock.now.addingTimeInterval(300))
        controller.end(.stopped)
    }

    // MARK: Exit gesture

    @Test("CLN-10: holding ⌃⌥⌘ for 2 s ends it; the keys are still swallowed while held")
    func exitGesture() {
        let h = makeHarness()
        h.controller.start()
        #expect(h.tap.send(exitKeys))
        h.clock.advance(1)
        h.ticker.fire()
        #expect(h.controller.isActive)
        #expect(abs(h.controller.exitHoldProgress - 0.5) < 0.001)
        h.clock.advance(0.9)
        h.ticker.fire()
        #expect(h.controller.isActive)
        h.clock.advance(0.1)
        h.ticker.fire()
        #expect(!h.controller.isActive)
        #expect(h.controller.lastEndReason == .exitGesture)
        #expect(h.controller.exitHoldProgress == 0)
        #expect(!h.tap.isInstalled)
    }

    @Test("CLN-11: another key, Shift, or letting go starts the hold over; the same change seen twice does not")
    func exitGestureResets() {
        var gesture = CleaningModeExitGesture()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        gesture.observe(exitKeys, at: t0)
        gesture.observe(exitKeys, at: t0.addingTimeInterval(1.5))   // tap and window both saw it
        #expect(gesture.isComplete(at: t0.addingTimeInterval(2)))

        gesture.observe(.keyDown(keyCode: 7), at: t0.addingTimeInterval(2))
        #expect(gesture.progress(at: t0.addingTimeInterval(5)) == 0)

        gesture.observe(exitKeys, at: t0.addingTimeInterval(5))
        gesture.observe(.modifiersChanged([.control, .option, .command, .shift]), at: t0.addingTimeInterval(6))
        #expect(gesture.progress(at: t0.addingTimeInterval(8)) == 0)

        gesture.observe(exitKeys, at: t0.addingTimeInterval(8))
        gesture.observe(.modifiersChanged([.control, .command]), at: t0.addingTimeInterval(9))
        #expect(!gesture.isComplete(at: t0.addingTimeInterval(11)))

        // Clicks and scrolling while holding do not interrupt it.
        gesture.observe(exitKeys, at: t0.addingTimeInterval(11))
        gesture.observe(.pointer, at: t0.addingTimeInterval(11.5))
        gesture.observe(.scroll, at: t0.addingTimeInterval(12))
        #expect(gesture.isComplete(at: t0.addingTimeInterval(13)))
    }

    @Test("CLN-12: a palm on the keyboard (other keys with ⌃⌥⌘) does not end it")
    func palmDoesNotExit() {
        let h = makeHarness()
        h.controller.start()
        h.tap.send(exitKeys)
        for _ in 0..<10 {
            h.clock.advance(0.5)
            h.tap.send(.keyDown(keyCode: 12))
            h.ticker.fire()
        }
        #expect(h.controller.isActive)
        #expect(h.controller.exitHoldProgress == 0)
    }

    // MARK: Tap disabled

    @Test("CLN-13: when macOS disables the tap, Cleaning Mode ends instead of re-enabling it", arguments: [
        CleaningModeTapDisableReason.timeout, .userInput
    ])
    func tapDisabled(reason: CleaningModeTapDisableReason) {
        let h = makeHarness()
        var ended: [CleaningModeEndReason] = []
        h.controller.onEnd = { ended.append($0) }
        h.controller.start()
        h.tap.simulateDisabled(reason)
        #expect(!h.controller.isActive)
        #expect(h.controller.lastEndReason == .tapDisabled(reason))
        #expect(ended == [.tapDisabled(reason)])
        #expect(h.tap.installCount == 1, "never re-installed silently")
        #expect(!h.tap.isInstalled)
        #expect(!h.presenter.isShowing)
        #expect(h.announcements.messages.last == CleaningModeController.endMessage(for: .tapDisabled(reason)))
    }

    @Test("CLN-14: quitting releases the tap, and it can be started again afterwards")
    func quitAndRestart() {
        let h = makeHarness()
        h.controller.start()
        h.controller.end(.appQuit)
        #expect(!h.tap.isInstalled)
        #expect(h.controller.lastEndReason == .appQuit)
        #expect(h.controller.start() == .started)
        #expect(h.tap.installCount == 2)
        #expect(h.controller.swallowedEventCount == 0)
        h.controller.end(.stopped)
    }

    // MARK: Real tap translation (pure, no tap created)

    @Test("CLN-15: raw event types map to what Cleaning Mode blocks; the mask covers them and not the disable notices")
    func translation() {
        typealias Tap = SystemCleaningModeEventTap
        let cmdOptCtrl = CGEventFlags([.maskCommand, .maskAlternate, .maskControl, .maskAlphaShift]).rawValue
        #expect(Tap.translate(type: CGEventType.keyDown.rawValue, flags: 0, keyCode: 12) == .keyDown(keyCode: 12))
        #expect(Tap.translate(type: CGEventType.keyUp.rawValue, flags: 0, keyCode: 12) == .keyUp(keyCode: 12))
        #expect(Tap.translate(type: CGEventType.flagsChanged.rawValue, flags: cmdOptCtrl, keyCode: 0)
                == .modifiersChanged([.control, .option, .command]), "Caps Lock is ignored")
        #expect(Tap.translate(type: CGEventType.leftMouseDown.rawValue, flags: 0, keyCode: 0) == .pointer)
        #expect(Tap.translate(type: CGEventType.otherMouseDragged.rawValue, flags: 0, keyCode: 0) == .pointer)
        #expect(Tap.translate(type: CGEventType.scrollWheel.rawValue, flags: 0, keyCode: 0) == .scroll)
        #expect(Tap.translate(type: 14, flags: 0, keyCode: 0) == .systemDefined)
        #expect(Tap.translate(type: 29, flags: 0, keyCode: 0) == .gesture)
        #expect(Tap.translate(type: CGEventType.tapDisabledByTimeout.rawValue, flags: 0, keyCode: 0) == nil)

        let mask = Tap.eventMask
        func has(_ type: UInt32) -> Bool { mask & (CGEventMask(1) << CGEventMask(type)) != 0 }
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseUp, .scrollWheel, .mouseMoved] {
            #expect(has(type.rawValue), "\(type.rawValue) missing from the mask")
        }
        #expect(has(14) && has(29) && has(30) && has(31))
        #expect(!has(CGEventType.null.rawValue))
    }

    // MARK: Wiring into the rest of Zenith

    @Test("CLN-16: the Permissions page knows Cleaning Mode uses Accessibility; its shortcut is the switch")
    func permissionsMapping() {
        #expect(ZenithPermissionFeature.cleaningMode.permission == .accessibility)
        let defaults = TestDefaults.make("cleaningMode.permissions")!
        defaults.removePersistentDomain(forName: "zenith.tests.cleaningMode.permissions")
        let settings = CleaningModeSettings(userDefaults: defaults)
        let activity = LiveFeatureActivity(cleaningMode: settings)
        #expect(activity.activity(for: .cleaningMode) == .alwaysAvailable)
        settings.hotKeyEnabled = true
        #expect(activity.activity(for: .cleaningMode) == .on)

        let accessibility = ZenithPermissionsReport.statuses(
            states: [.accessibility: .notGranted],
            activity: [.cleaningMode: .on]
        ).first { $0.kind == .accessibility }!
        #expect(accessibility.verdict == .neededButMissing)
    }

    @Test("CLN-17: the shortcut is built in but off by default, and does not use the ⌃⌥⌘ that ends it")
    func hotKey() {
        let definition = HotKeyDefinition.defaultCleaningMode
        #expect(HotKeyDefinition.builtIn(for: HotKeyDefinition.cleaningModeId) == definition)
        #expect(HotKeyDefinition.defaultDictionary[HotKeyDefinition.cleaningModeId] == nil)
        #expect(!CarbonModifierFlags(rawValue: definition.carbonModifiers).contains(.command))
        #expect(!definition.clashesWithMacOSScreenshot)
        #expect(definition.menuStyleKeyEquivalent == "⌃⌥⇧K")
        #expect(ZenithHubAction.cleaning.hotKeyId == HotKeyDefinition.cleaningModeId)
        #expect(ZenithHubAction.cleaning.matches(query: "wipe"))
        #expect(!ZenithHubAction.cleaning.detail.isEmpty)
    }
}
