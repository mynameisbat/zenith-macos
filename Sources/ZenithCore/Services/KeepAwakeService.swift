import Combine
import Foundation

// MARK: - Settings

/// Keep-awake preferences, saved in `UserDefaults`. The mode itself is not saved: keep awake ends when Zenith quits.
@MainActor
public final class KeepAwakeSettings: ObservableObject {
    public static let shared = KeepAwakeSettings()

    public enum Keys {
        public static let keepsDisplayOn = "zenith_keep_awake_display_on"
        public static let showsOnIsland = "zenith_keep_awake_show_on_island"
        public static let customMinutes = "zenith_keep_awake_custom_minutes"
        public static let watchedApps = "zenith_keep_awake_watched_apps"
        public static let hotKeyEnabled = "zenith_keep_awake_hot_key_enabled"
    }

    public static let customMinutesRange = 5...1_440
    public static let customMinutesStep = 5
    public static let defaultCustomMinutes = 45

    /// Sent after any setting changed.
    public let didChange = PassthroughSubject<Void, Never>()

    /// Also keep the display from dimming and turning off.
    @Published public var keepsDisplayOn: Bool {
        didSet { save(keepsDisplayOn, Keys.keepsDisplayOn) }
    }

    /// Show an indicator on the closed Dynamic Island while the Mac is kept awake.
    @Published public var showsOnIsland: Bool {
        didSet { save(showsOnIsland, Keys.showsOnIsland) }
    }

    /// The "Custom" duration in the menus.
    @Published public var customMinutes: Int {
        didSet {
            let clamped = Self.clampedMinutes(customMinutes)
            if clamped != customMinutes { customMinutes = clamped; return }
            save(clamped, Keys.customMinutes)
        }
    }

    /// The apps for "while chosen apps run".
    @Published public var watchedApps: [KeepAwakeApp] {
        didSet {
            if let data = try? JSONEncoder().encode(watchedApps) { userDefaults.set(data, forKey: Keys.watchedApps) }
            didChange.send()
        }
    }

    /// Whether the global shortcut is registered (off by default).
    @Published public var hotKeyEnabled: Bool {
        didSet { save(hotKeyEnabled, Keys.hotKeyEnabled) }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        keepsDisplayOn = userDefaults.object(forKey: Keys.keepsDisplayOn) as? Bool ?? false
        showsOnIsland = userDefaults.object(forKey: Keys.showsOnIsland) as? Bool ?? true
        customMinutes = Self.clampedMinutes(userDefaults.object(forKey: Keys.customMinutes) as? Int ?? Self.defaultCustomMinutes)
        hotKeyEnabled = userDefaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? false
        if let data = userDefaults.data(forKey: Keys.watchedApps),
           let apps = try? JSONDecoder().decode([KeepAwakeApp].self, from: data) {
            watchedApps = apps
        } else {
            watchedApps = []
        }
    }

    public var watchedBundleIdentifiers: Set<String> {
        Set(watchedApps.map(\.bundleIdentifier))
    }

    public func addWatchedApp(_ app: KeepAwakeApp) {
        guard !watchedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        watchedApps.append(app)
    }

    public func removeWatchedApp(bundleIdentifier: String) {
        watchedApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    public static func clampedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, customMinutesRange.lowerBound), customMinutesRange.upperBound)
    }

    public func resetToDefaults() {
        keepsDisplayOn = false
        showsOnIsland = true
        customMinutes = Self.defaultCustomMinutes
        watchedApps = []
        hotKeyEnabled = false
    }

    private func save(_ value: Any, _ key: String) {
        userDefaults.set(value, forKey: key)
        didChange.send()
    }
}

// MARK: - Service

/// Keeps the Mac awake with an IOKit power assertion, for a time, until turned off, while chosen apps run, or while on
/// the power adapter.
///
/// A timed mode counts down to an end date (right across sleep). The assertion is released as soon as the mode ends,
/// when the user turns it off, and on quit (`stop()` from `applicationWillTerminate`; macOS also drops it if the
/// process dies). App and power modes stay armed while their condition is false and only hold the assertion while it
/// is true; they are told about launches, quits and power changes, nothing polls.
@MainActor
public final class KeepAwakeService: ObservableObject {
    public static let shared = KeepAwakeService()

    /// The mode the user chose, or nil when off.
    @Published public private(set) var mode: KeepAwakeMode?
    /// Whether an assertion is held right now.
    @Published public private(set) var isHoldingAssertion = false
    @Published public private(set) var snapshot: KeepAwakeSnapshot?
    /// Set when the system refused the assertion.
    @Published public private(set) var assertionFailed = false

    public var isActive: Bool { mode != nil }

