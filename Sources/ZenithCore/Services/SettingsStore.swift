import Foundation
import Observation
import Combine

/// High-performance, thread-safe user configuration store backed by UserDefaults.
/// Conforms to both `@Observable` (modern macOS 14+ SwiftUI) and `ObservableObject` (Combine / AppKit).
@Observable
public final class SettingsStore: ObservableObject, @unchecked Sendable {
    public static let shared = SettingsStore()

    @ObservationIgnored
    private let lock = NSLock()
    @ObservationIgnored
    private let userDefaults: UserDefaults

    // MARK: - UserDefaults Keys
    public enum Keys {
        public static let historyLimit = "gg_history_limit"
        public static let soundEffectsEnabled = "gg_sound_effects_enabled"
        public static let soundVolume = "gg_sound_volume"
        public static let launchAtLoginEnabled = "gg_launch_at_login_enabled"
        public static let hotkeyMappings = "gg_hotkey_mappings"
        public static let soundEffectAssignments = "gg_sound_effect_assignments"
        public static let dohProvider = "gg_doh_provider"
    }

    // MARK: - Constants & Defaults
    public static let minHistoryLimit: Int = 5
    public static let maxHistoryLimit: Int = 500
    public static let defaultHistoryLimit: Int = 20
    public static let defaultSoundEffectsEnabled: Bool = true
    public static let defaultSoundVolume: Float = 0.8
    public static let defaultLaunchAtLoginEnabled: Bool = false

    // MARK: - Backing Storage (Protected by NSLock)
    @ObservationIgnored
    private var _historyLimit: Int
    @ObservationIgnored
    private var _soundEffectsEnabled: Bool
    @ObservationIgnored
    private var _soundVolume: Float
    @ObservationIgnored
    private var _launchAtLoginEnabled: Bool
    @ObservationIgnored
    private var _hotkeyMappings: [String: HotKeyDefinition]
    @ObservationIgnored
    private var _soundEffectAssignments: [String: SoundChoice]
    @ObservationIgnored
    private var _dohProvider: DoHProvider

    // MARK: - Observable Properties

