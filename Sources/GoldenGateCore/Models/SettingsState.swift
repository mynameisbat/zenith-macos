import Foundation

/// Value state representing an atomic snapshot of all user preferences.
public struct SettingsState: Sendable, Equatable, Hashable, Codable {
    /// Number of items retained in history before FIFO eviction begins [5, 500].
    public var historyLimit: Int {
        didSet {
            historyLimit = min(max(historyLimit, 5), 500)
        }
    }

    /// Whether audio cues are emitted during copy, paste, and screen capture.
    public var soundEffectsEnabled: Bool

    /// Whether the application launches automatically on system login.
    public var launchAtLoginEnabled: Bool

    /// User customized global shortcut definitions keyed by action identifier.
    public var hotkeyMappings: [String: HotKeyDefinition]

    /// Volume level for audio feedback cues [0.0, 1.0]. Defaults to 0.8.
    public var soundVolume: Float

    /// Configured sound effect choice per semantic action identifier.
    public var soundEffectAssignments: [String: SoundChoice]

    public init(
        historyLimit: Int = 20,
        soundEffectsEnabled: Bool = true,
        launchAtLoginEnabled: Bool = false,
        hotkeyMappings: [String: HotKeyDefinition] = HotKeyDefinition.defaultDictionary,
        soundVolume: Float = 0.8,
        soundEffectAssignments: [String: SoundChoice] = SoundChoice.defaultAssignments
    ) {
        self.historyLimit = min(max(historyLimit, 5), 500)
        self.soundEffectsEnabled = soundEffectsEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.hotkeyMappings = hotkeyMappings
        self.soundVolume = min(max(soundVolume, 0.0), 1.0)
        self.soundEffectAssignments = soundEffectAssignments
    }

    private enum CodingKeys: String, CodingKey {
        case historyLimit
        case soundEffectsEnabled
        case launchAtLoginEnabled
        case hotkeyMappings
        case soundVolume
        case soundEffectAssignments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.historyLimit = try container.decode(Int.self, forKey: .historyLimit)
        self.soundEffectsEnabled = try container.decode(Bool.self, forKey: .soundEffectsEnabled)
        self.launchAtLoginEnabled = try container.decode(Bool.self, forKey: .launchAtLoginEnabled)
        self.hotkeyMappings = try container.decode([String: HotKeyDefinition].self, forKey: .hotkeyMappings)
        self.soundVolume = try container.decodeIfPresent(Float.self, forKey: .soundVolume) ?? 0.8
        self.soundEffectAssignments = try container.decodeIfPresent([String: SoundChoice].self, forKey: .soundEffectAssignments) ?? SoundChoice.defaultAssignments
    }

    /// Convenience alias for launchAtLoginEnabled.
    public var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set { launchAtLoginEnabled = newValue }
    }

    /// Convenience alias for hotkeyMappings.
    public var hotkeys: [String: HotKeyDefinition] {
        get { hotkeyMappings }
        set { hotkeyMappings = newValue }
    }

    /// Default out-of-the-box settings state.
    public static let defaultState = SettingsState()
}