    public let settings: KeepAwakeSettings
    private let assertions: PowerAssertionProviding
    private let apps: RunningApplicationsProviding
    private let power: PowerSourceProviding
    private let now: () -> Date
    private weak var island: ZenithIslandState?
    private let autoTick: Bool

    private var endDate: Date?
    private var assertionID: UInt32?
    private var assertionKind: PowerAssertionKind?
    private var tickTask: Task<Void, Never>?
    private var settingsSubscription: AnyCancellable?
    private var observesApps = false
    private var observesPower = false

    static let assertionReason = "Zenith: Keep Awake"

    /// - Parameters:
    ///   - autoTick: Whether a timed mode refreshes once a second on its own; tests call `tick()` instead.
    public init(
        settings: KeepAwakeSettings? = nil,
        assertions: PowerAssertionProviding? = nil,
        apps: RunningApplicationsProviding? = nil,
        power: PowerSourceProviding? = nil,
        now: @escaping () -> Date = Date.init,
        island: ZenithIslandState? = .shared,
        autoTick: Bool = true
    ) {
        self.settings = settings ?? .shared
        self.assertions = assertions ?? IOKitPowerAssertionProvider()
        self.apps = apps ?? WorkspaceRunningApplications()
        self.power = power ?? IOKitPowerSource()
        self.now = now
        self.island = island
        self.autoTick = autoTick
        settingsSubscription = self.settings.didChange.sink { [weak self] in
            // `didChange` is sent from the settings' didSet, on the main actor.
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }

    // MARK: Controls

    /// Starts (or replaces) a mode. A duration of zero or less is ignored.
    public func start(_ newMode: KeepAwakeMode) {
        if case .duration(let seconds) = newMode {
            guard seconds > 0 else { return }
            endDate = now().addingTimeInterval(seconds)
        } else {
            endDate = nil
        }
        mode = newMode
        updateObservation()
        reevaluate()
        if case .duration = newMode { startTicking() } else { stopTicking() }
    }

    /// Starts a timed mode of `minutes`.
    public func start(minutes: Int) {
        start(.duration(TimeInterval(max(1, minutes) * 60)))
    }

    /// Turns keep awake off and releases the assertion at once.
    public func stop() {
        mode = nil
        endDate = nil
        stopTicking()
        updateObservation()
        reevaluate()
    }

    /// Off if on; otherwise "until turned off". What the shortcut and the hub's switch do.
    public func toggle() {
        if isActive { stop() } else { start(.indefinite) }
    }

    /// Seconds left in a timed mode.
    public var remaining: TimeInterval? {
        endDate.map { max(0, $0.timeIntervalSince(now())) }
    }

    /// Ends a timed mode that has run out, and refreshes the time shown.
    public func tick() {
        if KeepAwakePolicy.hasExpired(endDate: endDate, now: now()) {
            stop()
        } else {
            publish()
        }
    }

    /// Takes or releases the assertion to match the mode, the running apps, the power source and the settings.
    public func reevaluate() {
        if KeepAwakePolicy.hasExpired(endDate: endDate, now: now()) {
            mode = nil
            endDate = nil
            stopTicking()
            updateObservation()
        }
        let hold = KeepAwakePolicy.shouldHoldAssertion(
            mode: mode,
            endDate: endDate,
            now: now(),
            runningBundleIdentifiers: mode == .whileAppsRunning ? apps.runningBundleIdentifiers() : [],
            watchedBundleIdentifiers: settings.watchedBundleIdentifiers,
            isOnACPower: mode == .whileOnACPower ? power.isOnACPower : false
        )
        let kind = KeepAwakePolicy.assertionKind(keepsDisplayOn: settings.keepsDisplayOn)
        if hold {
            if assertionID == nil || assertionKind != kind {
                // Take the new one before letting the old one go, so the Mac is never left without one.
                let old = assertionID
                if let id = assertions.createAssertion(kind, reason: Self.assertionReason) {
                    assertionID = id
                    assertionKind = kind
                    assertionFailed = false
                } else {
                    assertionID = nil
                    assertionKind = nil
                    assertionFailed = true
                }
                if let old { assertions.releaseAssertion(old) }
            }
        } else {
            releaseAssertion()
            assertionFailed = false
        }
        let holding = assertionID != nil
        if isHoldingAssertion != holding { isHoldingAssertion = holding }
        publish()
    }

    // MARK: Internals

    private func releaseAssertion() {
        if let id = assertionID {
            assertions.releaseAssertion(id)
        }
        assertionID = nil
        assertionKind = nil
    }

    private func updateObservation() {
        let wantsApps = mode == .whileAppsRunning
        if wantsApps != observesApps {
            observesApps = wantsApps
            if wantsApps {
                apps.startObserving { [weak self] in self?.reevaluate() }
            } else {
                apps.stopObserving()
            }
        }
        let wantsPower = mode == .whileOnACPower
        if wantsPower != observesPower {
            observesPower = wantsPower
            if wantsPower {
                power.startObserving { [weak self] in self?.reevaluate() }
            } else {
                power.stopObserving()
            }
        }
    }

    private func publish() {
        let value = mode.map {
            KeepAwakeSnapshot(mode: $0, isHoldingAssertion: assertionID != nil, keepsDisplayOn: settings.keepsDisplayOn, remaining: remaining)
        }
        if snapshot != value { snapshot = value }
        // The island shows it only while the Mac is really being kept awake.
        let shown = (settings.showsOnIsland && value?.isHoldingAssertion == true) ? value : nil
        if island?.keepAwake != shown { island?.keepAwake = shown }
    }

    private func startTicking() {
        guard autoTick else { return }
        stopTicking()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}

// MARK: - Global shortcut

public extension HotKeyDefinition {
    static let keepAwakeToggleId = "keepAwake.toggle"

    /// ⌃⌥K ("K for keep awake"). Registered only when the user turns the shortcut on.
    static let defaultKeepAwake = HotKeyDefinition(
        id: keepAwakeToggleId,
        name: "Keep Awake",
        keyCode: 40, // kVK_ANSI_K
        carbonModifiers: CarbonModifierFlags.control.rawValue | CarbonModifierFlags.option.rawValue,
        keyEquivalent: "⌃⌥K"
    )
}

/// The optional global shortcut that turns keep awake on ("until turned off") and off. It uses the same
/// `SettingsStore` mapping and `HotKeyManager` as the other shortcuts, but is registered only while switched on.
@MainActor
public final class KeepAwakeHotKeyController: ObservableObject {
    public static let shared = KeepAwakeHotKeyController()

    /// The last registration failed (another app holds the keys).
    @Published public private(set) var registrationFailed = false
    /// Why the last shortcut change was refused, ready to show; nil after one that worked.
    @Published public private(set) var changeProblem: String?

    private let settings: KeepAwakeSettings
    private let store: SettingsStore
    private let manager: HotKeyManager
    private let onTrigger: @MainActor () -> Void

    public init(
        settings: KeepAwakeSettings? = nil,
        store: SettingsStore = .shared,
        manager: HotKeyManager = .shared,
        onTrigger: (@MainActor () -> Void)? = nil
    ) {
        self.settings = settings ?? .shared
        self.store = store
        self.manager = manager
        self.onTrigger = onTrigger ?? { KeepAwakeService.shared.toggle() }
    }

    /// The saved shortcut, or ⌃⌥K.
    public var definition: HotKeyDefinition {
        store.hotkey(for: HotKeyDefinition.keepAwakeToggleId) ?? .defaultKeepAwake
    }

    public var isRegistered: Bool {
        manager.isRegistered(id: HotKeyDefinition.keepAwakeToggleId)
    }

    /// Registers or removes the shortcut to match the setting. Call at launch and after the setting changes.
    @discardableResult
    public func apply() -> Bool {
        let id = HotKeyDefinition.keepAwakeToggleId
        guard settings.hotKeyEnabled else {
            manager.unregisterHotKey(id: id)
            registrationFailed = false
            return true
        }
        let wanted = definition
        if manager.registeredHotKeys[id] == wanted {
            registrationFailed = false
            return true
        }
        let trigger = onTrigger
        let ok = manager.registerHotKey(wanted) {
            Task { @MainActor in trigger() }
        }
        registrationFailed = !ok
        return ok
    }

    /// Turns the shortcut on or off.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        settings.hotKeyEnabled = enabled
        return apply()
    }

    /// A new key combination. Saved only if no other Zenith shortcut uses it and (when switched on) the system takes it.
    @discardableResult
    public func change(_ newDefinition: HotKeyDefinition) -> HotKeyChangeResult {
        let candidate = HotKeyDefinition(
            id: HotKeyDefinition.keepAwakeToggleId,
            name: HotKeyDefinition.defaultKeepAwake.name,
            keyCode: newDefinition.keyCode,
            carbonModifiers: newDefinition.carbonModifiers,
            keyEquivalent: newDefinition.keyEquivalent
        )
        if let other = manager.findConflict(for: candidate) {
            changeProblem = String(localized: "\(candidate.menuStyleKeyEquivalent) is already used by another Zenith shortcut (\(other.name)).")
            return .conflict(with: other.name)
        }
        if isRegistered {
            guard manager.reRegister(definition: candidate) else {
                changeProblem = String(localized: "\(candidate.menuStyleKeyEquivalent) could not be registered, probably because another app uses it.")
                return .unavailable
            }
        }
        store.updateHotkey(candidate)
        changeProblem = nil
        objectWillChange.send()
        return .applied
    }

    @discardableResult
    public func resetToDefault() -> HotKeyChangeResult {
        change(.defaultKeepAwake)
    }
}