    /// Maximum number of clipboard history items retained before FIFO eviction.
    /// Strictly clamped to the range [5, 500]. Defaults to 20.
    public var historyLimit: Int {
        get {
            access(keyPath: \.historyLimit)
            lock.lock()
            defer { lock.unlock() }
            return _historyLimit
        }
        set {
            withMutation(keyPath: \.historyLimit) {
                let clamped = min(max(newValue, Self.minHistoryLimit), Self.maxHistoryLimit)
                lock.lock()
                _historyLimit = clamped
                userDefaults.set(clamped, forKey: Keys.historyLimit)
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// Whether sound effects (copy pop, paste sound, shutter click) are played.
    /// Defaults to true.
    public var soundEffectsEnabled: Bool {
        get {
            access(keyPath: \.soundEffectsEnabled)
            lock.lock()
            defer { lock.unlock() }
            return _soundEffectsEnabled
        }
        set {
            withMutation(keyPath: \.soundEffectsEnabled) {
                lock.lock()
                _soundEffectsEnabled = newValue
                userDefaults.set(newValue, forKey: Keys.soundEffectsEnabled)
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// Master volume level for audio feedback [0.0, 1.0]. Defaults to 0.8.
    public var soundVolume: Float {
        get {
            access(keyPath: \.soundVolume)
            lock.lock()
            defer { lock.unlock() }
            return _soundVolume
        }
        set {
            withMutation(keyPath: \.soundVolume) {
                let clamped = min(max(newValue, 0.0), 1.0)
                lock.lock()
                _soundVolume = clamped
                userDefaults.set(clamped, forKey: Keys.soundVolume)
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// Whether Zenith registers with SMAppService to launch on system login.
    /// Defaults to false.
    public var launchAtLoginEnabled: Bool {
        get {
            access(keyPath: \.launchAtLoginEnabled)
            lock.lock()
            defer { lock.unlock() }
            return _launchAtLoginEnabled
        }
        set {
            withMutation(keyPath: \.launchAtLoginEnabled) {
                lock.lock()
                _launchAtLoginEnabled = newValue
                userDefaults.set(newValue, forKey: Keys.launchAtLoginEnabled)
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// Semantic alias for launchAtLoginEnabled.
    public var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set { launchAtLoginEnabled = newValue }
    }

    /// Dictionary mapping shortcut action IDs to their configured HotKeyDefinition.
    public var hotkeyMappings: [String: HotKeyDefinition] {
        get {
            access(keyPath: \.hotkeyMappings)
            lock.lock()
            defer { lock.unlock() }
            return _hotkeyMappings
        }
        set {
            withMutation(keyPath: \.hotkeyMappings) {
                lock.lock()
                _hotkeyMappings = newValue
                Self.saveHotkeys(newValue, to: userDefaults)
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// Dictionary mapping semantic sound effect actions to their configured SoundChoice.
    public var soundEffectAssignments: [String: SoundChoice] {
        get {
            access(keyPath: \.soundEffectAssignments)
            lock.lock()
            defer { lock.unlock() }
            return _soundEffectAssignments
        }
        set {
            withMutation(keyPath: \.soundEffectAssignments) {
                lock.lock()
                _soundEffectAssignments = newValue
                Self.saveSoundAssignments(newValue, to: userDefaults)
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// DNS-over-HTTPS encrypted provider preference.
    public var dohProvider: DoHProvider {
        get {
            access(keyPath: \.dohProvider)
            lock.lock()
            defer { lock.unlock() }
            return _dohProvider
        }
        set {
            withMutation(keyPath: \.dohProvider) {
                lock.lock()
                _dohProvider = newValue
                Self.saveDoHProvider(newValue, to: userDefaults)
                lock.unlock()
                notifyChange()
            }
        }
    }

    // MARK: - Initializer

    /// Initializes a SettingsStore instance with a target UserDefaults container.
    /// - Parameter userDefaults: Backing UserDefaults instance (defaults to `.standard`).
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // 1. History limit with boundary clamping
        let storedLimit = userDefaults.object(forKey: Keys.historyLimit) as? Int ?? Self.defaultHistoryLimit
        self._historyLimit = min(max(storedLimit, Self.minHistoryLimit), Self.maxHistoryLimit)

        // 2. Sound effects with explicit true default fallback
        if let storedSound = userDefaults.object(forKey: Keys.soundEffectsEnabled) as? Bool {
            self._soundEffectsEnabled = storedSound
        } else {
            self._soundEffectsEnabled = Self.defaultSoundEffectsEnabled
        }

        // 2b. Sound volume level
        if let storedVolume = userDefaults.object(forKey: Keys.soundVolume) as? Float {
            self._soundVolume = min(max(storedVolume, 0.0), 1.0)
        } else if let storedDouble = userDefaults.object(forKey: Keys.soundVolume) as? Double {
            self._soundVolume = min(max(Float(storedDouble), 0.0), 1.0)
        } else {
            self._soundVolume = Self.defaultSoundVolume
        }

        // 3. Launch at login
        self._launchAtLoginEnabled = userDefaults.bool(forKey: Keys.launchAtLoginEnabled)

        // 4. Hotkey mappings with preset fallback
        self._hotkeyMappings = Self.loadHotkeys(from: userDefaults)

        // 5. Sound effect assignments
        self._soundEffectAssignments = Self.loadSoundAssignments(from: userDefaults)

        // 6. DoH Provider
        self._dohProvider = Self.loadDoHProvider(from: userDefaults)
    }

    // MARK: - Public Management Operations

    /// Resets all preferences back to out-of-the-box defaults and clears persisted overrides.
    public func resetToDefaults() {
        withMutation(keyPath: \.historyLimit) {
            withMutation(keyPath: \.soundEffectsEnabled) {
                withMutation(keyPath: \.soundVolume) {
                    withMutation(keyPath: \.launchAtLoginEnabled) {
                        withMutation(keyPath: \.hotkeyMappings) {
                            withMutation(keyPath: \.soundEffectAssignments) {
                                withMutation(keyPath: \.dohProvider) {
                                    lock.lock()
                                    _historyLimit = Self.defaultHistoryLimit
                                    _soundEffectsEnabled = Self.defaultSoundEffectsEnabled
                                    _soundVolume = Self.defaultSoundVolume
                                    _launchAtLoginEnabled = Self.defaultLaunchAtLoginEnabled
                                    _hotkeyMappings = HotKeyDefinition.defaultDictionary
                                    _soundEffectAssignments = SoundChoice.defaultAssignments
                                    _dohProvider = .cloudflare

                                    userDefaults.removeObject(forKey: Keys.historyLimit)
                                    userDefaults.removeObject(forKey: Keys.soundEffectsEnabled)
                                    userDefaults.removeObject(forKey: Keys.soundVolume)
                                    userDefaults.removeObject(forKey: Keys.launchAtLoginEnabled)
                                    userDefaults.removeObject(forKey: Keys.hotkeyMappings)
                                    userDefaults.removeObject(forKey: Keys.soundEffectAssignments)
                                    userDefaults.removeObject(forKey: Keys.dohProvider)
                                    lock.unlock()

                                    notifyChange()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Updates or replaces the definition for a specific shortcut action.
    /// - Parameter definition: The new hotkey definition.
    public func updateHotkey(_ definition: HotKeyDefinition) {
        var current = hotkeyMappings
        current[definition.id] = definition
        self.hotkeyMappings = current
    }

    /// Retrieves the hotkey definition configured for a given action ID.
    /// - Parameter id: Unique action identifier (e.g. "clipboard.toggle").
    /// - Returns: The registered HotKeyDefinition, or nil if none exists.
    public func hotkey(for id: String) -> HotKeyDefinition? {
        hotkeyMappings[id]
    }

    /// Atomic value snapshot of the current settings.
    public var state: SettingsState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return SettingsState(
                historyLimit: _historyLimit,
                soundEffectsEnabled: _soundEffectsEnabled,
                launchAtLoginEnabled: _launchAtLoginEnabled,
                hotkeyMappings: _hotkeyMappings,
                soundVolume: _soundVolume,
                soundEffectAssignments: _soundEffectAssignments
            )
        }
        set {
            historyLimit = newValue.historyLimit
            soundEffectsEnabled = newValue.soundEffectsEnabled
            launchAtLoginEnabled = newValue.launchAtLoginEnabled
            hotkeyMappings = newValue.hotkeyMappings
            soundVolume = newValue.soundVolume
            soundEffectAssignments = newValue.soundEffectAssignments
        }
    }

    // MARK: - Private Helpers

    private func notifyChange() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    private static func loadHotkeys(from defaults: UserDefaults) -> [String: HotKeyDefinition] {
        guard let data = defaults.data(forKey: Keys.hotkeyMappings),
              let decoded = try? JSONDecoder().decode([String: HotKeyDefinition].self, from: data) else {
            return HotKeyDefinition.defaultDictionary
        }
        return decoded
    }

    private static func saveHotkeys(_ mappings: [String: HotKeyDefinition], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(mappings) {
            defaults.set(data, forKey: Keys.hotkeyMappings)
        }
    }

    private static func loadSoundAssignments(from defaults: UserDefaults) -> [String: SoundChoice] {
        guard let data = defaults.data(forKey: Keys.soundEffectAssignments),
              let decoded = try? JSONDecoder().decode([String: SoundChoice].self, from: data) else {
            return SoundChoice.defaultAssignments
        }
        return decoded
    }

    private static func saveSoundAssignments(_ assignments: [String: SoundChoice], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(assignments) {
            defaults.set(data, forKey: Keys.soundEffectAssignments)
        }
    }

    private static func loadDoHProvider(from defaults: UserDefaults) -> DoHProvider {
        guard let data = defaults.data(forKey: Keys.dohProvider),
              let decoded = try? JSONDecoder().decode(DoHProvider.self, from: data) else {
            if let str = defaults.string(forKey: Keys.dohProvider) {
                switch str.lowercased() {
                case "cloudflare": return .cloudflare
                case "adguard": return .adguard
                case "google": return .google
                case "quad9": return .quad9
                default: break
                }
            }
            return .cloudflare
        }
        return decoded
    }

    private static func saveDoHProvider(_ provider: DoHProvider, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(provider) {
            defaults.set(data, forKey: Keys.dohProvider)
        }
    }
}
