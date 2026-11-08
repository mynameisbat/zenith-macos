import Testing
import Foundation
@testable import ZenithCore

/// A clock the tests move by hand.
private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@Suite("Island widgets: focus timer, next calendar event, tabs and settings")
@MainActor
struct IslandWidgetsTests {

    // MARK: Focus timer

    @Test("IW-01: A focus timer counts down from an end date and shows in the island")
    func testTimerCountsDown() {
        let clock = TestClock()
        let island = ZenithIslandState()
        let timer = FocusTimerService(now: { clock.date }, island: island, autoTick: false)

        timer.start(.focus, minutes: 25)
        #expect(timer.snapshot == FocusTimerSnapshot(mode: .focus, isPaused: false, duration: 1_500, remaining: 1_500))
        #expect(island.focusTimer == timer.snapshot)
        #expect(island.hasCompactActivity)
        #expect(timer.isRunning)

        clock.advance(61)
        timer.tick()
        #expect(timer.snapshot?.remaining == 1_439)
        #expect(timer.snapshot?.remainingText == "23:59")
        #expect(abs((timer.snapshot?.progress ?? 0) - 61.0 / 1_500) < 0.0001)
    }

    @Test("IW-02: Pausing freezes the time left; resuming carries on from there")
    func testPauseAndResume() {
        let clock = TestClock()
        let island = ZenithIslandState()
        let timer = FocusTimerService(now: { clock.date }, island: island, autoTick: false)
        timer.start(.focus, minutes: 10)

        clock.advance(120)
        timer.pause()
        #expect(timer.snapshot?.isPaused == true)
        #expect(timer.snapshot?.remaining == 480)
        #expect(!timer.isRunning)

        clock.advance(3_600) // paused for an hour: nothing passes
        timer.tick()
        #expect(timer.snapshot?.remaining == 480)

        timer.togglePause()
        #expect(timer.snapshot?.isPaused == false)
        clock.advance(30)
        timer.tick()
        #expect(timer.snapshot?.remaining == 450)

        timer.extend(byMinutes: 1)
        #expect(timer.snapshot?.remaining == 510)
        #expect(timer.snapshot?.duration == 660)
    }

    @Test("IW-03: Running out shows an alert, counts the session and calls onFinish; stopping does not")
    func testFinishAndStop() {
        let clock = TestClock()
        let island = ZenithIslandState()
        let timer = FocusTimerService(now: { clock.date }, island: island, autoTick: false)
        var finished: [FocusTimerMode] = []
        timer.onFinish = { finished.append($0) }

        timer.start(.focus, minutes: 1)
        clock.advance(60)
        timer.tick()
        #expect(timer.snapshot == nil)
        #expect(island.focusTimer == nil)
        #expect(finished == [.focus])
        #expect(timer.focusSessionsToday == 1)
        #expect(timer.lastFinishedMode == .focus)
        #expect(island.activeAlert?.title == "Focus session done")
        // VoiceOver users hear it too
        #expect(AccessibilityAnnouncer.recentAnnouncements.last == "Focus session done. Time for a short break")

        timer.start(.shortBreak, minutes: 5)
        timer.stop()
        #expect(timer.snapshot == nil)
        #expect(finished == [.focus])
        #expect(timer.focusSessionsToday == 1)

        // A new day starts the count again
        clock.advance(86_400)
        #expect(timer.focusSessionsToday == 0)
    }

    @Test("IW-04: Time left is written m:ss, or h:mm:ss past an hour, rounded up")
    func testFormatting() {
        #expect(FocusTimerSnapshot.format(1_500) == "25:00")
        #expect(FocusTimerSnapshot.format(599.2) == "10:00")
        #expect(FocusTimerSnapshot.format(5) == "0:05")
        #expect(FocusTimerSnapshot.format(0) == "0:00")
        #expect(FocusTimerSnapshot.format(-3) == "0:00")
        #expect(FocusTimerSnapshot.format(3_900) == "1:05:00")
    }

    // MARK: Calendar

