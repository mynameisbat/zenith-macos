import Foundation
import EventKit
import AppKit

/// Reads events with EventKit. Creating it does not ask for anything; only `requestAccess()` shows the prompt.
public final class EventKitUpcomingEventProvider: UpcomingEventProviding, @unchecked Sendable {
    private let store = EKEventStore()

    /// The Info.plist keys macOS needs before it can show the Calendar prompt. Without them (e.g. under `swift run`)
    /// asking would end the process, so access is reported as unavailable instead.
    public static let usageDescriptionKeys = ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"]

    public init() {}

    private var hasUsageDescription: Bool {
        Self.usageDescriptionKeys.allSatisfy { Bundle.main.object(forInfoDictionaryKey: $0) != nil }
    }

    public func accessState() -> CalendarAccessState {
        guard hasUsageDescription else { return .unavailable }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> Bool {
        guard hasUsageDescription else { return false }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func events(from start: Date, to end: Date) -> [UpcomingEvent] {
        guard accessState() == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            var components: [Double]?
            if let color = event.calendar?.color?.usingColorSpace(.sRGB) {
                components = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
            }
            return UpcomingEvent(
                id: event.calendarItemIdentifier + "@" + String(event.startDate.timeIntervalSince1970),
                title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled Event",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                colorComponents: components
            )
        }
    }
}

/// The next calendar event for the island. Refreshes once a minute and whenever the calendar database changes, only
/// while it is started (the Calendar widget is on).
@MainActor
public final class CalendarWidgetModel: ObservableObject {
    public static let shared = CalendarWidgetModel()

    @Published public private(set) var access: CalendarAccessState = .notDetermined
    @Published public private(set) var nextEvent: UpcomingEvent?

    private let provider: UpcomingEventProviding
    private let now: () -> Date
    private weak var island: ZenithIslandState?
    private var refreshTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?

    /// How far ahead to look for the next event.
    public static let lookahead: TimeInterval = 12 * 3_600

    public init(
        provider: UpcomingEventProviding = EventKitUpcomingEventProvider(),
        now: @escaping () -> Date = Date.init,
        island: ZenithIslandState? = .shared
    ) {
        self.provider = provider
        self.now = now
        self.island = island
    }

    public var isStarted: Bool {
        refreshTask != nil
    }

    /// Reads the access state and the next event now.
    public func refresh() {
        let state = provider.accessState()
        access = state
        island?.calendarAccess = state
        let event: UpcomingEvent?
        if state == .granted {
            let current = now()
            // Start a day back so an event that is still going on is found.
            let events = provider.events(from: current.addingTimeInterval(-86_400), to: current.addingTimeInterval(Self.lookahead))
            event = UpcomingEvent.next(from: events, now: current, lookahead: Self.lookahead)
        } else {
            event = nil
        }
        nextEvent = event
        if island?.upcomingEvent != event {
            island?.upcomingEvent = event
        }
    }

    /// Asks for calendar access (macOS shows its prompt the first time), then refreshes.
    @discardableResult
    public func requestAccess() async -> Bool {
        let granted = await provider.requestAccess()
        refresh()
        return granted
    }

    /// Starts refreshing: now, every minute, and when the calendars change.
    public func start(autoRefresh: Bool = true) {
        refresh()
        guard autoRefresh, refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// Stops refreshing and forgets the event (the widget was turned off).
    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
        nextEvent = nil
        island?.upcomingEvent = nil
    }
}
