import Foundation

/// How long Zenith keeps the Mac awake. Keeping it awake with the lid closed is not offered: that needs `pmset`
/// and administrator rights.
public enum KeepAwakeMode: Sendable, Equatable, Hashable {
    /// For a fixed time, then the Mac may sleep again.
    case duration(TimeInterval)
    /// Until the user turns it off (or quits Zenith).
    case indefinite
    /// While at least one of the chosen apps runs.
    case whileAppsRunning
    /// While the power adapter is connected.
    case whileOnACPower

    /// The durations offered in menus.
    public static let presetDurations: [TimeInterval] = [15 * 60, 3_600, 2 * 3_600, 5 * 3_600]

    public var title: String {
        switch self {
        case .duration(let seconds): return Self.durationTitle(seconds)
        case .indefinite: return String(localized: "Until Turned Off")
        case .whileAppsRunning: return String(localized: "While Chosen Apps Run")
        case .whileOnACPower: return String(localized: "While on Power Adapter")
        }
    }

    /// "15 min", "1 h", "1 h 30 min".
    public static func durationTitle(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return String(localized: "\(minutes) min") }
        if rest == 0 { return String(localized: "\(hours) h") }
        return String(localized: "\(hours) h \(rest) min")
    }
}

/// The pure decisions behind keep awake, kept apart from the clock and the system so they can be tested.
public enum KeepAwakePolicy {
    /// Whether a timed mode has run out.
    public static func hasExpired(endDate: Date?, now: Date) -> Bool {
        guard let endDate else { return false }
        return endDate.timeIntervalSince(now) <= 0
    }

    /// Whether the assertion should be held now. App and power modes stay armed while their condition is false:
    /// the assertion is released then, and taken again when the app starts or the adapter is connected.
    public static func shouldHoldAssertion(
        mode: KeepAwakeMode?,
        endDate: Date?,
        now: Date,
        runningBundleIdentifiers: Set<String>,
        watchedBundleIdentifiers: Set<String>,
        isOnACPower: Bool
    ) -> Bool {
        switch mode {
        case nil:
            return false
        case .duration:
            return !hasExpired(endDate: endDate, now: now)
        case .indefinite:
            return true
        case .whileAppsRunning:
            return !watchedBundleIdentifiers.isDisjoint(with: runningBundleIdentifiers)
        case .whileOnACPower:
            return isOnACPower
        }
    }

    /// The kind of assertion for the display setting.
    public static func assertionKind(keepsDisplayOn: Bool) -> PowerAssertionKind {
        keepsDisplayOn ? .preventIdleDisplaySleep : .preventIdleSystemSleep
    }
}

/// Keep awake as the island and the hub show it.
public struct KeepAwakeSnapshot: Sendable, Equatable {
    public let mode: KeepAwakeMode
    /// Whether the Mac is being kept awake right now (an app or power mode can be armed but waiting).
    public let isHoldingAssertion: Bool
    public let keepsDisplayOn: Bool
    /// Seconds left in a timed mode; nil for the others.
    public let remaining: TimeInterval?

    public init(mode: KeepAwakeMode, isHoldingAssertion: Bool, keepsDisplayOn: Bool, remaining: TimeInterval?) {
        self.mode = mode
        self.isHoldingAssertion = isHoldingAssertion
        self.keepsDisplayOn = keepsDisplayOn
        self.remaining = remaining
    }

    /// "1:59:59" for a timed mode (rounded up, like the focus timer), nil otherwise.
    public var remainingText: String? {
        remaining.map(FocusTimerSnapshot.format)
    }

    /// A short status line: the time left, or what the mode waits for.
    public var statusText: String {
        if let remainingText { return String(localized: "\(remainingText) left") }
        switch mode {
        case .indefinite, .duration:
            return String(localized: "Until turned off")
        case .whileAppsRunning:
            return isHoldingAssertion ? String(localized: "A chosen app is running") : String(localized: "Waiting for a chosen app")
        case .whileOnACPower:
            return isHoldingAssertion ? String(localized: "On the power adapter") : String(localized: "Waiting for the power adapter")
        }
    }

    /// What VoiceOver reads for the island indicator.
    public var accessibilityDescription: String {
        if let remainingText { return String(localized: "Keeping the Mac awake, \(remainingText) left") }
        return String(localized: "Keeping the Mac awake")
    }
}

// MARK: - Closed island

/// What sits beside the notch while the island is closed. One at a time, in this order of priority.
public enum IslandCompactActivity: Sendable, Equatable {
    case focusTimer
    case nowPlaying
    case keepAwake
}

public extension ZenithIslandState {
    /// The compact activity to draw: a running timer first, then playing media, then keep awake.
    var compactActivity: IslandCompactActivity? {
        if focusTimer != nil { return .focusTimer }
        if nowPlayingTrack?.isPlaying == true { return .nowPlaying }
        if keepAwake != nil { return .keepAwake }
        return nil
    }

    /// Whether the compact activity needs the wider wings (`timerIdleWidth`) to fit a time.
    var compactActivityUsesWideWings: Bool {
        switch compactActivity {
        case .focusTimer: return true
        case .keepAwake: return keepAwake?.remaining != nil
        case .nowPlaying, nil: return false
        }
    }
}