    private static func event(_ id: String, start: TimeInterval, length: TimeInterval = 1_800, allDay: Bool = false, now: Date) -> UpcomingEvent {
        UpcomingEvent(id: id, title: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + length), isAllDay: allDay)
    }

    @Test("IW-05: The next event is the one going on, else the soonest within the look-ahead; all-day ones are skipped")
    func testNextEventSelection() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = Self.event("ended", start: -3_600, length: 1_800, now: now)
        let allDay = Self.event("allday", start: -7_200, length: 86_400, allDay: true, now: now)
        let soon = Self.event("soon", start: 900, now: now)
        let later = Self.event("later", start: 7_200, now: now)
        let far = Self.event("far", start: 20 * 3_600, now: now)
        let ongoing = Self.event("ongoing", start: -600, length: 3_600, now: now)

        #expect(UpcomingEvent.next(from: [ended, allDay, later, soon, far], now: now)?.id == "soon")
        #expect(UpcomingEvent.next(from: [soon, ongoing, later], now: now)?.id == "ongoing")
        #expect(UpcomingEvent.next(from: [ended, allDay, far], now: now) == nil)
        #expect(UpcomingEvent.next(from: [far], now: now, lookahead: 24 * 3_600)?.id == "far")
    }

    @Test("IW-06: The event is described relative to now")
    func testRelativeDescription() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 08:00 UTC
        func text(_ start: TimeInterval, _ length: TimeInterval = 1_800) -> String {
            Self.event("e", start: start, length: length, now: now).relativeDescription(now: now, calendar: calendar, locale: locale)
        }
        #expect(text(300) == "In 5 min")
        #expect(text(59) == "In 1 min")
        #expect(text(3_600) == "In 1 h")
        #expect(text(4_800) == "In 1 h 20 min")
        #expect(text(4 * 3_600) == "At 12:00")
        #expect(text(-600, 3_600) == "Now · until 08:50")
        #expect(text(20 * 3_600) == "Tomorrow at 04:00")
    }

    @Test("IW-07: The calendar model shows the next event, asks for access only when told, and clears when stopped")
    func testCalendarModel() async {
        let clock = TestClock()
        let island = ZenithIslandState()
        let provider = MockUpcomingEventProvider(state: .notDetermined, events: [
            Self.event("standup", start: 600, now: clock.date)
        ])
        let model = CalendarWidgetModel(provider: provider, now: { clock.date }, island: island)

        model.start(autoRefresh: false)
        #expect(model.access == .notDetermined)
        #expect(model.nextEvent == nil)
        #expect(provider.requestCount == 0)

        let granted = await model.requestAccess()
        #expect(granted)
        #expect(provider.requestCount == 1)
        #expect(island.calendarAccess == .granted)
        #expect(model.nextEvent?.title == "standup")
        #expect(island.upcomingEvent?.title == "standup")

        // Once it is over, nothing is left to show
        clock.advance(3_600)
        model.refresh()
        #expect(model.nextEvent == nil)

        provider.events = [Self.event("review", start: 300, now: clock.date)]
        model.refresh()
        #expect(island.upcomingEvent?.title == "review")
        model.stop()
        #expect(island.upcomingEvent == nil)
        #expect(!model.isStarted)
    }

    @Test("IW-08: A refused calendar shows nothing")
    func testCalendarDenied() async {
        let island = ZenithIslandState()
        let provider = MockUpcomingEventProvider(state: .notDetermined, events: [
            Self.event("secret", start: 600, now: Date())
        ], grantsOnRequest: false)
        let model = CalendarWidgetModel(provider: provider, island: island)
        let granted = await model.requestAccess()
        #expect(!granted)
        #expect(model.access == .denied)
        #expect(island.upcomingEvent == nil)
    }

    // MARK: Tabs and settings

    @Test("IW-09: The expanded island picks a tab that exists, and the shelf while a file is dragged over")
    func testTabResolution() {
        typealias S = ZenithIslandState
        #expect(S.availableTabs(hasTrack: true, hasShelfItems: true, showsWidgets: true) == [.nowPlaying, .widgets, .shelf])
        #expect(S.availableTabs(hasTrack: false, hasShelfItems: false, showsWidgets: false) == [])

        // Default tab is the shelf; with no shelf items Now Playing comes first, as before widgets existed
        #expect(S.resolvedTab(active: .shelf, hasTrack: true, hasShelfItems: false, showsWidgets: true, isDropTargeted: false) == .nowPlaying)
        #expect(S.resolvedTab(active: .shelf, hasTrack: false, hasShelfItems: false, showsWidgets: true, isDropTargeted: false) == .widgets)
        #expect(S.resolvedTab(active: .shelf, hasTrack: true, hasShelfItems: true, showsWidgets: true, isDropTargeted: false) == .shelf)
        #expect(S.resolvedTab(active: .widgets, hasTrack: true, hasShelfItems: true, showsWidgets: true, isDropTargeted: false) == .widgets)
        #expect(S.resolvedTab(active: .widgets, hasTrack: false, hasShelfItems: false, showsWidgets: false, isDropTargeted: false) == .shelf)
        #expect(S.resolvedTab(active: .widgets, hasTrack: true, hasShelfItems: false, showsWidgets: true, isDropTargeted: true) == .shelf)
    }

    @Test("IW-10: Widget settings are saved, clamped, and passed to the island")
    func testWidgetSettings() {
        let defaults = TestDefaults.make("IslandWidgetsTests_\(UUID().uuidString)")!
        let island = ZenithIslandState()
        let settings = IslandWidgetSettings(userDefaults: defaults, island: island)
        #expect(settings.showTimer)
        #expect(!settings.showCalendar)
        #expect(settings.focusMinutes == 25)
        #expect(island.showsTimerWidget)
        #expect(!island.showsCalendarWidget)
        #expect(island.showsWidgets)

        settings.showCalendar = true
        settings.focusMinutes = 500
        settings.breakMinutes = 0
        #expect(settings.focusMinutes == IslandWidgetSettings.focusRange.upperBound)
        #expect(settings.breakMinutes == IslandWidgetSettings.breakRange.lowerBound)
        #expect(island.showsCalendarWidget)

        let reloaded = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(reloaded.showCalendar)
        #expect(reloaded.focusMinutes == 120)
        #expect(reloaded.breakMinutes == 1)

        reloaded.showTimer = false
        reloaded.showCalendar = false
        #expect(!reloaded.showsAnyWidget)
        reloaded.resetToDefaults()
        #expect(reloaded.showTimer && !reloaded.showCalendar && reloaded.focusMinutes == 25 && reloaded.breakMinutes == 5)
    }

    @Test("IW-11: The network speed widget is off by default, saved, and counts as a widget for the tab")
    func testNetworkWidgetSetting() {
        let defaults = TestDefaults.make("IslandWidgetsTests_\(UUID().uuidString)")!
        let island = ZenithIslandState()
        let settings = IslandWidgetSettings(userDefaults: defaults, island: island)
        #expect(!settings.showNetwork)
        #expect(!island.showsNetworkWidget)

        settings.showTimer = false
        settings.showCalendar = false
        #expect(!settings.showsAnyWidget)
        #expect(!island.showsWidgets)

        settings.showNetwork = true
        #expect(settings.showsAnyWidget)
        #expect(island.showsNetworkWidget && island.showsWidgets)

        let reloaded = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(reloaded.showNetwork)
        reloaded.resetToDefaults()
        #expect(!reloaded.showNetwork)
    }
}
