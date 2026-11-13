import Foundation
import Combine

// MARK: - Focus Timer

/// What a focus timer is counting: a focus session or a break after one.
public enum FocusTimerMode: String, Sendable, Codable, CaseIterable {
    case focus
    case shortBreak

    public var title: String {
        switch self {
        case .focus: return String(localized: "Focus")
        case .shortBreak: return String(localized: "Break")
        }
    }

    public var symbolName: String {
        switch self {
        case .focus: return "timer"
        case .shortBreak: return "cup.and.saucer.fill"
        }
    }
}

/// A running or paused timer, as the island shows it.
public struct FocusTimerSnapshot: Sendable, Equatable {
    public let mode: FocusTimerMode
    public let isPaused: Bool
    public let duration: TimeInterval
    public let remaining: TimeInterval

    public init(mode: FocusTimerMode, isPaused: Bool, duration: TimeInterval, remaining: TimeInterval) {
        self.mode = mode
        self.isPaused = isPaused
        self.duration = duration
        self.remaining = remaining
    }

    /// How much of the timer has passed, 0...1.
    public var progress: Double {
        guard duration > 0 else { return 1 }
        return min(max(1 - remaining / duration, 0), 1)
    }

    public var remainingText: String {
        Self.format(remaining)
    }

    /// "25:00", "9:59", "0:05", or "1:05:00" past an hour. Rounds up, so a timer never shows 0:00 while still running.
    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Calendar

/// Whether Zenith may read the user's calendars.
public enum CalendarAccessState: Sendable, Equatable {
    case notDetermined
    case denied
    case granted
    /// Running outside an app bundle (e.g. `swift run`): macOS would end the process if it were asked.
    case unavailable
}

/// A calendar event, reduced to what the island shows.
public struct UpcomingEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?
    /// The calendar's color as sRGB components, when known.
    public let colorComponents: [Double]?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        colorComponents: [Double]? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.colorComponents = colorComponents
    }

    public func isOngoing(at now: Date) -> Bool {
        start <= now && now < end
    }

    /// "Now · until 10:30", "In 5 min", "In 1 h 20 min", or "At 15:00" when it is further away.
    public func relativeDescription(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        if isOngoing(at: now) {
            return String(localized: "Now · until \(timeFormatter.string(from: end))")
        }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 {
            return String(localized: "Now")
        }
        if minutes < 60 {
            return String(localized: "In \(minutes) min")
        }
        if minutes < 180 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? String(localized: "In \(hours) h") : String(localized: "In \(hours) h \(rest) min")
        }
        if calendar.isDate(start, inSameDayAs: now) {
            return String(localized: "At \(timeFormatter.string(from: start))")
        }
        return String(localized: "Tomorrow at \(timeFormatter.string(from: start))")
    }

    /// The event to show: one going on now (the one that started last), otherwise the next to start within
    /// `lookahead`. All-day events are left out, they would always be "now".
    public static func next(from events: [UpcomingEvent], now: Date, lookahead: TimeInterval = 12 * 3_600) -> UpcomingEvent? {
        let timed = events.filter { !$0.isAllDay && $0.end > now }
        let ongoing = timed.filter { $0.isOngoing(at: now) }
        if let current = ongoing.max(by: { $0.start < $1.start }) {
            return current
        }
        return timed
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= lookahead }
            .min(by: { $0.start < $1.start })
    }
}

/// Reads calendar events. The EventKit implementation is `EventKitUpcomingEventProvider`; tests use
/// `MockUpcomingEventProvider`, so they never touch the user's calendars or trigger a permission prompt.
public protocol UpcomingEventProviding: AnyObject, Sendable {
    func accessState() -> CalendarAccessState
    func requestAccess() async -> Bool
    func events(from start: Date, to end: Date) -> [UpcomingEvent]
}

// MARK: - Island Tabs

public extension ZenithIslandState {
    /// The tabs the expanded island offers, in order.
    static func availableTabs(hasTrack: Bool, hasShelfItems: Bool, showsWidgets: Bool) -> [IslandExpandedTab] {
        var tabs: [IslandExpandedTab] = []
        if hasTrack { tabs.append(.nowPlaying) }
        if showsWidgets { tabs.append(.widgets) }
        if hasShelfItems { tabs.append(.shelf) }
        return tabs
    }

    /// The tab to show: the shelf while a file is dragged over (it is the drop target), else the chosen tab if it
    /// exists, else the first one there is. With nothing at all, the (empty) shelf, which explains how to use it.
    static func resolvedTab(
        active: IslandExpandedTab,
        hasTrack: Bool,
        hasShelfItems: Bool,
        showsWidgets: Bool,
        isDropTargeted: Bool
    ) -> IslandExpandedTab {
        if isDropTargeted { return .shelf }
        let tabs = availableTabs(hasTrack: hasTrack, hasShelfItems: hasShelfItems, showsWidgets: showsWidgets)
        if tabs.contains(active) { return active }
        return tabs.first ?? .shelf
    }

    /// Something to show next to the notch while the island is closed: a running timer or playing media.
    var hasCompactActivity: Bool {
        focusTimer != nil || nowPlayingTrack?.isPlaying == true
    }
}

// MARK: - Widget Settings

/// Which island widgets are on, and the timer lengths. Saved in `UserDefaults`.
@MainActor
public final class IslandWidgetSettings: ObservableObject {
    public static let shared = IslandWidgetSettings()

    public enum Keys {
        public static let showTimer = "zenith_island_show_timer"
        public static let showCalendar = "zenith_island_show_calendar"
        public static let showNetwork = "zenith_island_show_network"
        public static let focusMinutes = "zenith_island_focus_minutes"
        public static let breakMinutes = "zenith_island_break_minutes"
        public static let showLevelHUD = "zenith_island_show_level_hud"
        public static let hideInFullscreen = "zenith_island_hide_in_fullscreen"
        public static let scrollGestures = "zenith_island_scroll_gestures"
        public static let hoverOpenDelay = "zenith_island_hover_open_delay"
    }

