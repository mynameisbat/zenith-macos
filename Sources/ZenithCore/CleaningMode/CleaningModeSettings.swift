import Foundation
import Combine

/// How the screen looks while Cleaning Mode blocks input.
public enum CleaningModeAppearance: String, CaseIterable, Sendable, Identifiable {
    /// Every display goes black, so smudges show up best.
    case black
    /// The screen stays visible behind a dark veil, with a small indicator.
    case dimmed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .black: return String(localized: "Black Screen")
        case .dimmed: return String(localized: "Dimmed")
        }
    }
}

/// The Cleaning Mode preferences: how long it lasts, how it looks, and whether its global shortcut is on.
/// An `ObservableObject` (not `@Observable`, which needs macOS 14); every setter calls `objectWillChange.send()`.
@MainActor
public final class CleaningModeSettings: ObservableObject {
    public static let shared = CleaningModeSettings()

    public enum Keys {
        public static let duration = "zenith.cleaningMode.durationSeconds"
        public static let appearance = "zenith.cleaningMode.appearance"
        public static let hotKeyEnabled = "zenith.cleaningMode.hotKeyEnabled"
    }

    /// The shortest and longest time limit. Cleaning Mode always ends by itself, at the latest after five minutes.
    public static let minimumDuration = 15
    public static let maximumDuration = 300
    public static let defaultDuration = 60
    /// The choices offered in Settings.
    public static let durationChoices = [15, 30, 45, 60, 90, 120, 180, 300]

    private let defaults: UserDefaults
    private var _durationSeconds: Int
    private var _appearance: CleaningModeAppearance
    private var _hotKeyEnabled: Bool

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        let stored = userDefaults.object(forKey: Keys.duration) as? Int ?? Self.defaultDuration
        self._durationSeconds = Self.clamp(stored)
        self._appearance = userDefaults.string(forKey: Keys.appearance).flatMap(CleaningModeAppearance.init(rawValue:)) ?? .black
        self._hotKeyEnabled = userDefaults.bool(forKey: Keys.hotKeyEnabled)
    }

    /// How long input stays blocked, in seconds (15 to 300, default 60).
    public var durationSeconds: Int {
        get { _durationSeconds }
        set {
            objectWillChange.send()
            _durationSeconds = Self.clamp(newValue)
            defaults.set(_durationSeconds, forKey: Keys.duration)
        }
    }

    public var appearance: CleaningModeAppearance {
        get { _appearance }
        set {
            objectWillChange.send()
            _appearance = newValue
            defaults.set(newValue.rawValue, forKey: Keys.appearance)
        }
    }

    /// Whether the global shortcut that starts Cleaning Mode is registered. Off by default.
    public var hotKeyEnabled: Bool {
        get { _hotKeyEnabled }
        set {
            objectWillChange.send()
            _hotKeyEnabled = newValue
            defaults.set(newValue, forKey: Keys.hotKeyEnabled)
        }
    }

    public static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, minimumDuration), maximumDuration)
    }

    /// A duration in words, as the system's locale writes it ("1 minute, 30 seconds").
    public nonisolated static func durationText(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }

    /// A duration as a clock shows it ("1:05").
    public nonisolated static func countdownText(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}