    public static let focusRange = 5...120
    public static let breakRange = 1...60
    public static let defaultFocusMinutes = 25
    public static let defaultBreakMinutes = 5
    /// Seconds the pointer rests on the closed island before it opens.
    public static let hoverDelayRange: ClosedRange<Double> = 0.1...1.0
    public static let hoverDelayStep = 0.05
    public static let defaultHoverOpenDelay = 0.25

    /// `seconds` within `hoverDelayRange`, on a 0.05 s step. A value that is not a number gives the default.
    public static func clampedHoverDelay(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultHoverOpenDelay }
        let stepped = (seconds / hoverDelayStep).rounded() * hoverDelayStep
        let clamped = min(max(stepped, hoverDelayRange.lowerBound), hoverDelayRange.upperBound)
        // Two decimals, so 0.15 is stored and compared as 0.15, not 0.15000000000000002.
        return (clamped * 100).rounded() / 100
    }

    @Published public var showTimer: Bool {
        didSet { save(showTimer, Keys.showTimer); syncIsland() }
    }

    @Published public var showCalendar: Bool {
        didSet { save(showCalendar, Keys.showCalendar); syncIsland() }
    }

    @Published public var showNetwork: Bool {
        didSet { save(showNetwork, Keys.showNetwork); syncIsland() }
    }

    /// Volume and brightness changes appear on the island.
    @Published public var showLevelHUD: Bool {
        didSet { save(showLevelHUD, Keys.showLevelHUD); syncIsland() }
    }

    /// The island is taken away while a full-screen app has the display.
    @Published public var hideInFullscreen: Bool {
        didSet { save(hideInFullscreen, Keys.hideInFullscreen); syncIsland() }
    }

    /// Swipes on the island open, close and change track.
    @Published public var scrollGestures: Bool {
        didSet { save(scrollGestures, Keys.scrollGestures); syncIsland() }
    }

    /// How long the pointer must rest on the closed island before it opens, in seconds.
    @Published public var hoverOpenDelay: Double {
        didSet {
            let clamped = Self.clampedHoverDelay(hoverOpenDelay)
            if clamped != hoverOpenDelay { hoverOpenDelay = clamped }
            save(clamped, Keys.hoverOpenDelay)
            syncIsland()
        }
    }

    @Published public var focusMinutes: Int {
        didSet {
            let clamped = min(max(focusMinutes, Self.focusRange.lowerBound), Self.focusRange.upperBound)
            if clamped != focusMinutes { focusMinutes = clamped }
            save(clamped, Keys.focusMinutes)
        }
    }

    @Published public var breakMinutes: Int {
        didSet {
            let clamped = min(max(breakMinutes, Self.breakRange.lowerBound), Self.breakRange.upperBound)
            if clamped != breakMinutes { breakMinutes = clamped }
            save(clamped, Keys.breakMinutes)
        }
    }

    private let userDefaults: UserDefaults
    private weak var island: ZenithIslandState?

    public init(userDefaults: UserDefaults = .standard, island: ZenithIslandState? = .shared) {
        self.userDefaults = userDefaults
        self.island = island
        self.showTimer = userDefaults.object(forKey: Keys.showTimer) as? Bool ?? true
        self.showCalendar = userDefaults.object(forKey: Keys.showCalendar) as? Bool ?? false
        self.showNetwork = userDefaults.object(forKey: Keys.showNetwork) as? Bool ?? false
        self.showLevelHUD = userDefaults.object(forKey: Keys.showLevelHUD) as? Bool ?? true
        self.hideInFullscreen = userDefaults.object(forKey: Keys.hideInFullscreen) as? Bool ?? true
        self.scrollGestures = userDefaults.object(forKey: Keys.scrollGestures) as? Bool ?? true
        let delay = userDefaults.object(forKey: Keys.hoverOpenDelay) as? Double ?? Self.defaultHoverOpenDelay
        self.hoverOpenDelay = Self.clampedHoverDelay(delay)
        let focus = userDefaults.object(forKey: Keys.focusMinutes) as? Int ?? Self.defaultFocusMinutes
        self.focusMinutes = min(max(focus, Self.focusRange.lowerBound), Self.focusRange.upperBound)
        let pause = userDefaults.object(forKey: Keys.breakMinutes) as? Int ?? Self.defaultBreakMinutes
        self.breakMinutes = min(max(pause, Self.breakRange.lowerBound), Self.breakRange.upperBound)
        syncIsland()
    }

    /// Whether the island has a Widgets tab at all.
    public var showsAnyWidget: Bool {
        showTimer || showCalendar || showNetwork
    }

    public func resetToDefaults() {
        showTimer = true
        showCalendar = false
        showNetwork = false
        showLevelHUD = true
        hideInFullscreen = true
        scrollGestures = true
        hoverOpenDelay = Self.defaultHoverOpenDelay
        focusMinutes = Self.defaultFocusMinutes
        breakMinutes = Self.defaultBreakMinutes
    }

    private func save(_ value: Any, _ key: String) {
        userDefaults.set(value, forKey: key)
    }

    private func syncIsland() {
        island?.showsTimerWidget = showTimer
        island?.showsCalendarWidget = showCalendar
        island?.showsNetworkWidget = showNetwork
        island?.showsLevelHUD = showLevelHUD
        island?.allowsScrollGestures = scrollGestures
        island?.hoverOpenDelay = hoverOpenDelay
        if island?.hidesInFullscreen != hideInFullscreen { island?.hidesInFullscreen = hideInFullscreen }
    }
}
